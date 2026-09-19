/*
 * gdtool - exercises the Garden client from the command line.
 *   gdtool list <apps|games> [selector] [page]
 *   gdtool item </apps/slug>
 *   gdtool search <keywords>
 *   gdtool get <url> <file>
 */
#import <Foundation/Foundation.h>
#import "GDHTTP.h"
#import "GDGarden.h"

static NSData *fetch(NSURL *u, NSData *post)
{
    GDHTTPRequest *r = [GDHTTPRequest requestWithURL:u];
    double t0 = CFAbsoluteTimeGetCurrent();
    if (post)
        [r setPostBody:post];
    if (![r startSynchronous]) {
        fprintf(stderr, "%s: %s\n", [[u absoluteString] UTF8String], [[r error] UTF8String]);
        return nil;
    }
    fprintf(stderr, "%s -> %ld, %lu bytes, %.2fs\n", [[u absoluteString] UTF8String],
            [r statusCode], (unsigned long)[[r data] length], CFAbsoluteTimeGetCurrent() - t0);
    return [r data];
}

static void printListing(GDListing *L)
{
    int i;
    printf("page %d of %d, %d items\n", [L page] + 1, [L pageCount], (int)[[L items] count]);
    for (i = 0; i < (int)[[L items] count]; i++) {
        GDItem *it = [[L items] objectAtIndex:i];
        printf("%-40s %-6s %-28s %.1f(%d) %s\n", [[it path] UTF8String],
               [[it year] ?: @"" UTF8String], [[it category] ?: @"" UTF8String],
               [it rating], [it votes], [[it title] UTF8String]);
    }
}

int main(int argc, const char **argv)
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSString *cmd = argc > 1 ? [NSString stringWithUTF8String:argv[1]] : @"list";
    NSData *d;

    if ([cmd isEqualToString:@"list"]) {
        NSString *sec = argc > 2 ? [NSString stringWithUTF8String:argv[2]] : @"apps";
        NSString *sel = argc > 3 ? [NSString stringWithUTF8String:argv[3]] : @"all";
        int page = argc > 4 ? atoi(argv[4]) : 0;
        d = fetch([GDGarden listURLForSection:sec selector:sel page:page], nil);
        if (d)
            printListing([GDGarden parseListing:d]);
    } else if ([cmd isEqualToString:@"item"] && argc > 2) {
        NSString *path = [NSString stringWithUTF8String:argv[2]];
        GDItemDetail *D;
        int i;
        d = fetch([GDGarden itemURL:path], nil);
        D = d ? [GDGarden parseItem:d path:path] : nil;
        if (D) {
            printf("title: %s\nyear: %s\ncategory: %s\nauthor: %s\npublisher: %s\n"
                   "rating: %.1f (%d)\narch: %s\nthumb: %s\n",
                   [[D title] UTF8String], [[D year] ?: @"" UTF8String],
                   [[D category] ?: @"" UTF8String], [[D author] ?: @"" UTF8String],
                   [[D publisher] ?: @"" UTF8String], [D rating], [D votes],
                   [[D architecture] ?: @"" UTF8String], [[D thumbURL] ?: @"" UTF8String]);
            for (i = 0; i < (int)[[D screenshots] count]; i++)
                printf("shot: %s\n", [[[D screenshots] objectAtIndex:i] UTF8String]);
            for (i = 0; i < (int)[[D files] count]; i++) {
                GDFile *f = [[D files] objectAtIndex:i];
                printf("file %d: %s | %s (%.0f) | %s | md5 %s | for: %s\n", [f index],
                       [[f name] UTF8String], [[f sizeText] ?: @"" UTF8String], [f sizeBytes],
                       [[f date] ?: @"" UTF8String], [[f md5] ?: @"" UTF8String],
                       [[f systems] ?: @"" UTF8String]);
                printf("   mirrors: %s\n", [[[f mirrors] componentsJoinedByString:@" "] UTF8String]);
            }
            printf("--- description\n%s\n", [[D descriptionText] UTF8String]);
            printf("author path: %s  category path: %s\n", [[D authorPath] ?: @"" UTF8String],
                   [[D categoryPath] ?: @"" UTF8String]);
            for (i = 0; i < (int)[[D seeAlso] count]; i++)
                printf("see also: %s %s\n", [[[[D seeAlso] objectAtIndex:i] path] UTF8String],
                       [[[[D seeAlso] objectAtIndex:i] title] UTF8String]);
            for (i = 0; i < (int)[[D reviews] count] && i < 3; i++) {
                NSDictionary *rv = [[D reviews] objectAtIndex:i];
                printf("review by %s on %s: %.80s\n", [[rv objectForKey:@"author"] UTF8String],
                       [[rv objectForKey:@"date"] UTF8String], [[rv objectForKey:@"text"] UTF8String]);
            }
            printf("reviews: %u\n", (unsigned)[[D reviews] count]);
        }
    } else if ([cmd isEqualToString:@"search"] && argc > 2) {
        NSString *keys = [NSString stringWithUTF8String:argv[2]];
        NSString *token, *body;
        d = fetch([GDGarden listURLForSection:@"games" selector:@"all" page:0], nil);
        token = d ? [GDGarden parseFormToken:d] : nil;
        printf("token %s\n", [token ?: @"(none)" UTF8String]);
        body = [NSString stringWithFormat:@"keys=%@&form_token=%@&form_id=search_form&op=Search",
                GDFormEncode(keys), token ?: @""];
        d = fetch([GDGarden absoluteURL:@"/search/node"],
                  [body dataUsingEncoding:NSUTF8StringEncoding]);
        if (d)
            printListing([GDGarden parseSearch:d]);
    } else if ([cmd isEqualToString:@"feed"]) {
        NSArray *news;
        int i;
        d = fetch([GDGarden feedURL], nil);
        news = d ? [GDGarden parseFeed:d] : nil;
        for (i = 0; i < (int)[news count]; i++) {
            GDNewsItem *n = [news objectAtIndex:i];
            printf("%-45s %-24s %s | %s\n", [[n path] UTF8String], [[[n published] description] UTF8String],
                   [[n title] UTF8String], [[n thumbURL] ?: @"" UTF8String]);
        }
    } else if ([cmd isEqualToString:@"get"] && argc > 3) {
        GDHTTPRequest *r = [GDHTTPRequest requestWithURL:
                               [NSURL URLWithString:[NSString stringWithUTF8String:argv[2]]]];
        double t0 = CFAbsoluteTimeGetCurrent();
        [r setDestinationPath:[NSString stringWithUTF8String:argv[3]]];
        if ([r startSynchronous])
            printf("ok %ld in %.1fs (resumed from %lld) -> %s\n", [r statusCode],
                   CFAbsoluteTimeGetCurrent() - t0, [r resumedFrom], [[r effectiveURL] UTF8String]);
        else
            printf("failed: %s\n", [[r error] UTF8String]);
    } else {
        fprintf(stderr, "usage: gdtool list|item|search|get ...\n");
        return 2;
    }
    [pool release];
    return 0;
}
