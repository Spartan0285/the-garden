#import "GDWebWindow.h"
#import "GDWebProtocol.h"
#import "GDHTTP.h"
#import <WebKit/WebKit.h>

static GDWebWindow *shared;

@implementation GDWebWindow

+ (void) openURL:(NSURL *)url title:(NSString *)title
{
    if (shared == nil)
        shared = [[self alloc] init];
    [shared showURL:url title:title];
}

- (id) init
{
    NSRect frame = NSMakeRect(0, 0, 780, 560);
    NSView *content;

    self = [super init];
    if (self == nil)
        return nil;

    [GDWebProtocol install];
    window = [[NSWindow alloc] initWithContentRect:frame
                                         styleMask:(NSTitledWindowMask | NSClosableWindowMask |
                                                    NSMiniaturizableWindowMask | NSResizableWindowMask)
                                           backing:NSBackingStoreBuffered defer:NO];
    [window setReleasedWhenClosed:NO];
    [window setMinSize:NSMakeSize(480, 360)];
    content = [window contentView];

    webView = [[WebView alloc] initWithFrame:[content bounds] frameName:nil groupName:nil];
    [webView setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];
    [webView setApplicationNameForUserAgent:@"TheGarden"];
    [webView setCustomUserAgent:[GDHTTPRequest userAgent]];
    [webView setFrameLoadDelegate:self];
    [webView setPolicyDelegate:self];
    [content addSubview:webView];

    spinner = [[NSProgressIndicator alloc] initWithFrame:
                  NSMakeRect(NSWidth(frame) / 2 - 16, NSHeight(frame) / 2 - 16, 32, 32)];
    [spinner setStyle:NSProgressIndicatorSpinningStyle];
    [spinner setAutoresizingMask:(NSViewMinXMargin | NSViewMaxXMargin |
                                  NSViewMinYMargin | NSViewMaxYMargin)];
    [spinner setDisplayedWhenStopped:NO];
    [content addSubview:spinner];
    return self;
}

- (void) showURL:(NSURL *)url title:(NSString *)title
{
    [window setTitle:[title length] ? title : @"Macintosh Garden"];
    [window center];
    [window makeKeyAndOrderFront:nil];
    [spinner startAnimation:nil];
    [[webView mainFrame] loadRequest:[NSURLRequest requestWithURL:url]];
}

/* ------------------------------------------------------------ WebKit */

- (void) webView:(WebView *)sender didFinishLoadForFrame:(WebFrame *)frame
{
    if (frame == [sender mainFrame])
        [spinner stopAnimation:nil];
}

- (void) webView:(WebView *)sender didFailLoadWithError:(NSError *)error forFrame:(WebFrame *)frame
{
    if (frame == [sender mainFrame])
        [spinner stopAnimation:nil];
}

- (void) webView:(WebView *)sender didFailProvisionalLoadWithError:(NSError *)error
                                                         forFrame:(WebFrame *)frame
{
    if (frame != [sender mainFrame])
        return;
    [spinner stopAnimation:nil];
    [[webView mainFrame] loadHTMLString:
        [NSString stringWithFormat:
            @"<html><body style='font:13px -apple-system,\"Lucida Grande\";color:#444;"
             "text-align:center;margin-top:80px'><p>%@</p></body></html>",
            [error localizedDescription] ?: @"The page could not be loaded."]
                                baseURL:nil];
}

- (void) webView:(WebView *)sender didReceiveTitle:(NSString *)title forFrame:(WebFrame *)frame
{
    if (frame == [sender mainFrame] && [title length])
        [window setTitle:title];
}

/* Anything that is not a web page (a download link) goes to the system, which
 * is where the Garden's own Get button already put it. */
- (void) webView:(WebView *)sender decidePolicyForMIMEType:(NSString *)type
                                                   request:(NSURLRequest *)request
                                                     frame:(WebFrame *)frame
                                          decisionListener:(id<WebPolicyDecisionListener>)listener
{
    if ([WebView canShowMIMEType:type])
        [listener use];
    else
        [listener ignore];
}

- (void) dealloc
{
    [webView release];
    [spinner release];
    [window release];
    [super dealloc];
}

@end
