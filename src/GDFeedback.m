#import "GDFeedback.h"
#import "GDHTTP.h"
#import "GDCompat.h"
#import "GDAccelerator.h"
#import "GDStyle.h"
#include <sys/sysctl.h>
#include <stdlib.h>          /* arc4random */

/* One endpoint for every app in this family; the "app" field says which.
 * Changeable without a new build: defaults write org.macintoshgarden.store
 * GDFeedbackURL <address>. */
static NSString * const GDFeedbackDefaultURL = @"https://www.cytrusretro.com/api/feedback";
static NSString * const GDFeedbackAppID = @"the-garden";
/* Not a secret - it is in the binary - but it keeps a public endpoint from
 * being the first thing a scanner finds.  The real limits are on the server. */
static NSString * const GDFeedbackClientToken = @"garden-client-1";

#define SHOT_MAX_EDGE 800.0

/* A plain, non-editable text field: the window is built in code. */
static NSTextField *makeLabel(NSString *text, NSRect r)
{
    NSTextField *t = [[[NSTextField alloc] initWithFrame:r] autorelease];
    [t setStringValue:text ?: @""];
    [t setEditable:NO];
    [t setSelectable:NO];
    [t setBordered:NO];
    [t setDrawsBackground:NO];
    [t setFont:[NSFont systemFontOfSize:12]];
    return t;
}

static NSString *feedbackURL(void)
{
    NSString *u = [[NSUserDefaults standardUserDefaults] stringForKey:@"GDFeedbackURL"];
    return [u length] ? u : GDFeedbackDefaultURL;
}

/* ---- the small encodings Tiger's Foundation does not have --------------- */

static NSString *base64(NSData *data)
{
    static const char *alphabet =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    const unsigned char *b = [data bytes];
    unsigned n = (unsigned)[data length], i;
    NSMutableString *out = [NSMutableString stringWithCapacity:(n + 2) / 3 * 4];

    for (i = 0; i < n; i += 3) {
        unsigned long v = (unsigned long)b[i] << 16;
        int have = 1;
        if (i + 1 < n) { v |= (unsigned long)b[i + 1] << 8; have++; }
        if (i + 2 < n) { v |= (unsigned long)b[i + 2]; have++; }
        [out appendFormat:@"%c%c%c%c",
            alphabet[(v >> 18) & 0x3F], alphabet[(v >> 12) & 0x3F],
            have > 1 ? alphabet[(v >> 6) & 0x3F] : '=',
            have > 2 ? alphabet[v & 0x3F] : '='];
    }
    return out;
}

static NSString *jsonString(NSString *s)
{
    NSMutableString *out = [NSMutableString stringWithString:@"\""];
    unsigned i, n = [s length];
    for (i = 0; i < n; i++) {
        unichar c = [s characterAtIndex:i];
        switch (c) {
        case '"':  [out appendString:@"\\\""]; break;
        case '\\': [out appendString:@"\\\\"]; break;
        case '\n': [out appendString:@"\\n"]; break;
        case '\r': [out appendString:@"\\r"]; break;
        case '\t': [out appendString:@"\\t"]; break;
        default:
            if (c < 0x20 || c > 0x7E)
                [out appendFormat:@"\\u%04x", (unsigned)c];
            else
                [out appendFormat:@"%C", c];
        }
    }
    [out appendString:@"\""];
    return out;
}

/* ---- what this Mac is --------------------------------------------------- */

static NSString *sysctlString(const char *name)
{
    char buf[256];
    size_t len = sizeof buf;
    if (sysctlbyname(name, buf, &len, NULL, 0) != 0)
        return @"";
    buf[sizeof buf - 1] = 0;
    return [NSString stringWithUTF8String:buf];
}

