#import "GDHTTP.h"
#import "GDAccelerator.h"
#include <curl/curl.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <openssl/evp.h>

/* What to do after an attempt that did not produce the site's answer. */
enum { GDRestartNone = 0, GDRestartDirect, GDRestartRedirect, GDRestartAgain };

static CURLSH *gShare;
static CURLM *gMulti;
static pthread_mutex_t gShareLocks[CURL_LOCK_DATA_LAST];
static NSString *gCABundle;

/* The network thread's queues. */
static pthread_mutex_t gQueueLock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t gQueueCond = PTHREAD_COND_INITIALIZER;
static NSMutableArray *gPending, *gActive, *gCancelled;
static BOOL gThreadStarted;

@interface GDHTTPRequest (Network)
- (BOOL) cacheable;
- (BOOL) preflightCache;
- (BOOL) useCachedBodyAt:(NSString *)path meta:(NSDictionary *)meta;
- (BOOL) useRevalidatedCache;
- (BOOL) useStaleCache;
- (void) storeInCache;
- (BOOL) prepareHandle;
- (void *) easyHandle;
- (void) finishWithCurlCode:(int)code;
- (void) releaseHandle;
- (BOOL) takeRestart;
- (void) deliver;
@end

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

    gMulti = curl_multi_init();
    /* The Garden talks to one site and a handful of mirrors.  Four connections
     * to a host is as much as a store page needs and keeps the site's load
     * where a person browsing would put it; an idle connection costs little
     * even on a 256MB G3. */
    curl_multi_setopt(gMulti, CURLMOPT_MAX_TOTAL_CONNECTIONS, 8L);
    curl_multi_setopt(gMulti, CURLMOPT_MAX_HOST_CONNECTIONS, 4L);
    curl_multi_setopt(gMulti, CURLMOPT_MAXCONNECTS, 12L);

    gPending = [[NSMutableArray alloc] init];
    gActive = [[NSMutableArray alloc] init];
    gCancelled = [[NSMutableArray alloc] init];

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

static NSString *gPageCacheDir;

static NSString *pageCachePath(NSURL *u)
{
    unsigned char d[EVP_MAX_MD_SIZE];
    unsigned int n = 0, i;
    const char *c = [[u absoluteString] UTF8String];
    NSMutableString *h = [NSMutableString string];
    if (gPageCacheDir == nil) {
        NSString *base = [[NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES)
                              objectAtIndex:0] stringByAppendingPathComponent:@"The Garden"];
        [[NSFileManager defaultManager] createDirectoryAtPath:base attributes:nil];
        gPageCacheDir = [[base stringByAppendingPathComponent:@"Pages"] retain];
        [[NSFileManager defaultManager] createDirectoryAtPath:gPageCacheDir attributes:nil];
    }
    EVP_Digest(c, strlen(c), d, &n, EVP_md5(), NULL);
    for (i = 0; i < n; i++)
        [h appendFormat:@"%02x", d[i]];
    return [gPageCacheDir stringByAppendingPathComponent:h];
}

/* Age in seconds of the cached copy, or -1. */
static double cacheAge(NSString *p)
{
    struct stat st;
    if (stat([p fileSystemRepresentation], &st) != 0)
        return -1;
    return difftime(time(NULL), st.st_mtime);
}

NSString *GDFormEncode(NSString *s)
{
    NSString *r = (NSString *)CFURLCreateStringByAddingPercentEscapes(
        NULL, (CFStringRef)s, NULL, CFSTR("!*'();:@&=+$,/?%#[] "),
        kCFStringEncodingUTF8);
    return [r autorelease];
}

/* ---- the network thread -------------------------------------------------
 *
 * One thread, one multi handle, for the life of the process.  Requests are
 * handed over under gQueueLock; curl_multi_wakeup gets the thread out of its
 * poll without waiting for the timeout.
 */

