#import "GDInstaller.h"
#import "GDSheepShaver.h"
#import "GDHTTP.h"
#import "GDCatalog.h"
#import "GDUtil.h"
#import "GDExtract.h"
#import <AppKit/AppKit.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/attr.h>
#include <math.h>

NSString *GDJobChangedNotification = @"GDJobChanged";
NSString *GDLibraryChangedNotification = @"GDLibraryChanged";
NSString *GDUpdatesChangedNotification = @"GDUpdatesChanged";

/* ----------------------------------------------------------------- jobs */

@implementation GDInstallJob
- (void) dealloc
{
    [item release]; [file release]; [status release];
    [downloadPath release]; [workDir release]; [installed release];
    [launchPath release]; [revealPath release]; [request release]; [mirrorOrder release];
    [replaces release];
    [super dealloc];
}
- (GDItemDetail *) item { return item; }
- (GDFile *) file { return file; }
- (GDJobState) state { return state; }
- (NSString *) status { return status; }
- (double) progress { return progress; }
- (NSString *) launchPath { return launchPath; }
- (NSString *) revealPath { return revealPath; }
- (BOOL) isActive { return state < GDJobDone; }
@end

/* ------------------------------------------------------- small utilities */

static NSString *runTask(NSString *tool, NSArray *args, int *status)
{
    NSTask *t = [[[NSTask alloc] init] autorelease];
    NSPipe *out = [NSPipe pipe];
    NSData *d;
    [t setLaunchPath:tool];
    [t setArguments:args];
    [t setStandardOutput:out];
    [t setStandardError:out];
    NS_DURING
        [t launch];
    NS_HANDLER
        if (status) *status = -1;
        return @"";
    NS_ENDHANDLER
    d = [[out fileHandleForReading] readDataToEndOfFile];
    [t waitUntilExit];
    if (status)
        *status = [t terminationStatus];
    return [[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] autorelease] ?: @"";
}

static BOOL isDir(NSString *p)
{
    BOOL d = NO;
    return [[NSFileManager defaultManager] fileExistsAtPath:p isDirectory:&d] && d;
}

static NSData *head(NSString *p, unsigned n)
{
    NSFileHandle *h = [NSFileHandle fileHandleForReadingAtPath:p];
    NSData *d = [h readDataOfLength:n];
    [h closeFile];
    return d ?: [NSData data];
}

static BOOL startsWith(NSData *d, const char *magic, unsigned off)
{
    unsigned n = strlen(magic);
    return [d length] >= off + n && memcmp((const char *)[d bytes] + off, magic, n) == 0;
}

/* Finder's "invisible" flag (classic volumes hide their Desktop file etc.). */
static BOOL isInvisible(NSString *p)
{
    struct attrlist al;
    struct { u_int32_t len; char fi[32]; } buf;
    memset(&al, 0, sizeof(al));
    al.bitmapcount = ATTR_BIT_MAP_COUNT;
    al.commonattr = ATTR_CMN_FNDRINFO;
    if (getattrlist([p fileSystemRepresentation], &al, &buf, sizeof(buf), FSOPT_NOFOLLOW) != 0)
        return NO;
    return (((unsigned char)buf.fi[8] << 8) & 0x4000) != 0;
}

/* Visible entries of a folder or volume. */
/* A symbolic link pointing out of the folder we are installing from.
 *
 * Nearly every Mac disk image carries "Applications -> /Applications", the
 * alias you are meant to drag the program onto.  Treating it as content is
 * catastrophic: -fileExistsAtPath:isDirectory: follows the link and says it
 * is a directory, so the installer copied the whole of /Applications into a
 * new folder inside /Applications, recursively, until the disk filled.  Found
 * on Marathon: Aleph One, 8.9 GB in before it was stopped.
 *
 * Links that stay inside the payload are kept; they belong to it. */
static BOOL linksOutside(NSString *dir, NSString *name)
{
    NSString *p = [dir stringByAppendingPathComponent:name];
    struct stat st;
    NSString *target, *base;

    if (lstat([p fileSystemRepresentation], &st) != 0 || !S_ISLNK(st.st_mode))
        return NO;
    target = [p stringByResolvingSymlinksInPath];
    base = [dir stringByResolvingSymlinksInPath];
    return !([target isEqualToString:base] ||
             [target hasPrefix:[base stringByAppendingString:@"/"]]);
}

static NSArray *visibleContents(NSString *dir)
{
    NSArray *all = [[NSFileManager defaultManager] directoryContentsAtPath:dir];
    NSMutableArray *out = [NSMutableArray array];
    unsigned i;
    for (i = 0; i < [all count]; i++) {
        NSString *n = [all objectAtIndex:i];
        if ([n hasPrefix:@"."] || [n isEqualToString:@"Desktop DB"] ||
            [n isEqualToString:@"Desktop DF"] || [n isEqualToString:@"Icon\r"] ||
            [n isEqualToString:@"TheVolumeSettingsFolder"] || [n isEqualToString:@"Trash"] ||
            [n isEqualToString:@"Network Trash Folder"] || [n isEqualToString:@"__MACOSX"] ||
            [n hasPrefix:@"Desktop Folder"] || [n isEqualToString:@"AppleShare PDS"] ||
            [n isEqualToString:@"Move&Rename"] || [n isEqualToString:@"Temporary Items"] ||
            [n isEqualToString:@"Cleanup At Startup"] || [n isEqualToString:@"Shutdown Check"] ||
            [n isEqualToString:@"OpenFolderListDF\r"] || [n isEqualToString:@"Icon\r"] ||
            isInvisible([dir stringByAppendingPathComponent:n]) ||
            linksOutside(dir, n))
            continue;
        [out addObject:n];
    }
    return out;
}

static BOOL isDoc(NSString *name)
{
    NSString *l = [name lowercaseString];
    NSString *e = [l pathExtension];
    return [e isEqualToString:@"txt"] || [e isEqualToString:@"rtf"] || [e isEqualToString:@"rtfd"] ||
           [e isEqualToString:@"pdf"] || [e isEqualToString:@"html"] || [e isEqualToString:@"htm"] ||
           [e isEqualToString:@"webloc"] || [e isEqualToString:@"url"] ||
           [l rangeOfString:@"read"].location != NSNotFound ||
           [l rangeOfString:@"license"].location != NSNotFound ||
           [l rangeOfString:@"licence"].location != NSNotFound;
}

static OSType fileType(NSString *p)
{
    NSDictionary *a = [[NSFileManager defaultManager] fileAttributesAtPath:p traverseLink:NO];
    return [[a objectForKey:NSFileHFSTypeCode] unsignedLongValue];
}

/* How likely a program is the one people mean by the title.  Helpers that
 * ship next to the program (updaters, installers, Read Me viewers, network
 * clients) lose to it; a name sharing a word with the title wins. */
static int launchScore(NSString *path, NSString *title)
{
    NSString *n = [[[path lastPathComponent] stringByDeletingPathExtension] lowercaseString];
    NSArray *helpers = [NSArray arrayWithObjects:@"update", @"install", @"uninstall", @"read me", @"readme",
                                 @"patch", @"setup", @"battle.net", @"register", @"registration", @"help",
                                 @"manual", @"license", @"remover", @"updater", @"launcher prefs", @"editor", nil];
    NSArray *words = [[title ?: @"" lowercaseString] componentsSeparatedByString:@" "];
    int score = 0;
    unsigned i;
    for (i = 0; i < [helpers count]; i++)
        if ([n rangeOfString:[helpers objectAtIndex:i]].location != NSNotFound)
            score -= 20;
    for (i = 0; i < [words count]; i++) {
        NSString *w = [words objectAtIndex:i];
        if ([w length] >= 3 && [n rangeOfString:w].location != NSNotFound)
            score += 10;
    }
    if ([[path pathExtension] isEqualToString:@"app"])
        score += 2;             /* a native program beats a classic one alike */
    return score;
}

static void collectLaunchables(NSString *root, int depth, NSMutableArray *out)
{
    NSArray *c;
    unsigned i;
    if ([[root pathExtension] isEqualToString:@"app"]) {
        [out addObject:[NSArray arrayWithObjects:root, [NSNumber numberWithInt:depth], nil]];
        return;
    }
    if (!isDir(root)) {
        if (fileType(root) == 'APPL')
            [out addObject:[NSArray arrayWithObjects:root, [NSNumber numberWithInt:depth], nil]];
        return;
    }
    if (depth > 3)
        return;
    c = visibleContents(root);
    for (i = 0; i < [c count]; i++)
        collectLaunchables([root stringByAppendingPathComponent:[c objectAtIndex:i]], depth + 1, out);
}

