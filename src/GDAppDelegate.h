#import <Cocoa/Cocoa.h>

@class GDStoreController;

@interface GDAppDelegate : NSObject
{
    GDStoreController *store;
    NSTimer *debugTimer;
    int debugQuiet;
    BOOL debugInstallStarted;
    BOOL debugWebOpened;
}
- (void) buildMainMenu;
@end
