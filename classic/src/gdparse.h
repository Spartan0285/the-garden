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

/* Fills `out` and returns how many rows were found. */
short GDParse_Listing(const char *html, long len, GDItemRow *out, short maxItems);

#endif /* GDPARSE_H */
