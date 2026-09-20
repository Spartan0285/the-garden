#import "GDSelfUpdate.h"
#import "GDHTTP.h"
#import "GDExtract.h"
#import "GDCompat.h"
#include <openssl/evp.h>
#include <unistd.h>
#include <sys/stat.h>
#include <stdarg.h>

NSString *GDSelfUpdateChangedNotification = @"GDSelfUpdateChanged";

/* Where the appcast lives.  raw.githubusercontent.com serves the file on the
 * repository's main branch, so a release is published by committing it. */
static NSString * const GDAppcastURL =
    @"https://raw.githubusercontent.com/Spartan0285/the-garden/main/updates.plist";

/* The release key's public half, raw Ed25519, base64.  The private half is
 * not in this repository; scripts/release.sh signs with it. */
static NSString * const GDReleasePublicKey = @"f19crpWnp22ave4rgXuC2eYjfTcXPuRaVKYUH29OSA4=";

static NSString * const GDLastCheckKey = @"GDLastUpdateCheck";
static const NSTimeInterval GDCheckInterval = 24 * 60 * 60;

@interface GDSelfUpdate (Private)
- (void) appcastArrived:(GDHTTPRequest *)r;
- (void) zipArrived:(GDHTTPRequest *)r;
- (NSDictionary *) newerEntryIn:(NSData *)plist;
- (void) announce;
- (void) installDownloaded;
- (void) failed:(NSString *)why;
@end

/* ---- signatures and hashes --------------------------------------------- */

/* Exactly what scripts/release.sh signs.  It binds the version to the file
 * and to where the file comes from, so a signature cannot be moved to a
 * different download. */
static NSData *signedStatement(NSDictionary *entry)
{
    NSString *s = [NSString stringWithFormat:
        @"TheGarden-update-1\nversion=%@\nbuild=%@\nsha256=%@\nsize=%@\nurl=%@\n",
        [entry objectForKey:@"version"], [entry objectForKey:@"build"],
        [entry objectForKey:@"sha256"], [entry objectForKey:@"size"],
        [entry objectForKey:@"url"]];
    return [s dataUsingEncoding:NSUTF8StringEncoding];
}

/* Base64 without Foundation's help: -initWithBase64Encoding: is 10.6. */
static NSData *decodeBase64(NSString *text)
{
    static const char *alphabet =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    NSMutableData *out = [NSMutableData data];
    const char *p = [text UTF8String];
    unsigned long bits = 0;
    int have = 0;

    if (p == NULL)
        return nil;
    for (; *p; p++) {
        const char *at;
        if (*p == '=' || *p == '\n' || *p == '\r' || *p == ' ')
            continue;
        at = strchr(alphabet, *p);
        if (at == NULL)
            return nil;                 /* not base64: refuse it */
        bits = (bits << 6) | (unsigned long)(at - alphabet);
        have += 6;
        if (have >= 8) {
            unsigned char byte = (unsigned char)((bits >> (have - 8)) & 0xFF);
            have -= 8;
            [out appendBytes:&byte length:1];
        }
    }
    return out;
}

static BOOL signatureIsGood(NSData *statement, NSString *signatureBase64)
{
    NSData *signature = decodeBase64(signatureBase64);
    NSData *key = decodeBase64(GDReleasePublicKey);
    EVP_PKEY *pkey;
    EVP_MD_CTX *ctx;
    BOOL ok = NO;

    if ([signature length] != 64 || [key length] != 32)
        return NO;
    pkey = EVP_PKEY_new_raw_public_key(EVP_PKEY_ED25519, NULL,
                                       (const unsigned char *)[key bytes], 32);
    if (pkey == NULL)
        return NO;
    ctx = EVP_MD_CTX_new();
    if (ctx != NULL) {
        /* Ed25519 signs in one piece: no digest, no streaming. */
        if (EVP_DigestVerifyInit(ctx, NULL, NULL, NULL, pkey) == 1 &&
            EVP_DigestVerify(ctx, (const unsigned char *)[signature bytes], 64,
                             (const unsigned char *)[statement bytes], [statement length]) == 1)
            ok = YES;
        EVP_MD_CTX_free(ctx);
    }
    EVP_PKEY_free(pkey);
    return ok;
}

