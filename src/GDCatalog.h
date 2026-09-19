/*
 * GDCatalog - shared, cached access to item pages and pictures.
 *
 * Browsing shows ten items a page, and each tile wants its item page too
 * (for the compatibility badge) plus a thumbnail.  Both are fetched once,
 * kept in memory, and pictures also on disk, so going back and forth costs
 * nothing.  Views ask, get nil the first time, and redraw when the matching
 * notification arrives (object: the path or URL string).
 */
#import <Cocoa/Cocoa.h>
#import "GDGarden.h"
#import "GDCompat.h"

extern NSString *GDDetailLoadedNotification;   /* object: item path */
extern NSString *GDImageLoadedNotification;    /* object: image URL */

@interface GDCatalog : NSObject
{
    NSMutableDictionary *details;      /* path -> GDItemDetail */
    NSMutableDictionary *verdicts;     /* path -> NSNumber GDVerdict */
    NSMutableSet *detailLoads;
    NSMutableDictionary *images;       /* url -> NSImage (or NSNull on failure) */
    NSMutableSet *imageLoads;
    NSMutableArray *imageLRU;
    NSString *cacheDir;
}
+ (GDCatalog *) sharedCatalog;

- (GDItemDetail *) detailForPath:(NSString *)path;   /* nil: loading */
- (void) refreshDetailForPath:(NSString *)path;      /* fetch again (fresh download links) */
- (GDVerdict) verdictForPath:(NSString *)path known:(BOOL *)known;

- (NSImage *) imageForURL:(NSString *)url;           /* nil: loading or none */
- (NSString *) cacheDirectory;
- (int) pendingLoads;
@end

NSString *GDMD5OfString(NSString *s);
NSString *GDMD5OfFile(NSString *path);                /* hex, nil on error */
