#import "GDGarden.h"
#import "GDHTTP.h"
#include <libxml/HTMLparser.h>
#include <libxml/xpath.h>
#include <libxml/xpathInternals.h>

/* ------------------------------------------------------------ model classes */

@implementation GDItem
- (void) dealloc
{
    [section release]; [slug release]; [title release]; [year release];
    [category release]; [categoryPath release]; [author release];
    [blurb release]; [thumbURL release];
    [super dealloc];
}
- (NSString *) section { return section; }
- (NSString *) slug { return slug; }
- (NSString *) path { return [NSString stringWithFormat:@"/%@/%@", section, slug]; }
- (NSString *) title { return title; }
- (NSString *) year { return year; }
- (NSString *) category { return category; }
- (NSString *) author { return author; }
- (NSString *) blurb { return blurb; }
- (NSString *) thumbURL { return thumbURL; }
- (float) rating { return rating; }
- (int) votes { return votes; }
- (NSString *) description { return [NSString stringWithFormat:@"<%@ %@>", [self path], title]; }
@end

@implementation GDFile
- (void) dealloc
{
    [name release]; [sizeText release]; [date release]; [md5 release];
    [systems release]; [mirrors release];
    [super dealloc];
}
- (NSString *) name { return name; }
- (NSString *) sizeText { return sizeText; }
- (double) sizeBytes { return sizeBytes; }
- (NSString *) date { return date; }
- (NSString *) md5 { return md5; }
- (NSString *) systems { return systems; }
- (NSArray *) mirrors { return mirrors; }
- (int) index { return index; }
@end

@implementation GDItemDetail
- (void) dealloc
{
    [publisher release]; [architecture release]; [descriptionText release];
    [screenshots release]; [files release];
    [super dealloc];
}
- (NSString *) publisher { return publisher; }
- (NSString *) architecture { return architecture; }
- (NSString *) descriptionText { return descriptionText; }
- (NSArray *) screenshots { return screenshots; }
- (NSArray *) files { return files; }
@end

@implementation GDListing
- (void) dealloc { [items release]; [super dealloc]; }
- (NSArray *) items { return items; }
- (int) page { return page; }
- (int) pageCount { return pageCount; }
@end

/* ----------------------------------------------------------- libxml helpers */

static htmlDocPtr parseHTML(NSData *d)
{
    /* NOERROR | NOWARNING | NONET */
    int opts = (1 << 5) | (1 << 6) | (1 << 11);
    if ([d length] == 0)
        return NULL;
    return htmlReadMemory([d bytes], (int)[d length], "https://macintoshgarden.org/",
                          "UTF-8", opts);
}

/* Evaluate expr relative to node (NULL: the document).  Caller frees. */
static xmlXPathObjectPtr xp(xmlXPathContextPtr ctx, xmlNodePtr node, const char *expr)
{
    xmlXPathObjectPtr o;
    ctx->node = node ? node : xmlDocGetRootElement(ctx->doc);
    o = xmlXPathEvalExpression((const xmlChar *)expr, ctx);
    if (o && (o->type != XPATH_NODESET || o->nodesetval == NULL || o->nodesetval->nodeNr == 0)) {
        xmlXPathFreeObject(o);
        return NULL;
    }
    return o;
}

static int xpCount(xmlXPathObjectPtr o) { return o ? o->nodesetval->nodeNr : 0; }
static xmlNodePtr xpNode(xmlXPathObjectPtr o, int i) { return o->nodesetval->nodeTab[i]; }

static NSString *collapse(NSString *s)
{
    NSMutableString *m = [NSMutableString string];
    NSScanner *sc = [NSScanner scannerWithString:s];
    NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    NSString *word;
    [sc setCharactersToBeSkipped:ws];
    while ([sc scanUpToCharactersFromSet:ws intoString:&word]) {
        if ([m length])
            [m appendString:@" "];
        [m appendString:word];
    }
    return m;
}