static NSString *systemJSON(void)
{
    NSRect screen = [[NSScreen mainScreen] frame];
    uint64_t memory = 0;
    size_t len = sizeof memory;
    NSString *accelerator;

    sysctlbyname("hw.memsize", &memory, &len, NULL, 0);
    accelerator = [GDAccelerator baseURL] != nil ? @"in use" : @"not in use";
    return [NSString stringWithFormat:
        @"{\"os\":%@,\"arch\":%@,\"model\":%@,\"memoryMB\":%llu,\"screen\":%@,"
         "\"classic\":%@,\"accelerator\":%@}",
        jsonString([NSString stringWithFormat:@"10.%d", [GDCompat hostOSMinor]]),
        jsonString([GDCompat hostIsPPC] ? @"PowerPC" : @"Intel"),
        jsonString(sysctlString("hw.model")),
        (unsigned long long)(memory / (1024 * 1024)),
        jsonString([NSString stringWithFormat:@"%dx%d",
                       (int)NSWidth(screen), (int)NSHeight(screen)]),
        [GDCompat hostHasClassic] ? @"true" : @"false",
        jsonString(accelerator)];
}

@interface GDFeedback (Private)
- (void) build;
- (void) send:(id)sender;
- (void) cancel:(id)sender;
- (void) shotToggled:(id)sender;
- (NSString *) reportJSON;
- (void) postJSON:(NSString *)json;
- (void) queueJSON:(NSString *)json;
@end

static NSMutableArray *liveReports;     /* retried in the background */
static GDFeedback *shared;              /* the window being filled in, for the test hook */

@implementation GDFeedback

+ (NSString *) outboxDirectory
{
    NSString *dir = [[NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,
                          NSUserDomainMask, YES) objectAtIndex:0]
                        stringByAppendingPathComponent:@"The Garden"];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:dir attributes:nil];
    dir = [dir stringByAppendingPathComponent:@"Outbox"];
    [fm createDirectoryAtPath:dir attributes:nil];
    return dir;
}

+ (void) openForWindow:(NSWindow *)w page:(NSString *)pageDescription
{
    GDFeedback *f = [[self alloc] init];    /* released when the window closes */
    shared = f;
    f->page = [pageDescription copy];
    if (w != nil) {
        NSView *v = [[w contentView] superview];
        NSBitmapImageRep *bm = [v bitmapImageRepForCachingDisplayInRect:[v bounds]];
        [v cacheDisplayInRect:[v bounds] toBitmapImageRep:bm];
        f->shot = [[NSImage alloc] initWithSize:[bm size]];
        [f->shot addRepresentation:bm];
    }
    [f build];
}

+ (void) debugSendFor:(NSWindow *)w page:(NSString *)pageDescription
              message:(NSString *)text
{
    [self openForWindow:w page:pageDescription];
    if (shared != nil) {
        [[shared->message textStorage] replaceCharactersInRange:NSMakeRange(0, 0)
                                                     withString:text];
        [shared send:nil];
    }
}

/* Anything written to the outbox when the network was not there. */
+ (void) sendQueuedReports
{
    NSString *dir = [self outboxDirectory];
    NSEnumerator *e = [[[NSFileManager defaultManager] directoryContentsAtPath:dir]
                          objectEnumerator];
    NSString *name;

    if (liveReports == nil)
        liveReports = [[NSMutableArray alloc] init];
    while ((name = [e nextObject]) != nil) {
        NSString *p = [dir stringByAppendingPathComponent:name];
        NSString *json;
        GDFeedback *f;
        if (![[name pathExtension] isEqualToString:@"json"])
            continue;
        json = [NSString stringWithContentsOfFile:p];
        if ([json length] == 0) {
            [[NSFileManager defaultManager] removeFileAtPath:p handler:nil];
            continue;
        }
        f = [[self alloc] init];
        f->queuedPath = [p copy];
        [liveReports addObject:f];
        [f release];
        [f postJSON:json];
    }
}

- (void) dealloc
{
    [request setDelegate:nil];
    [request release];
    [window release];
    [shot release];
    [page release];
    [reportID release];
    [queuedPath release];
    [super dealloc];
}

