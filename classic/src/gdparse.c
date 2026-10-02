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

/* ---------------------------------------------------------------- item page */

/* Copy text, dropping tags and squeezing runs of space, up to `stop`. */
static void copyTextUntil(const char *h, long len, long at, const char *stop,
                          char *out, long outMax)
{
    long o = 0, stopLen = (long) strlen(stop);
    Boolean inTag = false;
    out[0] = '\0';
    if (at < 0) return;
    while (at < len && o < outMax - 1) {
        if (!inTag && at + stopLen <= len && memcmp(h + at, stop, stopLen) == 0)
            break;
        if (h[at] == '<') { inTag = true;  at++; continue; }
        if (h[at] == '>') { inTag = false; at++; continue; }
        if (inTag) { at++; continue; }
        if (h[at] == '\n' || h[at] == '\r' || h[at] == '\t' || h[at] == ' ') {
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

/* Split "//host/path..." into its two parts, dropping any query string: the
 * Garden's own www link carries an expiring token, the mirrors do not. */
static void splitURL(const char *url, char *host, long hostMax,
                     char *path, long pathMax)
{
    long i = 0, o = 0;
    host[0] = path[0] = '\0';
    if (url[0] == '/' && url[1] == '/') i = 2;
    while (url[i] && url[i] != '/' && o < hostMax - 1) host[o++] = url[i++];
    host[o] = '\0';
    o = 0;
    while (url[i] && url[i] != '?' && o < pathMax - 1) path[o++] = url[i++];
    path[o] = '\0';
}

Boolean GDParse_Item(const char *html, long len, GDItemInfo *out)
{
    long at = 0;
    short n = 0;

    memset(out, 0, sizeof(*out));

    at = findAfter(html, len, 0, "<h1>");
    copyUntil(html, len, at, '<', out->title, sizeof(out->title));

    /* The blurb is the first paragraph of the description. */
    at = findAfter(html, len, 0, "class=\"descr\"");
    at = findAfter(html, len, at, "<p>");
    copyTextUntil(html, len, at, "</p>", out->blurb, sizeof(out->blurb));

    /* "Architecture: 68k\tPPC" is a bare text node, not a table field. */
    at = findAfter(html, len, 0, "Architecture:");
    copyTextUntil(html, len, at, "<", out->arch, sizeof(out->arch));

    /* One "note download" block per file. */
    at = 0;
    while (n < GDP_MAX_FILES) {
        long start = findAfter(html, len, at, "class=\"note download\"");
        long next, limit, p, best = -1;
        char host[64], path[128];
        if (start < 0) break;
        next  = findAfter(html, len, start, "class=\"note download\"");
        limit = (next < 0) ? len : next;

        /* Prefer old.mac.gdn: it serves these over plain HTTP, where the
         * www link expires and the .us mirror answers 403. */
        p = start;
        while ((p = findAfter(html, limit, p, "href=\"")) > 0) {
            char url[200];
            copyUntil(html, limit, p, '"', url, sizeof(url));
            if (strstr(url, "arch_md5.php")) continue;
            splitURL(url, host, sizeof(host), path, sizeof(path));
            if (host[0] == '\0') continue;
            if (best < 0) best = 1;                      /* something usable */
            strncpy(out->files[n].host, host, sizeof(out->files[n].host) - 1);
            strncpy(out->files[n].path, path, sizeof(out->files[n].path) - 1);
            if (strstr(host, "old.mac.gdn")) break;      /* the one we want   */
        }
        if (best < 0) { at = start; continue; }

        /* <small>NAME <i>(SIZE</i>)</small> */
        p = findAfter(html, limit, start, "<br/><small>");
        if (p < 0) p = findAfter(html, limit, start, "<br /><small>");
        copyUntil(html, limit, p, '<', out->files[n].name, sizeof(out->files[n].name));
        {
            long q = findAfter(html, limit, p, "<i>(");
            copyUntil(html, limit, q, '<', out->files[n].size, sizeof(out->files[n].size));
        }
        /* "For <systems>" trails the MD5, up to the end of the block. */
        {
            long q = findAfter(html, limit, p, "</small></br>");
            if (q < 0) q = findAfter(html, limit, p, "</small></br >");
            q = findAfter(html, limit, q, "For");
            copyTextUntil(html, limit, q, "</div>",
                          out->files[n].systems, sizeof(out->files[n].systems));
        }
        if (out->files[n].name[0]) n++;
        at = start;
    }
    out->fileCount = n;
    return out->title[0] != '\0';
}

/* ------------------------------------------------------- search and feed */

/* "http://macintoshgarden.org/apps/slug" -> "/apps/slug" */
static void trimHost(char *url)
{
    char *p;
    if (strncmp(url, "http://", 7) == 0) p = url + 7;
    else if (strncmp(url, "https://", 8) == 0) p = url + 8;
    else return;
    p = strchr(p, '/');
    if (!p) { url[0] = '\0'; return; }
    memmove(url, p, strlen(p) + 1);
}

short GDParse_Search(const char *html, long len, GDItemRow *out, short maxItems)
{
    short n = 0;
    long  at = 0;
    while (n < maxItems) {
        long p = findAfter(html, len, at, "<dt class=\"title\"");
        if (p < 0) break;
        p = findAfter(html, len, p, "href=\"");
        if (p < 0) break;
        copyUntil(html, len, p, '"', out[n].path, sizeof(out[n].path));
        trimHost(out[n].path);
        p = findAfter(html, len, p, ">");
        copyUntil(html, len, p, '<', out[n].title, sizeof(out[n].title));
        out[n].category[0] = out[n].year[0] = '\0';
        /* The site searches its forum too; only software has a page we can
         * read, so the rest is dropped rather than offered and then failing. */
        if (out[n].path[0] && out[n].title[0] &&
            (strncmp(out[n].path, "/apps/", 6) == 0 ||
             strncmp(out[n].path, "/games/", 7) == 0))
            n++;
        at = p;
    }
    return n;
}

short GDParse_Feed(const char *xml, long len, GDItemRow *out, short maxItems)
{
    short n = 0;
    long  at = 0;
    while (n < maxItems) {
        long p = findAfter(xml, len, at, "<item>");
        long q;
        if (p < 0) break;
        q = findAfter(xml, len, p, "<title>");
        copyUntil(xml, len, q, '<', out[n].title, sizeof(out[n].title));
        q = findAfter(xml, len, p, "<link>");
        copyUntil(xml, len, q, '<', out[n].path, sizeof(out[n].path));
        trimHost(out[n].path);
        strcpy(out[n].category, "New & Noteworthy");
        out[n].year[0] = '\0';
        if (out[n].path[0] && out[n].title[0]) n++;
        at = p;
    }
    return n;
}