/* The program to open for this title: best name match, then shallowest. */
static NSString *findLaunchableFor(NSString *root, NSString *title)
{
    NSMutableArray *all = [NSMutableArray array];
    NSString *best = nil;
    int bestScore = -1000, bestDepth = 99;
    unsigned i;
    collectLaunchables(root, 0, all);
    for (i = 0; i < [all count]; i++) {
        NSString *p = [[all objectAtIndex:i] objectAtIndex:0];
        int d = [[[all objectAtIndex:i] objectAtIndex:1] intValue];
        int sc = launchScore(p, title);
        if (sc > bestScore || (sc == bestScore && d < bestDepth)) {
            best = p;
            bestScore = sc;
            bestDepth = d;
        }
    }
    return best;
}

static NSString *safeName(NSString *s)
{
    NSMutableString *m = [[s mutableCopy] autorelease];
    [m replaceOccurrencesOfString:@"/" withString:@"-" options:0 range:NSMakeRange(0, [m length])];
    [m replaceOccurrencesOfString:@":" withString:@"-" options:0 range:NSMakeRange(0, [m length])];
    if ([m length] > 60)
        [m deleteCharactersInRange:NSMakeRange(60, [m length] - 60)];
    return [m length] ? m : @"Download";
}

/* ------------------------------------------------------------ installer */

@interface GDInstaller (Private)
- (void) changed:(GDInstallJob *)job;
- (void) startDownload:(GDInstallJob *)job;
- (void) saveLibrary;
- (NSString *) attachImage:(NSString *)p;
- (void) repairLaunchPaths;
- (void) recordJob:(GDInstallJob *)job;
- (void) saveHistory;
- (void) saveIgnored;
- (NSMutableDictionary *) recordForKey:(NSString *)key;
- (GDFile *) fileFromRecord:(NSDictionary *)h;
- (GDItemDetail *) detailFromRecord:(NSDictionary *)h;
@end

/* How many past downloads to keep.  Only records nothing is working on are
 * dropped, oldest first. */
#define GD_HISTORY_MAX 40

/* A record's identity, and the key an ignored update is remembered under.
 * A file name is unique within an item, and neither part can hold a tab. */
static NSString *gdKey(NSString *path, NSString *file)
{
    return [NSString stringWithFormat:@"%@\t%@", path ?: @"", file ?: @""];
}

static NSString *jobStateName(GDJobState s)
{
    switch (s) {
    case GDJobDone:      return @"done";
    case GDJobFailed:    return @"failed";
    case GDJobCancelled: return @"cancelled";
    default:             return @"downloading";    /* every state still running */
    }
}

/* -setObject:forKey: with a nil object throws; most of a record is optional. */
static void put(NSMutableDictionary *d, NSString *key, id value)
{
    if (value != nil)
        [d setObject:value forKey:key];
}

@implementation GDInstaller

+ (GDInstaller *) sharedInstaller
{
    static GDInstaller *i;
    if (i == nil)
        i = [[GDInstaller alloc] init];
    return i;
}

+ (NSString *) downloadsFolder
{
    NSString *d = [[NSHomeDirectory() stringByAppendingPathComponent:@"Downloads"]
                      stringByAppendingPathComponent:@"The Garden"];
    [[NSFileManager defaultManager] createDirectoryAtPath:[d stringByDeletingLastPathComponent]
                                               attributes:nil];
    [[NSFileManager defaultManager] createDirectoryAtPath:d attributes:nil];
    return d;
}

/* ------------------------------------------------------------- updates */

/* A file name's "kind": lower-case, version numbers, archive wrappers and
 * release words removed.  legacy_132beta1_macosx_sit.hqx and
 * legacy_140_macosx.dmg are the same kind; IE5.1.7fr.sit and IE5.1.7.sit are not. */
static NSString *fileKind(NSString *name)
{
    NSMutableString *m = [[[name lowercaseString] mutableCopy] autorelease];
    NSArray *junk = [NSArray arrayWithObjects:@".sitx", @".sit", @"_sit", @".hqx", @".bin", @".zip", @".dmg", @".img",
                              @".smi", @".toast", @".cdr", @".iso", @".sea", @".cpt", @".tgz", @".gz",
                              @"beta", @"alpha", @"final", @"release", @"_folder", @"folder", @"_", @"-",
                              @".", @" ", nil];
    unsigned i, k;
    for (i = 0; i < [junk count]; i++)
        [m replaceOccurrencesOfString:[junk objectAtIndex:i] withString:@"" options:0
                                range:NSMakeRange(0, [m length])];
    for (k = 0; k < [m length]; ) {
        unichar c = [m characterAtIndex:k];
        if (c >= '0' && c <= '9')
            [m deleteCharactersInRange:NSMakeRange(k, 1)];
        else
            k++;
    }
    /* A lone trailing "b"/"a" left from "132b1"-style betas. */
    while ([m hasSuffix:@"b"] || [m hasSuffix:@"a"])
        [m deleteCharactersInRange:NSMakeRange([m length] - 1, 1)];
    return m;
}

/* The version in a file name as a comparable list: "1.48.6" -> 1,48,6;
 * "legacy_140" -> 140 (written without dots). */
static NSArray *fileVersion(NSString *name)
{
    NSScanner *sc = [NSScanner scannerWithString:name];
    NSMutableArray *v = [NSMutableArray array];
    NSCharacterSet *digits = [NSCharacterSet decimalDigitCharacterSet];
    int n;
    [sc scanUpToCharactersFromSet:digits intoString:NULL];
    while ([sc scanInt:&n]) {
        [v addObject:[NSNumber numberWithInt:n]];
        if (![sc scanString:@"." intoString:NULL])
            break;
    }
    return v;
}

static int compareVersions(NSArray *a, NSArray *b)
{
    unsigned i;
    /* "132" vs "140" and "1.3.2" vs "1.4": compare digit strings when either
     * has no dots. */
    if ([a count] == 1 || [b count] == 1) {
        NSString *sa = [a componentsJoinedByString:@""], *sb = [b componentsJoinedByString:@""];
        unsigned w = MAX([sa length], [sb length]);
        while ([sa length] < w) sa = [sa stringByAppendingString:@"0"];
        while ([sb length] < w) sb = [sb stringByAppendingString:@"0"];
        return [sa compare:sb];
    }
    for (i = 0; i < MAX([a count], [b count]); i++) {
        int x = i < [a count] ? [[a objectAtIndex:i] intValue] : 0;
        int y = i < [b count] ? [[b objectAtIndex:i] intValue] : 0;
        if (x != y)
            return x < y ? -1 : 1;
    }
    return 0;
}

+ (GDFile *) newerFileFor:(NSDictionary *)entry inDetail:(GDItemDetail *)d
{
    NSString *have = [entry objectForKey:@"file"];
    GDFile *mine = nil, *best = nil;
    NSString *kind;
    NSArray *myVer;
    unsigned i;
    if (d == nil || [have length] == 0)
        return nil;
    for (i = 0; i < [[d files] count]; i++)
        if ([[[[d files] objectAtIndex:i] name] isEqualToString:have])
            mine = [[d files] objectAtIndex:i];
    kind = fileKind(have);
    myVer = fileVersion(have);
    for (i = 0; i < [[d files] count]; i++) {
        GDFile *f = [[d files] objectAtIndex:i];
        NSArray *v = fileVersion([f name]);
        NSString *ln = [[f name] lowercaseString];
        if (f == mine || ![fileKind([f name]) isEqualToString:kind])
            continue;
        if (![GDCompat runsHere:[GDCompat verdictForFile:f architecture:[d architecture]]] ||
            [GDCompat verdictForFile:f architecture:[d architecture]] == GDVerdictUnknown)
            continue;
        if ([ln rangeOfString:@"beta"].location != NSNotFound || [ln rangeOfString:@"demo"].location != NSNotFound)
            continue;
        /* Versions when both names carry one; upload dates only when
         * neither does (a re-upload is not a newer version); if just one
         * has a number there is no telling, so no offer. */
        if ([v count] && [myVer count]) {
            if (compareVersions(v, myVer) <= 0)
                continue;
        } else if ([v count] == 0 && [myVer count] == 0) {
            if (!(mine && [[f date] compare:[mine date]] == NSOrderedDescending))
                continue;
        } else {
            continue;
        }
        if (best == nil || compareVersions(fileVersion([f name]), fileVersion([best name])) > 0)
            best = f;
    }
    return best;
}

