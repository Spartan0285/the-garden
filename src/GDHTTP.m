#import "GDHTTP.h"
#include <curl/curl.h>
#include <pthread.h>
#include <stdio.h>
#include <unistd.h>
#include <sys/stat.h>

#define GD_HTTP_MAX_ACTIVE 4

static CURLSH *gShare;
static pthread_mutex_t gShareLocks[CURL_LOCK_DATA_LAST];
static pthread_mutex_t gSlotLock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t gSlotCond = PTHREAD_COND_INITIALIZER;
static int gActive;
static NSString *gCABundle;

static void shareLock(CURL *h, curl_lock_data d, curl_lock_access a, void *u)
{
    pthread_mutex_lock(&gShareLocks[d]);
}

static void shareUnlock(CURL *h, curl_lock_data d, void *u)
{
    pthread_mutex_unlock(&gShareLocks[d]);
}

static void GDHTTPSetup(void)
{
    static BOOL done;
    int i;
    if (done)
        return;
    done = YES;
    curl_global_init(CURL_GLOBAL_ALL);
    for (i = 0; i < CURL_LOCK_DATA_LAST; i++)
        pthread_mutex_init(&gShareLocks[i], NULL);
    gShare = curl_share_init();
    curl_share_setopt(gShare, CURLSHOPT_LOCKFUNC, shareLock);
    curl_share_setopt(gShare, CURLSHOPT_UNLOCKFUNC, shareUnlock);
    curl_share_setopt(gShare, CURLSHOPT_SHARE, CURL_LOCK_DATA_COOKIE);
    curl_share_setopt(gShare, CURLSHOPT_SHARE, CURL_LOCK_DATA_DNS);
    curl_share_setopt(gShare, CURLSHOPT_SHARE, CURL_LOCK_DATA_SSL_SESSION);

    /* The app bundle's copy; a command-line tool finds it next to itself. */
    gCABundle = [[[NSBundle mainBundle] pathForResource:@"cacert" ofType:@"pem"] retain];
    if (gCABundle == nil) {
        NSString *exe = [[[NSProcessInfo processInfo] arguments] objectAtIndex:0];
        NSString *p = [[exe stringByDeletingLastPathComponent]
                          stringByAppendingPathComponent:@"cacert.pem"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:p])
            gCABundle = [p retain];
    }
}

NSString *GDFormEncode(NSString *s)
{
    NSString *r = (NSString *)CFURLCreateStringByAddingPercentEscapes(
        NULL, (CFStringRef)s, NULL, CFSTR("!*'();:@&=+$,/?%#[] "),
        kCFStringEncodingUTF8);
    return [r autorelease];
}

@implementation GDHTTPRequest

+ (void) initialize
{
    if (self == [GDHTTPRequest class])
        GDHTTPSetup();
}

+ (GDHTTPRequest *) requestWithURL:(NSURL *)u
{
    GDHTTPRequest *r = [[[self alloc] init] autorelease];
    r->url = [u retain];
    return r;
}

+ (NSString *) userAgent
{
    static NSString *ua;
    if (ua == nil) {
        NSDictionary *sv = [NSDictionary dictionaryWithContentsOfFile:
                               @"/System/Library/CoreServices/SystemVersion.plist"];
        NSString *v = [sv objectForKey:@"ProductVersion"];
#if defined(__ppc__)
        NSString *cpu = @"PPC";
#else
        NSString *cpu = @"Intel";
#endif
        ua = [[NSString stringWithFormat:@"TheGarden/0.1 (Macintosh; %@ Mac OS X %@)",
               cpu, v ? v : @"10.4"] retain];
    }
    return ua;
}

- (void) dealloc
{
    [url release];
    [postBody release];
    [destinationPath release];
    [userInfo release];
    [data release];
    [error release];
    [effectiveURL release];
    [contentType release];
    [super dealloc];
}

- (void) setPostBody:(NSData *)body { [postBody autorelease]; postBody = [body copy]; }
- (void) setDestinationPath:(NSString *)p { [destinationPath autorelease]; destinationPath = [p copy]; }
- (void) setDelegate:(id)d { delegate = d; }
- (id) delegate { return delegate; }
- (void) setTag:(int)t { tag = t; }
- (int) tag { return tag; }
- (void) setUserInfo:(id)info { [userInfo autorelease]; userInfo = [info retain]; }
- (id) userInfo { return userInfo; }
- (NSURL *) url { return url; }
- (NSData *) data { return data; }
- (long) statusCode { return statusCode; }
- (NSString *) error { return error; }
- (NSString *) effectiveURL { return effectiveURL; }
- (NSString *) contentType { return contentType; }
- (BOOL) isCancelled { return cancelled != 0; }
- (BOOL) isFinished { return finished; }
- (long long) resumedFrom { return resumedFrom; }
- (BOOL) isTransientFailure
{
    return curlCode == CURLE_OPERATION_TIMEDOUT || curlCode == CURLE_PARTIAL_FILE ||
           curlCode == CURLE_RECV_ERROR || curlCode == CURLE_SEND_ERROR ||
           curlCode == CURLE_GOT_NOTHING || curlCode == CURLE_COULDNT_CONNECT ||
           curlCode == CURLE_SSL_CONNECT_ERROR || curlCode == CURLE_COULDNT_RESOLVE_HOST ||
           (statusCode >= 500 && statusCode < 600);
}
- (void) cancel { cancelled = 1; }

