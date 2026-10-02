/*
 * gdparse - pull the rows out of a Macintosh Garden listing page.
 *
 * Not a general HTML parser, and deliberately not: the site's landmarks are
 * stable and few, so this looks for exactly those and ignores everything
 * else.  A real parser would be several times the size and no more correct
 * about this one site.
 *
 * What a listing row looks like, and all this needs to know:
 *     <div class="game-preview">
 *       <h2><a href="/apps/slug">Title</a></h2>
 *       ... <strong>Category:</strong></td><td>...<a ...>Value</a>
 *           <strong>Year released:</strong></td><td>...<a ...>Value</a>
 */
#ifndef GDPARSE_H
#define GDPARSE_H

#include <MacTypes.h>

#define GDP_MAX_ITEMS 20

typedef struct {
    char path[72];        /* "/apps/slug"  */
    char title[80];
    char category[48];
    char year[12];
} GDItemRow;

#define GDP_MAX_FILES 12

typedef struct {
    char name[72];        /* "TheUnarchiver3.11.1.zip" */
    char size[16];        /* "5.27 MB"                 */
    char host[64];        /* mirror host, no scheme    */
    char path[128];       /* path on that host         */
    char systems[56];     /* "System 6.x - Mac OS 9"   */
} GDFileRow;

typedef struct {
    char      title[80];
    char      arch[40];       /* "68k PPC", from the Architecture line */
    char      blurb[420];     /* the description, tags stripped */
    short     fileCount;
    GDFileRow files[GDP_MAX_FILES];
} GDItemInfo;

/* Fills `out` and returns how many rows were found. */
short GDParse_Listing(const char *html, long len, GDItemRow *out, short maxItems);

/* An item page: its title, what it says about itself, and what can be had.
 * The mirror chosen is the one that serves plain HTTP without complaint -
 * old.mac.gdn - falling back to whatever else the page offers. */
Boolean GDParse_Item(const char *html, long len, GDItemInfo *out);

/* Search results: <dt class="title"><a href="...">Title</a>.  The hrefs come
 * back absolute here, unlike a listing's, so the host is trimmed off. */
short GDParse_Search(const char *html, long len, GDItemRow *out, short maxItems);

/* The front page's feed: <item><title>..</title><link>..</link>. */
short GDParse_Feed(const char *xml, long len, GDItemRow *out, short maxItems);

#endif /* GDPARSE_H */