- (void) recomputeUpdates:(NSNotification *)n
{
    NSMutableArray *u = [NSMutableArray array];
    unsigned i;
    for (i = 0; i < [library count]; i++) {
        NSDictionary *e = [library objectAtIndex:i];
        GDItemDetail *d = [[GDCatalog sharedCatalog] detailForPath:[e objectForKey:@"path"]];
        GDFile *f = [GDInstaller newerFileFor:e inDetail:d];
        /* A title stays here while its update is downloading and installing -
         * it is not up to date until that has finished.  Once it has, the
         * library entry names the new file and there is nothing newer, so the
         * row leaves by itself. */
        if (f && ![self isUpdateIgnoredForPath:[e objectForKey:@"path"] file:[f name]])
            [u addObject:[NSDictionary dictionaryWithObjectsAndKeys:e, @"entry", f, @"file", d, @"detail", nil]];
    }
    if (![u isEqualToArray:updates]) {
        [updates setArray:u];
        [[NSNotificationCenter defaultCenter] postNotificationName:GDUpdatesChangedNotification object:self];
    }
}

- (void) checkForUpdates
{
    unsigned i;
    /* Item pages of installed titles, at most a day old. */
    for (i = 0; i < [library count]; i++)
        [[GDCatalog sharedCatalog] detailForPath:[[library objectAtIndex:i] objectForKey:@"path"]];
    [self recomputeUpdates:nil];
}

- (NSArray *) updates { return updates; }

/* An item page has arrived.  If a retry was waiting for this one, it can go
 * ahead now; either way the update list may have changed. */
- (void) detailLoaded:(NSNotification *)n
{
    NSString *path = [n object];
    if ([path isKindOfClass:[NSString class]] && [retrying containsObject:path]) {
        NSArray *snapshot = [[history copy] autorelease];
        unsigned i;
        [retrying removeObject:path];
        for (i = 0; i < [snapshot count]; i++) {
            NSDictionary *h = [snapshot objectAtIndex:i];
            if ([[h objectForKey:@"path"] isEqualToString:path] &&
                [[h objectForKey:@"state"] isEqualToString:@"retrying"])
                [self retryHistoryEntry:h];
        }
    }
    [self recomputeUpdates:n];
}

/* ------------------------------------------------------- ignored updates */

- (BOOL) isUpdateIgnoredForPath:(NSString *)path file:(NSString *)name
{
    return [ignored containsObject:gdKey(path, name)];
}

- (void) ignoreUpdate:(NSDictionary *)u
{
    NSDictionary *e = [u objectForKey:@"entry"];
    GDFile *f = [u objectForKey:@"file"];
    NSString *k;
    if (e == nil || f == nil)
        return;
    k = gdKey([e objectForKey:@"path"], [f name]);
    if (![ignored containsObject:k])
        [ignored addObject:k];
    [self saveIgnored];
    [self recomputeUpdates:nil];
}

- (unsigned) ignoredUpdateCount { return (unsigned)[ignored count]; }

- (void) clearIgnoredUpdates
{
    if ([ignored count] == 0)
        return;
    [ignored removeAllObjects];
    [self saveIgnored];
    [self recomputeUpdates:nil];
}

- (void) saveIgnored
{
    [[NSUserDefaults standardUserDefaults] setObject:ignored forKey:@"GDIgnoredUpdates"];
}

- (GDInstallJob *) installUpdate:(NSDictionary *)u
{
    GDInstallJob *job = [self installFile:[u objectForKey:@"file"] ofItem:[u objectForKey:@"detail"]];
    [self recomputeUpdates:nil];
    return job;
}

/* ---------------------------------------------------------------- icons */

- (NSString *) iconDir
{
    NSString *d = [[libraryPath stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"Icons"];
    [[NSFileManager defaultManager] createDirectoryAtPath:d attributes:nil];
    return d;
}

- (NSImage *) iconForEntry:(NSDictionary *)e
{
    static NSMutableDictionary *mem;
    NSString *target = [e objectForKey:@"launch"] ?: [[e objectForKey:@"installed"] lastObject];
    NSString *png;
    NSImage *img;
    if (target == nil || ![[NSFileManager defaultManager] fileExistsAtPath:target])
        return nil;
    if (mem == nil)
        mem = [[NSMutableDictionary alloc] init];
    if ((img = [mem objectForKey:target]) != nil)
        return img;
    png = [[self iconDir] stringByAppendingPathComponent:[GDMD5OfString(target) stringByAppendingPathExtension:@"tiff"]];
    img = [[[NSImage alloc] initWithContentsOfFile:png] autorelease];
    if (img == nil) {
        /* The Finder's icon: an .app's icns, or a classic program's icon resources. */
        img = [[NSWorkspace sharedWorkspace] iconForFile:target];
        [img setSize:NSMakeSize(128, 128)];
        [[img TIFFRepresentation] writeToFile:png atomically:YES];
    }
    if (img)
        [mem setObject:img forKey:target];
    return img;
}

/* ----------------------------------------------------------------- dock */

- (BOOL) addToDock:(NSDictionary *)e
{
    NSString *app = [e objectForKey:@"launch"];
    NSMutableArray *apps;
    NSDictionary *tile;
    CFPropertyListRef cur;
    unsigned i;
    if (app == nil)
        return NO;
    cur = CFPreferencesCopyAppValue(CFSTR("persistent-apps"), CFSTR("com.apple.dock"));
    apps = [NSMutableArray arrayWithArray:(NSArray *)cur ?: [NSArray array]];
    if (cur)
        CFRelease(cur);
    for (i = 0; i < [apps count]; i++) {
        NSString *u = [[[[apps objectAtIndex:i] objectForKey:@"tile-data"] objectForKey:@"file-data"]
                          objectForKey:@"_CFURLString"];
        if ([u isEqualToString:app] || [[[NSURL URLWithString:u] path] isEqualToString:app])
            return YES;     /* already there */
    }
    tile = [NSDictionary dictionaryWithObjectsAndKeys:
               [NSDictionary dictionaryWithObjectsAndKeys:
                   [NSDictionary dictionaryWithObjectsAndKeys:app, @"_CFURLString",
                       [NSNumber numberWithInt:0], @"_CFURLStringType", nil], @"file-data",
                   [[app lastPathComponent] stringByDeletingPathExtension], @"file-label", nil], @"tile-data",
               @"file-tile", @"tile-type", nil];
    [apps addObject:tile];
    CFPreferencesSetAppValue(CFSTR("persistent-apps"), (CFArrayRef)apps, CFSTR("com.apple.dock"));
    CFPreferencesAppSynchronize(CFSTR("com.apple.dock"));
    /* The Dock rereads its preferences when restarted, as it does after
     * dragging an app in; it comes straight back. */
    [NSTask launchedTaskWithLaunchPath:@"/usr/bin/killall" arguments:[NSArray arrayWithObject:@"Dock"]];
    return YES;
}

- (id) init
{
    NSString *dir;
    if ((self = [super init]) == nil)
        return nil;
    jobs = [[NSMutableArray alloc] init];
    dir = [[NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES)
               objectAtIndex:0] stringByAppendingPathComponent:@"The Garden"];
    [[NSFileManager defaultManager] createDirectoryAtPath:[dir stringByDeletingLastPathComponent]
                                               attributes:nil];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir attributes:nil];
    libraryPath = [[dir stringByAppendingPathComponent:@"Library.plist"] retain];
    library = [[NSMutableArray alloc] initWithContentsOfFile:libraryPath] ?: [[NSMutableArray alloc] init];
    speeds = [[[NSUserDefaults standardUserDefaults] dictionaryForKey:@"GDMirrorSpeeds"] mutableCopy]
             ?: [[NSMutableDictionary alloc] init];
    updates = [[NSMutableArray alloc] init];
    retrying = [[NSMutableSet alloc] init];
    ignored = [[[NSUserDefaults standardUserDefaults] arrayForKey:@"GDIgnoredUpdates"] mutableCopy]
              ?: [[NSMutableArray alloc] init];
    historyPath = [[dir stringByAppendingPathComponent:@"History.plist"] retain];
    {
        /* Records are mutable from here on; a plist read gives immutable ones.
         * Anything still marked as downloading belongs to a run that never got
         * to finish - the app crashed, or was killed - so it is offered as an
         * interrupted download that can be tried again. */
        NSArray *saved = [NSArray arrayWithContentsOfFile:historyPath];
        unsigned i;
        BOOL repaired = NO;
        history = [[NSMutableArray alloc] init];
        for (i = 0; i < [saved count]; i++) {
            NSMutableDictionary *h = [[[saved objectAtIndex:i] mutableCopy] autorelease];
            if (![h isKindOfClass:[NSDictionary class]] || [h objectForKey:@"key"] == nil)
                continue;
            if ([[h objectForKey:@"state"] isEqualToString:@"downloading"] ||
                [[h objectForKey:@"state"] isEqualToString:@"retrying"]) {
                [h setObject:@"interrupted" forKey:@"state"];
                [h setObject:@"The Garden stopped before this finished." forKey:@"status"];
                repaired = YES;
            }
            [history addObject:h];
        }
        if (repaired)
            [self saveHistory];
    }
    [self repairLaunchPaths];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(detailLoaded:)
                                                 name:GDDetailLoadedNotification object:nil];
    return self;
}

