/*
 * GDWebWindow - the Garden's own pages, on the web, in a window of the app.
 *
 * The system WebKit draws them; GDWebProtocol makes it load through the
 * Garden's network stack, so the site is reachable on Tiger (whose own TLS
 * stops at 1.0) and the session is the app's own.
 */
#import <Cocoa/Cocoa.h>

@class WebView;

@interface GDWebWindow : NSObject
{
    NSWindow *window;
    WebView *webView;
    NSProgressIndicator *spinner;
}

/* One window, reused: shows this address, with this title. */
+ (void) openURL:(NSURL *)url title:(NSString *)title;
- (void) showURL:(NSURL *)url title:(NSString *)title;

@end
