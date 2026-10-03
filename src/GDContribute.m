#import "GDContribute.h"
#import "GDGarden.h"
#import "GDHTTP.h"

/* One endpoint, changeable without a new build like the others:
 *   defaults write org.macintoshgarden.store GDCatalogURL <address>
 * An empty string switches contributing off however the checkbox is set. */
static NSString * const GDCatalogDefaultURL = @"https://www.cytrusretro.com/api/catalog";
static NSString * const GDCatalogClientToken = @"garden-client-1";

#define ENABLED_KEY   @"GDContributeIndex"
#define COUNT_KEY     @"GDContributedRows"
#define SEND_AT       30        /* rows: a batch worth sending */
#define QUEUE_MAX     3000      /* rows: what we will hold if the endpoint is down */
#define SEND_EVERY    180.0     /* seconds: at most one batch this often */

static NSMutableDictionary *gQueue;     /* path -> the row, so a page read twice
                                           is still one row */
static NSDate *gLastSend;
static GDHTTPRequest *gRequest;

@implementation GDContribute

+ (BOOL) isEnabled
{
    NSString *url = [[NSUserDefaults standardUserDefaults] stringForKey:@"GDCatalogURL"];
    if (url != nil && [url length] == 0)
        return NO;
    return [[NSUserDefaults standardUserDefaults] boolForKey:ENABLED_KEY];
}

+ (void) setEnabled:(BOOL)flag
{
    [[NSUserDefaults standardUserDefaults] setBool:flag forKey:ENABLED_KEY];
    if (!flag) {
        /* Off means off: what was queued is dropped, not sent later. */
        [gQueue removeAllObjects];
    }
}

+ (unsigned) queuedCount { return (unsigned)[gQueue count]; }

+ (unsigned) contributedCount
{
    return (unsigned)[[NSUserDefaults standardUserDefaults] integerForKey:COUNT_KEY];
}

/* A row, in the columns /api/search answers in.  Tabs and newlines are what
 * separates them, so they cannot appear inside one. */
static NSString *clean(NSString *s)
{
    NSMutableString *m;
    if ([s length] == 0)
        return @"";
    m = [[s mutableCopy] autorelease];
    [m replaceOccurrencesOfString:@"\t" withString:@" "
                          options:0 range:NSMakeRange(0, [m length])];
    [m replaceOccurrencesOfString:@"\n" withString:@" "
                          options:0 range:NSMakeRange(0, [m length])];
    [m replaceOccurrencesOfString:@"\r" withString:@" "
                          options:0 range:NSMakeRange(0, [m length])];
    return m;
}

+ (void) offerItems:(NSArray *)items
{
    NSEnumerator *e;
    GDItem *it;

    if (![self isEnabled] || [items count] == 0)
        return;
    if (gQueue == nil)
        gQueue = [[NSMutableDictionary alloc] init];

    e = [items objectEnumerator];
    while ((it = [e nextObject]) != nil) {
        NSString *path = [it path];
        NSString *row;
        if ([path length] == 0 || [[it title] length] == 0)
            continue;
        if ([gQueue count] >= QUEUE_MAX && [gQueue objectForKey:path] == nil)
            continue;
        row = [NSString stringWithFormat:
                  @"%@\t%@\t%@\t%@\t%@\t%@\t%@\t%d\t%@\t%@",
                  path, clean([it title]), [it section] ?: @"",
                  clean([it year]), clean([it category]), clean([it author]),
                  [it rating] > 0 ? [NSString stringWithFormat:@"%.1f", [it rating]] : @"",
                  [it votes], clean([it thumbURL]),
                  clean([[it blurb] length] > 140 ? [[it blurb] substringToIndex:140] : [it blurb])];
        [gQueue setObject:row forKey:path];
    }

    /* -flush keeps to one batch every SEND_EVERY seconds, so under heavy
     * browsing the batches get bigger rather than more frequent. */
    if ([gQueue count] >= SEND_AT)
        [self flush];
}

+ (void) flush
{
    NSMutableArray *rows;
    NSMutableString *body;
    NSString *url;
    unsigned i, n;

    if (![self isEnabled] || [gQueue count] == 0 || gRequest != nil)
        return;
    if (gLastSend != nil && -[gLastSend timeIntervalSinceNow] < SEND_EVERY)
        return;

    /* Shuffled, so a batch is not a reading order.  Fisher-Yates, with the
     * rows taken out of the queue only once the request is made. */
    rows = [[[gQueue allValues] mutableCopy] autorelease];
    n = (unsigned)[rows count];
    for (i = n; i > 1; i--) {
        unsigned j = (unsigned)(random() % i);
        [rows exchangeObjectAtIndex:i - 1 withObjectAtIndex:j];
    }

    body = [NSMutableString stringWithString:@"#garden-rows\t1\n"];
    for (i = 0; i < n; i++)
        [body appendFormat:@"%@\n", [rows objectAtIndex:i]];

    url = [[NSUserDefaults standardUserDefaults] stringForKey:@"GDCatalogURL"];
    if ([url length] == 0)
        url = GDCatalogDefaultURL;

    gRequest = [[GDHTTPRequest requestWithURL:[NSURL URLWithString:url]] retain];
    [gRequest setPostBody:[body dataUsingEncoding:NSUTF8StringEncoding]];
    [gRequest setRequestHeaders:[NSDictionary dictionaryWithObjectsAndKeys:
                                    @"text/tab-separated-values", @"Content-Type",
                                    GDCatalogClientToken, @"X-Garden-Client", nil]];
    [gRequest setDelegate:(id)self];
    [gRequest start];

    [gLastSend release];
    gLastSend = [[NSDate date] retain];
    [gQueue removeAllObjects];
}

/* Nothing is retried: these rows come back the next time those pages are
 * opened, by this copy or another one, and a lost batch costs nobody
 * anything.  Keeping a queue across launches would be a record of browsing
 * on disk, which is exactly what this must not have. */
+ (void) httpRequestDidFinish:(GDHTTPRequest *)r
{
    if ([r error] == nil && [r statusCode] >= 200 && [r statusCode] < 300) {
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        /* The server says how many rows it took. */
        NSString *reply = [[[NSString alloc] initWithData:[r data]
                               encoding:NSUTF8StringEncoding] autorelease];
        int took = [reply intValue];
        if (took > 0)
            [d setInteger:[d integerForKey:COUNT_KEY] + took forKey:COUNT_KEY];
    }
    [gRequest release];
    gRequest = nil;
}

@end
