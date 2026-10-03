#import "GDReports.h"
#import "GDCompat.h"
#import "GDHTTP.h"

NSString *GDReportsChangedNotification = @"GDReportsChanged";

/* Alongside the other endpoints, and movable the same way:
 *   defaults write org.macintoshgarden.store GDReportsURL <address>
 * An empty string turns the whole thing off - no figures, no question. */
static NSString * const GDReportsDefaultURL = @"https://www.cytrusretro.com/api/reports";
static NSString * const GDReportsClientToken = @"garden-client-1";

#define ANSWERED_KEY @"GDReportedTitles"

/* path -> {ran here, did not here, ran anywhere, did not anywhere}.  The
 * sentence is made from these rather than kept, so that answering the
 * question changes what the page says at once instead of after a round trip
 * (which the page cache would answer with the figures from before). */
static NSMutableDictionary *gCounts;
static NSMutableSet *gAsked;             /* paths already fetched            */
static NSMutableSet *gStale;             /* ... and worth asking about again  */
static NSMutableSet *gAsking;            /* paths being fetched right now    */
static NSMutableArray *gRequests;        /* the requests themselves          */

@implementation GDReports

static NSString *endpoint(void)
{
    NSString *u = [[NSUserDefaults standardUserDefaults] stringForKey:@"GDReportsURL"];
    if (u == nil)
        return GDReportsDefaultURL;
    return [u length] ? u : nil;
}

+ (BOOL) hasAnswered:(NSString *)path
{
    NSDictionary *d = [[NSUserDefaults standardUserDefaults] dictionaryForKey:ANSWERED_KEY];
    return path != nil && [d objectForKey:path] != nil;
}

+ (void) report:(BOOL)ran forPath:(NSString *)path variant:(NSString *)variant
{
    NSMutableDictionary *answered;
    GDHTTPRequest *r;
    NSString *body;

    if ([path length] == 0 || endpoint() == nil)
        return;

    /* Remembered here as well as counted there, so the question is asked once
     * however the server answers. */
    answered = [[[[NSUserDefaults standardUserDefaults] dictionaryForKey:ANSWERED_KEY]
                    mutableCopy] autorelease];
    if (answered == nil)
        answered = [NSMutableDictionary dictionary];
    [answered setObject:(ran ? @"ran" : @"did not") forKey:path];
    [[NSUserDefaults standardUserDefaults] setObject:answered forKey:ANSWERED_KEY];

    body = [NSString stringWithFormat:@"#garden-report\t1\n%@\t%@\t%@\t%d\n",
               path, variant ?: @"", [GDCompat hostDescription], ran ? 1 : 0];

    if (gRequests == nil)
        gRequests = [[NSMutableArray alloc] init];
    r = [GDHTTPRequest requestWithURL:[NSURL URLWithString:endpoint()]];
    [r setPostBody:[body dataUsingEncoding:NSUTF8StringEncoding]];
    [r setRequestHeaders:[NSDictionary dictionaryWithObjectsAndKeys:
                             @"text/tab-separated-values", @"Content-Type",
                             GDReportsClientToken, @"X-Garden-Client", nil]];
    [r setDelegate:(id)self];
    [r setTag:1];
    [gRequests addObject:r];
    [r start];

    /* Counted here straight away: the page should say what you just said,
     * not what the server last told us.  And the figures we have are now a
     * report out of date, so they are asked for again without the cache -
     * which would otherwise hand back the answer from before this one. */
    [self count:path ranHere:(ran ? 1 : 0) failedHere:(ran ? 0 : 1)
     ranAnywhere:(ran ? 1 : 0) failedAnywhere:(ran ? 0 : 1) add:YES];
    if (gStale == nil)
        gStale = [[NSMutableSet alloc] init];
    [gStale addObject:path];
    [[NSNotificationCenter defaultCenter] postNotificationName:GDReportsChangedNotification
                                                        object:path];
}

+ (void) count:(NSString *)path ranHere:(int)rh failedHere:(int)fh
   ranAnywhere:(int)ra failedAnywhere:(int)fa add:(BOOL)add
{
    NSArray *was;
    if (gCounts == nil)
        gCounts = [[NSMutableDictionary alloc] init];
    was = add ? [gCounts objectForKey:path] : nil;
    if (was != nil) {
        rh += [[was objectAtIndex:0] intValue];
        fh += [[was objectAtIndex:1] intValue];
        ra += [[was objectAtIndex:2] intValue];
        fa += [[was objectAtIndex:3] intValue];
    }
    [gCounts setObject:[NSArray arrayWithObjects:
                           [NSNumber numberWithInt:rh], [NSNumber numberWithInt:fh],
                           [NSNumber numberWithInt:ra], [NSNumber numberWithInt:fa], nil]
                forKey:path];
    [[NSNotificationCenter defaultCenter] postNotificationName:GDReportsChangedNotification
                                                        object:path];
}