/* Entries made by earlier versions may point Open at a helper (an updater
 * found first) or at nothing; choose again with the title in mind. */
- (void) repairLaunchPaths
{
    BOOL changed = NO;
    unsigned i;
    for (i = 0; i < [library count]; i++) {
        NSMutableDictionary *e = [[[library objectAtIndex:i] mutableCopy] autorelease];
        NSArray *inst = [e objectForKey:@"installed"];
        NSString *old = [e objectForKey:@"launch"], *best;
        if ([inst count] == 0 || ![[NSFileManager defaultManager] fileExistsAtPath:[inst objectAtIndex:0]])
            continue;
        best = findLaunchableFor([inst objectAtIndex:0], [e objectForKey:@"title"]);
        if (best && ![best isEqualToString:old]) {
            [e setObject:best forKey:@"launch"];
            [library replaceObjectAtIndex:i withObject:e];
            changed = YES;
        }
    }
    if (changed)
        [library writeToFile:libraryPath atomically:YES];
}

- (NSArray *) jobs { return jobs; }
- (NSArray *) library { return library; }

- (NSDictionary *) libraryEntryForPath:(NSString *)path
{
    unsigned i;
    for (i = 0; i < [library count]; i++)
        if ([[[library objectAtIndex:i] objectForKey:@"path"] isEqualToString:path])
            return [library objectAtIndex:i];
    return nil;
}

- (GDInstallJob *) jobForItemPath:(NSString *)path
{
    int i;
    for (i = (int)[jobs count] - 1; i >= 0; i--) {
        GDInstallJob *j = [jobs objectAtIndex:i];
        if ([[j->item path] isEqualToString:path])
            return j;
    }
    return nil;
}

- (void) saveLibrary
{
    [library writeToFile:libraryPath atomically:YES];
    [[NSNotificationCenter defaultCenter] postNotificationName:GDLibraryChangedNotification object:self];
}

- (void) removeLibraryEntry:(NSDictionary *)entry moveToTrash:(BOOL)trash
{
    if (trash) {
        NSArray *paths = [entry objectForKey:@"installed"];
        unsigned i;
        for (i = 0; i < [paths count]; i++) {
            NSString *p = [paths objectAtIndex:i];
            [[NSWorkspace sharedWorkspace]
                performFileOperation:NSWorkspaceRecycleOperation
                              source:[p stringByDeletingLastPathComponent]
                         destination:@""
                               files:[NSArray arrayWithObject:[p lastPathComponent]]
                                 tag:NULL];
        }
    }
    [library removeObject:entry];
    [self saveLibrary];
}

/* ------------------------------------------------------ download history */

- (NSArray *) history { return history; }

- (NSMutableDictionary *) recordForKey:(NSString *)key
{
    unsigned i;
    for (i = 0; i < [history count]; i++) {
        NSMutableDictionary *h = [history objectAtIndex:i];
        if ([[h objectForKey:@"key"] isEqualToString:key])
            return h;
    }
    return nil;
}

- (GDInstallJob *) jobForHistoryEntry:(NSDictionary *)h
{
    NSString *key = [h objectForKey:@"key"];
    int i;
    if (key == nil)
        return nil;
    for (i = (int)[jobs count] - 1; i >= 0; i--) {
        GDInstallJob *j = [jobs objectAtIndex:i];
        if (j->item != nil && j->file != nil &&
            [gdKey([j->item path], [j->file name]) isEqualToString:key])
            return j;
    }
    return nil;
}

/* Being worked on right now: the row cannot be removed, and the record must
 * not be dropped to make room. */
- (BOOL) isRecordBusy:(NSDictionary *)h
{
    GDInstallJob *j = [self jobForHistoryEntry:h];
    if (j != nil && [j isActive])
        return YES;
    return [[h objectForKey:@"state"] isEqualToString:@"retrying"];
}

- (void) saveHistory
{
    /* A cap, so a copy kept for years does not grow without end. */
    while ([history count] > GD_HISTORY_MAX) {
        int i, drop = -1;
        for (i = (int)[history count] - 1; i >= 0; i--)
            if (![self isRecordBusy:[history objectAtIndex:i]]) {
                drop = i;
                break;
            }
        if (drop < 0)
            break;
        [history removeObjectAtIndex:drop];
    }
    [history writeToFile:historyPath atomically:YES];
}

/* The record for a job: made the first time, kept in step after that.  It is
 * written out at each change, because the whole point is to still be there
 * when this run of the app is not. */
- (void) recordJob:(GDInstallJob *)job
{
    NSMutableDictionary *h;
    NSString *key;

    if (job == nil || job->item == nil || job->file == nil)
        return;
    key = gdKey([job->item path], [job->file name]);
    h = [self recordForKey:key];
    if (h == nil) {
        h = [NSMutableDictionary dictionary];
        [h setObject:key forKey:@"key"];
        [history insertObject:h atIndex:0];
    } else if ([history objectAtIndex:0] != h) {
        /* Newest first: whatever was just worked on goes to the top. */
        [[h retain] autorelease];
        [history removeObject:h];
        [history insertObject:h atIndex:0];
    }
    put(h, @"path", [job->item path]);
    put(h, @"title", [job->item title]);
    put(h, @"thumb", [job->item thumbURL]);
    put(h, @"arch", [job->item architecture]);
    put(h, @"file", [job->file name]);
    put(h, @"size", [job->file sizeText]);
    put(h, @"sizeBytes", [NSNumber numberWithDouble:[job->file sizeBytes]]);
    put(h, @"fileDate", [job->file date]);
    put(h, @"md5", [job->file md5]);
    put(h, @"systems", [job->file systems]);
    put(h, @"mirrors", [job->file mirrors]);
    put(h, @"verdict", [NSNumber numberWithInt:job->verdict]);
    put(h, @"state", jobStateName(job->state));
    put(h, @"status", job->status);
    put(h, @"date", [NSDate date]);
    put(h, @"bytesDone", [NSNumber numberWithLongLong:job->bytesDone]);
    put(h, @"bytesTotal", [NSNumber numberWithLongLong:job->bytesTotal]);
    put(h, @"launch", job->launchPath);
    put(h, @"reveal", job->revealPath);
    [self saveHistory];
}

- (void) setRecordForKey:(NSString *)key state:(NSString *)st status:(NSString *)text
{
    NSMutableDictionary *h = [self recordForKey:key];
    if (h == nil)
        return;
    put(h, @"state", st);
    put(h, @"status", text);
    put(h, @"date", [NSDate date]);
    [self saveHistory];
    [[NSNotificationCenter defaultCenter] postNotificationName:GDLibraryChangedNotification object:self];
}

/* The file as the page described it when it was asked for.  Used when the item
 * page cannot be had again - the mirrors were saved with the record, so a
 * download interrupted days ago can still be resumed offline from the site. */
- (GDFile *) fileFromRecord:(NSDictionary *)h
{
    GDFile *f;
    if ([[h objectForKey:@"mirrors"] count] == 0 || [h objectForKey:@"file"] == nil)
        return nil;
    f = [[[GDFile alloc] init] autorelease];
    f->name = [[h objectForKey:@"file"] copy];
    f->sizeText = [[h objectForKey:@"size"] copy];
    f->sizeBytes = [[h objectForKey:@"sizeBytes"] doubleValue];
    f->date = [[h objectForKey:@"fileDate"] copy];
    f->md5 = [[h objectForKey:@"md5"] copy];
    f->systems = [[h objectForKey:@"systems"] copy];
    f->mirrors = [[h objectForKey:@"mirrors"] copy];
    return f;
}