static void engineRun(void)
{
    int running = 0;
    long hostLimit = 4;

    while (1) {
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
        NSArray *starting, *stopping;
        unsigned i;
        int pending = 0;
        long wanted;
        CURLMsg *m;

        pthread_mutex_lock(&gQueueLock);
        while ([gPending count] == 0 && [gCancelled count] == 0 && [gActive count] == 0)
            pthread_cond_wait(&gQueueCond, &gQueueLock);
        starting = [gPending copy];
        stopping = [gCancelled copy];
        [gPending removeAllObjects];
        [gCancelled removeAllObjects];
        pthread_mutex_unlock(&gQueueLock);

        for (i = 0; i < [stopping count]; i++) {
            GDHTTPRequest *r = [stopping objectAtIndex:i];
            if (![gActive containsObject:r])
                continue;
            curl_multi_remove_handle(gMulti, [r easyHandle]);
            [r finishWithCurlCode:CURLE_ABORTED_BY_CALLBACK];
            [r releaseHandle];
            [[r retain] autorelease];
            [gActive removeObject:r];
            [r deliver];
        }
        [stopping release];

        /* Through PowerEmu every request goes to one host, so the usual four
         * connections per host would queue a page's pictures behind it. */
        wanted = [GDAccelerator baseURL] != nil ? 8 : 4;
        if (wanted != hostLimit) {
            hostLimit = wanted;
            curl_multi_setopt(gMulti, CURLMOPT_MAX_HOST_CONNECTIONS, hostLimit);
        }

        for (i = 0; i < [starting count]; i++) {
            GDHTTPRequest *r = [starting objectAtIndex:i];
            if ([r isCancelled]) {
                [r finishWithCurlCode:CURLE_ABORTED_BY_CALLBACK];
                [r deliver];
                continue;
            }
            if ([r preflightCache]) {
                [r deliver];
                continue;
            }
            if ([r prepareHandle] && curl_multi_add_handle(gMulti, [r easyHandle]) == CURLM_OK) {
                [gActive addObject:r];
            } else {
                [r finishWithCurlCode:CURLE_FAILED_INIT];
                [r releaseHandle];
                [r deliver];
            }
        }
        [starting release];

        curl_multi_perform(gMulti, &running);

        while ((m = curl_multi_info_read(gMulti, &pending)) != NULL) {
            GDHTTPRequest *r = nil;
            if (m->msg != CURLMSG_DONE)
                continue;
            curl_easy_getinfo(m->easy_handle, CURLINFO_PRIVATE, &r);
            if (r == nil)
                continue;
            [[r retain] autorelease];
            [r finishWithCurlCode:(int)m->data.result];
            curl_multi_remove_handle(gMulti, m->easy_handle);
            [r releaseHandle];
            [gActive removeObject:r];
            if ([r takeRestart]) {
                /* PowerEmu failed, or answered a redirect it does not follow:
                 * around the loop once more. */
                pthread_mutex_lock(&gQueueLock);
                [gPending addObject:r];
                pthread_mutex_unlock(&gQueueLock);
            } else {
                [r deliver];
            }
        }

        if ([gActive count] > 0) {
            int descriptors = 0;
            curl_multi_poll(gMulti, NULL, 0, 250, &descriptors);
        }
        [pool release];
    }
}

@interface GDHTTPEngine : NSObject
+ (void) threadMain:(id)ignored;
@end

@implementation GDHTTPEngine
+ (void) threadMain:(id)ignored
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    engineRun();
    [pool release];
}
@end

static void engineEnqueue(GDHTTPRequest *r)
{
    pthread_mutex_lock(&gQueueLock);
    [gPending addObject:r];
    if (!gThreadStarted) {
        gThreadStarted = YES;
        [NSThread detachNewThreadSelector:@selector(threadMain:)
                                 toTarget:[GDHTTPEngine class] withObject:nil];
    }
    pthread_cond_signal(&gQueueCond);
    pthread_mutex_unlock(&gQueueLock);
    curl_multi_wakeup(gMulti);
}

