/*
 * GDAbout - who made this, and what it is not.
 *
 * The Garden is not the Macintosh Garden, and saying so plainly is the point
 * of this window: the site does the hosting and the cataloguing, this is only
 * a way to read it.  It also carries the alpha warning, and two links out -
 * opened in the app's own web view, because the browsers these systems ship
 * with cannot reach a modern site (GDWebWindow).
 */
#import <Cocoa/Cocoa.h>

@interface GDAbout : NSObject
{
    NSWindow *window;
}

+ (void) show;

/* "0.3", "Alpha", and the build number, as the Info.plist has them. */
+ (NSString *) versionLine;
+ (NSString *) stage;          /* "Alpha", or nil once it is not */

@end
