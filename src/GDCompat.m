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

/* ----------------------------------------------------- which file to offer
 *
 * A Garden item's downloads are not all the program.  Next to the game sit
 * interviews, manuals, box scans, patches, level packs and source archives,
 * and the Get button must offer the program.  Three things say which is
 * which, in this order: what the download is (the item's own "DL #N:" line
 * says so in words, and the file name usually hints at it), whether it is
 * named after the item, and only last, how convenient the archive format is.
 */

static BOOL wordChar(unichar c)
{
    return (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9');
}

static BOOL isDigit(unichar c) { return c >= '0' && c <= '9'; }
static BOOL isLetter(unichar c) { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'); }

/* Whole-word search, plural allowed, over lowercase text: "key" does not
 * match "monkey", "doc" does not match "docking", "scan" matches "scans".
 * File names separate their words with _ - . and digits, so anything that is
 * not a letter or a digit is a word boundary. */
static BOOL hasWord(NSString *hay, NSString *word)
{
    unsigned n = [hay length], from = 0;
    while (from < n) {
        NSRange r = [hay rangeOfString:word options:0 range:NSMakeRange(from, n - from)];
        unsigned end;
        if (r.location == NSNotFound)
            return NO;
        end = NSMaxRange(r);
        if (end < n && [hay characterAtIndex:end] == 's')
            end++;
        if ((r.location == 0 || !wordChar([hay characterAtIndex:r.location - 1])) &&
            (end == n || !wordChar([hay characterAtIndex:end])))
            return YES;
        from = r.location + 1;
    }
    return NO;
}

static BOOL hasAnyWord(NSString *hay, NSArray *words)
{
    unsigned i;
    for (i = 0; i < [words count]; i++)
        if (hasWord(hay, [words objectAtIndex:i]))
            return YES;
    return NO;
}

/* Reading matter, pictures and recordings.  A download that is only this is
 * not the program, however convenient its format. */
static NSArray *documentWords(void)
{
    static NSArray *w = nil;
    if (w == nil)
        w = [[NSArray alloc] initWithObjects:
                @"pdf", @"doc", @"document", @"documentation", @"manual", @"instruction",
                @"instructions", @"interview", @"scan", @"booklet", @"guide", @"walkthrough",
                @"hint book", @"hintbook", @"clue book", @"cluebook", @"review",
                @"box art", @"boxart", @"cover art", @"artwork", @"poster", @"catalog",
                @"catalogue", @"brochure", @"advert", @"advertisement", @"flyer",
                @"leaflet", @"magazine", @"article", @"comic", @"readme", @"read me",
                @"faq", @"screenshot", @"wallpaper", @"soundtrack", nil];
    return w;
}

/* Words that say this download is the program itself.  They outrank the list
 * above, so an archive of disk images that also holds box scans still counts
 * as the program. */
static NSArray *programWords(void)
{
    static NSArray *w = nil;
    if (w == nil)
        w = [[NSArray alloc] initWithObjects:
                @"install", @"installer", @"installation", @"disk image", @"diskimage",
                @"disc image", @"cd image", @"image of", @"bootable", @"diskette",
                @"floppy", @"full version", @"complete version", @"application",
                @"program", @"game", @"playable", @"executable", nil];
    return w;
}

/* Pieces that need the program before they are worth anything. */
static NSArray *extraWords(void)
{
    static NSArray *w = nil;
    if (w == nil)
        w = [[NSArray alloc] initWithObjects:
                @"patch", @"update", @"updater", @"upgrade", @"addon", @"add-on",
                @"plugin", @"plug-in", @"expansion", @"level pack", @"level", @"map",
                @"mod", @"skin", @"theme", @"scenario", @"mission", @"font",
                @"source", @"source code", @"src", @"sdk",
                @"cheat", @"crack", @"keygen", @"serial", @"key",
                /* an editor for the item, not an item that is an editor */
                @"save editor", @"save game editor", @"level editor", @"map editor",
                @"scenario editor", @"character editor",
                /* flux and copy-protected images: preservation, not something
                 * an emulator here will boot */
                @"moof", @"woz", @"copy-protected", @"copy protected", nil];
    return w;
}

/* Unfinished or cut-down editions. */
static NSArray *previewWords(void)
{
    static NSArray *w = nil;
    if (w == nil)
        w = [[NSArray alloc] initWithObjects:
                @"demo", @"beta", @"alpha", @"preview", @"prerelease", @"trial", nil];
    return w;
}

/* A file whose extension is a document is a document, whatever it is called. */
static BOOL isDocumentExtension(NSString *e)
{
    static NSArray *w = nil;
    if (w == nil)
        w = [[NSArray alloc] initWithObjects:
                @"pdf", @"txt", @"rtf", @"doc", @"docx", @"html", @"htm", @"jpg",
                @"jpeg", @"png", @"gif", @"tif", @"tiff", @"bmp", @"mp3", @"wav",
                @"aiff", @"mov", @"avi", @"mp4", nil];
    return [w containsObject:e];
}

/* "1.0SafariBeta2.dmg" -> "1 0 safari beta 2 dmg".  File names run their
 * words together, and a word only says something when it stands on its own:
 * "alphabet" is not an alpha, but "SafariBeta2" is a beta. */
static NSString *spaced(NSString *s)
{
    NSMutableString *out = [NSMutableString stringWithCapacity:2 * [s length]];
    unsigned i, n = [s length];
    for (i = 0; i < n; i++) {
        unichar c = [s characterAtIndex:i];
        unichar prev = i > 0 ? [s characterAtIndex:i - 1] : 0;
        unichar next = i + 1 < n ? [s characterAtIndex:i + 1] : 0;
        BOOL upper = c >= 'A' && c <= 'Z';
        if (!upper && !wordChar(c)) {
            [out appendString:@" "];
            continue;
        }
        if ((isDigit(prev) && !isDigit(c)) ||
            (isLetter(prev) && isDigit(c)) ||
            (prev >= 'a' && prev <= 'z' && upper) ||
            (prev >= 'A' && prev <= 'Z' && upper && next >= 'a' && next <= 'z'))
            [out appendString:@" "];
        [out appendFormat:@"%C", (unichar)(upper ? c + ('a' - 'A') : c)];
    }
    return out;
}

/* Lowercase letters and digits only: "Dark_Castle_0.sit" -> "darkcastle0". */
static NSString *squash(NSString *s)
{
    NSMutableString *out = [NSMutableString stringWithCapacity:[s length]];
    unsigned i;
    for (i = 0; i < [s length]; i++) {
        unichar c = [s characterAtIndex:i];
        if (c >= 'A' && c <= 'Z')
            c += 'a' - 'A';
        if (wordChar(c))
            [out appendFormat:@"%C", c];
    }
    return out;
}

/* How much of the item's title the file name carries: 2 for all of it, 1 for
 * some, 0 for none.  "Dark_Castle_0.sit" and "darkcastle.img_.sit" are both
 * Dark Castle; "jonathan_gay_interview.zip" is not, and neither is
 * "Brood_War_v115_Mac.sit" on the StarCraft page. */
static int titleMatch(NSString *name, NSString *title)
{
    NSMutableString *word = [NSMutableString string];
    NSString *flat = squash(name);
    int words = 0, hits = 0;
    unsigned i, n = [title length];

    for (i = 0; i <= n; i++) {
        unichar c = i < n ? [title characterAtIndex:i] : ' ';
        if (c >= 'A' && c <= 'Z')
            c += 'a' - 'A';
        if (wordChar(c)) {
            [word appendFormat:@"%C", c];
            continue;
        }
        /* "the", "of", "a" and the like say nothing about which file this is. */
        if ([word length] >= 4) {
            words++;
            if ([flat rangeOfString:word].location != NSNotFound)
                hits++;
        }
        [word setString:@""];
    }
    if (words == 0 || hits == 0)
        return 0;
    return hits == words ? 2 : 1;
}

/* What the Get button should offer, high is better.  Every term but the last
 * is about what the download is; the format is only a tiebreak between files
 * that are equally the program. */
static int installScore(GDFile *f, GDItemDetail *d)
{
    NSString *name = [[f name] ?: @"" lowercaseString];
    NSString *ext = [name pathExtension];
    NSString *note = [[f note] ?: @"" lowercaseString];
    NSString *words = spaced([f name] ?: @"");
    NSString *what = [words stringByAppendingFormat:@" %@", note];
    BOOL namedDocument = hasAnyWord(words, documentWords());
    BOOL notedDocument = hasAnyWord(note, documentWords());
    BOOL program = hasAnyWord(what, programWords());
    int score = 100;

    /* 1. Is this the program at all?  A file named for a document is one; a
     *    note that mentions one may only be listing what is inside. */
    if (isDocumentExtension(ext))
        score -= 70;
    else if (namedDocument && !program)
        score -= 60;
    else if (notedDocument && !program)
        score -= 30;
    else if (namedDocument || notedDocument)
        score -= 10;              /* the program, bundled with extras */
    if (hasAnyWord(what, extraWords()))
        score -= 30;
    if (hasAnyWord(what, previewWords()))
        score -= 15;
    /* The item's own "DL #N:" line is worth more than a guess at the name. */
    if (hasAnyWord(note, programWords()))
        score += 6;

    /* 2. Is it named after the item? */
    score += 5 * titleMatch(name, [d title] ?: @"");

    /* 3. Convenience: disk images and zips need nothing extra, StuffIt and
     *    BinHex need an expander. */
    if ([ext isEqualToString:@"dmg"] || [ext isEqualToString:@"zip"] ||
        [ext isEqualToString:@"img"] || [ext isEqualToString:@"image"] ||
        [ext isEqualToString:@"toast"] || [ext isEqualToString:@"iso"] ||
        [ext isEqualToString:@"cdr"] || [ext isEqualToString:@"smi"])
        score += 4;
    else if ([ext isEqualToString:@"sit"] || [ext isEqualToString:@"sitx"] ||
             [ext isEqualToString:@"sea"] || [ext isEqualToString:@"cpt"] ||
             [ext isEqualToString:@"hqx"] || [ext isEqualToString:@"bin"])
        score += 2;
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
        int sc = installScore(f, d);
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