/* Text of a node with runs of whitespace collapsed. */
static NSString *nodeText(xmlNodePtr n)
{
    xmlChar *c;
    NSString *s;
    if (n == NULL)
        return @"";
    c = xmlNodeGetContent(n);
    s = c ? [NSString stringWithUTF8String:(const char *)c] : @"";
    if (c)
        xmlFree(c);
    return collapse(s ? s : @"");
}

/* Text that keeps <br> and block boundaries as line breaks. */
static void appendRich(NSMutableString *out, xmlNodePtr n)
{
    for (; n; n = n->next) {
        if (n->type == XML_TEXT_NODE && n->content) {
            NSString *t = [NSString stringWithUTF8String:(const char *)n->content];
            if (t) {
                t = collapse(t);
                if ([t length]) {
                    if ([out length] && ![out hasSuffix:@"\n"] && ![out hasSuffix:@" "])
                        [out appendString:@" "];
                    [out appendString:t];
                }
            }
        } else if (n->type == XML_ELEMENT_NODE) {
            if (xmlStrcasecmp(n->name, (const xmlChar *)"br") == 0)
                [out appendString:@"\n"];
            else
                appendRich(out, n->children);
        }
    }
}

static NSString *attr(xmlNodePtr n, const char *name)
{
    xmlChar *v;
    NSString *s;
    if (n == NULL)
        return nil;
    v = xmlGetProp(n, (const xmlChar *)name);
    if (v == NULL)
        return nil;
    s = [NSString stringWithUTF8String:(const char *)v];
    xmlFree(v);
    return s;
}

static NSString *firstText(xmlXPathContextPtr ctx, xmlNodePtr base, const char *expr)
{
    xmlXPathObjectPtr o = xp(ctx, base, expr);
    NSString *s = o ? nodeText(xpNode(o, 0)) : nil;
    if (o)
        xmlXPathFreeObject(o);
    return s;
}

static NSString *firstAttr(xmlXPathContextPtr ctx, xmlNodePtr base, const char *expr, const char *a)
{
    xmlXPathObjectPtr o = xp(ctx, base, expr);
    NSString *s = o ? attr(xpNode(o, 0), a) : nil;
    if (o)
        xmlXPathFreeObject(o);
    return s;
}

/* "/apps/slug" or "https://macintoshgarden.org/apps/slug" -> (section, slug) */
static BOOL splitItemPath(NSString *href, NSString **section, NSString **slug)
{
    NSRange r;
    NSArray *parts;
    if (href == nil)
        return NO;
    r = [href rangeOfString:@"macintoshgarden.org"];
    if (r.location != NSNotFound)
        href = [href substringFromIndex:NSMaxRange(r)];
    parts = [href componentsSeparatedByString:@"/"];
    if ([parts count] != 3 || [[parts objectAtIndex:0] length] != 0)
        return NO;
    if (![[parts objectAtIndex:1] isEqualToString:@"apps"] &&
        ![[parts objectAtIndex:1] isEqualToString:@"games"])
        return NO;
    *section = [parts objectAtIndex:1];
    *slug = [parts objectAtIndex:2];
    return [*slug length] > 0;
}

