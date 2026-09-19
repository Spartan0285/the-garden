#import "GDCatalog.h"
#import "GDHTTP.h"
#include <openssl/evp.h>
#include <stdio.h>

NSString *GDDetailLoadedNotification = @"GDDetailLoaded";
NSString *GDImageLoadedNotification = @"GDImageLoaded";

#define GD_IMAGE_MEMORY_LIMIT 160      /* decoded pictures kept in memory */

static NSString *hex(const unsigned char *d, int n)
{
    NSMutableString *s = [NSMutableString stringWithCapacity:n * 2];
    int i;
    for (i = 0; i < n; i++)
        [s appendFormat:@"%02x", d[i]];
    return s;
}

NSString *GDMD5OfString(NSString *s)
{
    unsigned char d[EVP_MAX_MD_SIZE];
    unsigned int n = 0;
    const char *u = [s UTF8String];
    EVP_Digest(u, strlen(u), d, &n, EVP_md5(), NULL);
    return hex(d, (int)n);
}

NSString *GDMD5OfFile(NSString *path)
{
    unsigned char d[EVP_MAX_MD_SIZE];
    unsigned int dn = 0;
    unsigned char *buf;
    EVP_MD_CTX *c;
    size_t n;
    FILE *fp = fopen([path fileSystemRepresentation], "rb");
    if (fp == NULL)
        return nil;
    buf = malloc(256 * 1024);
    c = EVP_MD_CTX_new();
    EVP_DigestInit_ex(c, EVP_md5(), NULL);
    while ((n = fread(buf, 1, 256 * 1024, fp)) > 0)
        EVP_DigestUpdate(c, buf, n);
    fclose(fp);
    free(buf);
    EVP_DigestFinal_ex(c, d, &dn);
    EVP_MD_CTX_free(c);
    return hex(d, (int)dn);
}

@implementation GDCatalog

+ (GDCatalog *) sharedCatalog
{
    static GDCatalog *c;
    if (c == nil)
        c = [[GDCatalog alloc] init];
    return c;
}

- (id) init
{
    NSArray *caches;
    if ((self = [super init]) == nil)
        return nil;
    details = [[NSMutableDictionary alloc] init];
    verdicts = [[NSMutableDictionary alloc] init];
    detailLoads = [[NSMutableSet alloc] init];
    images = [[NSMutableDictionary alloc] init];
    imageLoads = [[NSMutableSet alloc] init];
    imageLRU = [[NSMutableArray alloc] init];
    refreshing = [[NSMutableSet alloc] init];
    [GDHTTPRequest purgePageCacheOlderThan:30 * 86400];
    caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    cacheDir = [[[[caches objectAtIndex:0] stringByAppendingPathComponent:@"The Garden"]
                    stringByAppendingPathComponent:@"Pictures"] retain];
    [[NSFileManager defaultManager] createDirectoryAtPath:[cacheDir stringByDeletingLastPathComponent]
                                               attributes:nil];
    [[NSFileManager defaultManager] createDirectoryAtPath:cacheDir attributes:nil];
    return self;
}

- (int) pendingLoads
{
    return (int)([detailLoads count] + [imageLoads count]);
}

- (NSString *) cacheDirectory
{
    return [cacheDir stringByDeletingLastPathComponent];
}

/* ------------------------------------------------------------- details */

- (void) startDetail:(NSString *)path
{
    GDHTTPRequest *r;
    if ([detailLoads containsObject:path])
        return;
    [detailLoads addObject:path];
    r = [GDHTTPRequest requestWithURL:[GDGarden itemURL:path]];
    [r setUserInfo:path];
    [r setTag:1];
    /* Item pages change rarely; download links are re-fetched by Get. */
    [r setCacheTTL:[refreshing containsObject:path] ? 1 : 3 * 86400];
    [refreshing removeObject:path];
    [r setDelegate:self];
    [r start];
}

- (GDItemDetail *) detailForPath:(NSString *)path
{
    GDItemDetail *d = [details objectForKey:path];
    if (d == nil)
        [self startDetail:path];
    return d;
}

- (void) refreshDetailForPath:(NSString *)path
{
    [refreshing addObject:path];
    [self startDetail:path];
}

- (GDVerdict) verdictForPath:(NSString *)path known:(BOOL *)known
{
    NSNumber *n = [verdicts objectForKey:path];
    if (known)
        *known = n != nil;
    if (n == nil) {
        [self detailForPath:path];
        return GDVerdictUnknown;
    }
    return [n intValue];
}

/* -------------------------------------------------------------- images */

- (NSString *) diskPathForURL:(NSString *)url
{
    return [cacheDir stringByAppendingPathComponent:GDMD5OfString(url)];
}

- (void) remember:(id)image forURL:(NSString *)url
{
    [images setObject:image forKey:url];
    [imageLRU removeObject:url];
    [imageLRU addObject:url];
    while ([imageLRU count] > GD_IMAGE_MEMORY_LIMIT) {
        [images removeObjectForKey:[imageLRU objectAtIndex:0]];
        [imageLRU removeObjectAtIndex:0];
    }
}

- (NSImage *) imageForURL:(NSString *)url
{
    id img;
    NSString *disk;
    GDHTTPRequest *r;

    if ([url length] == 0)
        return nil;
    img = [images objectForKey:url];
    if (img != nil) {
        [imageLRU removeObject:url];
        [imageLRU addObject:url];
        return img == [NSNull null] ? nil : img;
    }
    disk = [self diskPathForURL:url];
    if ([[NSFileManager defaultManager] fileExistsAtPath:disk]) {
        NSImage *i = [[[NSImage alloc] initWithContentsOfFile:disk] autorelease];
        if (i != nil && [[i representations] count]) {
            [self remember:i forURL:url];
            return i;
        }
    }
    if (![imageLoads containsObject:url]) {
        [imageLoads addObject:url];
        r = [GDHTTPRequest requestWithURL:[NSURL URLWithString:url]];
        [r setUserInfo:url];
        [r setTag:2];
        [r setDelegate:self];
        [r start];
    }
    return nil;
}

/* ----------------------------------------------------------- delivery */

- (void) httpRequestDidFinish:(GDHTTPRequest *)r
{
    NSString *key = [r userInfo];
    if ([r tag] == 1) {
        GDItemDetail *d = [r error] ? nil : [GDGarden parseItem:[r data] path:key];
        [detailLoads removeObject:key];
        if (d != nil) {
            [details setObject:d forKey:key];
            [verdicts setObject:[NSNumber numberWithInt:[GDCompat verdictForItem:d bestFile:NULL]]
                         forKey:key];
        }
        [[NSNotificationCenter defaultCenter] postNotificationName:GDDetailLoadedNotification
                                                            object:key];
    } else {
        NSImage *i = nil;
        [imageLoads removeObject:key];
        if ([r error] == nil && [[r data] length]) {
            i = [[[NSImage alloc] initWithData:[r data]] autorelease];
            if (i != nil && [[i representations] count])
                [[r data] writeToFile:[self diskPathForURL:key] atomically:NO];
            else
                i = nil;
        }
        [self remember:(i ? (id)i : (id)[NSNull null]) forURL:key];
        [[NSNotificationCenter defaultCenter] postNotificationName:GDImageLoadedNotification
                                                            object:key];
    }
}

@end
