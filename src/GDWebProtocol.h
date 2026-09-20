/*
 * GDWebProtocol - the system WebKit, loading through the Garden's own stack.
 *
 * Tiger and Leopard load web pages through Foundation, whose TLS stops at 1.0
 * and which tries a site's IPv6 address first on networks that have none.
 * Registering this class puts GDHTTP (libcurl + OpenSSL 3, and PowerEmu's
 * accelerator when it is there) in front of it, so a WebView in this app
 * reaches the same sites the rest of the app can reach.
 *
 * Requests from a WebView always go straight to the site and share the
 * Garden's cookie jar, so signing in in a web view signs the whole app in.
 */
#import <Cocoa/Cocoa.h>

@class GDHTTPRequest;

@interface GDWebProtocol : NSURLProtocol
{
    GDHTTPRequest *request_;
}

/* Once, before the first WebView is made. */
+ (void) install;

@end

/* NSHTTPURLResponse could not be made directly until Mac OS X 10.7, so the
 * answer WebKit sees is built by subclassing it. */
@interface GDHTTPURLResponse : NSHTTPURLResponse
{
    int responseStatusCode;
    NSDictionary *responseHeaderFields;
}

- (id) initWithURL:(NSURL *)aURL
        statusCode:(int)aStatusCode
      headerFields:(NSDictionary *)fields
          MIMEType:(NSString *)MIMEType
     contentLength:(long long)contentLength
      textEncoding:(NSString *)encoding;

@end