- (GDItemDetail *) detailFromRecord:(NSDictionary *)h
{
    GDItemDetail *d = [[[GDItemDetail alloc] init] autorelease];
    NSArray *parts = [([h objectForKey:@"path"] ?: @"") pathComponents];
    NSString *section = [parts count] > 1 ? [parts objectAtIndex:1] : @"apps";
    NSString *slug = [parts count] > 2 ? [parts objectAtIndex:2] : @"";
    d->section = [section copy];
    d->slug = [slug copy];
    d->title = [([h objectForKey:@"title"] ?: @"") copy];
    d->thumbURL = [[h objectForKey:@"thumb"] copy];
    d->architecture = [[h objectForKey:@"arch"] copy];
    return d;
}

static GDFile *fileNamed(NSString *name, GDItemDetail *d)
{
    unsigned i;
    for (i = 0; i < [[d files] count]; i++)
        if ([[[[d files] objectAtIndex:i] name] isEqualToString:name])
            return [[d files] objectAtIndex:i];
    return nil;
}

- (void) retryHistoryEntry:(NSDictionary *)h
{
    GDInstallJob *live = [self jobForHistoryEntry:h];
    NSString *key = [h objectForKey:@"key"], *path = [h objectForKey:@"path"];
    GDItemDetail *d;
    GDFile *f;
    BOOL waited;

    if (live != nil) {
        /* Still this run: the job knows where it got to, and resumes. */
        if (![live isActive])
            [self retry:live];
        return;
    }
    /* A record from an earlier run.  Ask for the item page first, so the
     * download links are fresh ones; the saved mirrors are the fallback. */
    waited = [[h objectForKey:@"state"] isEqualToString:@"retrying"];
    d = [path length] ? [[GDCatalog sharedCatalog] detailForPath:path] : nil;
    if (d == nil && !waited) {
        [retrying addObject:path];
        [self setRecordForKey:key state:@"retrying" status:@"Looking up the item page..."];
        return;
    }
    f = d != nil ? fileNamed([h objectForKey:@"file"], d) : nil;
    if (f == nil) {
        f = [self fileFromRecord:h];
        if (d == nil)
            d = [self detailFromRecord:h];
    }
    if (f == nil) {
        [self setRecordForKey:key state:@"failed"
                       status:@"This file is no longer listed on its Garden page."];
        return;
    }
    [self installFile:f ofItem:d];
    [[NSNotificationCenter defaultCenter] postNotificationName:GDLibraryChangedNotification object:self];
}

- (void) removeHistoryEntry:(NSDictionary *)h
{
    GDInstallJob *j;
    if ([self isRecordBusy:h])
        return;                        /* cancel it first */
    j = [self jobForHistoryEntry:h];
    if (j != nil)
        [jobs removeObject:j];
    [retrying removeObject:[h objectForKey:@"path"] ?: @""];
    [history removeObject:h];
    [self saveHistory];
    [self changed:nil];
    [[NSNotificationCenter defaultCenter] postNotificationName:GDLibraryChangedNotification object:self];
}

- (void) clearHistory
{
    int i;
    for (i = (int)[history count] - 1; i >= 0; i--) {
        NSDictionary *h = [history objectAtIndex:i];
        GDInstallJob *j;
        if ([self isRecordBusy:h])
            continue;
        j = [self jobForHistoryEntry:h];
        if (j != nil)
            [jobs removeObject:j];
        [history removeObjectAtIndex:i];
    }
    /* Jobs with no record of their own (nothing should be left) go too. */
    for (i = (int)[jobs count] - 1; i >= 0; i--)
        if (![[jobs objectAtIndex:i] isActive])
            [jobs removeObjectAtIndex:i];
    [self saveHistory];
    [self changed:nil];
    [[NSNotificationCenter defaultCenter] postNotificationName:GDLibraryChangedNotification object:self];
}

/* ---------------------------------------------------------------- jobs */

- (void) changed:(GDInstallJob *)job
{
    [[NSNotificationCenter defaultCenter] postNotificationName:GDJobChangedNotification object:job];
}

- (void) setJob:(GDInstallJob *)job state:(GDJobState)s status:(NSString *)text
{
    job->state = s;
    [job->status autorelease];
    job->status = [text copy];
    [self recordJob:job];
    [self changed:job];
}

- (NSArray *) orderMirrors:(NSArray *)m
{
    /* Best measured speed first; hosts never tried keep the page's order,
     * ahead of ones known to be slow (below 100 KB/s). */
    NSMutableArray *known = [NSMutableArray array], *fresh = [NSMutableArray array],
                   *slow = [NSMutableArray array];
    unsigned i, j;
    for (i = 0; i < [m count]; i++) {
        NSString *u = [m objectAtIndex:i];
        NSNumber *sp = [speeds objectForKey:[[NSURL URLWithString:u] host] ?: @""];
        if (sp == nil)
            [fresh addObject:u];
        else if ([sp doubleValue] < 100 * 1024)
            [slow addObject:u];
        else {
            for (j = 0; j < [known count]; j++)
                if ([[speeds objectForKey:[[NSURL URLWithString:[known objectAtIndex:j]] host]] doubleValue]
                        < [sp doubleValue])
                    break;
            [known insertObject:u atIndex:j];
        }
    }
    [known addObjectsFromArray:fresh];
    [known addObjectsFromArray:slow];
    return known;
}

- (void) noteSpeed:(double)bps host:(NSString *)host
{
    NSNumber *old = [speeds objectForKey:host];
    if (host == nil || bps <= 0)
        return;
    if (old)
        bps = 0.6 * bps + 0.4 * [old doubleValue];
    [speeds setObject:[NSNumber numberWithDouble:bps] forKey:host];
    [[NSUserDefaults standardUserDefaults] setObject:speeds forKey:@"GDMirrorSpeeds"];
}

static NSString *megabytes(double b)
{
    return b >= 1024 * 1024 * 1024 ? [NSString stringWithFormat:@"%.1f GB", b / (1024.0 * 1024 * 1024)]
                                    : [NSString stringWithFormat:@"%.0f MB", ceil(b / (1024.0 * 1024))];
}

- (GDInstallJob *) installFile:(GDFile *)f ofItem:(GDItemDetail *)d
{
    GDInstallJob *job = [[[GDInstallJob alloc] init] autorelease];
    NSDictionary *fs;
    double freeBytes, need;
    job->item = [d retain];
    job->file = [f retain];
    job->verdict = [GDCompat verdictForFile:f architecture:[d architecture]];
    job->installed = [[NSMutableArray alloc] init];
    job->progress = -1;
    job->started = CFAbsoluteTimeGetCurrent();
    job->workDir = [[[GDInstaller downloadsFolder] stringByAppendingPathComponent:safeName([d title])] retain];
    [[NSFileManager defaultManager] createDirectoryAtPath:job->workDir attributes:nil];
    /* One path for the life of the job, so retries resume the same .part. */
    job->downloadPath = [[job->workDir stringByAppendingPathComponent:[f name]] retain];
    if ([[NSFileManager defaultManager] fileExistsAtPath:job->downloadPath]) {
        /* A copy is already here from a previous attempt.  Use it rather than
         * fetching fifty megabytes again over a modem-era link to prove what
         * the checksum proves in seconds: postProcess verifies the MD5 on a
         * thread anyway, and throws the file away if it is wrong, so the next
         * attempt downloads afresh.
         *
         * Only when there is a checksum to answer to.  -sizeBytes cannot
         * stand in for one: it is parsed from the size the page displays
         * ("5.27 MB"), so it is rounded, and never equals the real length. */
        NSDictionary *a = [[NSFileManager defaultManager]
                              fileAttributesAtPath:job->downloadPath traverseLink:NO];
        if ([a fileSize] > 0 && [[f md5] length] == 32) {
            job->reusedDownload = YES;
        } else {
            NSString *old = job->downloadPath;
            job->downloadPath = [GDUniquePath(job->workDir, [f name]) retain];
            [old release];
        }
    }
    job->mirrorOrder = [[self orderMirrors:[f mirrors]] retain];
    /* One copy per title, as in the App Store: getting it again (or another
     * of its files) replaces what is installed, which goes to the Trash. */
    if ([self libraryEntryForPath:[d path]])
        job->replaces = [[[self libraryEntryForPath:[d path]] objectForKey:@"installed"] copy];
    [jobs addObject:job];
    /* On the list before a byte moves, so an attempt that goes nowhere - or
     * that the app does not outlive - is still an attempt the user can see. */
    [self recordJob:job];

    /* Room for the download, what it expands to, and the installed copy. */
    fs = [[NSFileManager defaultManager] fileSystemAttributesAtPath:job->workDir];
    freeBytes = [[fs objectForKey:NSFileSystemFreeSize] doubleValue];
    need = [f sizeBytes] * 3 + 20 * 1024 * 1024;
    if (fs && freeBytes < need) {
        [self setJob:job state:GDJobFailed status:[NSString stringWithFormat:
            @"Not enough disk space: this needs about %@ free, and %@ is available.",
            megabytes(need), megabytes(freeBytes)]];
        return job;
    }
    [self startDownload:job];
    return job;
}

