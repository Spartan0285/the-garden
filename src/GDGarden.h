/*
 * GDGarden - Macintosh Garden site model and HTML parsing (libxml2).
 *
 * The Garden is a Drupal 6 site with no API, so everything here comes from
 * its HTML.  The landmarks used are stable across the site: listing rows are
 * <div class="game-preview">, item pages carry the same div plus
 * <div class="note download"> blocks, fields sit in two-column tables with
 * <strong>Label:</strong>.
 */
#import <Foundation/Foundation.h>

#define GD_SITE @"https://macintoshgarden.org"

typedef enum {
    GDSectionAll = 0,
    GDSectionGames,
    GDSectionApps
} GDSection;

/* One row of a listing / search result, and the basis of an item page. */
@interface GDItem : NSObject
{
@public
    NSString *section;      /* "games" | "apps" */
    NSString *slug;
    NSString *title;
    NSString *year;
    NSString *category;
    NSString *categoryPath; /* e.g. "/apps/internet" */
    NSString *author;
    NSString *authorPath;   /* "/author/microsoft" */
    NSString *blurb;
    NSString *thumbURL;
    float rating;           /* 0..5, 0 = unrated */
    int votes;
}
- (NSString *) section;
- (NSString *) slug;
- (NSString *) path;        /* "/apps/slug" */
- (NSString *) title;
- (NSString *) year;
- (NSString *) category;
- (NSString *) author;
- (NSString *) authorPath;
- (NSString *) categoryPath;
- (NSString *) blurb;
- (NSString *) thumbURL;
- (float) rating;
- (int) votes;
@end

@interface GDFile : NSObject
{
@public
    NSString *name;
    NSString *sizeText;     /* "4.37 MB" */
    double sizeBytes;
    NSString *date;         /* "2009-04-24" */
    NSString *md5;
    NSString *systems;      /* "System 7.0 - 7.6 - Mac OS 9", "Mac OS X" */
    NSString *note;         /* the description's "DL #N:" line, if it has one */
    NSArray *mirrors;       /* absolute URLs, best first */
    int index;              /* the page's own DL number, less one */
}
- (NSString *) name;
- (NSString *) sizeText;
- (double) sizeBytes;
- (NSString *) date;
- (NSString *) md5;
- (NSString *) systems;
- (NSString *) note;
- (NSArray *) mirrors;
- (int) index;
@end

@interface GDItemDetail : GDItem
{
@public
    NSString *publisher;
    NSString *architecture; /* "PPC", "68k PPC", "PPC x86", ... */
    NSString *descriptionText;
    NSArray *screenshots;   /* full-size URLs */
    NSArray *files;         /* GDFile */
    NSArray *reviews;       /* {author, date, text}, newest first */
    NSArray *seeAlso;       /* GDItem (title + path) linked from the description */
}
- (NSString *) publisher;
- (NSString *) architecture;
- (NSString *) descriptionText;
- (NSArray *) screenshots;
- (NSArray *) files;
- (NSArray *) reviews;
- (NSArray *) seeAlso;
@end

@interface GDListing : NSObject
{
@public
    NSArray *items;
    int page;               /* 0-based */
    int pageCount;
}
- (NSArray *) items;
- (int) page;
- (int) pageCount;
@end

/* One entry of the site's rss.xml (newest additions). */
@interface GDNewsItem : GDItem
{
@public
    NSDate *published;
}
- (NSDate *) published;
@end

@interface GDGarden : NSObject
/* URL builders */
+ (NSURL *) listURLForSection:(NSString *)section selector:(NSString *)sel page:(int)page;
+ (NSURL *) itemURL:(NSString *)path;
+ (NSURL *) searchResultsURL:(NSString *)keys page:(int)page;
+ (NSURL *) absoluteURL:(NSString *)href;

/* Parsers; all take the raw page bytes. */
+ (GDListing *) parseListing:(NSData *)html;
+ (GDListing *) parseSearch:(NSData *)html;
+ (GDItemDetail *) parseItem:(NSData *)html path:(NSString *)path;
+ (NSArray *) parseCategories:(NSData *)html section:(NSString *)section; /* {name, path} */
+ (NSString *) parseFormToken:(NSData *)html;
+ (NSArray *) parseFeed:(NSData *)rss;             /* GDNewsItem */
+ (NSURL *) feedURL;
@end
