#import "GDAccelerator.h"
#include <Security/Security.h>
#include <ApplicationServices/ApplicationServices.h>
#include <curl/curl.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <sys/socket.h>

NSString *GDAcceleratorStatusDidChangeNotification = @"GDAcceleratorStatusDidChange";

static NSString * const GDAcceleratorEnabledKey = @"GDAcceleratorEnabled";
static NSString * const GDAcceleratorVMBase = @"http://10.0.2.100:7780/";
static NSString * const GDAcceleratorServiceType = @"_poweremu-web._tcp.";
/* A generic Keychain item of the Garden's own. */
static const char GDAcceleratorKeychainService[] = "The Garden: PowerEmu pairing code";
static const char GDAcceleratorKeychainAccount[] = "PowerEmu";
static const NSTimeInterval GDAcceleratorFailurePause = 60.0;
static const NSTimeInterval GDAcceleratorRetryInterval = 300.0;

/* State shared with the network thread, under the lock. */
static NSLock *stateLock = nil;
static NSString *baseURL = nil;             /* nil: not available */
static NSString *serverName = nil;          /* "Adam's MacBook Air" */
static NSString *token = nil;               /* for a PowerEmu on the network */
static NSTimeInterval failedUntil = 0;
static BOOL probing = NO;
static BOOL sawServiceWithoutCode = NO;
static BOOL pairingRejected = NO;

static NSNetServiceBrowser *browser = nil;
static NSMutableArray *services = nil;
static NSTimer *retryTimer = nil;

@interface GDAccelerator (Private)
+ (NSString *) configuredBase;
+ (void) probe;
+ (void) probeThread:(id)unused;
+ (NSDictionary *) helloAt:(NSString *)base token:(NSString *)code
          connectTimeoutMs:(long)timeout status:(long *)status;
+ (void) browseNetwork;
+ (void) stopBrowsing;
+ (void) finishedProbeWithBase:(NSString *)base name:(NSString *)name token:(NSString *)code;
+ (void) postStatus;
@end

static BOOL debugLogging(void)
{
    return [[NSUserDefaults standardUserDefaults] boolForKey:@"GDDebugNetwork"];
}

static size_t collect(char *bytes, size_t size, size_t count, void *context)
{
    [(NSMutableData *)context appendBytes:bytes length:size * count];
    return size * count;
}

/* Private networks, loopback and .local names are reached directly. */
static BOOL isLocalHost(NSString *host)
{
    struct in_addr address;
    uint32_t value;

    if (host == nil || [host length] == 0)
        return YES;
    host = [host lowercaseString];
    if ([host isEqualToString:@"localhost"] || [host hasSuffix:@".local"] ||
        [host hasSuffix:@".local."])
        return YES;
    if ([host rangeOfString:@":"].location != NSNotFound)
        return YES;     /* an IPv6 literal: leave it alone */
    if (inet_aton([host UTF8String], &address) == 0)
        return NO;
    value = ntohl(address.s_addr);
    return (value >> 24) == 127 || (value >> 24) == 10 || (value >> 16) == 0xC0A8 ||
           (value >> 20) == 0xAC1 || (value >> 16) == 0xA9FE;
}

@implementation GDAccelerator

+ (void) initialize
{
    if (self == [GDAccelerator class])
        stateLock = [[NSLock alloc] init];
}

+ (BOOL) isEnabled
{
    id value = [[NSUserDefaults standardUserDefaults] objectForKey:GDAcceleratorEnabledKey];
    return value == nil || [value boolValue];
}

+ (void) setEnabled:(BOOL)enabled
{
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:GDAcceleratorEnabledKey];
    [self start];
}

