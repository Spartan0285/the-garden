/*
 * GDSelfUpdate - the Garden keeping itself up to date.
 *
 * A small plist on the project's site (the "appcast") says what the newest
 * build is, where its zip is and what it hashes to, and carries an Ed25519
 * signature over those facts.  The app has the matching public key built in
 * and verifies the signature with the OpenSSL it already bundles, so a build
 * is only installed if it was signed by whoever holds the release key - not
 * merely by whoever can write to the download.
 *
 * It checks once a day in the background and downloads quietly; installing
 * means quitting and starting again, so it always asks first.  Everything
 * goes through GDHTTP, because Tiger's own TLS cannot reach the site.
 */
#import <Cocoa/Cocoa.h>

extern NSString *GDSelfUpdateChangedNotification;

@class GDHTTPRequest;

@interface GDSelfUpdate : NSObject
{
    GDHTTPRequest *request;
    NSDictionary *available;     /* the newer build's appcast entry */
    NSString *downloadedZip;
    BOOL checking, downloading, announced;
    BOOL userAsked;              /* they chose Check for Updates: always answer */
    BOOL installWithoutAsking;   /* the test hook */
}

+ (GDSelfUpdate *) sharedUpdater;

/* At launch, and once a day after that.  Silent: nothing is said unless a
 * newer build is there, signed, and downloaded. */
- (void) checkInBackground;
/* The menu item: says so either way, and says why if it could not look. */
- (IBAction) checkForUpdates:(id)sender;

/* Test hook (GDDebugUpdate=1): check, download, verify and install without
 * the question, so the whole path can be driven from a script. */
- (void) checkAndInstallNow;

- (BOOL) isBusy;
- (NSString *) availableVersion;    /* nil when there is nothing newer */

+ (NSString *) currentVersion;      /* CFBundleShortVersionString */
+ (int) currentBuild;               /* CFBundleVersion, a whole number */

@end