/* The two-column <strong>Label:</strong> tables used on listings and items. */
static void readFields(xmlXPathContextPtr ctx, xmlNodePtr base, GDItem *it,
                       NSString **publisher)
{
    xmlXPathObjectPtr rows = xp(ctx, base, ".//div[@class='descr']//tr");
    int i;
    for (i = 0; i < xpCount(rows); i++) {
        xmlNodePtr tr = xpNode(rows, i);
        NSString *label = firstText(ctx, tr, "./td[1]/strong");
        NSString *value = firstText(ctx, tr, "./td[2]");
        if (label == nil)
            continue;
        if ([label hasPrefix:@"Category"]) {
            [it->category release];
            it->category = [(firstText(ctx, tr, "./td[2]//a") ?: value) retain];
            [it->categoryPath release];
            it->categoryPath = [firstAttr(ctx, tr, "./td[2]//a", "href") retain];
        } else if ([label hasPrefix:@"Year"]) {
            [it->year release];
            it->year = [value retain];
        } else if ([label hasPrefix:@"Author"]) {
            [it->author release];
            it->author = [(firstText(ctx, tr, "./td[2]//a") ?: value) retain];
        } else if ([label hasPrefix:@"Publisher"] && publisher) {
            *publisher = firstText(ctx, tr, "./td[2]//a") ?: value;
        } else if ([label hasPrefix:@"Rating"]) {
            NSString *avg = firstText(ctx, tr, ".//span[@class='average-rating']/span");
            NSString *n = firstText(ctx, tr, ".//span[@class='total-votes']/span");
            it->rating = avg ? [avg floatValue] : 0;
            it->votes = n ? [n intValue] : 0;
        }
    }
    if (rows)
        xmlXPathFreeObject(rows);
}

static int parsePageCount(xmlXPathContextPtr ctx)
{
    /* "Go to last page" -> ?page=N (0-based) */
    NSString *href = firstAttr(ctx, NULL, "//li[contains(@class,'pager-last')]/a", "href");
    NSRange r;
    if (href == nil) {
        /* No "last" link: last numbered page, or a single page. */
        xmlXPathObjectPtr o = xp(ctx, NULL, "//ul[contains(@class,'pager')]//li/a");
        int i, best = 0;
        for (i = 0; i < xpCount(o); i++) {
            NSString *h = attr(xpNode(o, i), "href");
            r = h ? [h rangeOfString:@"page="] : NSMakeRange(NSNotFound, 0);
            if (r.location != NSNotFound) {
                NSString *v = [h substringFromIndex:NSMaxRange(r)];
                NSRange comma = [v rangeOfString:@"%2C"];
                if (comma.location == NSNotFound)
                    comma = [v rangeOfString:@","];
                if (comma.location != NSNotFound)
                    v = [v substringFromIndex:NSMaxRange(comma)];
                if ([v intValue] > best)
                    best = [v intValue];
            }
        }
        if (o)
            xmlXPathFreeObject(o);
        return best + 1;
    }
    r = [href rangeOfString:@"page="];
    if (r.location == NSNotFound)
        return 1;
    href = [href substringFromIndex:NSMaxRange(r)];
    r = [href rangeOfString:@"%2C"];
    if (r.location == NSNotFound)
        r = [href rangeOfString:@","];
    if (r.location != NSNotFound)
        href = [href substringFromIndex:NSMaxRange(r)];
    return [href intValue] + 1;
}

static int currentPage(xmlXPathContextPtr ctx)
{
    NSString *t = firstText(ctx, NULL, "//li[contains(@class,'pager-current')]");
    return t ? MAX([t intValue] - 1, 0) : 0;
}

/* ------------------------------------------------------------------ GDGarden */

@implementation GDGarden

+ (NSURL *) absoluteURL:(NSString *)href
{
    if (href == nil)
        return nil;
    if ([href hasPrefix:@"//"])
        href = [@"https:" stringByAppendingString:href];
    else if ([href hasPrefix:@"/"])
        href = [GD_SITE stringByAppendingString:href];
    /* Hrefs arrive mostly escaped; escape stray spaces and the like. */
    return [NSURL URLWithString:href] ?:
        [NSURL URLWithString:[href stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding]];
}

+ (NSURL *) listURLForSection:(NSString *)section selector:(NSString *)sel page:(int)page
{
    /* sel: nil/"all" (featured), a letter or "0".."9", a category path
     * ("/apps/internet"), or "year:1998". */
    NSString *path;
    if ([sel hasPrefix:@"/"])
        path = sel;
    else if ([sel hasPrefix:@"year:"])
        path = [NSString stringWithFormat:@"/year/%@", [sel substringFromIndex:5]];
    else
        path = [NSString stringWithFormat:@"/%@/%@", section, [sel length] ? sel : @"all"];
    if (page > 0)
        path = [path stringByAppendingFormat:@"?page=%d", page];
    return [self absoluteURL:path];
}