static void engineCancel(GDHTTPRequest *r)
{
    if (!gThreadStarted)
        return;
    pthread_mutex_lock(&gQueueLock);
    [gCancelled addObject:r];
    pthread_cond_signal(&gQueueCond);
    pthread_mutex_unlock(&gQueueLock);
    curl_multi_wakeup(gMulti);
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
    [self releaseHandle];
    [url release];
    [postBody release];
    [destinationPath release];
    [partialPath release];
    [userInfo release];
    [data release];
    [error release];
    [effectiveURL release];
    [contentType release];
    [cachedETag release];
    [cachedModified release];
    [newETag release];
    [newModified release];
    [location release];
    [responseHeaders release];
    [requestHeaders release];
    [super dealloc];
}

- (void) setPostBody:(NSData *)body { [postBody autorelease]; postBody = [body copy]; }
- (void) setDestinationPath:(NSString *)p { [destinationPath autorelease]; destinationPath = [p copy]; }
- (void) setUsesSession:(BOOL)flag { usesSession = flag; }
- (void) setWantsResponseHeaders:(BOOL)flag { wantsHeaders = flag; }
- (void) setRequestHeaders:(NSDictionary *)h { [requestHeaders autorelease]; requestHeaders = [h copy]; }
- (NSDictionary *) responseHeaders { return responseHeaders; }
- (BOOL) viaAccelerator { return viaAccelerator; }
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
- (void) setCacheTTL:(double)ttl { cacheTTL = ttl; }
- (BOOL) isFromCache { return fromCache; }
- (BOOL) isStale { return stale; }
- (BOOL) wasRevalidated { return revalidated; }
- (void *) easyHandle { return easy; }

+ (void) purgePageCacheOlderThan:(double)seconds
{
    NSString *dir, *f;
    NSEnumerator *e;
    pageCachePath([NSURL URLWithString:@"about:blank"]);
    dir = gPageCacheDir;
    e = [[[NSFileManager defaultManager] directoryContentsAtPath:dir] objectEnumerator];
    while ((f = [e nextObject]) != nil) {
        NSString *p = [dir stringByAppendingPathComponent:f];
        if (cacheAge(p) > seconds)
            unlink([p fileSystemRepresentation]);
    }
}

- (BOOL) cacheable
{
    return cacheTTL > 0 && postBody == nil && destinationPath == nil;
}

- (BOOL) isTransientFailure
{
    return curlCode == CURLE_OPERATION_TIMEDOUT || curlCode == CURLE_PARTIAL_FILE ||
           curlCode == CURLE_RECV_ERROR || curlCode == CURLE_SEND_ERROR ||
           curlCode == CURLE_GOT_NOTHING || curlCode == CURLE_COULDNT_CONNECT ||
           curlCode == CURLE_SSL_CONNECT_ERROR || curlCode == CURLE_COULDNT_RESOLVE_HOST ||
           (statusCode >= 500 && statusCode < 600);
}

- (void) cancel
{
    cancelled = 1;
    engineCancel(self);
}

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

/* ---- the page cache ---------------------------------------------------- */

/* The body is the file itself; its validators and content type are a small
 * plist beside it, so a copy past its time can be revalidated. */
static NSString *cacheMetaPath(NSString *body)
{
    return [body stringByAppendingPathExtension:@"h"];
}

- (BOOL) useCachedBodyAt:(NSString *)path meta:(NSDictionary *)meta
{
    NSData *d = [NSData dataWithContentsOfFile:path];
    if ([d length] == 0)
        return NO;
    [data release];
    data = [d mutableCopy];
    [contentType release];
    contentType = [[meta objectForKey:@"type"] copy];
    statusCode = 200;
    fromCache = YES;
    return YES;
}

/* Network thread, before the transfer: a fresh copy needs no network at all,
 * and an older one lends us its validators. */
- (BOOL) preflightCache
{
    NSString *path, *metaPath;
    NSDictionary *meta;
    double age;

    if (![self cacheable])
        return NO;
    path = pageCachePath(url);
    age = cacheAge(path);
    if (age < 0)
        return NO;
    metaPath = cacheMetaPath(path);
    meta = [NSDictionary dictionaryWithContentsOfFile:metaPath];
    [cachedETag release];
    cachedETag = [[meta objectForKey:@"etag"] copy];
    [cachedModified release];
    cachedModified = [[meta objectForKey:@"modified"] copy];
    if (age < cacheTTL && [self useCachedBodyAt:path meta:meta]) {
        finished = YES;
        return YES;
    }
    return NO;
}