- (NSString *) string
{
    NSString *s;
    if (data == nil)
        return nil;
    s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (s == nil)
        s = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    return [s autorelease];
}

static size_t writeMemory(char *p, size_t sz, size_t n, void *ud)
{
    GDHTTPRequest *r = ud;
    if (r->cancelled)
        return 0;
    [r->data appendBytes:p length:sz * n];
    return sz * n;
}

static size_t writeFile(char *p, size_t sz, size_t n, void *ud)
{
    void **ctx = ud;
    GDHTTPRequest *r = ctx[0];
    if (r->cancelled)
        return 0;
    return fwrite(p, sz, n, (FILE *)ctx[1]) * sz;
}

- (void) reportProgress:(NSArray *)a
{
    if (!cancelled && [delegate respondsToSelector:@selector(httpRequest:receivedBytes:of:)])
        [delegate httpRequest:self
                receivedBytes:[[a objectAtIndex:0] longLongValue]
                           of:[[a objectAtIndex:1] longLongValue]];
}

static int progress(void *ud, curl_off_t dltotal, curl_off_t dlnow,
                    curl_off_t ultotal, curl_off_t ulnow)
{
    GDHTTPRequest *r = ud;
    double now;
    if (r->cancelled)
        return 1;
    now = CFAbsoluteTimeGetCurrent();
    if (r->destinationPath != nil && now - r->lastProgress > 0.25) {
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
        r->lastProgress = now;
        [r performSelectorOnMainThread:@selector(reportProgress:)
                            withObject:[NSArray arrayWithObjects:
                                           [NSNumber numberWithLongLong:dlnow + r->resumedFrom],
                                           [NSNumber numberWithLongLong:dltotal ? dltotal + r->resumedFrom : 0],
                                           nil]
                         waitUntilDone:NO];
        [pool release];
    }
    return 0;
}