+ (NSURL *) itemURL:(NSString *)path
{
    return [self absoluteURL:path];
}

+ (NSURL *) searchResultsURL:(NSString *)keys page:(int)page
{
    NSString *p = [NSString stringWithFormat:@"/search/node/%@", GDFormEncode(keys)];
    if (page > 0)
        p = [p stringByAppendingFormat:@"?page=%d", page];
    return [self absoluteURL:p];
}

+ (GDListing *) parseListing:(NSData *)html
{
    htmlDocPtr doc = parseHTML(html);
    xmlXPathContextPtr ctx;
    xmlXPathObjectPtr rows;
    NSMutableArray *items = [NSMutableArray array];
    GDListing *L = [[[GDListing alloc] init] autorelease];
    int i;

    if (doc == NULL)
        return nil;
    ctx = xmlXPathNewContext(doc);
    rows = xp(ctx, NULL, "//div[@class='game-preview']");
    for (i = 0; i < xpCount(rows); i++) {
        xmlNodePtr row = xpNode(rows, i);
        GDItem *it = [[[GDItem alloc] init] autorelease];
        NSString *href = firstAttr(ctx, row, "./h2/a", "href");
        NSString *sec, *slug;
        if (!splitItemPath(href, &sec, &slug))
            continue;
        it->section = [sec retain];
        it->slug = [slug retain];
        it->title = [firstText(ctx, row, "./h2/a") retain];
        it->thumbURL = [[[self absoluteURL:firstAttr(ctx, row, ".//div[@class='images']//img", "src")]
                            absoluteString] retain];
        it->blurb = [firstText(ctx, row, "./div[@class='descr']/p") retain];
        readFields(ctx, row, it, NULL);
        [items addObject:it];
    }
    if (rows)
        xmlXPathFreeObject(rows);
    L->items = [items retain];
    L->pageCount = parsePageCount(ctx);
    L->page = currentPage(ctx);
    xmlXPathFreeContext(ctx);
    xmlFreeDoc(doc);
    return L;
}

+ (GDListing *) parseSearch:(NSData *)html
{
    htmlDocPtr doc = parseHTML(html);
    xmlXPathContextPtr ctx;
    xmlXPathObjectPtr dts;
    NSMutableArray *items = [NSMutableArray array];
    GDListing *L = [[[GDListing alloc] init] autorelease];
    int i;

    if (doc == NULL)
        return nil;
    ctx = xmlXPathNewContext(doc);
    dts = xp(ctx, NULL, "//dl[contains(@class,'search-results')]/dt[@class='title']");
    for (i = 0; i < xpCount(dts); i++) {
        xmlNodePtr dt = xpNode(dts, i);
        GDItem *it = [[[GDItem alloc] init] autorelease];
        NSString *sec, *slug;
        if (!splitItemPath(firstAttr(ctx, dt, "./a", "href"), &sec, &slug))
            continue;   /* forum posts, pages, ... */
        it->section = [sec retain];
        it->slug = [slug retain];
        it->title = [firstText(ctx, dt, "./a") retain];
        it->blurb = [firstText(ctx, dt, "following-sibling::dd[1]/p[@class='search-snippet']") retain];
        [items addObject:it];
    }
    if (dts)
        xmlXPathFreeObject(dts);
    L->items = [items retain];
    L->pageCount = parsePageCount(ctx);
    L->page = currentPage(ctx);
    xmlXPathFreeContext(ctx);
    xmlFreeDoc(doc);
    return L;
}

