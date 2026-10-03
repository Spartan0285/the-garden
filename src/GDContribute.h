/*
 * GDContribute - sharing the rows this copy has already fetched, so that
 * searching does not depend on the Garden's own search being up.
 *
 * The index behind /api/search has to come from somewhere, and the Garden's
 * robots.txt says plainly that it is not to be crawled - a crawl of it from
 * here on 3 October 2026 had this network blocked inside a minute, which is
 * the site's answer and a fair one.  So nothing crawls.  Instead, when you
 * open a listing page the app has fetched anyway, the rows it parsed are
 * offered to the index.  The site sees exactly the traffic it saw before, and
 * less of it once search is answered at the edge.
 *
 * It is off until it is switched on (Settings), because it is still true that
 * what a copy sends says something about which pages were opened on this Mac.
 * What is sent is a public catalogue row - path, title, year, category,
 * author, rating, thumbnail, first line - with no identifier of any kind, no
 * account, no session, no timestamp of our making, and in a shuffled batch
 * rather than the order the pages were read.
 */
#import <Foundation/Foundation.h>

@interface GDContribute : NSObject

+ (BOOL) isEnabled;
+ (void) setEnabled:(BOOL)flag;

/* GDItem rows just parsed from a page the reader opened.  Ignored entirely
 * when this is switched off. */
+ (void) offerItems:(NSArray *)items;

/* Send what is queued, at most one batch every few minutes.  Nothing is sent
 * at quit and nothing is kept on disk: a batch that never goes costs nobody
 * anything, and a queue that outlived the app would be a record of browsing
 * written down, which is the thing this must not do. */
+ (void) flush;
+ (unsigned) queuedCount;

/* How many rows this copy has contributed since it was installed - the number
 * Settings shows, so that "on" is not an abstraction. */
+ (unsigned) contributedCount;

@end