- (BOOL) perform
{
    char errbuf[CURL_ERROR_SIZE];
    struct curl_slist *headers = NULL;
    FILE *fp = NULL;
    NSString *partial = nil;
    void *fctx[2];
    CURL *h;
    CURLcode rc;
    char *s = NULL;

    errbuf[0] = 0;
    [data release];
    data = [[NSMutableData alloc] init];

    h = curl_easy_init();
    curl_easy_setopt(h, CURLOPT_SHARE, gShare);
    curl_easy_setopt(h, CURLOPT_COOKIEFILE, "");     /* cookie engine on */
    curl_easy_setopt(h, CURLOPT_URL, [[url absoluteString] UTF8String]);
    curl_easy_setopt(h, CURLOPT_ERRORBUFFER, errbuf);
    curl_easy_setopt(h, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(h, CURLOPT_FOLLOWLOCATION, 1L);
    curl_easy_setopt(h, CURLOPT_MAXREDIRS, 10L);
    curl_easy_setopt(h, CURLOPT_HTTP_VERSION, (long)CURL_HTTP_VERSION_1_1);
    curl_easy_setopt(h, CURLOPT_ACCEPT_ENCODING, "");
    curl_easy_setopt(h, CURLOPT_USERAGENT, [[GDHTTPRequest userAgent] UTF8String]);
    curl_easy_setopt(h, CURLOPT_CONNECTTIMEOUT, 30L);
    curl_easy_setopt(h, CURLOPT_LOW_SPEED_LIMIT, 1L);
    curl_easy_setopt(h, CURLOPT_LOW_SPEED_TIME, 90L);
    curl_easy_setopt(h, CURLOPT_SSL_VERIFYPEER, 1L);
    curl_easy_setopt(h, CURLOPT_SSL_VERIFYHOST, 2L);
    curl_easy_setopt(h, CURLOPT_SSLVERSION, (long)CURL_SSLVERSION_TLSv1_2);
    if (gCABundle != nil)
        curl_easy_setopt(h, CURLOPT_CAINFO, [gCABundle fileSystemRepresentation]);
    curl_easy_setopt(h, CURLOPT_XFERINFOFUNCTION, progress);
    curl_easy_setopt(h, CURLOPT_XFERINFODATA, self);
    curl_easy_setopt(h, CURLOPT_NOPROGRESS, 0L);
    headers = curl_slist_append(headers, "Expect:");
    headers = curl_slist_append(headers, "Accept-Language: en");
    curl_easy_setopt(h, CURLOPT_HTTPHEADER, headers);

    if (postBody != nil) {
        curl_easy_setopt(h, CURLOPT_POSTFIELDS, [postBody bytes]);
        curl_easy_setopt(h, CURLOPT_POSTFIELDSIZE_LARGE, (curl_off_t)[postBody length]);
    }

    if (destinationPath != nil) {
        /* name.part until complete, so a half download never looks finished */
        struct stat st;
        partial = [destinationPath stringByAppendingPathExtension:@"part"];
        resumedFrom = 0;
        if (stat([partial fileSystemRepresentation], &st) == 0 && st.st_size > 0)
            resumedFrom = st.st_size;
        fp = fopen([partial fileSystemRepresentation], resumedFrom ? "ab" : "wb");
        if (fp == NULL) {
            error = [[NSString stringWithFormat:@"Cannot write %@", partial] retain];
            curl_slist_free_all(headers);
            curl_easy_cleanup(h);
            return NO;
        }
        fctx[0] = self;
        fctx[1] = fp;
        curl_easy_setopt(h, CURLOPT_WRITEFUNCTION, writeFile);
        curl_easy_setopt(h, CURLOPT_WRITEDATA, fctx);
        if (resumedFrom)
            curl_easy_setopt(h, CURLOPT_RESUME_FROM_LARGE, (curl_off_t)resumedFrom);
    } else {
        curl_easy_setopt(h, CURLOPT_WRITEFUNCTION, writeMemory);
        curl_easy_setopt(h, CURLOPT_WRITEDATA, self);
    }

    rc = curl_easy_perform(h);
    if (rc == CURLE_RANGE_ERROR && resumedFrom && fp != NULL) {
        /* The server ignores Range: start this file over. */
        fclose(fp);
        fp = fopen([partial fileSystemRepresentation], "wb");
        resumedFrom = 0;
        fctx[1] = fp;
        curl_easy_setopt(h, CURLOPT_RESUME_FROM_LARGE, (curl_off_t)0);
        rc = curl_easy_perform(h);
    }
    curlCode = rc;
    curl_easy_getinfo(h, CURLINFO_RESPONSE_CODE, &statusCode);
    if (curl_easy_getinfo(h, CURLINFO_EFFECTIVE_URL, &s) == CURLE_OK && s)
        effectiveURL = [[NSString alloc] initWithUTF8String:s];
    s = NULL;
    if (curl_easy_getinfo(h, CURLINFO_CONTENT_TYPE, &s) == CURLE_OK && s)
        contentType = [[NSString alloc] initWithUTF8String:s];

    if (cancelled)
        error = [@"Cancelled" retain];
    else if (rc != CURLE_OK)
        error = [[NSString stringWithFormat:@"%s", errbuf[0] ? errbuf : curl_easy_strerror(rc)] retain];
    else if (statusCode == 416 && resumedFrom > 0)
        ;   /* the .part was already whole; the caller's checksum decides */
    else if (statusCode < 200 || statusCode >= 300)
        error = [[NSString stringWithFormat:@"HTTP %ld", statusCode] retain];

    if (fp != NULL) {
        fclose(fp);
        /* On failure the .part stays, so the next attempt resumes it. */
        if (error == nil) {
            [[NSFileManager defaultManager] removeFileAtPath:destinationPath handler:nil];
            rename([partial fileSystemRepresentation], [destinationPath fileSystemRepresentation]);
        } else if (statusCode == 404 || statusCode == 403 || statusCode == 410) {
            unlink([partial fileSystemRepresentation]);
        }
    }
    curl_slist_free_all(headers);
    curl_easy_cleanup(h);
    return error == nil;
}

- (BOOL) startSynchronous
{
    BOOL ok = [self perform];
    finished = YES;
    return ok;
}

- (void) finishOnMain
{
    finished = YES;
    if ([delegate respondsToSelector:@selector(httpRequestDidFinish:)])
        [delegate httpRequestDidFinish:self];
}

- (void) threadMain
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    pthread_mutex_lock(&gSlotLock);
    while (gActive >= GD_HTTP_MAX_ACTIVE)
        pthread_cond_wait(&gSlotCond, &gSlotLock);
    gActive++;
    pthread_mutex_unlock(&gSlotLock);

    if (!cancelled)
        [self perform];
    else
        error = [@"Cancelled" retain];

    pthread_mutex_lock(&gSlotLock);
    gActive--;
    pthread_cond_signal(&gSlotCond);
    pthread_mutex_unlock(&gSlotLock);

    [self performSelectorOnMainThread:@selector(finishOnMain) withObject:nil waitUntilDone:NO];
    [self release];         /* balances the retain in -start */
    [pool release];
}

- (void) start
{
    [self retain];
    [NSThread detachNewThreadSelector:@selector(threadMain) toTarget:self withObject:nil];
}

@end
