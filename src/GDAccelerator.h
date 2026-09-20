/*
 * GDAccelerator - PowerEmu's Web Accelerator, as a client.
 *
 * PowerEmu (the macOS app that runs Tiger and Leopard in a virtual PowerPC
 * Mac) offers a Service Hub that does work old Macs are too slow to do
 * themselves.  Its Web Accelerator fetches HTTP and HTTPS with a modern
 * Mac's networking and hands back the bytes, so this Mac does not make a
 * TLS connection per mirror, and pictures arrive already scaled to the size
 * this screen can show.  For a store whose pages are mostly screenshots,
 * that is most of the work of a page.
 *
 * Inside a PowerEmu virtual Mac it is always at 10.0.2.100:7780 and needs no
 * pairing.  A real Mac finds it with Bonjour and uses it only once the user
 * has entered the pairing code PowerEmu shows: that hop is plain HTTP, so it
 * is an explicit choice.
 *
 * The protocol is in Captain Polliwog's docs/POWEREMU_WEB_ACCELERATOR.md.
 * Everything here is thread-safe: the network thread asks +shouldRoute: for
 * every request.  When PowerEmu is not there, nothing changes.
 */
#import <Foundation/Foundation.h>

extern NSString *GDAcceleratorStatusDidChangeNotification;

@interface GDAccelerator : NSObject

/* At launch, and whenever the preference or the pairing code changes. */
+ (void) start;
/* For tools with no run loop: the virtual-Mac probe, inline, once. */
+ (void) startSynchronously;

+ (BOOL) isEnabled;                 /* the default is on */
+ (void) setEnabled:(BOOL)enabled;

/* The pairing code for a PowerEmu on the network, kept in the Keychain. */
+ (NSString *) pairingCode;
+ (void) setPairingCode:(NSString *)code;

/* Whether this request should go through PowerEmu now. */
+ (BOOL) shouldRoute:(NSURL *)url;
+ (NSString *) baseURL;             /* "http://10.0.2.100:7780/", or nil */
+ (NSString *) engineHeader;        /* the X-PowerEmu-Engine value for this Mac */
+ (NSString *) token;               /* the pairing code in use, or nil */

/* PowerEmu could not be reached: go direct for a minute, then look again. */
+ (void) markFailed;

/* For the preferences: "Using PowerEmu on Adam's MacBook Air", ... */
+ (NSString *) statusDescription;
+ (BOOL) needsPairingCode;

@end
