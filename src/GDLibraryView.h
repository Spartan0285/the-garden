/*
 * GDLibraryView - "Library": downloads in progress, then everything the
 * store has installed, each with Open / Show in Finder / Move to Trash.
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
}
- (void) setDelegate:(id)d;
- (void) reload;
@end
