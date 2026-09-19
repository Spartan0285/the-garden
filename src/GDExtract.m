#import "GDExtract.h"

/* The 10.4u SDK predates NSInteger; on 32-bit it is plain int, which is what
 * the framework was built with. */
#ifndef NSINTEGER_DEFINED
typedef int NSInteger;
typedef unsigned int NSUInteger;
#define NSINTEGER_DEFINED 1
#endif
#import <XADMaster/XADSimpleUnarchiver.h>
#import <XADMaster/XADString.h>
#import <XADMaster/XADException.h>

@interface GDExtractDelegate : NSObject
{
@public
    id target;
    SEL action;
    double lastReport;
}
@end

@implementation GDExtractDelegate

/* Old Mac archives rarely say how names are encoded.  Trust a confident
 * guess; otherwise MacRoman, which is what nearly all of them are. */
- (NSString *) simpleUnarchiver:(XADSimpleUnarchiver *)u encodingNameForXADString:(id <XADString>)s
{
    if ([s encodingIsKnown] || [s confidence] >= 0.8)
        return [s encodingName];
    if ([s canDecodeWithEncodingName:XADMacOSRomanStringEncodingName])
        return XADMacOSRomanStringEncodingName;
    return [s encodingName];
}

- (void) simpleUnarchiverNeedsPassword:(XADSimpleUnarchiver *)u
{
    /* Nothing sensible to ask; extraction of protected entries fails. */
}

- (void) report:(double)fraction
{
    double now = CFAbsoluteTimeGetCurrent();
    if (target && now - lastReport > 0.3) {
        lastReport = now;
        [target performSelector:action withObject:[NSNumber numberWithDouble:fraction]];
    }
}

- (void) simpleUnarchiver:(XADSimpleUnarchiver *)u
    extractionProgressForEntryWithDictionary:(NSDictionary *)d
    fileProgress:(off_t)fp of:(off_t)fs totalProgress:(off_t)tp of:(off_t)ts
{
    if (ts > 0)
        [self report:(double)tp / ts];
}

- (void) simpleUnarchiver:(XADSimpleUnarchiver *)u
    estimatedExtractionProgressForEntryWithDictionary:(NSDictionary *)d
    fileProgress:(double)fp totalProgress:(double)tp
{
    [self report:tp];
}

@end

BOOL GDIsArchive(NSString *path)
{
    static NSArray *exts;
    NSString *e = [[path pathExtension] lowercaseString];
    if (exts == nil)
        exts = [[NSArray alloc] initWithObjects:@"sit", @"sitx", @"sea", @"cpt", @"hqx", @"bin",
                   @"macbin", @"zip", @"gz", @"tgz", @"bz2", @"tbz", @"tar", @"rar", @"7z", @"lha",
                   @"lzh", @"dd", @"arc", @"pit", @"z", @"cab", @"xar", @"pkg-archive", nil];
    return [exts containsObject:e];
}

NSString *GDExtractArchive(NSString *path, NSString *destDir, NSString **error,
                           id progressTarget, SEL progressSelector)
{
    GDExtractDelegate *del = [[[GDExtractDelegate alloc] init] autorelease];
    XADSimpleUnarchiver *u = nil;
    XADError err = XADNoError;
    NSString *made = nil;

    del->target = progressTarget;
    del->action = progressSelector;
    NS_DURING
        u = [XADSimpleUnarchiver simpleUnarchiverForPath:path error:&err];
        if (u != nil) {
            [u setDelegate:del];
            [u setDestination:destDir];
            [u setRemovesEnclosingDirectoryForSoloItems:YES];
            [u setAlwaysRenamesFiles:YES];
            [u setExtractsSubArchives:YES];
            [u setMacResourceForkStyle:XADMacOSXForkStyle];
            [u setPreserevesPermissions:YES];
            err = [u parse];
            if (err == XADNoError)
                err = [u unarchive];
            if (err == XADNoError || [u numberOfItemsExtracted] > 0)
                made = [u createdItemOrActualDestination];
        }
    NS_HANDLER
        err = [XADException parseException:localException];
    NS_ENDHANDLER

    if (made == nil && error)
        *error = u == nil && err == XADNoError ? @"This file is not an archive the Garden can open."
                                                : [XADException describeXADError:err];
    return made;
}
