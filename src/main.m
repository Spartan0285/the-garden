/*
 * The Garden - a store for Macintosh Garden software, for Mac OS X 10.4 and
 * 10.5 on PowerPC and Intel.
 */
#import <Cocoa/Cocoa.h>
#import "GDAppDelegate.h"

int main(int argc, const char *argv[])
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSApplication *app = [NSApplication sharedApplication];
    /* No nib: menus are built in code so Xcode 2.5 and 3.1 both build it. */
    GDAppDelegate *delegate = [[GDAppDelegate alloc] init];
    [app setDelegate:delegate];
    [delegate buildMainMenu];
    [app run];
    [delegate release];
    [pool release];
    return 0;
}