static NSArray *fileMirrors(xmlXPathContextPtr ctx, xmlNodePtr note)
{
    /* [www] is the site's signed link (expires=...), then static mirrors.
     * The page is always fetched right before downloading, so the signed
     * link is fresh; mirrors are the fallback. */
    xmlXPathObjectPtr links = xp(ctx, note, "./strong//a");
    NSMutableArray *m = [NSMutableArray array];
    int i;
    for (i = 0; i < xpCount(links); i++) {
        NSString *h = attr(xpNode(links, i), "href");
        NSURL *u;
        if (h == nil || [h rangeOfString:@"arch_md5"].location != NSNotFound)
            continue;
        u = [GDGarden absoluteURL:h];
        if (u)
            [m addObject:[u absoluteString]];
    }
    if (links)
        xmlXPathFreeObject(links);
    return m;
}

static double parseSize(NSString *s)
{
    double v = [s doubleValue];
    NSString *u = [s uppercaseString];
    if ([u rangeOfString:@"GB"].location != NSNotFound) return v * 1024 * 1024 * 1024;
    if ([u rangeOfString:@"MB"].location != NSNotFound) return v * 1024 * 1024;
    if ([u rangeOfString:@"KB"].location != NSNotFound) return v * 1024;
    return v;
}

+ (GDItemDetail *) parseItem:(NSData *)html path:(NSString *)path
{
    htmlDocPtr doc = parseHTML(html);
    xmlXPathContextPtr ctx;
    xmlXPathObjectPtr o;
    xmlNodePtr preview = NULL;
    GDItemDetail *D;
    NSString *sec = nil, *slug = nil, *pub = nil, *s;
    NSMutableArray *shots = [NSMutableArray array];
    NSMutableArray *files = [NSMutableArray array];
    NSMutableString *desc = [NSMutableString string];
    int i;

    if (doc == NULL)
        return nil;
    ctx = xmlXPathNewContext(doc);
    D = [[[GDItemDetail alloc] init] autorelease];
    if (splitItemPath(path, &sec, &slug)) {
        D->section = [sec retain];
        D->slug = [slug retain];
    }
    D->title = [firstText(ctx, NULL, "//h1") retain];

    o = xp(ctx, NULL, "//h1/following::div[@class='game-preview'][1]");
    if (o) {
        preview = xpNode(o, 0);
        xmlXPathFreeObject(o);
    }
    if (preview) {
        readFields(ctx, preview, D, &pub);
        D->publisher = [pub retain];

        o = xp(ctx, preview, "./div[@class='images']//a[contains(@class,'thickbox')]");
        for (i = 0; i < xpCount(o); i++) {
            NSURL *u = [GDGarden absoluteURL:attr(xpNode(o, i), "href")];
            if (u && ![shots containsObject:[u absoluteString]])
                [shots addObject:[u absoluteString]];
        }
        if (o)
            xmlXPathFreeObject(o);
        D->thumbURL = [[[self absoluteURL:firstAttr(ctx, preview, "./div[@class='images']//img", "src")]
                           absoluteString] retain];

        o = xp(ctx, preview, ".//div[@class='note download']");
        for (i = 0; i < xpCount(o); i++) {
            xmlNodePtr note = xpNode(o, i);
            GDFile *f = [[[GDFile alloc] init] autorelease];
            NSString *line = firstText(ctx, note, "./small[i]");
            NSString *all = nodeText(note);
            NSRange r;

            f->index = i;
            f->mirrors = [fileMirrors(ctx, note) retain];
            if (line) {
                r = [line rangeOfString:@"(" options:NSBackwardsSearch];
                if (r.location != NSNotFound) {
                    f->name = [[line substringToIndex:r.location] retain];
                    f->sizeText = [[[line substringFromIndex:NSMaxRange(r)]
                                       stringByTrimmingCharactersInSet:
                                           [NSCharacterSet characterSetWithCharactersInString:@"() "]] retain];
                } else {
                    f->name = [line retain];
                }
                [f->name autorelease];
                f->name = [[f->name stringByTrimmingCharactersInSet:
                               [NSCharacterSet whitespaceCharacterSet]] retain];
                f->sizeBytes = parseSize(f->sizeText);
            }
            s = firstText(ctx, note, ".//div[contains(@class,'numeral')]/small");
            if (s) {
                r = [s rangeOfString:@", "];
                f->date = [(r.location != NSNotFound ? [s substringFromIndex:NSMaxRange(r)] : s) retain];
            }
            f->md5 = [firstText(ctx, note, ".//a[contains(@href,'arch_md5')]") retain];
            r = [all rangeOfString:@" For " options:NSBackwardsSearch];
            if (r.location != NSNotFound)
                f->systems = [[all substringFromIndex:NSMaxRange(r)] retain];
            if ([f->mirrors count])
                [files addObject:f];
        }
        if (o)
            xmlXPathFreeObject(o);
    }

    /* Description: the <p>s after the preview block, before the comments. */
    o = xp(ctx, NULL, "//h1/following::div[@class='game-preview'][1]/following-sibling::p");
    for (i = 0; i < xpCount(o); i++) {
        NSMutableString *para = [NSMutableString string];
        appendRich(para, xpNode(o, i)->children);
        if ([para length]) {
            if ([desc length])
                [desc appendString:@"\n\n"];
            [desc appendString:para];
        }
    }
    if (o)
        xmlXPathFreeObject(o);
    if ([desc length] == 0) {
        s = firstAttr(ctx, NULL, "//meta[@name='description']", "content");
        if (s)
            [desc appendString:s];
    }
    D->descriptionText = [desc retain];

    o = xp(ctx, NULL, "//text()[contains(.,'Architecture:')]");
    if (o) {
        s = nodeText(xpNode(o, 0));
        D->architecture = [[[s substringFromIndex:NSMaxRange([s rangeOfString:@"Architecture:"])]
                               stringByTrimmingCharactersInSet:
                                   [NSCharacterSet whitespaceAndNewlineCharacterSet]] retain];
        xmlXPathFreeObject(o);
    }
    D->screenshots = [shots retain];
    D->files = [files retain];

    xmlXPathFreeContext(ctx);
    xmlFreeDoc(doc);
    return D;
}

