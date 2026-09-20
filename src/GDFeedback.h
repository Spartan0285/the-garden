/*
 * GDFeedback - telling whoever makes this what went wrong.
 *
 * A window with a topic, a description, optionally a picture of the Garden's
 * own window, and the few facts about this Mac that make a report actionable
 * (which system, which processor, which version of the app).  Everything that
 * will be sent is shown before it is sent; nothing is collected in the
 * background, and nothing is sent unless Send is pressed.
 *
 * It goes as JSON to one endpoint, which serves every app in this family: the
 * "app" field says which one.  When that cannot be reached - no network, or
 * the site is not up yet - the report is kept in an outbox on disk and offered
 * again at the next launch, so writing one is never wasted.
 */
#import <Cocoa/Cocoa.h>

@class GDHTTPRequest;

@interface GDFeedback : NSObject
{
    NSWindow *window;
    NSPopUpButton *topic;
    NSTextView *message;
    NSTextField *email;
    NSButton *includeShot;
    NSImageView *shotView;
    NSTextField *status;
    NSButton *sendButton;
    NSImage *shot;
    NSString *page;          /* the page they were on */
    GDHTTPRequest *request;
    NSString *reportID;      /* kept across retries, so one report is one issue */
    NSString *queuedPath;    /* the file this report came from, if retrying */
}

/* Opens the window, with a picture of this window ready to attach. */
+ (void) openForWindow:(NSWindow *)w page:(NSString *)pageDescription;

/* At launch: anything in the outbox that could not be sent before. */
+ (void) sendQueuedReports;

/* Where reports wait when the network is not there. */
+ (NSString *) outboxDirectory;

@end