- (void) retry:(GDInstallJob *)job
{
    job->mirror = 0;
    job->attempts = 0;
    job->cancelled = NO;
    [job->installed removeAllObjects];
    [job->mirrorOrder release];
    job->mirrorOrder = [[self orderMirrors:[job->file mirrors]] retain];
    [self startDownload:job];
}

- (void) cancel:(GDInstallJob *)job
{
    job->cancelled = YES;
    [job->request cancel];
    if (job->state == GDJobQueued || job->state == GDJobDownloading)
        [self setJob:job state:GDJobCancelled status:@"Cancelled"];
}

- (void) clearFinished
{
    int i;
    for (i = (int)[jobs count] - 1; i >= 0; i--)
        if (![[jobs objectAtIndex:i] isActive])
            [jobs removeObjectAtIndex:i];
    [self changed:nil];
}

/* ------------------------------------------------------------- download */

- (void) startDownload:(GDInstallJob *)job
{
    NSString *url, *host;
    if (job->reusedDownload) {
        /* Already on disk and the right size: straight to the checksum. */
        job->reusedDownload = NO;          /* a retry after this one downloads */
        job->bytesDone = job->bytesTotal = (long long)[job->file sizeBytes];   /* rounded; for the bar only */
        job->progress = -1;
        [self setJob:job state:GDJobVerifying status:@"Checking the copy already downloaded..."];
        [NSThread detachNewThreadSelector:@selector(postProcess:) toTarget:self withObject:job];
        return;
    }
    if (job->mirror >= (int)[job->mirrorOrder count]) {
        [self setJob:job state:GDJobFailed
              status:@"Could not download from any mirror. Check the network and try again."];
        return;
    }
    url = [job->mirrorOrder objectAtIndex:job->mirror];
    host = [[NSURL URLWithString:url] host];
    [job->request setDelegate:nil];
    [job->request release];
    job->request = [[GDHTTPRequest requestWithURL:[NSURL URLWithString:url]] retain];
    [job->request setDestinationPath:job->downloadPath];
    [job->request setDelegate:self];
    [job->request setUserInfo:job];
    job->switchingMirror = NO;
    job->attemptStart = CFAbsoluteTimeGetCurrent();
    job->attemptBytes = -1;
    if (job->progress < 0)
        job->progress = 0;
    [self setJob:job state:GDJobDownloading
          status:[NSString stringWithFormat:@"%@ from %@...",
                     job->bytesDone > 0 ? @"Resuming" : @"Downloading", host]];
    [job->request start];
}

- (void) httpRequest:(GDHTTPRequest *)r receivedBytes:(long long)done of:(long long)total
{
    GDInstallJob *job = [r userInfo];
    double now = CFAbsoluteTimeGetCurrent(), elapsed, rate;
    if (r != job->request)
        return;
    if (total <= 0)
        total = (long long)[job->file sizeBytes];
    if (job->attemptBytes < 0)
        job->attemptBytes = [r resumedFrom];
    job->bytesDone = done;
    job->bytesTotal = total;
    job->progress = total > 0 ? (double)done / total : -1;
    elapsed = now - job->attemptStart;
    rate = elapsed > 0 ? (done - job->attemptBytes) / elapsed : 0;
    [job->status autorelease];
    job->status = [[NSString stringWithFormat:@"%.1f of %.1f MB  (%.0f KB/s)",
                       done / 1048576.0, total / 1048576.0, rate / 1024] retain];

    /* A crawling mirror: after 12 s under 48 KB/s with over 2 MB to go,
     * try the next one; the bytes so far are kept and resumed. */
    if (elapsed > 12 && rate < 48 * 1024 && total - done > 2 * 1024 * 1024 &&
        job->mirror + 1 < (int)[job->mirrorOrder count] && !job->switchingMirror) {
        job->switchingMirror = YES;
        [self noteSpeed:rate host:[[r url] host]];
        [r cancel];
    }
    /* The bytes arrive in small chunks, many times a second, and every one of
     * them used to be a notification.  Each notification has the item page
     * lay itself out again, the Library reload and the Dock icon redraw, so a
     * download could take the whole main thread on a slower Mac and leave the
     * window unable to answer its own close button.  Five a second is more
     * than an eye can follow; the state changes around it still go out whole.
     */
    if (now - job->lastProgressPost >= 0.2 || (total > 0 && done >= total)) {
        job->lastProgressPost = now;
        [self changed:job];
    }
}

- (void) httpRequestDidFinish:(GDHTTPRequest *)r
{
    GDInstallJob *job = [r userInfo];
    double elapsed = CFAbsoluteTimeGetCurrent() - job->attemptStart;
    if (r != job->request)
        return;
    if (job->cancelled) {
        [self setJob:job state:GDJobCancelled status:@"Cancelled"];
        return;
    }
    if (job->switchingMirror) {
        job->mirror++;
        job->attempts = 0;
        [self startDownload:job];
        return;
    }
    if ([r error] != nil) {
        /* Dropped connections (sleep, Wi-Fi) resume on the same mirror twice
         * before moving on; hard errors (404, expired signed link) move on. */
        if ([r isTransientFailure] && job->attempts < 2) {
            job->attempts++;
            [self performSelector:@selector(startDownload:) withObject:job afterDelay:3];
            return;
        }
        job->mirror++;
        job->attempts = 0;
        [self startDownload:job];
        return;
    }
    if (elapsed > 2 && job->attemptBytes >= 0)
        [self noteSpeed:(job->bytesDone - job->attemptBytes) / elapsed host:[[r url] host]];
    job->progress = -1;
    [self setJob:job state:GDJobVerifying status:@"Verifying..."];
    [NSThread detachNewThreadSelector:@selector(postProcess:) toTarget:self withObject:job];
}

/* ------------------------------------------------------ worker thread */

- (void) mainSetStatus:(NSArray *)a
{
    GDInstallJob *job = [a objectAtIndex:0];
    [self setJob:job state:[[a objectAtIndex:1] intValue] status:[a objectAtIndex:2]];
}

- (void) job:(GDInstallJob *)job state:(GDJobState)s status:(NSString *)text
{
    [self performSelectorOnMainThread:@selector(mainSetStatus:)
                           withObject:[NSArray arrayWithObjects:job, [NSNumber numberWithInt:s], text, nil]
                        waitUntilDone:YES];
}

/* Worker thread: extraction progress. */
- (void) extractProgress:(NSNumber *)fraction
{
    GDInstallJob *job = currentExtractJob;
    if (job == nil)
        return;
    job->progress = [fraction doubleValue];
    [self performSelectorOnMainThread:@selector(changed:) withObject:job waitUntilDone:NO];
}

static BOOL looksLikeMacBinary(NSData *h)
{
    const unsigned char *b = [h bytes];
    return [h length] >= 128 && b[0] == 0 && b[74] == 0 && b[82] == 0 && b[1] >= 1 && b[1] <= 63;
}

/* One unwrapping step; returns the new path, nil when nothing to unwrap,
 * or @"" on a fatal error (status already set). */