- (void) storeInCache
{
    NSString *path = pageCachePath(url);
    NSMutableDictionary *meta = [NSMutableDictionary dictionary];
    if (![self cacheable] || [data length] == 0)
        return;
    if (![data writeToFile:path atomically:YES])
        return;
    if (newETag != nil)
        [meta setObject:newETag forKey:@"etag"];
    if (newModified != nil)
        [meta setObject:newModified forKey:@"modified"];
    if (contentType != nil)
        [meta setObject:contentType forKey:@"type"];
    [meta setObject:[url absoluteString] forKey:@"url"];
    [meta writeToFile:cacheMetaPath(path) atomically:YES];
}

/* 304 Not Modified: the copy on disk is current.  Its time starts again, so
 * the next visit inside the TTL costs nothing at all. */
- (BOOL) useRevalidatedCache
{
    NSString *path = pageCachePath(url);
    NSDictionary *meta = [NSDictionary dictionaryWithContentsOfFile:cacheMetaPath(path)];
    if (![self useCachedBodyAt:path meta:meta])
        return NO;
    utimes([path fileSystemRepresentation], NULL);
    utimes([cacheMetaPath(path) fileSystemRepresentation], NULL);
    revalidated = YES;
    [error release];
    error = nil;
    return YES;
}

/* The network failed and there is a copy, however old: show it (offline). */
- (BOOL) useStaleCache
{
    NSString *path;
    NSDictionary *meta;
    if (![self cacheable] || cancelled)
        return NO;
    path = pageCachePath(url);
    if (cacheAge(path) < 0)
        return NO;
    meta = [NSDictionary dictionaryWithContentsOfFile:cacheMetaPath(path)];
    if (![self useCachedBodyAt:path meta:meta])
        return NO;
    [error release];
    error = nil;
    stale = YES;
    return YES;
}

/* ---- libcurl callbacks -------------------------------------------------- */

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
    GDHTTPRequest *r = ud;
    if (r->cancelled || r->file == NULL)
        return 0;
    return fwrite(p, sz, n, (FILE *)r->file) * sz;
}

static void setField(NSString **slot, const char *value, size_t length)
{
    NSString *s = [[NSString alloc] initWithBytes:value length:length
                                         encoding:NSUTF8StringEncoding];
    [*slot release];
    *slot = [[s stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]] copy];
    [s release];
}

