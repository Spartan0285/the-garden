/*
 * GDInstaller - the "Get" button: download, verify, unpack, install.
 *
 *   download   curl, trying each mirror in turn; into ~/Downloads/The Garden
 *   verify     MD5 against the one the Garden publishes
 *   unpack     everything archive-shaped through the bundled XADMaster
 *              (StuffIt, BinHex, MacBinary, zip, ...); disk images via hdiutil
 *   install    an .app goes to /Applications; anything with more parts is
 *              copied as a folder named after the title; installer packages
 *              open in Installer; Mac OS 9 software goes to
 *              "Applications (Mac OS 9)" when that folder exists
 *
 * Everything after the download runs on a worker thread.  Progress and state
 * changes are posted as GDJobChangedNotification on the main thread.
 */
#import <Foundation/Foundation.h>
#import "GDGarden.h"
#import "GDCompat.h"

extern NSString *GDJobChangedNotification;      /* object: GDInstallJob */
extern NSString *GDLibraryChangedNotification;

typedef enum {
    GDJobQueued,
    GDJobDownloading,
    GDJobVerifying,
    GDJobUnpacking,
    GDJobInstalling,
    GDJobDone,
    GDJobFailed,
    GDJobCancelled
} GDJobState;

@class GDHTTPRequest;

@interface GDInstallJob : NSObject
{
@public
    GDItemDetail *item;
    GDFile *file;
    GDVerdict verdict;
    GDJobState state;
    NSString *status;          /* human-readable line */
    double progress;           /* 0..1, <0 = indeterminate */
    long long bytesDone, bytesTotal;
    NSString *downloadPath;
    NSString *workDir;
    NSMutableArray *installed; /* paths */
    NSString *launchPath;      /* app to open, if any */
    NSString *revealPath;
    int mirror;                /* index into mirrorOrder */
    NSArray *mirrorOrder;      /* fastest known first */
    int attempts;              /* on the current mirror */
    double attemptStart;
    long long attemptBytes;    /* bytesDone when this attempt began */
    BOOL switchingMirror;      /* cancelled on purpose: too slow */
    GDHTTPRequest *request;
    volatile BOOL cancelled;
    double started;
}
- (GDItemDetail *) item;
- (GDFile *) file;
- (GDJobState) state;
- (NSString *) status;
- (double) progress;
- (NSString *) launchPath;
- (NSString *) revealPath;
- (BOOL) isActive;
@end

@interface GDInstaller : NSObject
{
    NSMutableArray *jobs;
    NSMutableArray *library;   /* NSDictionary per installed title */
    NSString *libraryPath;
    NSMutableDictionary *speeds;   /* mirror host -> bytes/s, remembered */
    GDInstallJob *currentExtractJob;   /* worker thread's job, for progress */
}
+ (GDInstaller *) sharedInstaller;

- (GDInstallJob *) installFile:(GDFile *)f ofItem:(GDItemDetail *)d;
- (void) cancel:(GDInstallJob *)job;
- (void) retry:(GDInstallJob *)job;
- (void) clearFinished;
- (NSArray *) jobs;
- (GDInstallJob *) jobForItemPath:(NSString *)path;

/* Library: {path, title, file, installed (array), launch, date, thumb, verdict} */
- (NSArray *) library;
- (NSDictionary *) libraryEntryForPath:(NSString *)path;
- (void) removeLibraryEntry:(NSDictionary *)entry moveToTrash:(BOOL)trash;

+ (NSString *) downloadsFolder;
@end