@end

@implementation GDFeedback (Private)

- (void) build
{
    NSRect frame = NSMakeRect(0, 0, 520, 470);
    NSView *content;
    NSScrollView *scroll;
    NSTextField *label;
    float y;

    window = [[NSWindow alloc] initWithContentRect:frame
                  styleMask:(NSTitledWindowMask | NSClosableWindowMask)
                    backing:NSBackingStoreBuffered defer:NO];
    [window setTitle:@"Send Feedback"];
    [window setReleasedWhenClosed:NO];
    [window setDelegate:self];
    content = [window contentView];
    y = frame.size.height - 46;

    label = makeLabel(@"What is this about?", NSMakeRect(20, y, 220, 18));
    [content addSubview:label];
    topic = [[[NSPopUpButton alloc] initWithFrame:NSMakeRect(220, y - 4, 280, 26)] autorelease];
    [topic addItemWithTitle:@"Something is broken"];
    [topic addItemWithTitle:@"A download would not install"];
    [topic addItemWithTitle:@"The compatibility badge is wrong"];
    [topic addItemWithTitle:@"Something looks wrong on screen"];
    [topic addItemWithTitle:@"It was too slow"];
    [topic addItemWithTitle:@"A suggestion"];
    [topic addItemWithTitle:@"Something else"];
    [content addSubview:topic];
    y -= 36;

    label = makeLabel(@"What happened?", NSMakeRect(20, y, 300, 18));
    [content addSubview:label];
    y -= 150;
    scroll = [[[NSScrollView alloc] initWithFrame:NSMakeRect(20, y, 480, 144)] autorelease];
    [scroll setHasVerticalScroller:YES];
    [scroll setBorderType:NSBezelBorder];
    message = [[[NSTextView alloc] initWithFrame:[[scroll contentView] bounds]] autorelease];
    [message setMinSize:NSMakeSize(0, 0)];
    [message setMaxSize:NSMakeSize(1e7, 1e7)];
    [message setVerticallyResizable:YES];
    [message setHorizontallyResizable:NO];
    [message setAutoresizingMask:NSViewWidthSizable];
    [[message textContainer] setWidthTracksTextView:YES];
    [message setFont:[NSFont systemFontOfSize:12]];
    [scroll setDocumentView:message];
    [content addSubview:scroll];
    y -= 30;

    label = makeLabel(@"Your email (only if you want an answer)", NSMakeRect(20, y, 300, 18));
    [content addSubview:label];
    email = [[[NSTextField alloc] initWithFrame:NSMakeRect(320, y - 3, 180, 22)] autorelease];
    [[email cell] setPlaceholderString:@"optional"];
    [content addSubview:email];
    y -= 40;

    includeShot = [[[NSButton alloc] initWithFrame:NSMakeRect(20, y, 320, 20)] autorelease];
    [includeShot setButtonType:NSSwitchButton];
    [includeShot setTitle:@"Include a picture of the Garden's window"];
    [includeShot setState:shot != nil ? NSOnState : NSOffState];
    [includeShot setEnabled:shot != nil];
    [includeShot setTarget:self];
    [includeShot setAction:@selector(shotToggled:)];
    [content addSubview:includeShot];

    shotView = [[[NSImageView alloc] initWithFrame:NSMakeRect(350, y - 54, 150, 76)] autorelease];
    [shotView setImageScaling:NSScaleProportionally];
    [shotView setImageFrameStyle:NSImageFrameGrayBezel];
    [shotView setImage:shot];
    [content addSubview:shotView];
    y -= 62;

    label = makeLabel([NSString stringWithFormat:
        @"Sent with this: The Garden %@ (build %@), %@, and the page you were on. "
         "Nothing else, and nothing until you press Send.",
        [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"],
        [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"],
        [GDCompat hostDescription]], NSMakeRect(20, y - 16, 320, 46));
    [label setFont:[NSFont systemFontOfSize:10]];
    [[label cell] setWraps:YES];
    [label setTextColor:GDSubtleTextColor()];
    [content addSubview:label];

    status = makeLabel(@"", NSMakeRect(20, 18, 300, 18));
    [status setFont:[NSFont systemFontOfSize:11]];
    [status setTextColor:GDSubtleTextColor()];
    [content addSubview:status];

    sendButton = [[[NSButton alloc] initWithFrame:NSMakeRect(400, 14, 100, 30)] autorelease];
    [sendButton setBezelStyle:NSRoundedBezelStyle];
    [sendButton setTitle:@"Send"];
    [sendButton setKeyEquivalent:@"\r"];
    [sendButton setTarget:self];
    [sendButton setAction:@selector(send:)];
    [content addSubview:sendButton];

    {
        NSButton *c = [[[NSButton alloc] initWithFrame:NSMakeRect(296, 14, 100, 30)] autorelease];
        [c setBezelStyle:NSRoundedBezelStyle];
        [c setTitle:@"Cancel"];
        [c setKeyEquivalent:@"\033"];
        [c setTarget:self];
        [c setAction:@selector(cancel:)];
        [content addSubview:c];
    }

    [window center];
    [window makeKeyAndOrderFront:nil];
    [window makeFirstResponder:message];
}

- (void) shotToggled:(id)sender
{
    [shotView setImage:[includeShot state] == NSOnState ? shot : nil];
}

- (void) cancel:(id)sender
{
    [window close];
}

- (void) windowWillClose:(NSNotification *)n
{
    [self autorelease];
}

- (NSString *) reportJSON
{
    NSString *text = [[message textStorage] string];
    NSString *shotBase64 = @"";
    NSString *summary;
    NSRange nl;

    if ([includeShot state] == NSOnState && shot != nil) {
        /* Scaled down: a 1024-pixel window is a big thing to push through a
         * modem-era network, and the point is to see what it looked like. */
        NSSize size = [shot size];
        float scale = SHOT_MAX_EDGE / (size.width > size.height ? size.width : size.height);
        NSImage *small = shot;
        NSBitmapImageRep *rep = nil;
        if (scale < 1.0) {
            NSSize to = NSMakeSize(floor(size.width * scale), floor(size.height * scale));
            small = [[[NSImage alloc] initWithSize:to] autorelease];
            [small lockFocus];
            [[NSGraphicsContext currentContext] setImageInterpolation:NSImageInterpolationHigh];
            [shot drawInRect:NSMakeRect(0, 0, to.width, to.height)
                    fromRect:NSMakeRect(0, 0, size.width, size.height)
                   operation:NSCompositeCopy fraction:1.0];
            rep = [[[NSBitmapImageRep alloc] initWithFocusedViewRect:
                       NSMakeRect(0, 0, to.width, to.height)] autorelease];
            [small unlockFocus];
        } else {
            NSEnumerator *e = [[shot representations] objectEnumerator];
            id r;
            while ((r = [e nextObject]) != nil)
                if ([r isKindOfClass:[NSBitmapImageRep class]])
                    rep = r;
        }
        if (rep != nil)
            shotBase64 = base64([rep representationUsingType:NSPNGFileType properties:nil]);
    }

    nl = [text rangeOfString:@"\n"];
    summary = nl.location == NSNotFound ? text : [text substringToIndex:nl.location];
    if ([summary length] > 90)
        summary = [summary substringToIndex:90];

    /* A name this report keeps across retries, so a report that was stored but
     * whose issue could not be opened does not become two.
     *
     * The random half must be unguessable, not merely varied: the screenshot
     * that goes with a report is served from /api/shot/<app>/<id>.png with no
     * authentication - it has to be, so the issue can show it - so the id is
     * the only thing keeping one person's screenshot from anybody else.
     * random() without srandom() would return the same sequence on every Mac
     * and every launch (6b8b4567 first, every time), which left the timestamp
     * as the whole secret.  arc4random seeds itself from the kernel. */
    if (reportID == nil)
        reportID = [[NSString alloc] initWithFormat:@"%@-%08x%08x",
                       [[NSDate date] descriptionWithCalendarFormat:@"%Y%m%d%H%M%S"
                                                           timeZone:nil locale:nil],
                       (unsigned)arc4random(), (unsigned)arc4random()];
    return [NSString stringWithFormat:
        @"{\"id\":%@,\"app\":%@,\"version\":%@,\"build\":%@,\"topic\":%@,\"summary\":%@,"
         "\"message\":%@,\"email\":%@,\"page\":%@,\"system\":%@,\"screenshot\":%@}",
        jsonString(reportID),
        jsonString(GDFeedbackAppID),
        jsonString([[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?"),
        jsonString([[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"?"),
        jsonString([topic titleOfSelectedItem] ?: @""),
        jsonString(summary),
        jsonString(text),
        jsonString([email stringValue] ?: @""),
        jsonString(page ?: @""),
        systemJSON(),
        jsonString(shotBase64)];
}

- (void) send:(id)sender
{
    NSString *text = [[message textStorage] string];

    if ([[text stringByTrimmingCharactersInSet:
             [NSCharacterSet whitespaceAndNewlineCharacterSet]] length] < 5) {
        NSRunAlertPanel(@"Say a little more", @"A sentence about what happened is what makes "
                        "a report worth sending.", @"OK", nil, nil);
        return;
    }
    [sendButton setEnabled:NO];
    [status setStringValue:@"Sending..."];
    [self postJSON:[self reportJSON]];
}

- (void) postJSON:(NSString *)json
{
    [request setDelegate:nil];
    [request release];
    request = [[GDHTTPRequest requestWithURL:[NSURL URLWithString:feedbackURL()]] retain];
    [request setPostBody:[json dataUsingEncoding:NSUTF8StringEncoding]];
    [request setRequestHeaders:[NSDictionary dictionaryWithObjectsAndKeys:
        @"application/json", @"Content-Type",
        GDFeedbackClientToken, @"X-Feedback-Client", nil]];
    /* Straight to the site: not PowerEmu's business, and it carries a picture
     * that must arrive exactly as it left. */
    [request setUsesSession:YES];
    [request setDelegate:self];
    [request start];
}

/* Kept for the next launch rather than lost. */
- (void) queueJSON:(NSString *)json
{
    NSString *p = queuedPath;
    if (p == nil)
        p = [[GDFeedback outboxDirectory] stringByAppendingPathComponent:
                [NSString stringWithFormat:@"%.0f.json",
                    [NSDate timeIntervalSinceReferenceDate] * 1000]];
    [json writeToFile:p atomically:YES];
}

- (void) httpRequestDidFinish:(GDHTTPRequest *)r
{
    BOOL ok = [r error] == nil;

    if (window == nil) {
        /* A queued report retrying quietly in the background. */
        if (ok && queuedPath != nil)
            [[NSFileManager defaultManager] removeFileAtPath:queuedPath handler:nil];
        [liveReports removeObject:self];
        return;
    }
    if (ok) {
        if (queuedPath != nil)
            [[NSFileManager defaultManager] removeFileAtPath:queuedPath handler:nil];
        [window close];
        NSRunAlertPanel(@"Thank you", @"Your report has been sent.", @"OK", nil, nil);
        return;
    }
    [self queueJSON:[self reportJSON]];
    [sendButton setEnabled:YES];
    [status setStringValue:@"Kept for later; it will go when the network is back."];
    NSRunAlertPanel(@"That could not be sent",
                    @"%@\n\nYour report has been kept and will be sent the next time "
                     "The Garden starts.", @"OK", nil, nil, [r error]);
}

@end
