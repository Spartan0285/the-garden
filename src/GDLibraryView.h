/*
 * GDLibraryView - "Library": downloads in progress, then everything the
 * store has installed, each with Open / Add to Dock / Show in Finder / Move
 * to Trash.  With setShowsUpdates: it is the Updates tab instead: installed
 * titles with a newer file of the same kind, each with Update.
 */
#import <Cocoa/Cocoa.h>

@interface NSObject (GDLibraryViewDelegate)
- (void) libraryView:(id)v openItemPath:(NSString *)path;
@end

@interface GDLibraryView : NSView
{
    id delegate;
    NSMutableArray *controls;
    NSMutableArray *rows;       /* {kind, object, rect} */
    BOOL showsUpdates;          /* the Updates tab instead of the Library */
    NSMutableSet *docked;       /* entries added to the Dock this session */
}
- (void) setDelegate:(id)d;
- (void) setShowsUpdates:(BOOL)f;
- (void) reload;
@end
