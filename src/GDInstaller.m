#import "GDInstaller.h"
#import "GDHTTP.h"
#import "GDCatalog.h"
#import "GDUtil.h"
#import "GDExtract.h"
#import <AppKit/AppKit.h>
#include <unistd.h>
#include <sys/attr.h>
#include <math.h>

NSString *GDJobChangedNotification = @"GDJobChanged";
NSString *GDLibraryChangedNotification = @"GDLibraryChanged";

/* ----------------------------------------------------------------- jobs */

@implementation GDInstallJob
- (void) dealloc
{
    [item release]; [file release]; [status release];
    [downloadPath release]; [workDir release]; [installed release];
    [launchPath release]; [revealPath release]; [request release]; [mirrorOrder release];
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
            isInvisible([dir stringByAppendingPathComponent:n]))
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

/* First launchable thing under root: an .app bundle, else a classic APPL. */
static NSString *findLaunchable(NSString *root, int depth)
{
    NSArray *c;
    unsigned i;
    if ([[root pathExtension] isEqualToString:@"app"])
        return root;
    if (!isDir(root))
        return fileType(root) == 'APPL' ? root : nil;
    if (depth > 3)
        return nil;
    c = visibleContents(root);
    for (i = 0; i < [c count]; i++) {
        NSString *p = [root stringByAppendingPathComponent:[c objectAtIndex:i]];
        if ([[p pathExtension] isEqualToString:@"app"])
            return p;
    }
    for (i = 0; i < [c count]; i++) {
        NSString *p = [root stringByAppendingPathComponent:[c objectAtIndex:i]];
        if (!isDir(p) && fileType(p) == 'APPL')
            return p;
    }
    for (i = 0; i < [c count]; i++) {
        NSString *p = [root stringByAppendingPathComponent:[c objectAtIndex:i]];
        NSString *hit;
        if (isDir(p) && (hit = findLaunchable(p, depth + 1)) != nil)
            return hit;
    }
    return nil;
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
@end

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
    return self;
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

- (void) changed:(GDInstallJob *)job
{
    [[NSNotificationCenter defaultCenter] postNotificationName:GDJobChangedNotification object:job];
}

- (void) setJob:(GDInstallJob *)job state:(GDJobState)s status:(NSString *)text
{
    job->state = s;
    [job->status autorelease];
    job->status = [text copy];
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
        NSString *old = job->downloadPath;
        job->downloadPath = [GDUniquePath(job->workDir, [f name]) retain];
        [old release];
    }
    job->mirrorOrder = [[self orderMirrors:[f mirrors]] retain];
    [jobs addObject:job];

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
    [self changed:job];
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
    if ((job->verdict == GDVerdictClassic || job->verdict == GDVerdictNeedsClassic) &&
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
    job->launchPath = [findLaunchable(copied, 0) retain];
    job->revealPath = [copied retain];
    return YES;
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
        int st;
        NSString *out;
        NSDictionary *plist;
        NSArray *ents;
        NSString *mount = nil;
        unsigned i;
        [self job:job state:GDJobUnpacking status:@"Opening disk image..."];
        out = runTask(@"/usr/bin/hdiutil", [NSArray arrayWithObjects:@"attach", @"-nobrowse",
                          @"-noautoopen", @"-readonly", @"-noverify", @"-noautofsck", @"-plist", p, nil], &st);
        plist = [out propertyList];
        ents = [plist isKindOfClass:[NSDictionary class]] ? [plist objectForKey:@"system-entities"] : nil;
        for (i = 0; i < [ents count]; i++) {
            NSString *mp = [[ents objectAtIndex:i] objectForKey:@"mount-point"];
            if (mp)
                mount = mp;
        }
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

- (void) finish:(GDInstallJob *)job
{
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
    [self setJob:job state:GDJobDone
          status:job->launchPath ? @"Installed" : @"Installed (open it from the Finder)"];
}

@end
