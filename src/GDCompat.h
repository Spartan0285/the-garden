/*
 * GDCompat - will this download run on this Mac?
 *
 * The Garden gives two hints: the item's "Architecture:" (68k, PPC, x86 ...)
 * and each file's "For ..." line (System 7.0 - Mac OS 9, Mac OS X 10.4 ...).
 * Combined with what this Mac is (PowerPC or Intel, 10.4 or 10.5, Classic
 * installed or not) that gives a verdict per file, and the best file's
 * verdict is the item's.
 */
#import <Foundation/Foundation.h>

@class GDItemDetail, GDFile;

typedef enum {                /* ordered worst .. best */
    GDVerdictUnknown = 0,
    GDVerdictIncompatible,
    GDVerdictNeedsEmulator,   /* Mac OS 9 software on a Mac with no Classic at all */
    GDVerdictNeedsNewerOS,
    GDVerdictNeedsClassic,    /* PowerPC Tiger without a Mac OS 9 System Folder */
    GDVerdictClassic,
    GDVerdictRosetta,
    GDVerdictNative
} GDVerdict;

@interface GDCompat : NSObject
+ (BOOL) hostIsPPC;
+ (int) hostOSMinor;          /* 4 = Tiger, 5 = Leopard */
+ (BOOL) hostHasClassic;      /* Classic environment usable (PPC, 10.4, System Folder) */
+ (NSString *) hostDescription;

+ (GDVerdict) verdictForFile:(GDFile *)f architecture:(NSString *)arch;
/* For GDVerdictNeedsEmulator: which emulator, and where it is in the Garden. */
+ (NSString *) emulatorNameForItem:(GDItemDetail *)d;
+ (NSString *) emulatorPathForItem:(GDItemDetail *)d;
+ (GDVerdict) verdictForItem:(GDItemDetail *)d bestFile:(GDFile **)best;

+ (NSString *) shortLabel:(GDVerdict)v;    /* badge text */
+ (NSString *) explanation:(GDVerdict)v;   /* one sentence */
+ (BOOL) runsHere:(GDVerdict)v;            /* shown under "Runs on this Mac" */
@end
