/*
 * GDWebLink - opening a web address from an app on a twenty-year-old Mac.
 *
 * The browsers these systems shipped with stop at TLS 1.0, which almost no
 * site accepts any more, so "open this link" usually means "watch Safari fail".
 * Captain Polliwog is a browser for 10.4 and 10.5 that can reach a modern
 * site, so:
 *
 *   - if it is already the default browser, the link just opens;
 *   - if it is installed but not the default, it is offered first, with the
 *     reader's own browser next to it;
 *   - if it is not installed, it is recommended, with the reader's own
 *     browser next to it.
 *
 * The reader's choice always wins: the recommendation is a default button,
 * never the only button.  Captain Polliwog itself should not use this.
 */
#import <Cocoa/Cocoa.h>

extern NSString *GDPolliwogBundleID;

@interface GDWebLink : NSObject

/* The whole policy above, in one call. */
+ (void) openURL:(NSURL *)url;

+ (NSString *) polliwogPath;       /* nil when it is not installed */
+ (BOOL) polliwogIsDefaultBrowser;
/* "Safari", "Captain Polliwog", ... - worth knowing in a bug report. */
+ (NSString *) defaultBrowserName;

@end