static size_t headerLine(char *p, size_t sz, size_t n, void *ud)
{
    GDHTTPRequest *r = ud;
    size_t len = sz * n, i;
    const char *colon;

    if (r->cancelled)
        return 0;
    /* A status line starts a new answer: a redirect's headers are not this
     * one's.  (libcurl follows redirects itself when we are not routed.) */
    if (len >= 5 && strncasecmp(p, "HTTP/", 5) == 0) {
        [r->newETag release]; r->newETag = nil;
        [r->newModified release]; r->newModified = nil;
        [r->location release]; r->location = nil;
        [r->responseHeaders removeAllObjects];
        return len;
    }
    colon = memchr(p, ':', len);
    if (colon == NULL)
        return len;
    i = colon - p;
    if (r->wantsHeaders) {
        NSString *name = [[NSString alloc] initWithBytes:p length:i encoding:NSUTF8StringEncoding];
        NSString *value = nil;
        setField(&value, colon + 1, len - i - 1);
        if (r->responseHeaders == nil)
            r->responseHeaders = [[NSMutableDictionary alloc] init];
        if (name != nil && value != nil)
            [r->responseHeaders setObject:value forKey:name];
        [name release];
        [value release];
    }
    if (i == 4 && strncasecmp(p, "ETag", 4) == 0)
        setField(&r->newETag, colon + 1, len - i - 1);
    else if (i == 13 && strncasecmp(p, "Last-Modified", 13) == 0)
        setField(&r->newModified, colon + 1, len - i - 1);
    else if (i == 8 && strncasecmp(p, "Location", 8) == 0)
        setField(&r->location, colon + 1, len - i - 1);
    return len;
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

/* ---- one attempt -------------------------------------------------------- */

- (BOOL) prepareHandle
{
    struct curl_slist *headers = NULL;
    CURL *h = curl_easy_init();

    if (h == NULL)
        return NO;
    easy = h;
    errorBuffer = calloc(1, CURL_ERROR_SIZE);

    [data release];
    data = [[NSMutableData alloc] init];
    statusCode = 0;

    /* Through PowerEmu only what cannot go wrong there: a download must arrive
     * byte for byte (its MD5 is checked), a form post and the search token
     * need the site's own session, and both are cheap to fetch directly. */
    viaAccelerator = !bypassAccelerator && destinationPath == nil && postBody == nil &&
                     !usesSession && [GDAccelerator shouldRoute:url];

    curl_easy_setopt(h, CURLOPT_PRIVATE, self);
    curl_easy_setopt(h, CURLOPT_SHARE, gShare);
    if (viaAccelerator) {
        /* To PowerEmu, asking for the real URL (an absolute-form request
         * target, as to a forward proxy); PowerEmu makes the TLS connection.
         * No cookie engine: curl would key the site's cookies to PowerEmu's
         * address. */
        NSString *target = [url absoluteString];
        NSString *host = [url host];
        NSRange fragment = [target rangeOfString:@"#"];
        if (fragment.location != NSNotFound)
            target = [target substringToIndex:fragment.location];
        if ([url port] != nil)
            host = [NSString stringWithFormat:@"%@:%@", host, [url port]];
        curl_easy_setopt(h, CURLOPT_URL, [[GDAccelerator baseURL] UTF8String]);
        curl_easy_setopt(h, CURLOPT_REQUEST_TARGET, [target UTF8String]);
        headers = curl_slist_append(headers, [[@"Host: " stringByAppendingString:host] UTF8String]);
        headers = curl_slist_append(headers, [[@"X-PowerEmu-Engine: "
            stringByAppendingString:[GDAccelerator engineHeader]] UTF8String]);
        if ([GDAccelerator token] != nil)
            headers = curl_slist_append(headers, [[@"X-PowerEmu-Token: "
                stringByAppendingString:[GDAccelerator token]] UTF8String]);
        /* PowerEmu hands back a redirect as it is, for us to follow. */
        curl_easy_setopt(h, CURLOPT_FOLLOWLOCATION, 0L);
        curl_easy_setopt(h, CURLOPT_CONNECTTIMEOUT_MS, 1500L);
    } else {
        curl_easy_setopt(h, CURLOPT_COOKIEFILE, "");     /* cookie engine on */
        curl_easy_setopt(h, CURLOPT_URL, [[url absoluteString] UTF8String]);
        curl_easy_setopt(h, CURLOPT_FOLLOWLOCATION, 1L);
        curl_easy_setopt(h, CURLOPT_CONNECTTIMEOUT, 30L);
    }
    curl_easy_setopt(h, CURLOPT_ERRORBUFFER, errorBuffer);
    curl_easy_setopt(h, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(h, CURLOPT_MAXREDIRS, 10L);
    curl_easy_setopt(h, CURLOPT_HTTP_VERSION, (long)CURL_HTTP_VERSION_1_1);
    curl_easy_setopt(h, CURLOPT_ACCEPT_ENCODING, "");
    curl_easy_setopt(h, CURLOPT_USERAGENT, [[GDHTTPRequest userAgent] UTF8String]);
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
    curl_easy_setopt(h, CURLOPT_HEADERFUNCTION, headerLine);
    curl_easy_setopt(h, CURLOPT_HEADERDATA, self);
    headers = curl_slist_append(headers, "Expect:");
    headers = curl_slist_append(headers, "Accept-Language: en");
    if (requestHeaders != nil) {
        NSEnumerator *names = [requestHeaders keyEnumerator];
        NSString *name;
        while ((name = [names nextObject]) != nil)
            headers = curl_slist_append(headers, [[NSString stringWithFormat:@"%@: %@", name,
                          [requestHeaders objectForKey:name]] UTF8String]);
    }
    /* Revalidate rather than download again. */
    if (cachedETag != nil)
        headers = curl_slist_append(headers,
            [[@"If-None-Match: " stringByAppendingString:cachedETag] UTF8String]);
    if (cachedModified != nil)
        headers = curl_slist_append(headers,
            [[@"If-Modified-Since: " stringByAppendingString:cachedModified] UTF8String]);
    headerList = headers;
    curl_easy_setopt(h, CURLOPT_HTTPHEADER, headers);

    if (postBody != nil) {
        curl_easy_setopt(h, CURLOPT_POSTFIELDS, [postBody bytes]);
        curl_easy_setopt(h, CURLOPT_POSTFIELDSIZE_LARGE, (curl_off_t)[postBody length]);
    }

    if (destinationPath != nil) {
        /* name.part until complete, so a half download never looks finished */
        struct stat st;
        [partialPath release];
        partialPath = [[destinationPath stringByAppendingPathExtension:@"part"] retain];
        resumedFrom = 0;
        if (stat([partialPath fileSystemRepresentation], &st) == 0 && st.st_size > 0)
            resumedFrom = st.st_size;
        file = fopen([partialPath fileSystemRepresentation], resumedFrom ? "ab" : "wb");
        if (file == NULL) {
            [error release];
            error = [[NSString stringWithFormat:@"Cannot write %@", partialPath] retain];
            return NO;
        }
        curl_easy_setopt(h, CURLOPT_WRITEFUNCTION, writeFile);
        curl_easy_setopt(h, CURLOPT_WRITEDATA, self);
        if (resumedFrom)
            curl_easy_setopt(h, CURLOPT_RESUME_FROM_LARGE, (curl_off_t)resumedFrom);
    } else {
        curl_easy_setopt(h, CURLOPT_WRITEFUNCTION, writeMemory);
        curl_easy_setopt(h, CURLOPT_WRITEDATA, self);
    }
    return YES;
}

- (void) releaseHandle
{
    if (file != NULL) {
        fclose((FILE *)file);
        file = NULL;
    }
    if (easy != NULL) {
        curl_easy_cleanup((CURL *)easy);
        easy = NULL;
    }
    if (headerList != NULL) {
        curl_slist_free_all((struct curl_slist *)headerList);
        headerList = NULL;
    }
    if (errorBuffer != NULL) {
        free(errorBuffer);
        errorBuffer = NULL;
    }
}

/* Between attempts: should this request run again, and how?  Network thread,
 * after the handle is gone. */
- (BOOL) takeRestart
{
    int what = restart;
    if (what == GDRestartNone || cancelled)
        return NO;
    restart = GDRestartNone;
    if (what == GDRestartAgain) {
        ;                       /* the same request, from the start */
    } else if (what == GDRestartDirect) {
        bypassAccelerator = YES;
        viaAccelerator = NO;
    } else {
        NSURL *next = [NSURL URLWithString:location relativeToURL:url];
        if (next == nil)
            return NO;
        [url release];
        url = [[next absoluteURL] retain];
        redirects++;
        /* validators belong to the page we came from */
        [cachedETag release];
        cachedETag = nil;
        [cachedModified release];
        cachedModified = nil;
    }
    [error release];
    error = nil;
    statusCode = 0;
    return YES;
}

- (void) finishWithCurlCode:(int)code
{
    char *s = NULL;
    CURL *h = (CURL *)easy;

    curlCode = code;
    if (h != NULL) {
        curl_easy_getinfo(h, CURLINFO_RESPONSE_CODE, &statusCode);
        if (curl_easy_getinfo(h, CURLINFO_EFFECTIVE_URL, &s) == CURLE_OK && s) {
            [effectiveURL release];
            effectiveURL = [[NSString alloc] initWithUTF8String:s];
        }
        s = NULL;
        if (curl_easy_getinfo(h, CURLINFO_CONTENT_TYPE, &s) == CURLE_OK && s) {
            [contentType release];
            contentType = [[NSString alloc] initWithUTF8String:s];
        }
    }
    if (viaAccelerator && effectiveURL != nil) {
        /* The transfer went to PowerEmu; the URL the caller asked for is the
         * one it should see. */
        [effectiveURL release];
        effectiveURL = [[url absoluteString] copy];
    }

    [error release];
    error = nil;
    if (cancelled) {
        error = [@"Cancelled" retain];
    } else if (code != CURLE_OK) {
        error = [[NSString stringWithFormat:@"%s",
                     (errorBuffer && errorBuffer[0]) ? errorBuffer
                                                     : curl_easy_strerror((CURLcode)code)] retain];
    } else if (statusCode == 304 && [self useRevalidatedCache]) {
        ;   /* the copy on disk is current */
    } else if (statusCode == 416 && resumedFrom > 0) {
        ;   /* the .part was already whole; the caller's checksum decides */
    } else if (statusCode < 200 || statusCode >= 300) {
        error = [[NSString stringWithFormat:@"HTTP %ld", statusCode] retain];
    }

    /* The server ignored Range and sent the whole file: start it over. */
    if (code == CURLE_RANGE_ERROR && resumedFrom > 0 && partialPath != nil && !cancelled) {
        if (file != NULL) {
            fclose((FILE *)file);
            file = NULL;
        }
        unlink([partialPath fileSystemRepresentation]);
        resumedFrom = 0;
        restart = GDRestartAgain;
        return;
    }

    /* PowerEmu, not the site, failed: run the request again, directly.
     * Nothing reached the site, so this is safe for any request we route. */
    if (viaAccelerator && !cancelled && restart == GDRestartNone) {
        if (code != CURLE_OK && statusCode == 0) {
            [GDAccelerator markFailed];
            restart = GDRestartDirect;
        } else if (statusCode == 502 || statusCode == 504 || statusCode == 401) {
            restart = GDRestartDirect;
        } else if (statusCode >= 300 && statusCode < 400 && [location length] > 0 &&
                   redirects < 10) {
            restart = GDRestartRedirect;
        }
    }
    if (restart != GDRestartNone)
        return;

    if (error == nil && statusCode != 304)
        [self storeInCache];
    if (error != nil && !cancelled)
        [self useStaleCache];

    if (file != NULL) {
        fclose((FILE *)file);
        file = NULL;
        /* On failure the .part stays, so the next attempt resumes it. */
        if (error == nil) {
            [[NSFileManager defaultManager] removeFileAtPath:destinationPath handler:nil];
            rename([partialPath fileSystemRepresentation],
                   [destinationPath fileSystemRepresentation]);
        } else if (statusCode == 404 || statusCode == 403 || statusCode == 410) {
            unlink([partialPath fileSystemRepresentation]);
        }
    }
}

/* ---- running it --------------------------------------------------------- */

- (void) finishOnMain
{
    finished = YES;
    if ([delegate respondsToSelector:@selector(httpRequestDidFinish:)])
        [delegate httpRequestDidFinish:self];
}

/* Network thread: hand the answer to the main thread and let go of the retain
 * -start took. */
- (void) deliver
{
    [self performSelectorOnMainThread:@selector(finishOnMain) withObject:nil waitUntilDone:NO];
    [self release];
}

- (BOOL) startSynchronous
{
    if ([self preflightCache]) {
        finished = YES;
        return YES;
    }
    do {
        if (![self prepareHandle]) {
            [self releaseHandle];
            finished = YES;
            return NO;
        }
        [self finishWithCurlCode:curl_easy_perform((CURL *)easy)];
        [self releaseHandle];
    } while ([self takeRestart]);
    finished = YES;
    return error == nil;
}

- (void) start
{
    [self retain];              /* the engine gives this back in -deliver */
    finished = NO;
    engineEnqueue(self);
}

@end