static NSString *sha256OfFile(NSString *path)
{
    EVP_MD_CTX *ctx = EVP_MD_CTX_new();
    unsigned char digest[EVP_MAX_MD_SIZE];
    unsigned int length = 0, i;
    NSMutableString *hex;
    FILE *f;
    unsigned char buffer[64 * 1024];
    size_t got;

    if (ctx == NULL)
        return nil;
    f = fopen([path fileSystemRepresentation], "rb");
    if (f == NULL) {
        EVP_MD_CTX_free(ctx);
        return nil;
    }
    EVP_DigestInit_ex(ctx, EVP_sha256(), NULL);
    while ((got = fread(buffer, 1, sizeof buffer, f)) > 0)
        EVP_DigestUpdate(ctx, buffer, got);
    fclose(f);
    EVP_DigestFinal_ex(ctx, digest, &length);
    EVP_MD_CTX_free(ctx);
    hex = [NSMutableString string];
    for (i = 0; i < length; i++)
        [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

/* A line in the update log, beside the downloads: when an update is refused
 * there is otherwise nothing to look at, and these machines are often headless
 * when it happens. */
static void updateLog(NSString *format, ...)
{
    va_list args;
    NSString *line, *path;
    NSData *existing;
    NSMutableData *out;

    va_start(args, format);
    line = [[[NSString alloc] initWithFormat:format arguments:args] autorelease];
    va_end(args);
    NSLog(@"The Garden: %@", line);
    path = [[[NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES)
                 objectAtIndex:0] stringByAppendingPathComponent:@"The Garden"]
               stringByAppendingPathComponent:@"update-log.txt"];
    line = [NSString stringWithFormat:@"%@  %@\n", [[NSDate date] description], line];
    existing = [NSData dataWithContentsOfFile:path];
    out = [NSMutableData data];
    /* Keep the tail only: this must never grow without bound. */
    if ([existing length] > 16 * 1024)
        existing = [existing subdataWithRange:NSMakeRange([existing length] - 8 * 1024, 8 * 1024)];
    if (existing != nil)
        [out appendData:existing];
    [out appendData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [out writeToFile:path atomically:YES];
}

/* ---- the updater -------------------------------------------------------- */

@implementation GDSelfUpdate

+ (GDSelfUpdate *) sharedUpdater
{
    static GDSelfUpdate *shared;
    if (shared == nil)
        shared = [[self alloc] init];
    return shared;
}

+ (NSString *) currentVersion
{
    NSString *v = [[NSBundle mainBundle]
                      objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    return [v length] ? v : @"0";
}

+ (int) currentBuild
{
    return [[[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"] intValue];
}

- (BOOL) isBusy { return checking || downloading; }
- (NSString *) availableVersion { return [available objectForKey:@"version"]; }

- (void) dealloc
{
    [request setDelegate:nil];
    [request release];
    [available release];
    [downloadedZip release];
    [super dealloc];
}

- (NSString *) updateDirectory
{
    NSString *dir = [[NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES)
                         objectAtIndex:0] stringByAppendingPathComponent:@"The Garden"];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:dir attributes:nil];
    dir = [dir stringByAppendingPathComponent:@"Update"];
    [fm createDirectoryAtPath:dir attributes:nil];
    return dir;
}

- (void) startCheck
{
    if ([self isBusy])
        return;
    if (available != nil) {         /* already found and downloaded */
        [self announce];
        return;
    }
    checking = YES;
    [request setDelegate:nil];
    [request release];
    request = [[GDHTTPRequest requestWithURL:[NSURL URLWithString:GDAppcastURL]] retain];
    [request setTag:1];
    /* Its own session, and never through PowerEmu: this decides what gets
     * installed, so it goes to the source over verified TLS. */
    [request setUsesSession:YES];
    [request setDelegate:self];
    [request start];
    [[NSUserDefaults standardUserDefaults]
        setObject:[NSNumber numberWithDouble:[NSDate timeIntervalSinceReferenceDate]]
           forKey:GDLastCheckKey];
}

- (void) checkInBackground
{
    double last = [[[NSUserDefaults standardUserDefaults]
                       objectForKey:GDLastCheckKey] doubleValue];
    double now = [NSDate timeIntervalSinceReferenceDate];
    if (last > 0 && now - last < GDCheckInterval)
        return;
    userAsked = NO;
    [self startCheck];
}

- (IBAction) checkForUpdates:(id)sender
{
    userAsked = YES;
    announced = NO;
    [self startCheck];
}

- (void) checkAndInstallNow
{
    userAsked = NO;
    announced = NO;
    installWithoutAsking = YES;
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:GDLastCheckKey];
    [self startCheck];
}

- (void) httpRequestDidFinish:(GDHTTPRequest *)r
{
    if (r != request)
        return;
    if ([r tag] == 1)
        [self appcastArrived:r];
    else
        [self zipArrived:r];
}

@end

@implementation GDSelfUpdate (Private)

- (void) failed:(NSString *)why
{
    checking = downloading = NO;
    updateLog(@"update: %@", why);
    if (userAsked)
        NSRunAlertPanel(@"The Garden could not check for updates", @"%@", @"OK", nil, nil, why);
}

/* The newest entry that is newer than this build, runs on this Mac, and is
 * signed.  nil otherwise - and an entry that fails its signature is not a
 * candidate at all. */
- (NSDictionary *) newerEntryIn:(NSData *)plist
{
    NSString *error = nil;
    NSPropertyListFormat format;
    id root = [NSPropertyListSerialization propertyListFromData:plist
                   mutabilityOption:NSPropertyListImmutable format:&format
                   errorDescription:&error];
    NSDictionary *entry;
    int build;

    if (![root isKindOfClass:[NSDictionary class]])
        return nil;
    entry = root;
    build = [[entry objectForKey:@"build"] intValue];
    if (build <= [GDSelfUpdate currentBuild])
        return nil;
    if ([[entry objectForKey:@"url"] length] == 0 ||
        [[entry objectForKey:@"sha256"] length] != 64)
        return nil;
    /* "10.5" on a Tiger Mac: not for this Mac. */
    {
        NSString *minimum = [entry objectForKey:@"minimumSystemVersion"];
        NSArray *parts = [minimum componentsSeparatedByString:@"."];
        if ([parts count] > 1 && [[parts objectAtIndex:1] intValue] > [GDCompat hostOSMinor])
            return nil;
    }
    if (!signatureIsGood(signedStatement(entry), [entry objectForKey:@"signature"])) {
        updateLog(@"refused build %d (%@): not signed by the release key",
                  build, [entry objectForKey:@"version"]);
        return nil;
    }
    updateLog(@"build %d (%@) is offered and properly signed",
              build, [entry objectForKey:@"version"]);
    return entry;
}

- (void) appcastArrived:(GDHTTPRequest *)r
{
    NSDictionary *entry;
    NSString *zip;

    checking = NO;
    if ([r error] != nil) {
        [self failed:[r error]];
        return;
    }
    entry = [self newerEntryIn:[r data]];
    if (entry == nil) {
        if (userAsked)
            NSRunAlertPanel(@"The Garden is up to date",
                            @"This is version %@, the newest there is.", @"OK", nil, nil,
                            [GDSelfUpdate currentVersion]);
        return;
    }
    [available release];
    available = [entry retain];

    /* Straight to a file: the download survives a restart and resumes. */
    zip = [[self updateDirectory] stringByAppendingPathComponent:
              [NSString stringWithFormat:@"TheGarden-%@.zip", [entry objectForKey:@"version"]]];
    [downloadedZip release];
    downloadedZip = [zip retain];
    if ([[NSFileManager defaultManager] fileExistsAtPath:zip] &&
        [sha256OfFile(zip) isEqualToString:[entry objectForKey:@"sha256"]]) {
        [self announce];            /* got it last time */
        return;
    }
    downloading = YES;
    [request setDelegate:nil];
    [request release];
    request = [[GDHTTPRequest requestWithURL:[NSURL URLWithString:[entry objectForKey:@"url"]]] retain];
    [request setTag:2];
    [request setUsesSession:YES];
    [request setDestinationPath:zip];
    [request setDelegate:self];
    [request start];
    [[NSNotificationCenter defaultCenter]
        postNotificationName:GDSelfUpdateChangedNotification object:nil];
}

- (void) zipArrived:(GDHTTPRequest *)r
{
    NSString *hash;

    downloading = NO;
    if ([r error] != nil) {
        [self failed:[r error]];
        return;
    }
    hash = sha256OfFile(downloadedZip);
    if (![hash isEqualToString:[available objectForKey:@"sha256"]]) {
        [[NSFileManager defaultManager] removeFileAtPath:downloadedZip handler:nil];
        [available release];
        available = nil;
        [self failed:@"The downloaded update did not match its checksum, so it was thrown away."];
        return;
    }
    [self announce];
}

- (void) announce
{
    NSString *notes = [available objectForKey:@"notes"];
    int answer;

    if (announced && !userAsked)
        return;
    announced = YES;
    if (installWithoutAsking) {
        updateLog(@"update %@ verified; installing", [available objectForKey:@"version"]);
        [self installDownloaded];
        return;
    }
    [[NSNotificationCenter defaultCenter]
        postNotificationName:GDSelfUpdateChangedNotification object:nil];
    answer = NSRunAlertPanel(
        [NSString stringWithFormat:@"The Garden %@ is ready to install",
            [available objectForKey:@"version"]],
        @"%@\n\nThe Garden will quit, put this version in the Trash and start again.",
        @"Install and Relaunch", @"Later", nil,
        [notes length] ? notes : @"A newer version of The Garden.");
    if (answer == NSAlertDefaultReturn)
        [self installDownloaded];
}

- (void) installDownloaded
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *work = [[self updateDirectory] stringByAppendingPathComponent:@"unpacked"];
    NSString *bundle = [[NSBundle mainBundle] bundlePath];
    NSString *error = nil;
    NSString *unpacked, *newApp = nil, *helper;
    NSArray *contents;
    unsigned i;

    if (![fm isWritableFileAtPath:[bundle stringByDeletingLastPathComponent]]) {
        NSRunAlertPanel(@"The Garden cannot replace itself where it is",
                        @"\"%@\" is not writable. Move The Garden to your Applications "
                         "folder and try again.", @"OK", nil, nil,
                        [bundle stringByDeletingLastPathComponent]);
        return;
    }

    [fm removeFileAtPath:work handler:nil];
    [fm createDirectoryAtPath:work attributes:nil];
    /* The bundled XADMaster, as for everything else the Garden unpacks: it
     * keeps the symbolic links inside the frameworks, which ditto on these
     * systems does not. */
    unpacked = GDExtractArchive(downloadedZip, work, &error, nil, NULL);
    if (unpacked == nil) {
        [self failed:error ?: @"The update could not be unpacked."];
        return;
    }
    if ([[[unpacked pathExtension] lowercaseString] isEqualToString:@"app"]) {
        newApp = unpacked;
    } else {
        contents = [fm directoryContentsAtPath:unpacked];
        for (i = 0; i < [contents count]; i++)
            if ([[[contents objectAtIndex:i] pathExtension] isEqualToString:@"app"])
                newApp = [unpacked stringByAppendingPathComponent:[contents objectAtIndex:i]];
    }
    if (newApp == nil ||
        ![fm fileExistsAtPath:[newApp stringByAppendingPathComponent:@"Contents/MacOS/TheGarden"]]) {
        [self failed:@"The update did not contain The Garden."];
        return;
    }
    /* What arrived must be what the appcast promised. */
    {
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
                                 [newApp stringByAppendingPathComponent:@"Contents/Info.plist"]];
        if ([[info objectForKey:@"CFBundleVersion"] intValue] !=
            [[available objectForKey:@"build"] intValue]) {
            [self failed:@"The update's version is not the one that was offered."];
            return;
        }
    }

    /* A running application cannot be replaced underneath itself, so a small
     * script waits for this one to quit, moves it to the Trash, puts the new
     * one in its place and opens it. */
    helper = [[self updateDirectory] stringByAppendingPathComponent:@"install.sh"];
    {
        NSString *trash = [NSHomeDirectory() stringByAppendingPathComponent:@".Trash"];
        NSString *script = [NSString stringWithFormat:
            @"#!/bin/sh\n"
             "pid=$1; new=$2; old=$3; trash=$4\n"
             "i=0\n"
             "while kill -0 \"$pid\" 2>/dev/null && [ $i -lt 60 ]; do sleep 1; i=$((i+1)); done\n"
             "name=`basename \"$old\"`\n"
             "keep=\"$trash/$name\"\n"
             "n=2\n"
             "while [ -e \"$keep\" ]; do keep=\"$trash/$name $n\"; n=$((n+1)); done\n"
             "mv \"$old\" \"$keep\" || exit 1\n"
             "if ! ditto \"$new\" \"$old\"; then mv \"$keep\" \"$old\"; exit 1; fi\n"
             "open \"$old\"\n"];
        if (![script writeToFile:helper atomically:YES]) {
            [self failed:@"The update helper could not be written."];
            return;
        }
        chmod([helper fileSystemRepresentation], 0755);
        [NSTask launchedTaskWithLaunchPath:@"/bin/sh"
            arguments:[NSArray arrayWithObjects:helper,
                          [NSString stringWithFormat:@"%d", (int)getpid()],
                          newApp, bundle, trash, nil]];
    }
    [NSApp terminate:nil];
}

@end