+ (NSString *) pairingCode
{
    UInt32 length = 0;
    void *data = NULL;
    NSString *code = nil;

    if (SecKeychainFindGenericPassword(NULL,
            strlen(GDAcceleratorKeychainService), GDAcceleratorKeychainService,
            strlen(GDAcceleratorKeychainAccount), GDAcceleratorKeychainAccount,
            &length, &data, NULL) == noErr) {
        code = [[[NSString alloc] initWithBytes:data length:length
                                       encoding:NSUTF8StringEncoding] autorelease];
        SecKeychainItemFreeContent(NULL, data);
    }
    /* Not in the Keychain: a code set by hand, which is how a Mac with no
     * preferences window (or a test script) gets one. */
    if ([code length] == 0)
        code = [[NSUserDefaults standardUserDefaults]
                   stringForKey:@"GDAcceleratorPairingCode"];
    return [code length] > 0 ? code : nil;
}

+ (void) setPairingCode:(NSString *)code
{
    SecKeychainItemRef item = NULL;
    const char *secret;

    code = [code stringByTrimmingCharactersInSet:
                     [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    secret = [code UTF8String];
    if (SecKeychainFindGenericPassword(NULL,
            strlen(GDAcceleratorKeychainService), GDAcceleratorKeychainService,
            strlen(GDAcceleratorKeychainAccount), GDAcceleratorKeychainAccount,
            NULL, NULL, &item) != noErr)
        item = NULL;
    if ([code length] == 0) {
        if (item != NULL)
            SecKeychainItemDelete(item);
    } else if (item != NULL) {
        SecKeychainItemModifyAttributesAndData(item, NULL, strlen(secret), secret);
    } else {
        SecKeychainAddGenericPassword(NULL,
            strlen(GDAcceleratorKeychainService), GDAcceleratorKeychainService,
            strlen(GDAcceleratorKeychainAccount), GDAcceleratorKeychainAccount,
            strlen(secret), secret, NULL);
    }
    if (item != NULL)
        CFRelease(item);

    [stateLock lock];
    pairingRejected = NO;
    [stateLock unlock];
    [self start];
}

+ (void) start
{
    [self engineHeader];        /* computed once, here */
    [stateLock lock];
    [baseURL release];
    baseURL = nil;
    failedUntil = 0;
    [stateLock unlock];
    [self stopBrowsing];
    if ([self isEnabled])
        [self probe];
    [self postStatus];
    if (retryTimer == nil)
        retryTimer = [[NSTimer scheduledTimerWithTimeInterval:GDAcceleratorRetryInterval
                                                       target:self
                                                     selector:@selector(retryTimerFired:)
                                                     userInfo:nil repeats:YES] retain];
}

/* gdtool and other run-loop-less callers: only the virtual-Mac address, which
 * answers in 300ms or not at all.  Bonjour needs a run loop, so a tool on a
 * real Mac simply goes direct. */
+ (void) startSynchronously
{
    long status = 0;
    NSDictionary *hello;

    NSString *configured = [self configuredBase];

    if (![self isEnabled])
        return;
    [self engineHeader];
    if (configured != nil) {
        NSString *code = [self pairingCode];
        hello = [self helloAt:configured token:code connectTimeoutMs:1500 status:&status];
        if (hello != nil)
            [self finishedProbeWithBase:configured
                                   name:[hello objectForKey:@"name"] token:code];
        return;
    }
    hello = [self helloAt:GDAcceleratorVMBase token:nil connectTimeoutMs:300 status:&status];
    if (hello != nil)
        [self finishedProbeWithBase:GDAcceleratorVMBase
                               name:[hello objectForKey:@"name"] token:nil];
}

+ (void) retryTimerFired:(NSTimer *)timer
{
    BOOL available;
    [stateLock lock];
    available = baseURL != nil;
    [stateLock unlock];
    if (!available && [self isEnabled])
        [self probe];
}

+ (BOOL) shouldRoute:(NSURL *)url
{
    NSString *scheme = [[url scheme] lowercaseString];
    BOOL route, reprobe = NO;

    if (!([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]))
        return NO;
    if (isLocalHost([url host]))
        return NO;
    [stateLock lock];
    route = baseURL != nil;
    if (route && failedUntil > 0) {
        if ([NSDate timeIntervalSinceReferenceDate] < failedUntil)
            route = NO;
        else {
            /* The pause is over: check PowerEmu is back before using it. */
            failedUntil = 0;
            route = NO;
            reprobe = YES;
        }
    }
    [stateLock unlock];
    if (reprobe)
        [self performSelectorOnMainThread:@selector(start) withObject:nil waitUntilDone:NO];
    return route;
}

+ (NSString *) baseURL
{
    NSString *result;
    [stateLock lock];
    result = [[baseURL retain] autorelease];
    [stateLock unlock];
    return result;
}

+ (NSString *) token
{
    NSString *result;
    [stateLock lock];
    result = [[token retain] autorelease];
    [stateLock unlock];
    return result;
}

/* The Garden is not a browser: it runs no scripts, and it draws pictures with
 * NSImage, which reads JPEG, PNG and GIF.  max-image is this screen's longest
 * side, because a screenshot is never shown larger than that. */
+ (NSString *) engineHeader
{
    static NSString *header = nil;
    if (header == nil) {
        CGDirectDisplayID display = CGMainDisplayID();
        size_t w = CGDisplayPixelsWide(display), h = CGDisplayPixelsHigh(display);
        int edge = (int)(w > h ? w : h);
        if (edge < 640)
            edge = 1024;        /* no display (a tool): a sane bound */
        header = [[NSString alloc] initWithFormat:
                     @"client=garden; js=none; images=jpeg,png,gif; max-image=%d", edge];
    }
    return header;
}

+ (void) markFailed
{
    [stateLock lock];
    failedUntil = [NSDate timeIntervalSinceReferenceDate] + GDAcceleratorFailurePause;
    [stateLock unlock];
    if (debugLogging())
        NSLog(@"The Garden: PowerEmu unreachable; going direct for %.0fs",
              GDAcceleratorFailurePause);
    [self performSelectorOnMainThread:@selector(postStatus) withObject:nil waitUntilDone:NO];
}

+ (BOOL) needsPairingCode
{
    BOOL needs;
    [stateLock lock];
    needs = baseURL == nil && (pairingRejected || sawServiceWithoutCode);
    [stateLock unlock];
    return needs;
}

+ (NSString *) statusDescription
{
    NSString *status;

    if (![self isEnabled])
        return @"Off.";
    [stateLock lock];
    if (baseURL != nil && failedUntil > 0)
        status = @"PowerEmu stopped answering; using the network directly for now.";
    else if (baseURL != nil)
        status = [NSString stringWithFormat:@"Using PowerEmu on %@.",
                     serverName != nil ? serverName : @"this Mac"];
    else if (pairingRejected)
        status = @"PowerEmu didn't accept the pairing code. Enter the one its Service Hub shows.";
    else if (sawServiceWithoutCode)
        status = @"Found PowerEmu on the network. Enter the pairing code its Service Hub shows to use it.";
    else if (probing)
        status = @"Looking for PowerEmu...";
    else
        status = @"PowerEmu not found.";
    [stateLock unlock];
    return status;
}

@end

@implementation GDAccelerator (Private)

/* An address given by hand ("http://host:7780/"), for a network where Bonjour
 * does not reach: it is used in place of the search, with the pairing code. */
+ (NSString *) configuredBase
{
    NSString *base = [[NSUserDefaults standardUserDefaults] stringForKey:@"GDAcceleratorBase"];
    if ([base length] == 0)
        return nil;
    if (![base hasSuffix:@"/"])
        base = [base stringByAppendingString:@"/"];
    return base;
}

+ (void) postStatus
{
    [[NSNotificationCenter defaultCenter]
        postNotificationName:GDAcceleratorStatusDidChangeNotification object:nil];
}

+ (void) probe
{
    [stateLock lock];
    if (probing) {
        [stateLock unlock];
        return;
    }
    probing = YES;
    sawServiceWithoutCode = NO;
    [stateLock unlock];
    [NSThread detachNewThreadSelector:@selector(probeThread:) toTarget:self withObject:nil];
}

/* Background thread: are we inside a PowerEmu virtual Mac? */
+ (void) probeThread:(id)unused
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSString *configured = [self configuredBase];
    long status = 0;
    NSDictionary *hello;

    if (configured != nil) {
        NSString *code = [self pairingCode];
        hello = [self helloAt:configured token:code connectTimeoutMs:1500 status:&status];
        if (status == 401) {
            [stateLock lock];
            pairingRejected = YES;
            [stateLock unlock];
        }
        [self finishedProbeWithBase:(hello != nil ? configured : nil)
                               name:[hello objectForKey:@"name"]
                              token:(hello != nil ? code : nil)];
        [pool release];
        return;
    }
    hello = [self helloAt:GDAcceleratorVMBase token:nil connectTimeoutMs:300 status:&status];

    if (hello != nil)
        [self finishedProbeWithBase:GDAcceleratorVMBase
                               name:[hello objectForKey:@"name"] token:nil];
    else    /* not a virtual Mac: look on the network, from the main run loop */
        [self performSelectorOnMainThread:@selector(browseNetwork) withObject:nil
                            waitUntilDone:NO];
    [pool release];
}

/* The hello exchange: the answer's "key: value" lines, or nil when there is no
 * accelerator there (or it wants a pairing code: *status is then 401). */
+ (NSDictionary *) helloAt:(NSString *)base token:(NSString *)code
          connectTimeoutMs:(long)timeout status:(long *)status
{
    CURL *easy = curl_easy_init();
    struct curl_slist *headers = NULL;
    NSMutableData *body = [NSMutableData data];
    NSMutableDictionary *answer = nil;
    CURLcode result;

    *status = 0;
    if (easy == NULL)
        return nil;
    curl_easy_setopt(easy, CURLOPT_URL,
                     [[base stringByAppendingString:@".poweremu/v1/hello"] UTF8String]);
    curl_easy_setopt(easy, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(easy, CURLOPT_CONNECTTIMEOUT_MS, timeout);
    curl_easy_setopt(easy, CURLOPT_TIMEOUT_MS, 3000L);
    curl_easy_setopt(easy, CURLOPT_WRITEFUNCTION, collect);
    curl_easy_setopt(easy, CURLOPT_WRITEDATA, body);
    if (code != nil)
        headers = curl_slist_append(headers,
                      [[@"X-PowerEmu-Token: " stringByAppendingString:code] UTF8String]);
    curl_easy_setopt(easy, CURLOPT_HTTPHEADER, headers);
    result = curl_easy_perform(easy);
    if (result == CURLE_OK)
        curl_easy_getinfo(easy, CURLINFO_RESPONSE_CODE, status);
    curl_easy_cleanup(easy);
    curl_slist_free_all(headers);

    if (result == CURLE_OK && *status == 200) {
        NSString *text = [[[NSString alloc] initWithData:body
                                                encoding:NSUTF8StringEncoding] autorelease];
        NSEnumerator *lines = [[text componentsSeparatedByString:@"\n"] objectEnumerator];
        NSString *line;
        answer = [NSMutableDictionary dictionary];
        while ((line = [lines nextObject]) != nil) {
            NSRange colon = [line rangeOfString:@":"];
            if (colon.location == NSNotFound)
                continue;
            [answer setObject:[[line substringFromIndex:NSMaxRange(colon)]
                                  stringByTrimmingCharactersInSet:
                                      [NSCharacterSet whitespaceAndNewlineCharacterSet]]
                       forKey:[[line substringToIndex:colon.location] lowercaseString]];
        }
        if (![[answer objectForKey:@"service"] isEqualToString:@"PowerEmu Web Accelerator"])
            answer = nil;
    }
    return answer;
}

+ (void) browseNetwork
{
    [self stopBrowsing];
    services = [[NSMutableArray alloc] init];
    browser = [[NSNetServiceBrowser alloc] init];
    [browser setDelegate:(id)self];
    [browser searchForServicesOfType:GDAcceleratorServiceType inDomain:@"local."];
    /* Two seconds to find one, as the protocol suggests. */
    [self performSelector:@selector(browseTimedOut) withObject:nil afterDelay:2.0];
}

+ (void) browseTimedOut
{
    BOOL found;
    [stateLock lock];
    found = baseURL != nil;
    [stateLock unlock];
    if (!found && [services count] == 0) {
        [self stopBrowsing];
        [self finishedProbeWithBase:nil name:nil token:nil];
    }
}

+ (void) stopBrowsing
{
    [NSObject cancelPreviousPerformRequestsWithTarget:self
                                             selector:@selector(browseTimedOut) object:nil];
    [browser setDelegate:nil];
    [browser stop];
    [browser release];
    browser = nil;
    [services makeObjectsPerformSelector:@selector(stop)];
    [services release];
    services = nil;
}

+ (void) netServiceBrowser:(NSNetServiceBrowser *)aBrowser
            didFindService:(NSNetService *)service moreComing:(BOOL)moreComing
{
    NSString *code = [self pairingCode];
    if ([code length] == 0) {
        /* Found, but using it over the network is the user's choice. */
        [stateLock lock];
        sawServiceWithoutCode = YES;
        [stateLock unlock];
        [self stopBrowsing];
        [self finishedProbeWithBase:nil name:[service name] token:nil];
        return;
    }
    [services addObject:service];
    [service setDelegate:(id)self];
    [service resolveWithTimeout:3.0];
}

+ (void) netServiceDidResolveAddress:(NSNetService *)service
{
    NSEnumerator *addresses = [[service addresses] objectEnumerator];
    NSData *data;

    /* An IPv4 address: the home network may have no IPv6 route, and Tiger
     * tries IPv6 first. */
    while ((data = [addresses nextObject]) != nil) {
        const struct sockaddr *address = (const struct sockaddr *)[data bytes];
        if ([data length] >= sizeof(struct sockaddr_in) && address->sa_family == AF_INET) {
            const struct sockaddr_in *ipv4 = (const struct sockaddr_in *)address;
            NSString *base = [NSString stringWithFormat:@"http://%s:%u/",
                                 inet_ntoa(ipv4->sin_addr), ntohs(ipv4->sin_port)];
            NSArray *candidate = [NSArray arrayWithObjects:base, [service name],
                                              [self pairingCode], nil];
            [self stopBrowsing];
            [NSThread detachNewThreadSelector:@selector(helloThread:) toTarget:self
                                   withObject:candidate];
            return;
        }
    }
}

+ (void) netService:(NSNetService *)service didNotResolve:(NSDictionary *)errors
{
    [self stopBrowsing];
    [self finishedProbeWithBase:nil name:nil token:nil];
}

/* Background thread: say hello to a PowerEmu found on the network. */
+ (void) helloThread:(NSArray *)candidate
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSString *base = [candidate objectAtIndex:0];
    NSString *code = [candidate count] > 2 ? [candidate objectAtIndex:2] : nil;
    long status = 0;
    NSDictionary *hello = [self helloAt:base token:code connectTimeoutMs:1500 status:&status];

    if (hello != nil) {
        [self finishedProbeWithBase:base name:[hello objectForKey:@"name"] token:code];
    } else {
        if (status == 401) {
            [stateLock lock];
            pairingRejected = YES;
            [stateLock unlock];
        }
        [self finishedProbeWithBase:nil name:[candidate objectAtIndex:1] token:nil];
    }
    [pool release];
}

+ (void) finishedProbeWithBase:(NSString *)base name:(NSString *)name token:(NSString *)code
{
    [stateLock lock];
    [baseURL release];
    baseURL = [base copy];
    [serverName release];
    serverName = [name copy];
    [token release];
    token = [code copy];
    failedUntil = 0;
    probing = NO;
    if (base != nil)
        pairingRejected = NO;
    [stateLock unlock];
    if (debugLogging())
        NSLog(@"The Garden: PowerEmu accelerator %@", base != nil ? base : @"not available");
    [self performSelectorOnMainThread:@selector(postStatus) withObject:nil waitUntilDone:NO];
}

@end