- (NSString *) unwrap:(NSString *)p job:(GDInstallJob *)job
{
    NSString *ext = [[p pathExtension] lowercaseString], *made, *err = nil;
    NSData *h;
    BOOL archive;

    if (isDir(p))
        return nil;
    h = head(p, 128);
    archive = GDIsArchive(p) || startsWith(h, "SIT!", 0) || startsWith(h, "StuffIt", 0) ||
              startsWith(h, "rLau", 10) || startsWith(h, "PK\003\004", 0) ||
              startsWith(h, "(This file must be converted", 0) ||
              ([ext isEqualToString:@"bin"] && looksLikeMacBinary(h));
    if (!archive)
        return nil;
    /* "name.bin" is often a CD image (bin/cue), not MacBinary. */
    if ([ext isEqualToString:@"bin"] && !looksLikeMacBinary(h))
        return nil;

    [self job:job state:GDJobUnpacking status:@"Expanding..."];
    currentExtractJob = job;
    made = GDExtractArchive(p, job->workDir, &err, self, @selector(extractProgress:));
    currentExtractJob = nil;
    job->progress = -1;
    if (made == nil && startsWith(h, "PK\003\004", 0)) {
        /* Fall back to the system's unzip for zips XADMaster rejects. */
        NSString *dest = GDUniquePath(job->workDir, [[p lastPathComponent] stringByDeletingPathExtension]);
        int st;
        runTask(@"/usr/bin/ditto", [NSArray arrayWithObjects:@"-x", @"-k", @"--rsrc", p, dest, nil], &st);
        if (st == 0 && [visibleContents(dest) count])
            made = dest;
    }
    if (made == nil) {
        [self job:job state:GDJobFailed
               status:[NSString stringWithFormat:@"Could not expand %@: %@", [p lastPathComponent],
                          err ?: @"unknown format"]];
        job->revealPath = [p retain];
        return @"";
    }
    /* A lone archive or image inside goes round again; a folder with a
     * single file in it is looked through. */
    if (isDir(made)) {
        NSArray *c = visibleContents(made);
        if ([c count] == 1) {
            NSString *only = [made stringByAppendingPathComponent:[c objectAtIndex:0]];
            if (!isDir(only))
                return only;
        }
    }
    return made;
}

static BOOL isDiskImage(NSString *p)
{
    NSString *e = [[p pathExtension] lowercaseString];
    NSArray *exts = [NSArray arrayWithObjects:@"dmg", @"img", @"image", @"toast", @"iso", @"cdr",
                              @"dsk", @"dc42", @"diskcopy42", @"hfs", @"hfv", @"sparseimage", nil];
    return !isDir(p) && ([exts containsObject:e] || fileType(p) == 'dimg' || fileType(p) == 'rohd');
}

/* Copy src into dir (unique name); returns the new path.  A folder or a
 * volume is copied item by item, leaving out volume furniture (.Trashes,
 * Desktop DB, ...) that ditto chokes on.  ditto also complains about some
 * old classic files it copies fine, so the result is judged by what
 * arrived, not by its exit status. */
- (NSString *) copy:(NSString *)src into:(NSString *)dir as:(NSString *)name
{
    NSString *dst = GDUniquePath(dir, name ?: [src lastPathComponent]);
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *ext = [[src pathExtension] lowercaseString];
    int st;
    if (isDir(src) && ![ext isEqualToString:@"app"] && ![ext isEqualToString:@"pkg"] &&
        ![ext isEqualToString:@"mpkg"]) {
        NSArray *c = visibleContents(src);
        unsigned i, arrived = 0;
        if (![fm createDirectoryAtPath:dst attributes:nil])
            return nil;
        for (i = 0; i < [c count]; i++) {
            NSString *n = [c objectAtIndex:i];
            NSString *to = [dst stringByAppendingPathComponent:n];
            runTask(@"/usr/bin/ditto", [NSArray arrayWithObjects:@"--rsrc",
                        [src stringByAppendingPathComponent:n], to, nil], &st);
            if (st != 0)
                NSLog(@"The Garden: ditto %@ exited %d", n, st);
            if ([fm fileExistsAtPath:to])
                arrived++;
        }
        return arrived ? dst : nil;
    }
    runTask(@"/usr/bin/ditto", [NSArray arrayWithObjects:@"--rsrc", src, dst, nil], &st);
    if (st != 0)
        NSLog(@"The Garden: ditto %@ exited %d", [src lastPathComponent], st);
    return [fm fileExistsAtPath:dst] ? dst : nil;
}

- (NSString *) applicationsFolderFor:(GDInstallJob *)job
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *os9 = @"/Applications (Mac OS 9)";
    NSString *apps = @"/Applications";
    /* Mac OS 9 software on a Mac with no Classic: where SheepShaver can see
     * it, which is usually "Applications (Mac OS 9)" anyway. */
    if (job->verdict == GDVerdictNeedsEmulator) {
        NSString *shared = [GDSheepShaver installFolder];
        if (shared != nil)
            return shared;
    }
    if ((job->verdict == GDVerdictClassic || job->verdict == GDVerdictNeedsClassic ||
         job->verdict == GDVerdictNeedsEmulator) &&
        [fm isWritableFileAtPath:os9])
        return os9;
    if ([fm isWritableFileAtPath:apps])
        return apps;
    apps = [NSHomeDirectory() stringByAppendingPathComponent:@"Applications"];
    [fm createDirectoryAtPath:apps attributes:nil];
    return apps;
}

/* Install from a folder or a mounted volume. */
- (BOOL) installFrom:(NSString *)root job:(GDInstallJob *)job
{
    NSArray *c;
    NSString *rext = [[root pathExtension] lowercaseString];

    /* Handed a bundle itself: install it from its folder. */
    if ([rext isEqualToString:@"app"] || [rext isEqualToString:@"pkg"] || [rext isEqualToString:@"mpkg"]) {
        NSString *dest = [self applicationsFolderFor:job], *copied;
        if (![rext isEqualToString:@"app"]) {
            [self job:job state:GDJobInstalling status:@"Opening the installer..."];
            [[NSWorkspace sharedWorkspace] openFile:root];
            job->revealPath = [root retain];
            [job->installed addObject:root];
            return YES;
        }
        [self job:job state:GDJobInstalling
               status:[NSString stringWithFormat:@"Installing in %@...", [dest lastPathComponent]]];
        copied = [self copy:root into:dest as:nil];
        if (copied == nil)
            return NO;
        [job->installed addObject:copied];
        job->launchPath = [copied retain];
        job->revealPath = [copied retain];
        return YES;
    }
    c = visibleContents(root);
    NSMutableArray *apps = [NSMutableArray array], *pkgs = [NSMutableArray array];
    NSString *dest, *copied;
    unsigned i, docs = 0;

    while ([c count] == 1 && isDir([root stringByAppendingPathComponent:[c objectAtIndex:0]])) {
        NSString *only = [c objectAtIndex:0];
        NSString *e = [[only pathExtension] lowercaseString];
        if ([e isEqualToString:@"app"] || [e isEqualToString:@"pkg"] || [e isEqualToString:@"mpkg"])
            break;
        root = [root stringByAppendingPathComponent:only];
        c = visibleContents(root);
    }
    for (i = 0; i < [c count]; i++) {
        NSString *n = [c objectAtIndex:i];
        NSString *e = [[n pathExtension] lowercaseString];
        if ([e isEqualToString:@"app"])
            [apps addObject:n];
        else if ([e isEqualToString:@"pkg"] || [e isEqualToString:@"mpkg"])
            [pkgs addObject:n];
        else if (isDoc(n))
            docs++;
    }

    if ([apps count] == 0 && [pkgs count] > 0) {
        /* An installer: copy it out of the image first so it survives the eject. */
        NSString *pkg = [self copy:[root stringByAppendingPathComponent:[pkgs objectAtIndex:0]]
                              into:job->workDir as:nil];
        [self job:job state:GDJobInstalling status:@"Opening the installer..."];
        if (pkg)
            [[NSWorkspace sharedWorkspace] openFile:pkg];
        job->revealPath = [pkg retain];
        [job->installed addObject:pkg ?: root];
        return pkg != nil;
    }

    dest = [self applicationsFolderFor:job];
    /* Nothing to run here, only disk images (a floppy set, say): open each
     * and copy what is on it, next to the images. */
    if ([apps count] == 0 && findLaunchableFor(root, [job->item title]) == nil) {
        NSMutableArray *images = [NSMutableArray array];
        for (i = 0; i < [c count]; i++)
            if (isDiskImage([root stringByAppendingPathComponent:[c objectAtIndex:i]]))
                [images addObject:[c objectAtIndex:i]];
        if ([images count]) {
            NSString *folder;
            [self job:job state:GDJobInstalling
                   status:[NSString stringWithFormat:@"Installing in %@...", [dest lastPathComponent]]];
            folder = [self copy:root into:dest as:safeName([job->item title])];
            if (folder == nil)
                return NO;
            [images sortUsingSelector:@selector(compare:)];
            for (i = 0; i < [images count]; i++) {
                NSString *img = [root stringByAppendingPathComponent:[images objectAtIndex:i]];
                NSString *mount = [self attachImage:img];
                if (mount) {
                    [self copy:mount into:folder as:[[images objectAtIndex:i] stringByDeletingPathExtension]];
                    runTask(@"/usr/bin/hdiutil", [NSArray arrayWithObjects:@"detach", mount, @"-force", nil], NULL);
                }
            }
            [job->installed addObject:folder];
            job->launchPath = [findLaunchableFor(folder, [job->item title]) retain];
            job->revealPath = [folder retain];
            return YES;
        }
    }
    [self job:job state:GDJobInstalling
           status:[NSString stringWithFormat:@"Installing in %@...", [dest lastPathComponent]]];
    if ([apps count] == 1 && [apps count] + docs == [c count]) {
        copied = [self copy:[root stringByAppendingPathComponent:[apps objectAtIndex:0]] into:dest as:nil];
    } else {
        copied = [self copy:root into:dest as:safeName([job->item title])];
    }
    if (copied == nil)
        return NO;
    [job->installed addObject:copied];
    job->launchPath = [findLaunchableFor(copied, [job->item title]) retain];
    job->revealPath = [copied retain];
    return YES;
}

