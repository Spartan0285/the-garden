/*
 * GDItemView - an item's store page: picture, Get button and facts on the
 * left; title, rating, description, screenshots and every download on the
 * right.  Rebuilt from the GDItemDetail whenever it (or an install job for
 * it) changes.
 */
#import <Cocoa/Cocoa.h>
#import "GDGarden.h"

@class GDInstallJob;

@interface NSObject (GDItemViewDelegate)
- (void) itemView:(id)v getFile:(GDFile *)f ofItem:(GDItemDetail *)d;
- (void) itemView:(id)v openInstalled:(NSDictionary *)entry;
- (void) itemView:(id)v showScreenshot:(NSString *)url;
- (void) itemView:(id)v showJob:(GDInstallJob *)job;
- (void) itemView:(id)v openItem:(GDItem *)item;
- (void) itemView:(id)v openListing:(NSDictionary *)page;
@end

@interface GDItemView : NSView
{
    NSString *path;
    GDItem *summary;            /* what the listing knew, shown while loading */
    GDItemDetail *detail;
    id delegate;
    NSMutableArray *shotRects;  /* {rect, url} */
    NSTextView *descView;
    NSButton *getButton;
    NSProgressIndicator *bar;
    NSMutableArray *fileButtons;
    float descHeight;

    /* below the downloads: reviews, more by the author, related */
    float extrasTop;
    BOOL showAllReviews;
    NSArray *moreByAuthor;      /* GDItem */
    NSArray *related;           /* GDItem */
    NSMutableArray *extraRequests;
    NSMutableArray *links;      /* {rect, kind, object} */
}
- (id) initWithFrame:(NSRect)f path:(NSString *)p summary:(GDItem *)s;
- (void) setDelegate:(id)d;
- (NSString *) path;
- (GDItemDetail *) detail;
@end
