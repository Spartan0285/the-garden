/*
 * GDSheepShaver - handing Mac OS 9 software to the emulator that can run it.
 *
 * On an Intel Mac, and on Leopard, there is no Classic environment, so a
 * Mac OS 9 title cannot be opened by double-clicking it.  SheepShaver is a
 * Mac OS 8.1-9.0.4 machine in a window, it is in the Garden itself, and it
 * can see a folder of this Mac: its settings file (~/.sheepshaver_prefs) has
 * an "extfs" line naming a folder, which appears inside Mac OS 9 as a disk.
 * Software installed there is ready to run without touching SheepShaver's own
 * disk images - which would mean writing into an HFS volume, and would be
 * unsafe while SheepShaver is running.
 *
 * Nothing here changes SheepShaver's settings without being asked to.
 */
#import <Cocoa/Cocoa.h>

@interface GDSheepShaver : NSObject

/* Where SheepShaver is, or nil.  These are old-style bundles with no bundle
 * identifier, so they are found by name, and by what the Garden installed. */
+ (NSString *) applicationPath;
+ (BOOL) isInstalled;
+ (BOOL) isRunning;

/* The folder SheepShaver shows inside Mac OS 9 ("extfs"), or nil if it shares
 * none.  "/" means the whole disk, so everything is already visible. */
+ (NSString *) sharedFolder;
+ (BOOL) sharesPath:(NSString *)path;

/* Where a Mac OS 9 title should be installed so that SheepShaver can see it:
 * "/Applications (Mac OS 9)" when that is shared, otherwise the shared folder
 * itself.  nil when SheepShaver shares nothing yet. */
+ (NSString *) installFolder;

/* Share this folder with Mac OS 9, by writing SheepShaver's settings file.
 * Only ever called after the reader has agreed; SheepShaver reads its
 * settings at launch, so it has to be started again. */
+ (BOOL) shareFolder:(NSString *)folder;

+ (void) launch;

@end
