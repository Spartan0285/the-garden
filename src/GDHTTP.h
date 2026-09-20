/*
 * GDHTTP - HTTPS for Mac OS X 10.4/10.5 through libcurl + OpenSSL 3.
 *
 * Tiger's own networking stops at TLS 1.0, which Macintosh Garden (and most
 * of today's web) refuses, so every request goes through a statically linked
 * libcurl with a bundled Mozilla CA list.
 *
 * One background thread drives every transfer through a single curl multi
 * handle: a thread per request costs far too much memory on a 256MB G3, and
 * one handle lets connections, DNS answers and TLS sessions be reused.
 * Requests report back on the main thread.  A shared cookie jar is what the
 * Garden's search form token needs.
 *
 * GETs can be cached on disk with a time to live, and a copy past its time is
 * revalidated (If-None-Match / If-Modified-Since) rather than downloaded
 * again, which is what keeps the app light on the site.
 *
 * When PowerEmu's Web Accelerator is reachable (GDAccelerator), page and
 * picture requests go through it: one connection instead of a TLS handshake
 * per mirror, and screenshots arrive scaled to what this screen can show.
 * Downloads, form posts and anything that needs the session cookie always go
 * straight to the site.
 */
#import <Foundation/Foundation.h>

@class GDHTTPRequest;

/* Informal protocol for the request's delegate; all calls on the main thread. */
@interface NSObject (GDHTTPRequestDelegate)
- (void) httpRequestDidFinish:(GDHTTPRequest *)request;
- (void) httpRequest:(GDHTTPRequest *)request
      receivedBytes:(long long)done of:(long long)total;
@end

@interface GDHTTPRequest : NSObject
{
    NSURL *url;
    NSData *postBody;
    NSString *destinationPath;   /* nil: keep the body in memory */
    id delegate;                 /* not retained */
    int tag;
    id userInfo;

    /* results */
    NSMutableData *data;
    long statusCode;
    NSString *error;
    NSString *effectiveURL;
    NSString *contentType;

    volatile int cancelled;
    BOOL finished;
    double lastProgress;
    long long resumedFrom;       /* bytes already on disk when this attempt began */
    int curlCode;
    double cacheTTL;             /* >0: serve a GET from the page cache if younger */
    BOOL fromCache, stale, revalidated;

    /* the libcurl transfer, built and torn down on the network thread */
    void *easy;                  /* CURL * */
    void *headerList;            /* struct curl_slist * */
    void *file;                  /* FILE *, in download mode */
    char *errorBuffer;
    NSString *partialPath;

    /* validators: those of the stored copy, and those this answer carried */
    NSString *cachedETag, *cachedModified;
    NSString *newETag, *newModified, *location;
    NSMutableDictionary *responseHeaders;   /* only collected when asked for */
    NSDictionary *requestHeaders;           /* extra headers to send */
    BOOL wantsHeaders;

    /* PowerEmu's Web Accelerator */
    BOOL usesSession;            /* the session cookie matters: never routed */
    BOOL viaAccelerator, bypassAccelerator;
    int restart;                 /* GDRestartNone/Direct/Redirect, between attempts */
    int redirects;
}

+ (GDHTTPRequest *) requestWithURL:(NSURL *)u;
+ (NSString *) userAgent;

- (void) setPostBody:(NSData *)body;             /* application/x-www-form-urlencoded */
/* Page cache for GETs kept in memory (not downloads): a copy younger than
 * ttl seconds is returned without touching the network; an older one is
 * revalidated, so an unchanged page costs a 304 and no body; if the network
 * fails, any copy is returned (offline browsing) and -isStale says so. */
- (void) setCacheTTL:(double)ttl;
- (BOOL) isFromCache;
- (BOOL) isStale;
- (BOOL) wasRevalidated;
+ (void) purgePageCacheOlderThan:(double)seconds;
- (void) setDestinationPath:(NSString *)path;    /* stream to this file; a
                                                    leftover path.part is resumed */
/* This request is part of a sequence that shares the site's session cookie
 * (the search form token): it must go to the site itself. */
- (void) setUsesSession:(BOOL)flag;
/* Extra headers to send (the WebKit bridge forwards WebKit's own). */
- (void) setRequestHeaders:(NSDictionary *)headers;
- (BOOL) viaAccelerator;
- (void) setDelegate:(id)d;
- (id) delegate;
- (void) setTag:(int)t;
- (int) tag;
- (void) setUserInfo:(id)info;
- (id) userInfo;

- (void) start;            /* asynchronous */
- (BOOL) startSynchronous; /* blocks; for tools and worker threads */
- (void) cancel;

- (NSURL *) url;
- (NSData *) data;
- (NSString *) string;     /* body decoded as UTF-8, else Latin-1 */
- (long) statusCode;
- (NSString *) error;      /* nil on success (2xx) */
- (NSString *) effectiveURL;
- (NSString *) contentType;
/* Keep every header of the answer (the WebKit bridge needs them); off by
 * default, because a listing page's headers are of no use to anyone. */
- (void) setWantsResponseHeaders:(BOOL)flag;
- (NSDictionary *) responseHeaders;
- (BOOL) isCancelled;
- (BOOL) isFinished;
- (long long) resumedFrom;
- (BOOL) isTransientFailure;  /* worth retrying (timeouts, dropped connections) */
@end

/* Percent-encode a form value. */
NSString *GDFormEncode(NSString *s);
