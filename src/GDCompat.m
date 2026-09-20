#import "GDCompat.h"
#import "GDGarden.h"
#include <sys/sysctl.h>

@implementation GDCompat

/* There is no Intel Mac running Tiger or Leopard here to test on, so the
 * compatibility rules can be tried on any Mac: GDDebugHostArch (ppc|intel)
 * and GDDebugHostOS (4|5) stand in for what this Mac is. */
static NSString *hostOverride(NSString *key)
{
    return [[NSUserDefaults standardUserDefaults] stringForKey:key];
}

+ (BOOL) hostIsPPC
{
    NSString *forced = hostOverride(@"GDDebugHostArch");
    if ([forced length])
        return [[forced lowercaseString] hasPrefix:@"ppc"] ||
               [[forced lowercaseString] hasPrefix:@"power"];
#if defined(__ppc__) || defined(__ppc64__)
    /* A PowerPC slice can still be running under Rosetta on an Intel Mac. */
    int native = 0;
    size_t len = sizeof(native);
    if (sysctlbyname("sysctl.proc_native", &native, &len, NULL, 0) == 0 && native == 0)
        return NO;
    return YES;
#else
    return NO;
#endif
}

+ (int) hostOSMinor
{
    static int minor = -1;
    NSString *forced = hostOverride(@"GDDebugHostOS");
    if ([forced length])
        return [forced intValue];
    if (minor < 0) {
        NSDictionary *sv = [NSDictionary dictionaryWithContentsOfFile:
                               @"/System/Library/CoreServices/SystemVersion.plist"];
        NSArray *parts = [[sv objectForKey:@"ProductVersion"] componentsSeparatedByString:@"."];
        minor = [parts count] > 1 ? [[parts objectAtIndex:1] intValue] : 4;
    }
    return minor;
}

+ (BOOL) hostHasClassicSupport
{
    return [self hostIsPPC] && [self hostOSMinor] <= 4 &&
        [[NSFileManager defaultManager] fileExistsAtPath:
            @"/System/Library/CoreServices/Classic Startup.app"];
}

+ (BOOL) hostHasClassic
{
    /* Classic Startup plus a Mac OS 9 System Folder on some volume.  The
     * Classic pane remembers its choice in com.apple.classic; failing that,
     * look at the roots of the mounted volumes. */
    static int cached = -1;
    NSFileManager *fm;
    NSEnumerator *e;
    NSString *vol;
    if (cached >= 0)
        return cached;
    cached = 0;
    if (![self hostHasClassicSupport])
        return NO;
    fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:@"/System Folder/System"]) {
        cached = 1;
        return YES;
    }
    e = [[fm directoryContentsAtPath:@"/Volumes"] objectEnumerator];
    while ((vol = [e nextObject]) != nil) {
        NSString *p = [NSString stringWithFormat:@"/Volumes/%@/System Folder/System", vol];
        if ([fm fileExistsAtPath:p]) {
            cached = 1;
            break;
        }
    }
    return cached;
}

+ (NSString *) hostDescription
{
    return [NSString stringWithFormat:@"%@ Mac, Mac OS X 10.%d%@",
            [self hostIsPPC] ? @"PowerPC" : @"Intel", [self hostOSMinor],
            [self hostHasClassic] ? @", Classic" : @""];
}

static BOOL has(NSString *hay, NSString *needle)
{
    return [hay rangeOfString:needle].location != NSNotFound;
}

/* Lowest "10.N" mentioned after "os x", or 0. */
static int minOSXVersion(NSString *s)
{
    NSRange r = [s rangeOfString:@"os x"];
    NSScanner *sc;
    int best = 0;
    if (r.location == NSNotFound)
        return 0;
    sc = [NSScanner scannerWithString:[s substringFromIndex:r.location]];
    while (![sc isAtEnd]) {
        int major, minor;
        [sc scanUpToCharactersFromSet:[NSCharacterSet decimalDigitCharacterSet] intoString:NULL];
        if ([sc scanInt:&major] && major == 10 && [sc scanString:@"." intoString:NULL] &&
            [sc scanInt:&minor]) {
            if (best == 0 || minor < best)
                best = minor;
        }
    }
    return best;
}