/* Mount an image read-only, out of sight; old floppy images (.dsk, .image)
 * are often headerless raw disks, which hdiutil opens only when told. */
- (NSString *) attachImage:(NSString *)p
{
    NSArray *base = [NSArray arrayWithObjects:@"attach", @"-nobrowse", @"-noautoopen", @"-readonly",
                              @"-noverify", @"-noautofsck", @"-plist", nil];
    int attempt;
    for (attempt = 0; attempt < 2; attempt++) {
        NSMutableArray *args = [NSMutableArray arrayWithArray:base];
        NSString *out;
        NSDictionary *plist;
        NSArray *ents;
        unsigned i;
        int st;
        if (attempt == 1)
            [args addObjectsFromArray:[NSArray arrayWithObjects:@"-imagekey",
                                          @"diskimage-class=CRawDiskImage", nil]];
        [args addObject:p];
        out = runTask(@"/usr/bin/hdiutil", args, &st);
        plist = [out propertyList];
        ents = [plist isKindOfClass:[NSDictionary class]] ? [plist objectForKey:@"system-entities"] : nil;
        for (i = 0; i < [ents count]; i++) {
            NSString *mp = [[ents objectAtIndex:i] objectForKey:@"mount-point"];
            if (mp)
                return mp;
        }
    }
    return nil;
}

- (void) postProcess:(GDInstallJob *)job
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSString *p = job->downloadPath, *md5;
    NSString *expected = [[job->file md5] lowercaseString];
    int pass;
    BOOL ok = NO;

    if ([expected length] == 32) {
        md5 = GDMD5OfFile(p);
        if (md5 && ![md5 isEqualToString:expected]) {
            [self job:job state:GDJobFailed status:@"The download is damaged (checksum mismatch). Try again."];
            unlink([p fileSystemRepresentation]);
            [pool release];
            return;
        }
    }

    for (pass = 0; pass < 6 && !job->cancelled; pass++) {
        NSString *next = [self unwrap:p job:job];
        if (next == nil)
            break;
        if ([next length] == 0) {
            [pool release];
            return;
        }
        p = next;
    }

    if (isDiskImage(p)) {
        NSString *mount = nil;
        [self job:job state:GDJobUnpacking status:@"Opening disk image..."];
        mount = [self attachImage:p];
        if (mount == nil) {
            [self job:job state:GDJobFailed
                   status:@"Could not open the disk image. It is in the Downloads folder."];
            job->revealPath = [p retain];
            [pool release];
            return;
        }
        ok = [self installFrom:mount job:job];
        runTask(@"/usr/bin/hdiutil", [NSArray arrayWithObjects:@"detach", mount, @"-force", nil], NULL);
    } else if (isDir(p)) {
        ok = [self installFrom:p job:job];
    } else {
        /* A single file: a classic application, a self-mounting image, a document. */
        NSString *dest = [self applicationsFolderFor:job];
        NSString *copied = [self copy:p into:dest as:nil];
        ok = copied != nil;
        if (ok) {
            [job->installed addObject:copied];
            if (fileType(copied) == 'APPL')
                job->launchPath = [copied retain];
            job->revealPath = [copied retain];
        }
    }

    if (ok)
        [self performSelectorOnMainThread:@selector(finish:) withObject:job waitUntilDone:YES];
    else if (job->state != GDJobFailed)
        [self job:job state:GDJobFailed status:@"Could not install. The download is in the Downloads folder."];
    [pool release];
}

- (void) trashPaths:(NSArray *)paths keeping:(NSArray *)keep
{
    unsigned i;
    for (i = 0; i < [paths count]; i++) {
        NSString *p = [paths objectAtIndex:i];
        if ([keep containsObject:p] || ![[NSFileManager defaultManager] fileExistsAtPath:p])
            continue;
        [[NSWorkspace sharedWorkspace] performFileOperation:NSWorkspaceRecycleOperation
                                                     source:[p stringByDeletingLastPathComponent]
                                                destination:@""
                                                      files:[NSArray arrayWithObject:[p lastPathComponent]]
                                                        tag:NULL];
    }
}

/* After an update or reinstall the new copy was made beside the old one
 * ("Name 2"); with the old one in the Trash, give it the original name. */
- (void) takeOriginalNames:(GDInstallJob *)job
{
    NSFileManager *fm = [NSFileManager defaultManager];
    unsigned i, k;
    for (i = 0; i < [job->installed count]; i++) {
        NSString *now = [job->installed objectAtIndex:i];
        for (k = 0; k < [job->replaces count]; k++) {
            NSString *was = [job->replaces objectAtIndex:k];
            NSString *base = [[was lastPathComponent] stringByDeletingPathExtension];
            NSString *nb = [[now lastPathComponent] stringByDeletingPathExtension];
            if (![[was stringByDeletingLastPathComponent] isEqualToString:[now stringByDeletingLastPathComponent]] ||
                ![nb hasPrefix:[base stringByAppendingString:@" "]] || [fm fileExistsAtPath:was] ||
                ![[was pathExtension] isEqualToString:[now pathExtension]])
                continue;
            if (rename([now fileSystemRepresentation], [was fileSystemRepresentation]) == 0) {
                /* keep the recorded paths pointing at the renamed copy */
                if (job->launchPath && [job->launchPath hasPrefix:now]) {
                    NSString *l = [was stringByAppendingString:[job->launchPath substringFromIndex:[now length]]];
                    [job->launchPath release];
                    job->launchPath = [l retain];
                }
                if (job->revealPath && [job->revealPath hasPrefix:now]) {
                    NSString *r = [was stringByAppendingString:[job->revealPath substringFromIndex:[now length]]];
                    [job->revealPath release];
                    job->revealPath = [r retain];
                }
                [job->installed replaceObjectAtIndex:i withObject:was];
            }
            break;
        }
    }
}

- (void) finish:(GDInstallJob *)job
{
    if (job->replaces) {
        [self trashPaths:job->replaces keeping:job->installed];
        [self takeOriginalNames:job];
    }
    if ([[job->launchPath pathExtension] isEqualToString:@"app"])
        LSRegisterURL((CFURLRef)[NSURL fileURLWithPath:job->launchPath], true);
    NSDictionary *old = [self libraryEntryForPath:[job->item path]];
    NSMutableDictionary *e = [NSMutableDictionary dictionary];
    [e setObject:[job->item path] forKey:@"path"];
    [e setObject:[job->item title] ?: @"" forKey:@"title"];
    [e setObject:[job->file name] ?: @"" forKey:@"file"];
    [e setObject:job->installed forKey:@"installed"];
    if (job->launchPath)
        [e setObject:job->launchPath forKey:@"launch"];
    [e setObject:[NSDate date] forKey:@"date"];
    if ([job->item thumbURL])
        [e setObject:[job->item thumbURL] forKey:@"thumb"];
    [e setObject:[NSNumber numberWithInt:job->verdict] forKey:@"verdict"];
    if (old)
        [library removeObject:old];
    [library insertObject:e atIndex:0];
    [self saveLibrary];
    job->progress = 1;
    [self recomputeUpdates:nil];
    [self setJob:job state:GDJobDone
          status:job->launchPath ? @"Installed" : @"Installed (open it from the Finder)"];
}

@end
