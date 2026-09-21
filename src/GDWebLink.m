#import "GDWebLink.h"
#import "GDWebWindow.h"
#import <ApplicationServices/ApplicationServices.h>

NSString *GDPolliwogBundleID = @"org.captainpolliwog.browser";

/* Where to send someone who wants it. */
static NSString * const GDPolliwogPage = @"https://www.cytrusretro.com/";

@implementation GDWebLink

+ (NSString *) polliwogPath
{
    return [[NSWorkspace sharedWorkspace]
               absolutePathForAppBundleWithIdentifier:GDPolliwogBundleID];
}

+ (BOOL) polliwogIsDefaultBrowser
{
    CFStringRef handler = LSCopyDefaultHandlerForURLScheme(CFSTR("http"));
    BOOL isPolliwog;

    if (handler == NULL)
        return NO;
    isPolliwog = [(NSString *)handler caseInsensitiveCompare:GDPolliwogBundleID] == NSOrderedSame;
    CFRelease(handler);
    return isPolliwog;
}

+ (NSString *) defaultBrowserName
{
    CFStringRef handler = LSCopyDefaultHandlerForURLScheme(CFSTR("http"));
    NSString *path, *name = nil;

    if (handler == NULL)
        return @"none";
    path = [[NSWorkspace sharedWorkspace]
               absolutePathForAppBundleWithIdentifier:(NSString *)handler];
    if ([path length])
        name = [[path lastPathComponent] stringByDeletingPathExtension];
    else
        name = [(NSString *)handler copy], name = [name autorelease];
    CFRelease(handler);
    return [name length] ? name : @"unknown";
}

+ (void) openInPolliwog:(NSURL *)url
{
    [[NSWorkspace sharedWorkspace]
                     openURLs:[NSArray arrayWithObject:url]
        withAppBundleIdentifier:GDPolliwogBundleID
                      options:NSWorkspaceLaunchDefault
   additionalEventParamDescriptor:nil
                launchIdentifiers:NULL];
}

+ (void) openURL:(NSURL *)url
{
    NSString *host = [url host] ?: [url absoluteString];
    int answer;

    /* Already their browser: nothing to ask about. */
    if ([self polliwogIsDefaultBrowser]) {
        [[NSWorkspace sharedWorkspace] openURL:url];
        return;
    }

    if ([self polliwogPath] != nil) {
        answer = NSRunAlertPanel(
            [NSString stringWithFormat:@"Open %@", host],
            @"Captain Polliwog can reach modern sites on this Mac; the browser this "
             "system came with usually cannot, because it stops at an old kind of "
             "secure connection.",
            @"Open in Captain Polliwog", @"Open in My Browser", @"Cancel");
        if (answer == NSAlertDefaultReturn)
            [self openInPolliwog:url];
        else if (answer == NSAlertAlternateReturn)
            [[NSWorkspace sharedWorkspace] openURL:url];
        return;
    }

    answer = NSRunAlertPanel(
        [NSString stringWithFormat:@"Open %@", host],
        @"The browser this Mac came with stops at an old kind of secure connection, "
         "so most sites - including this one - will refuse it.\n\nCaptain Polliwog is "
         "a browser for Mac OS X 10.4 and 10.5 that can reach them.",
        @"Get Captain Polliwog", @"Open in My Browser", @"Cancel");
    if (answer == NSAlertDefaultReturn) {
        /* Shown in this app's own web view, which has the modern networking:
         * sending them to a browser that cannot load the page would be a
         * strange way to recommend a browser. */
        [GDWebWindow openURL:[NSURL URLWithString:GDPolliwogPage] title:@"Cytrus Retro"];
    } else if (answer == NSAlertAlternateReturn) {
        [[NSWorkspace sharedWorkspace] openURL:url];
    }
}

@end
