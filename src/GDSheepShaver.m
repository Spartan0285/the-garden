#import "GDSheepShaver.h"
#import "GDInstaller.h"

static NSString *prefsPath(void)
{
    return [NSHomeDirectory() stringByAppendingPathComponent:@".sheepshaver_prefs"];
}

/* The settings file is one "key value" per line. */
static NSString *prefsValue(NSString *key)
{
    NSString *text = [NSString stringWithContentsOfFile:prefsPath()];
    NSEnumerator *lines;
    NSString *line;

    if ([text length] == 0)
        return nil;
    lines = [[text componentsSeparatedByString:@"\n"] objectEnumerator];
    while ((line = [lines nextObject]) != nil) {
        NSString *prefix = [key stringByAppendingString:@" "];
        if (![line hasPrefix:prefix])
            continue;
        return [[line substringFromIndex:[prefix length]]
                   stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }
    return nil;
}

@implementation GDSheepShaver

+ (NSString *) applicationPath
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *library = [[GDInstaller sharedInstaller] library];
    NSEnumerator *e;
    NSString *name;
    unsigned i;

    /* What the Garden installed itself, first: we know exactly where it is. */
    for (i = 0; i < [library count]; i++) {
        NSDictionary *entry = [library objectAtIndex:i];
        NSString *launch = [entry objectForKey:@"launch"];
        if ([[launch lastPathComponent] hasPrefix:@"SheepShaver"] &&
            [fm fileExistsAtPath:launch])
            return launch;
    }
    /* Otherwise /Applications, and one level down: these downloads unpack to
     * a folder with the program inside it. */
    e = [[fm directoryContentsAtPath:@"/Applications"] objectEnumerator];
    while ((name = [e nextObject]) != nil) {
        NSString *p = [@"/Applications" stringByAppendingPathComponent:name];
        if ([name isEqualToString:@"SheepShaver.app"])
            return p;
        if ([name rangeOfString:@"SheepShaver"].location != NSNotFound) {
            NSString *inside = [p stringByAppendingPathComponent:@"SheepShaver.app"];
            if ([fm fileExistsAtPath:inside])
                return inside;
            if ([[name pathExtension] isEqualToString:@"app"])
                return p;
        }
    }
    return nil;
}

+ (BOOL) isInstalled
{
    return [self applicationPath] != nil;
}

+ (BOOL) isRunning
{
    NSArray *running = [[NSWorkspace sharedWorkspace] launchedApplications];
    unsigned i;
    for (i = 0; i < [running count]; i++) {
        NSString *name = [[running objectAtIndex:i] objectForKey:@"NSApplicationName"];
        if ([name rangeOfString:@"SheepShaver"].location != NSNotFound)
            return YES;
    }
    return NO;
}

+ (NSString *) sharedFolder
{
    NSString *folder = prefsValue(@"extfs");
    return [folder length] ? folder : nil;
}

+ (BOOL) sharesPath:(NSString *)path
{
    NSString *shared = [self sharedFolder];
    if (shared == nil || [path length] == 0)
        return NO;
    if ([shared isEqualToString:@"/"])
        return YES;
    if (![shared hasSuffix:@"/"])
        shared = [shared stringByAppendingString:@"/"];
    return [[path stringByAppendingString:@"/"] hasPrefix:shared];
}

+ (NSString *) installFolder
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *os9 = @"/Applications (Mac OS 9)";
    NSString *shared = [self sharedFolder];

    if (shared == nil)
        return nil;
    if ([self sharesPath:os9]) {
        if (![fm fileExistsAtPath:os9])
            [fm createDirectoryAtPath:os9 attributes:nil];
        if ([fm isWritableFileAtPath:os9])
            return os9;
    }
    /* Their shared folder is somewhere else: put it there, where they will
     * see it in Mac OS 9, rather than move their share. */
    return [fm isWritableFileAtPath:shared] ? shared : nil;
}

+ (BOOL) shareFolder:(NSString *)folder
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *path = prefsPath();
    NSString *text = [NSString stringWithContentsOfFile:path];
    NSMutableArray *lines;
    NSString *line = [@"extfs " stringByAppendingString:folder];
    unsigned i;

    if (![fm fileExistsAtPath:folder])
        [fm createDirectoryAtPath:folder attributes:nil];
    if ([text length] == 0) {
        /* No settings file yet: SheepShaver writes one at first launch, and
         * reads what is there, so a file with this one line is enough. */
        return [[line stringByAppendingString:@"\n"] writeToFile:path atomically:YES];
    }
    /* Keep a copy: this is another program's settings. */
    [fm removeFileAtPath:[path stringByAppendingPathExtension:@"gardenbackup"] handler:nil];
    [fm copyPath:path toPath:[path stringByAppendingPathExtension:@"gardenbackup"] handler:nil];

    lines = [[[text componentsSeparatedByString:@"\n"] mutableCopy] autorelease];
    for (i = 0; i < [lines count]; i++) {
        if ([[lines objectAtIndex:i] hasPrefix:@"extfs "]) {
            [lines replaceObjectAtIndex:i withObject:line];
            return [[lines componentsJoinedByString:@"\n"] writeToFile:path atomically:YES];
        }
    }
    [lines addObject:line];
    return [[lines componentsJoinedByString:@"\n"] writeToFile:path atomically:YES];
}

+ (void) launch
{
    NSString *p = [self applicationPath];
    if (p != nil)
        [[NSWorkspace sharedWorkspace] openFile:p];
}

@end