+ (GDVerdict) verdictForFile:(GDFile *)f architecture:(NSString *)archRaw
{
    NSString *sys = [[f systems] ?: @"" lowercaseString];
    NSString *arch = [archRaw ?: @"" lowercaseString];
    NSString *name = [[f name] ?: @"" lowercaseString];
    BOOL osx = has(sys, @"os x") || has(sys, @"macos") || has(sys, @"mac os 10");
    BOOL classic = has(sys, @"system ") || has(sys, @"mac os 7") || has(sys, @"mac os 8") ||
                   has(sys, @"mac os 9");
    BOOL windows = has(sys, @"windows") || has(sys, @"dos") || has(name, @".exe");
    BOOL ppc = has(arch, @"ppc") || has(arch, @"powerpc");
    BOOL m68k = has(arch, @"68k");
    BOOL intel = has(arch, @"universal") || has(arch, @"intel") ||
                 (has(arch, @"x86") && !has(arch, @"x86 (windows)"));
    BOOL archKnown = ppc || m68k || intel;
    int need;

    if (windows && !osx && !classic)
        return GDVerdictIncompatible;
    /* A file named for one CPU overrides the item's architecture line. */
    if (has(name, @"universal") || has(name, @"_ub") || has(name, @"-ub")) {
        ppc = intel = YES;
    } else if (has(name, @"intel") || has(name, @"i386") || has(name, @"x86")) {
        ppc = NO;
        intel = YES;
        archKnown = YES;
    } else if (has(name, @"ppc") || has(name, @"powerpc")) {
        ppc = YES;
        intel = NO;
        archKnown = YES;
    }
    if (osx) {
        need = minOSXVersion(sys);
        if (need > [self hostOSMinor])
            return GDVerdictNeedsNewerOS;
        if ([self hostIsPPC]) {
            if (ppc || !archKnown || has(arch, @"universal"))
                return GDVerdictNative;
            return GDVerdictIncompatible;          /* Intel-only */
        }
        if (intel)
            return GDVerdictNative;
        return [self hostOSMinor] <= 6 ? GDVerdictRosetta : GDVerdictIncompatible;
    }
    if (classic || m68k) {
        if ([self hostHasClassic])
            return GDVerdictClassic;
        if ([self hostHasClassicSupport])
            return GDVerdictNeedsClassic;
        /* An Intel Mac, or Leopard, which dropped Classic: the software is
         * not for a different computer, it needs an emulator, and the Garden
         * has one. */
        return GDVerdictNeedsEmulator;
    }
    return GDVerdictUnknown;
}

/* SheepShaver is a Mac OS 8.1-9.0.4 Mac, so it runs both PowerPC and (through
 * Mac OS's own emulator) 68k software of that era.  Anything that stops at
 * System 7 wants Basilisk II, a 68k Mac. */
+ (BOOL) itemIsPreMacOS8:(GDItemDetail *)d
{
    unsigned i;
    BOOL sawOld = NO;
    for (i = 0; i < [[d files] count]; i++) {
        NSString *sys = [[[[d files] objectAtIndex:i] systems] ?: @"" lowercaseString];
        if (has(sys, @"mac os 8") || has(sys, @"mac os 9"))
            return NO;
        if (has(sys, @"system ") || has(sys, @"mac os 7"))
            sawOld = YES;
    }
    return sawOld;
}

+ (NSString *) emulatorNameForItem:(GDItemDetail *)d
{
    return [self itemIsPreMacOS8:d] ? @"Basilisk II" : @"SheepShaver";
}

