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
#import <AppKit/AppKit.h>

extern NSString *GDJobChangedNotification;      /* object: GDInstallJob */
extern NSString *GDLibraryChangedNotification;
extern NSString *GDUpdatesChangedNotification;

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
    BOOL reusedDownload;       /* the whole file was already on disk */
    GDHTTPRequest *request;
    volatile BOOL cancelled;
    double started;
    NSArray *replaces;         /* an update: installed paths to trash once done */
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
    NSMutableArray *updates;   /* {entry, file, detail} */
    NSMutableArray *history;   /* every download attempted, newest first */
    NSString *historyPath;
    NSMutableSet *retrying;    /* item paths whose page is being fetched to retry */
    NSMutableArray *ignored;   /* "path\tfile" of updates not to offer again */
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
- (NSImage *) iconForEntry:(NSDictionary *)entry;   /* the installed app's icon, or nil */

- (void) removeLibraryEntry:(NSDictionary *)entry moveToTrash:(BOOL)trash;

/* Download history: one record per file ever asked for, saved as it goes, so
 * an attempt that failed - or that the app was killed in the middle of - is
 * still there to try again after a relaunch.  Newest first.  Keys:
 *   key         path + tab + file name; the record's identity
 *   path title thumb arch          the item it came from
 *   file size sizeBytes md5 mirrors systems    the file that was asked for
 *   state       downloading | retrying | interrupted | cancelled | failed | done
 *   status      the last line that was shown for it
 *   date        when it was last worked on
 *   bytesDone bytesTotal
 *   launch reveal      set once installed, so Open keeps working next launch
 */
- (NSArray *) history;
- (GDInstallJob *) jobForHistoryEntry:(NSDictionary *)h;   /* nil after a relaunch */
- (void) retryHistoryEntry:(NSDictionary *)h;
- (void) removeHistoryEntry:(NSDictionary *)h;
- (void) clearHistory;     /* every record that is not being fetched right now */

/* Updates: a newer file of the same kind as the installed one. */
- (void) checkForUpdates;
- (NSArray *) updates;                               /* {entry, file, detail} */
- (GDInstallJob *) installUpdate:(NSDictionary *)update;
+ (GDFile *) newerFileFor:(NSDictionary *)entry inDetail:(GDItemDetail *)d;

/* An update the user does not want to be offered again.  Remembered per file,
 * so a later, newer one is still offered. */
- (void) ignoreUpdate:(NSDictionary *)update;
- (BOOL) isUpdateIgnoredForPath:(NSString *)path file:(NSString *)name;
- (unsigned) ignoredUpdateCount;
- (void) clearIgnoredUpdates;

/* Dock: add an installed app. */
- (BOOL) addToDock:(NSDictionary *)entry;

+ (NSString *) downloadsFolder;
@end
