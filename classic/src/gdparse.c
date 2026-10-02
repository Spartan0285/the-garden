#include "gdparse.h"
#include <string.h>

/* Find `needle` in [from, len); returns the index just past it, or -1. */
static long findAfter(const char *h, long len, long from, const char *needle)
{
    long n = (long) strlen(needle), i;
    if (from < 0) return -1;
    for (i = from; i + n <= len; i++)
        if (memcmp(h + i, needle, n) == 0)
            return i + n;
    return -1;
}

/* The handful of entities the Garden's titles actually contain.  Anything
 * else is left as it stands, which is better than mangling it. */
static void decodeEntities(char *s)
{
    char *r = s, *w = s;
    while (*r) {
        if (*r == '&') {
            if      (!strncmp(r, "&amp;",  5)) { *w++ = '&';  r += 5; continue; }
            else if (!strncmp(r, "&lt;",   4)) { *w++ = '<';  r += 4; continue; }
            else if (!strncmp(r, "&gt;",   4)) { *w++ = '>';  r += 4; continue; }
            else if (!strncmp(r, "&quot;", 6)) { *w++ = '"';  r += 6; continue; }
            else if (!strncmp(r, "&#039;", 6)) { *w++ = '\''; r += 6; continue; }
            else if (!strncmp(r, "&nbsp;", 6)) { *w++ = ' ';  r += 6; continue; }
        }
        *w++ = *r++;
    }
    *w = '\0';
}

/* Copy from `at` up to `stop`, trimming the whitespace the site's markup is
 * generous with. */
static void copyUntil(const char *h, long len, long at, char stop,
                      char *out, long outMax)
{
    long o = 0;
    out[0] = '\0';
    if (at < 0) return;
    while (at < len && h[at] != stop && o < outMax - 1) {
        if ((h[at] == '\n' || h[at] == '\t' || h[at] == '\r') ) {
            if (o > 0 && out[o-1] != ' ') out[o++] = ' ';
            at++;
            continue;
        }
        out[o++] = h[at++];
    }
    while (o > 0 && out[o-1] == ' ') o--;
    out[o] = '\0';
    decodeEntities(out);
}

/* A labelled field: <strong>Label:</strong> ... <a ...>Value</a> */
static void fieldAfter(const char *h, long len, long from, long limit,
                       const char *label, char *out, long outMax)
{
    char tag[64];
    long at;
    out[0] = '\0';
    if ((long) strlen(label) > (long) sizeof(tag) - 20) return;
    strcpy(tag, "<strong>");
    strcat(tag, label);
    strcat(tag, ":</strong>");
    at = findAfter(h, limit, from, tag);
    if (at < 0) return;
    at = findAfter(h, limit, at, "<a ");       /* into the value's link */
    if (at < 0) return;
    at = findAfter(h, limit, at, ">");
    copyUntil(h, limit, at, '<', out, outMax);
}

short GDParse_Listing(const char *html, long len, GDItemRow *out, short maxItems)
{
    short n = 0;
    long  at = 0;

    while (n < maxItems) {
        long start = findAfter(html, len, at, "class=\"game-preview\"");
        long next, limit, p;
        if (start < 0) break;

        /* This row ends where the next begins, so a missing field cannot be
         * filled in from the row below. */
        next  = findAfter(html, len, start, "class=\"game-preview\"");
        limit = (next < 0) ? len : next;

        p = findAfter(html, limit, start, "<h2><a href=\"");
        if (p < 0) { at = start; continue; }
        copyUntil(html, limit, p, '"', out[n].path, sizeof(out[n].path));
        p = findAfter(html, limit, p, ">");
        copyUntil(html, limit, p, '<', out[n].title, sizeof(out[n].title));

        fieldAfter(html, len, start, limit, "Category",
                   out[n].category, sizeof(out[n].category));
        fieldAfter(html, len, start, limit, "Year released",
                   out[n].year, sizeof(out[n].year));

        if (out[n].path[0] && out[n].title[0]) n++;
        at = start;
    }
    return n;
}