+ (NSString *) emulatorPathForItem:(GDItemDetail *)d
{
    /* SheepShaver has one page; Basilisk II has several builds, so send the
     * reader to the Garden's Emulators shelf to choose. */
    return [self itemIsPreMacOS8:d] ? nil : @"/apps/sheepshaver";
}

/* How pleasant a file is to install, all else equal: disk images and zips
 * need nothing extra; StuffIt needs an expander; betas and demos lose to
 * finished versions; documentation, source and extras lose to the program. */
static int installScore(GDFile *f)
{
    NSString *n = [[f name] ?: @"" lowercaseString];
    NSString *e = [n pathExtension];
    int score = 0;
    if (has(n, @"sit") || has(n, @"sea") || has(n, @".cpt"))
        score += 10;
    else if ([e isEqualToString:@"dmg"] || [e isEqualToString:@"zip"] || [e isEqualToString:@"img"] ||
             [e isEqualToString:@"toast"] || [e isEqualToString:@"iso"] || [e isEqualToString:@"cdr"])
        score += 30;
    else
        score += 20;
    if (!has(n, @"beta") && !has(n, @"alpha") && !has(n, @"_b") && !has(n, @"demo"))
        score += 5;
    if (has(n, @"source") || has(n, @"src") || has(n, @"manual") || has(n, @"doc") ||
        has(n, @"patch") || has(n, @"update") || has(n, @"key"))
        score -= 15;
    return score;
}

+ (GDVerdict) verdictForItem:(GDItemDetail *)d bestFile:(GDFile **)best
{
    GDVerdict v = GDVerdictUnknown;
    GDFile *pick = nil;
    int pickScore = 0;
    unsigned i;
    for (i = 0; i < [[d files] count]; i++) {
        GDFile *f = [[d files] objectAtIndex:i];
        GDVerdict fv = [self verdictForFile:f architecture:[d architecture]];
        int sc = installScore(f);
        if (pick == nil || fv > v || (fv == v && sc > pickScore)) {
            v = fv;
            pick = f;
            pickScore = sc;
        }
    }
    if (best)
        *best = pick;
    return v;
}

+ (NSString *) shortLabel:(GDVerdict)v
{
    switch (v) {
    case GDVerdictNative:       return @"Runs on this Mac";
    case GDVerdictRosetta:      return @"Runs via Rosetta";
    case GDVerdictClassic:      return @"Runs in Classic";
    case GDVerdictNeedsClassic: return @"Needs Mac OS 9";
    case GDVerdictNeedsEmulator: return @"Needs an Emulator";
    case GDVerdictNeedsNewerOS: return @"Needs newer Mac OS X";
    case GDVerdictIncompatible: return @"Not for this Mac";
    default:                    return @"Compatibility unknown";
    }
}

+ (NSString *) explanation:(GDVerdict)v
{
    switch (v) {
    case GDVerdictNative:
        return @"Made for Mac OS X on this kind of Mac.";
    case GDVerdictRosetta:
        return @"A PowerPC program; this Intel Mac runs it through Rosetta.";
    case GDVerdictClassic:
        return @"A Mac OS 9 program; it opens in the Classic environment.";
    case GDVerdictNeedsClassic:
        return @"A Mac OS 9 program. Install a Mac OS 9 System Folder to run it in Classic.";
    case GDVerdictNeedsEmulator:
        return @"A Mac OS 9 program, and this Mac has no Classic environment. "
                "An emulator runs it.";
    case GDVerdictNeedsNewerOS:
        return @"Needs a later version of Mac OS X than this Mac has.";
    case GDVerdictIncompatible:
        return @"Made for a different kind of computer.";
    default:
        return @"The Garden does not say what this runs on.";
    }
}

+ (BOOL) runsHere:(GDVerdict)v
{
    return v == GDVerdictNative || v == GDVerdictRosetta || v == GDVerdictClassic ||
           v == GDVerdictUnknown;
}

@end
