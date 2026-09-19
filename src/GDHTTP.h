/*
 * GDHTTP - HTTPS for Mac OS X 10.4/10.5 through libcurl + OpenSSL 3.
 *
 * Tiger's own networking stops at TLS 1.0, which Macintosh Garden (and most
 * of today's web) refuses, so every request goes through a statically linked
 * libcurl with a bundled Mozilla CA list.  Requests run on worker threads
 * (at most GD_HTTP_MAX_ACTIVE at once) and report back on the main thread.
 * One shared curl share handle keeps cookies, DNS and TLS sessions across
 * requests, which the Garden's search form token needs.
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
}

+ (GDHTTPRequest *) requestWithURL:(NSURL *)u;
+ (NSString *) userAgent;

- (void) setPostBody:(NSData *)body;             /* application/x-www-form-urlencoded */
- (void) setDestinationPath:(NSString *)path;    /* stream to this file; a
                                                    leftover path.part is resumed */
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
- (BOOL) isCancelled;
- (BOOL) isFinished;
- (long long) resumedFrom;
- (BOOL) isTransientFailure;  /* worth retrying (timeouts, dropped connections) */
@end

/* Percent-encode a form value. */
NSString *GDFormEncode(NSString *s);
