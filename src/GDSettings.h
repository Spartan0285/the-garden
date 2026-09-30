/*
 * GDSettings - the Settings window (Settings... in the application menu).
 *
 * Small on purpose: the things worth keeping between launches that are not
 * already a menu item.  Right now that is the Updates tab, which can be
 * turned off altogether, and the updates the user has told the app to stop
 * offering.
 */
#import <Cocoa/Cocoa.h>

/* Something in here changed; the store window re-reads what it shows. */
extern NSString *GDSettingsChangedNotification;

@interface GDSettings : NSObject
{
    NSWindow *window;
    NSButton *updatesTabBox;
    NSButton *unignoreButton;
    NSTextField *ignoredLine;
}
+ (void) show;

/* With the tab off, nothing is checked for updates and the tab is not there.
 * The app's own self-update is a separate thing and is not affected. */
+ (BOOL) updatesTabHidden;
@end
