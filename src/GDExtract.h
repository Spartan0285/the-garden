/*
 * GDExtract - unpack any archive the Garden serves, in-process.
 *
 * Uses XADMaster, The Unarchiver's engine (LGPL, bundled unmodified in
 * Contents/Frameworks): StuffIt 1-5 and X, Compact Pro, BinHex, MacBinary,
 * DiskDoubler, zip, gzip/bzip2/tar, rar, 7z, lha ...  Nested wrappers
 * (.sit.hqx, .sit.bin) are unpacked in one go, resource forks and Finder
 * info land on the HFS+ files, and old Mac file names are read as MacRoman
 * when their encoding can't be told - no dialogs, no helper application.
 */
#import <Foundation/Foundation.h>

/* Is this something XADMaster should open (rather than hdiutil)? */
BOOL GDIsArchive(NSString *path);

/* Extract into destDir.  Returns the single item created (file or folder),
 * or the folder holding several; nil on failure with *error set.
 * progress(fraction) is called on the calling thread. */
NSString *GDExtractArchive(NSString *path, NSString *destDir, NSString **error,
                           id progressTarget, SEL progressSelector);
