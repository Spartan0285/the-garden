/*
 * GDWelcome - what the reader sees the first time The Garden opens, and
 * afterwards from "What the Badges Mean..." in the View menu.
 *
 * Its job is the badges: what each one means, and - the part that is easy to
 * get wrong - that a badge is about compatibility, not about whether this
 * particular Mac is up to the job.
 */
#import <Cocoa/Cocoa.h>

@interface GDWelcome : NSObject
{
    NSWindow *window;
    NSButton *showAgain;
}
+ (void) show;
/* At launch, unless the reader has turned it off. */
+ (BOOL) shouldShowAtLaunch;
@end