+ (int) ranHereFor:(NSString *)path
{
    NSArray *a = [gCounts objectForKey:path];
    return a ? [[a objectAtIndex:0] intValue] : -1;
}

+ (int) failedHereFor:(NSString *)path
{
    NSArray *a = [gCounts objectForKey:path];
    return a ? [[a objectAtIndex:1] intValue] : -1;
}

+ (NSString *) summaryFor:(NSString *)path
{
    NSArray *c;
    int rh, fh, ra, fa;

    if ([path length] == 0 || endpoint() == nil)
        return nil;
    c = [gCounts objectForKey:path];
    if ((c == nil && ![gAsked containsObject:path]) || [gStale containsObject:path]) {
        if (![gAsking containsObject:path]) {
            BOOL fresh = [gStale containsObject:path];
            if (gAsking == nil) gAsking = [[NSMutableSet alloc] init];
            if (gAsked == nil) gAsked = [[NSMutableSet alloc] init];
            if (gRequests == nil) gRequests = [[NSMutableArray alloc] init];
            [gAsking addObject:path];
            [gStale removeObject:path];
            {
                NSString *u = [NSString stringWithFormat:@"%@?path=%@", endpoint(), GDFormEncode(path)];
                GDHTTPRequest *r = [GDHTTPRequest requestWithURL:[NSURL URLWithString:u]];
                [r setCacheTTL:fresh ? 0 : 300];
                [r setDelegate:(id)self];
                [r setTag:2];
                [r setUserInfo:path];
                [gRequests addObject:r];
                [r start];
            }
        }
        if (c == nil)
            return nil;
    }

    rh = [[c objectAtIndex:0] intValue]; fh = [[c objectAtIndex:1] intValue];
    ra = [[c objectAtIndex:2] intValue]; fa = [[c objectAtIndex:3] intValue];

    /* A Mac like this one is what the reader wants to know about; everywhere
     * else is what there is to say when nobody here has said anything. */
    if (rh || fh) {
        if (fh == 0)
            return rh == 1 ? @"Ran for one person on a Mac like yours"
                 : [NSString stringWithFormat:@"Ran for %d people on a Mac like yours", rh];
        if (rh == 0)
            return fh == 1 ? @"Did not run for one person on a Mac like yours"
                 : [NSString stringWithFormat:@"Did not run for %d people on a Mac like yours", fh];
        return [NSString stringWithFormat:@"Ran for %d of %d on a Mac like yours", rh, rh + fh];
    }
    if (ra || fa)
        return [NSString stringWithFormat:@"Ran for %d of %d on other Macs", ra, ra + fa];
    return nil;
}

/* "#garden-reports<tab>1<tab><path>" then variant, host, ok, n per line. */
+ (void) parse:(NSData *)data forPath:(NSString *)path
{
    NSString *body = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
    NSEnumerator *lines = [[body componentsSeparatedByString:@"\n"] objectEnumerator];
    NSString *line, *mine = [GDCompat hostDescription];
    int ranHere = 0, failedHere = 0, ranAnywhere = 0, failedAnywhere = 0;
    BOOL ours = NO;

    while ((line = [lines nextObject]) != nil) {
        NSArray *f;
        int ok, n;
        if ([line hasPrefix:@"#garden-reports"]) { ours = YES; continue; }
        if ([line hasPrefix:@"#"] || [line length] == 0)
            continue;
        f = [line componentsSeparatedByString:@"\t"];
        if ([f count] < 4)
            continue;
        ok = [[f objectAtIndex:2] intValue];
        n = [[f objectAtIndex:3] intValue];
        if (n <= 0)
            continue;
        if (ok) ranAnywhere += n; else failedAnywhere += n;
        if ([[f objectAtIndex:1] isEqualToString:mine]) {
            if (ok) ranHere += n; else failedHere += n;
        }
    }
    if (!ours)
        return;

    /* Replaces rather than adds: these are the server's totals.  An answer
     * given in this session is already among them, having been sent before
     * this was asked for. */
    [self count:path ranHere:ranHere failedHere:failedHere
     ranAnywhere:ranAnywhere failedAnywhere:failedAnywhere add:NO];
}

+ (void) httpRequestDidFinish:(GDHTTPRequest *)r
{
    if ([r tag] == 2) {
        NSString *path = [r userInfo];
        if ([r error] == nil)
            [self parse:[r data] forPath:path];
        [gAsking removeObject:path];
        [gAsked addObject:path];
    }
    [[r retain] autorelease];
    [gRequests removeObject:r];
}

@end