+ (NSArray *) parseCategories:(NSData *)html section:(NSString *)section
{
    htmlDocPtr doc = parseHTML(html);
    xmlXPathContextPtr ctx;
    xmlXPathObjectPtr o;
    NSMutableArray *out = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    NSString *prefix = [NSString stringWithFormat:@"/%@/", section];
    int i;
    if (doc == NULL)
        return out;
    ctx = xmlXPathNewContext(doc);
    o = xp(ctx, NULL, "//tr[td/strong[starts-with(.,'Category')]]/td[2]//a[@rel='tag']");
    for (i = 0; i < xpCount(o); i++) {
        NSString *h = attr(xpNode(o, i), "href");
        if ([h hasPrefix:prefix] && ![seen containsObject:h]) {
            [seen addObject:h];
            [out addObject:[NSDictionary dictionaryWithObjectsAndKeys:
                               nodeText(xpNode(o, i)), @"name", h, @"path", nil]];
        }
    }
    if (o)
        xmlXPathFreeObject(o);
    xmlXPathFreeContext(ctx);
    xmlFreeDoc(doc);
    return out;
}

+ (NSString *) parseFormToken:(NSData *)html
{
    htmlDocPtr doc = parseHTML(html);
    xmlXPathContextPtr ctx;
    NSString *t;
    if (doc == NULL)
        return nil;
    ctx = xmlXPathNewContext(doc);
    t = firstAttr(ctx, NULL, "//form[contains(@class,'search-form')]//input[@name='form_token']", "value");
    if (t == nil)
        t = firstAttr(ctx, NULL, "//input[@name='form_token']", "value");
    xmlXPathFreeContext(ctx);
    xmlFreeDoc(doc);
    return t;
}

@end
