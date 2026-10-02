/*
 * The Garden - browse the Macintosh Garden from Mac OS 9.
 *
 * It fetches and reads the site itself: no helper on another machine, which
 * the System 7 client needs because that era's TLS is long refused.  Mac OS 9
 * is no better at TLS - but it does not need to be, because the Garden serves
 * the same pages over plain HTTP.
 *
 * Lists are drawn by hand rather than through the List Manager, which keeps
 * the layout ours and the redraws cheap.
 */
#include <Quickdraw.h>
#include <Fonts.h>
#include <Windows.h>
#include <Events.h>
#include <Menus.h>
#include <TextEdit.h>
#include <Dialogs.h>
#include <OSUtils.h>
#include <ToolUtils.h>
#include <Files.h>
#include <Multiverse.h>
#include <string.h>
#include <stdio.h>

#include "gdhttp.h"
#include "gddns.h"
#include "gdparse.h"
#include "gdcompat.h"

#define kOnSystemDisk          ((short) 0x8000)
#define kCreateFolder          true
#define kPreferencesFolderType 'pref'

#define kGeneva 3
#define WIN_W   540
#define WIN_H   392
#define TOP_H    44          /* the bar across the top                 */
#define ROW_H    30
#define FOOT_H   26
#define LIST_ROWS 10

/* What the window is showing. */
enum { ST_LIST = 0, ST_ITEM, ST_BUSY, ST_FAILED };

static WindowPtr  gWin;
static short      gState = ST_BUSY;
static char       gStatus[80] = "Starting up...";
static short      gLogRef;

/* where we are: the tabs across the top, as the OS X version has them */
enum { SEC_FEATURED = 0, SEC_APPS, SEC_GAMES, SEC_SEARCH, SEC_COUNT };
static short      gSectionIdx = SEC_APPS;
static char       gQuery[48];
static Boolean    gTyping;
static char       gSection[8] = "apps";
static short      gPage;
static GDItemRow  gRows[GDP_MAX_ITEMS];
static short      gRowCount;
static short      gSelected = -1;
static GDItemInfo gItem;
static char       gItemPath[72];

/* what is in flight */
enum { REQ_NONE = 0, REQ_LIST, REQ_ITEM, REQ_FEED, REQ_SEARCH };
static short      gPending;
static UInt32     gGardenIP;

/* ------------------------------------------------------------ transcript */

static void logOpen(void)
{
    short  vRef = 0;
    long   dirID = 0;
    FSSpec spec;
    /* Preferences, not "the default volume": that is whatever the Finder last
     * set, and a run's own account of itself should be findable. */
    if (FindFolder(kOnSystemDisk, kPreferencesFolderType, kCreateFolder,
                   &vRef, &dirID) != noErr) { vRef = 0; dirID = 0; }
    (void) FSMakeFSSpec(vRef, dirID, "\pGardenNet.log", &spec);
    (void) FSpDelete(&spec);
    if (FSpCreate(&spec, 'ttxt', 'TEXT', 0) != noErr) return;
    if (FSpOpenDF(&spec, fsWrPerm, &gLogRef) != noErr) gLogRef = 0;
}

static void logLine(const char *s)
{
    long n;
    if (!gLogRef) return;
    n = (long) strlen(s);
    if (n) (void) FSWrite(gLogRef, &n, s);
    n = 1; (void) FSWrite(gLogRef, &n, "\r");
    (void) FlushVol(0L, 0);
}

static void setStatus(const char *s)
{
    strncpy(gStatus, s, sizeof(gStatus) - 1);
    gStatus[sizeof(gStatus) - 1] = '\0';
    logLine(s);
    if (gWin) { SetPort(gWin); InvalRect(&gWin->portRect); }
}

/* ---------------------------------------------------------------- drawing */

static void drawStr(short x, short y, const char *s, short face)
{
    TextFace(face);
    MoveTo(x, y);
    DrawText((Ptr) s, 0, (short) strlen(s));
    TextFace(0);
}

/* The clickable words along the top and bottom.  Keeping their rectangles
 * here means drawing and hit-testing cannot disagree. */
static Rect rTabs[SEC_COUNT], rPrevBtn, rNextBtn, rBackBtn;
static const char *kTabName[SEC_COUNT] = { "Featured", "Apps", "Games", "Search" };

static void drawChrome(void)
{
    char  buf[96];
    short i, x = 12;

    SetRect(&rBackBtn, 12, 10, 78, 28);
    for (i = 0; i < SEC_COUNT; i++) {
        short w = (short)(TextWidth((Ptr) kTabName[i], 0,
                                    (short) strlen(kTabName[i])) + 18);
        SetRect(&rTabs[i], x, 10, (short)(x + w), 28);
        x += w + 4;
    }
    SetRect(&rPrevBtn,  12, WIN_H - FOOT_H + 2,  80, WIN_H - 4);
    SetRect(&rNextBtn,  88, WIN_H - FOOT_H + 2, 156, WIN_H - 4);

    if (gState == ST_ITEM) {
        FrameRect(&rBackBtn);
        drawStr(rBackBtn.left + 8, rBackBtn.bottom - 5, "< Back", 0);
    } else {
        for (i = 0; i < SEC_COUNT; i++) {
            if (i == gSectionIdx) {
                Rect f = rTabs[i];
                PaintRect(&f);
                ForeColor(whiteColor);
                drawStr(rTabs[i].left + 9, rTabs[i].bottom - 5, kTabName[i], bold);
                ForeColor(blackColor);
            } else {
                FrameRect(&rTabs[i]);
                drawStr(rTabs[i].left + 9, rTabs[i].bottom - 5, kTabName[i], 0);
            }
        }
        /* the search field doubles as the page indicator */
        if (gSectionIdx == SEC_SEARCH) {
            Rect f;
            SetRect(&f, rTabs[SEC_COUNT-1].right + 10, 10, WIN_W - 12, 28);
            FrameRect(&f);
            sprintf(buf, "%s%s", gQuery, gTyping ? "_" : "");
            drawStr(f.left + 6, f.bottom - 5, buf[0] ? buf : "type, then Return", 0);
        } else if (gSectionIdx != SEC_FEATURED) {
            sprintf(buf, "page %d", (int)(gPage + 1));
            drawStr(rTabs[SEC_COUNT-1].right + 14, rTabs[0].bottom - 5, buf, 0);
        }
        if (gSectionIdx == SEC_APPS || gSectionIdx == SEC_GAMES) {
            FrameRect(&rPrevBtn);
            drawStr(rPrevBtn.left + 8, rPrevBtn.bottom - 6, "< Prev", 0);
            FrameRect(&rNextBtn);
            drawStr(rNextBtn.left + 8, rNextBtn.bottom - 6, "Next >", 0);
        }
    }

    TextSize(9);
    drawStr(170, WIN_H - 10, gStatus, 0);
    TextSize(10);
    MoveTo(0, TOP_H - 6); LineTo(WIN_W, TOP_H - 6);
    MoveTo(0, WIN_H - FOOT_H - 2); LineTo(WIN_W, WIN_H - FOOT_H - 2);
}

static void drawList(void)
{
    short i;
    for (i = 0; i < gRowCount && i < LIST_ROWS; i++) {
        short top = TOP_H + i * ROW_H;
        char  sub[96];
        if (i == gSelected) {
            Rect sel;
            SetRect(&sel, 4, top, WIN_W - 4, top + ROW_H - 2);
            InvertRect(&sel);
        }
        drawStr(12, top + 13, gRows[i].title, bold);
        sprintf(sub, "%s%s%s", gRows[i].category,
                gRows[i].year[0] ? "  -  " : "", gRows[i].year);
        TextSize(9);
        drawStr(12, top + 25, sub, 0);
        TextSize(10);
    }
    if (gRowCount == 0 && gState == ST_LIST)
        drawStr(12, TOP_H + 20, "Nothing here.", 0);
}

/* Lay a paragraph out across the width available, breaking on spaces. */
static short drawWrapped(const char *s, short x, short y, short width, short maxLines)
{
    char line[120];
    short lines = 0;
    long  i = 0, len = (long) strlen(s);

    while (i < len && lines < maxLines) {
        long take = 0, lastSpace = -1, o = 0;
        while (i + take < len && o < (long) sizeof(line) - 1) {
            char c = s[i + take];
            if (c == ' ') lastSpace = take;
            line[o++] = c;
            line[o] = '\0';
            if (TextWidth((Ptr) line, 0, (short) o) > width) {
                if (lastSpace > 0) { o = lastSpace; take = lastSpace + 1; }
                else take++;
                break;
            }
            take++;
        }
        line[o] = '\0';
        drawStr(x, y + lines * 13, line, 0);
        lines++;
        i += take;
        while (i < len && s[i] == ' ') i++;
    }
    return (short)(y + lines * 13);
}

static void drawItem(void)
{
    short y = TOP_H + 6, i;
    char  buf[120];

    TextSize(12);
    drawStr(12, y + 4, gItem.title, bold);
    TextSize(10);
    y += 22;

    if (gItem.blurb[0])
        y = drawWrapped(gItem.blurb, 12, y + 6, WIN_W - 24, 5) + 8;

    if (gItem.arch[0]) {
        TextSize(9);
        sprintf(buf, "Architecture: %s        This Mac: %s",
                gItem.arch, GDCompat_HostText());
        drawStr(12, y, buf, 0);
        TextSize(10);
        y += 15;
    }

    sprintf(buf, "%d download%s:", (int) gItem.fileCount,
            gItem.fileCount == 1 ? "" : "s");
    drawStr(12, y, buf, bold);
    y += 15;
    for (i = 0; i < gItem.fileCount && y < WIN_H - FOOT_H - 14; i++) {
        GDCVerdict v = GDCompat_Verdict(gItem.files[i].systems, gItem.arch,
                                        gItem.files[i].name);
        TextSize(9);
        sprintf(buf, "%.36s   %s", gItem.files[i].name, gItem.files[i].size);
        drawStr(20, y, buf, 0);
        /* The badge, right-aligned, saying what the OS X version's pills say:
         * this is about the processor and the system, not about whether this
         * Mac is quick enough. */
        {
            const char *lab = GDCompat_Label(v);
            short w = (short) TextWidth((Ptr) lab, 0, (short) strlen(lab));
            drawStr((short)(WIN_W - 18 - w), y, lab, v == GDC_NATIVE ? bold : 0);
        }
        TextSize(10);
        y += 13;
    }
}

static void drawAll(void)
{
    Rect r;
    if (!gWin) return;
    SetPort(gWin);
    r = gWin->portRect;
    /* State every attribute rather than trusting what the port was left
     * holding: EraseRect once worked while DrawText showed nothing. */
    PenNormal();
    ForeColor(blackColor);
    BackColor(whiteColor);
    TextMode(srcOr);
    TextFace(0);
    EraseRect(&r);
    TextFont(kGeneva);
    TextSize(10);

    drawChrome();
    if (gState == ST_ITEM)        drawItem();
    else if (gState == ST_LIST)   drawList();
    else                          drawStr(12, TOP_H + 24, gStatus, 0);
}

/* ------------------------------------------------------------- networking */

static void beginFetch(const char *host, const char *path, short what)
{
    char msg[120];
    sprintf(msg, "Fetching %.60s", path);
    setStatus(msg);
    gState   = ST_BUSY;
    gPending = what;
    GDHTTP_Clear();
    if (!GDHTTP_Get(host, gGardenIP, 80, path)) {
        setStatus("Could not start the request.");
        gState = ST_FAILED;
        gPending = REQ_NONE;
    }
}

static void loadList(void)
{
    char path[96];
    gSelected = -1;
    switch (gSectionIdx) {
    case SEC_FEATURED:
        beginFetch("macintoshgarden.org", "/rss.xml", REQ_FEED);
        return;
    case SEC_SEARCH:
        if (!gQuery[0]) { gState = ST_LIST; gRowCount = 0;
                          setStatus("Type something, then press Return."); return; }
        sprintf(path, "/search/node/%.40s", gQuery);
        beginFetch("macintoshgarden.org", path, REQ_SEARCH);
        return;
    default:
        strcpy(gSection, gSectionIdx == SEC_GAMES ? "games" : "apps");
        if (gPage > 0) sprintf(path, "/%s/all?page=%d", gSection, (int) gPage);
        else           sprintf(path, "/%s/all", gSection);
        beginFetch("macintoshgarden.org", path, REQ_LIST);
    }
}

static void loadItem(const char *itemPath)
{
    strncpy(gItemPath, itemPath, sizeof(gItemPath) - 1);
    beginFetch("macintoshgarden.org", gItemPath, REQ_ITEM);
}

static void fetchFinished(void)
{
    char msg[80];
    if (GDHTTP_State() != GDHTTP_DONE || GDHTTP_Status() != 200) {
        sprintf(msg, "Failed (HTTP %d)", (int) GDHTTP_Status());
        setStatus(msg);
        gState = ST_FAILED;
        gPending = REQ_NONE;
        return;
    }
    if (gPending == REQ_LIST || gPending == REQ_FEED || gPending == REQ_SEARCH) {
        if (gPending == REQ_FEED)
            gRowCount = GDParse_Feed(GDHTTP_Body(), GDHTTP_BodyLen(),
                                     gRows, LIST_ROWS);
        else if (gPending == REQ_SEARCH)
            gRowCount = GDParse_Search(GDHTTP_Body(), GDHTTP_BodyLen(),
                                       gRows, LIST_ROWS);
        else
            gRowCount = GDParse_Listing(GDHTTP_Body(), GDHTTP_BodyLen(),
                                        gRows, LIST_ROWS);
        sprintf(msg, "%d items", (int) gRowCount);
        setStatus(msg);
        gState = ST_LIST;
    } else {
        if (GDParse_Item(GDHTTP_Body(), GDHTTP_BodyLen(), &gItem)) {
            sprintf(msg, "%d downloads", (int) gItem.fileCount);
            setStatus(msg);
            gState = ST_ITEM;
        } else {
            setStatus("Could not read that page.");
            gState = ST_FAILED;
        }
    }
    gPending = REQ_NONE;
}

/* ----------------------------------------------------------------- events */

static void click(Point where)
{
    if (gState == ST_BUSY) return;

    if (gState == ST_ITEM) {
        if (PtInRect(where, &rBackBtn)) { gState = ST_LIST; setStatus(""); }
        return;
    }
    {
        short i;
        for (i = 0; i < SEC_COUNT; i++) {
            if (PtInRect(where, &rTabs[i])) {
                gSectionIdx = i;
                gPage = 0;
                gTyping = (i == SEC_SEARCH);
                if (i == SEC_SEARCH && !gQuery[0]) {
                    gRowCount = 0; gState = ST_LIST;
                    setStatus("Type something, then press Return.");
                } else {
                    loadList();
                }
                return;
            }
        }
    }
    if (PtInRect(where, &rNextBtn)) { gPage++; loadList(); return; }
    if (PtInRect(where, &rPrevBtn)) {
        if (gPage > 0) { gPage--; loadList(); }
        return;
    }
    if (where.v >= TOP_H && where.v < TOP_H + LIST_ROWS * ROW_H) {
        short i = (short)((where.v - TOP_H) / ROW_H);
        if (i < gRowCount) {
            gSelected = i;
            loadItem(gRows[i].path);
        }
    }
}

static Boolean gQuit;

static void pump(void)
{
    EventRecord ev;
    if (!WaitNextEvent(everyEvent, &ev, 2L, (RgnHandle)0)) return;
    switch (ev.what) {
    case updateEvt:
        BeginUpdate((WindowPtr) ev.message);
        drawAll();
        EndUpdate((WindowPtr) ev.message);
        break;
    case mouseDown: {
        WindowPtr w;
        short part = FindWindow(ev.where, &w);
        if (part == inDrag)      DragWindow(w, ev.where, &qd.screenBits.bounds);
        else if (part == inGoAway && TrackGoAway(w, ev.where)) gQuit = true;
        else if (part == inContent) {
            Point p = ev.where;
            SetPort(gWin);
            GlobalToLocal(&p);
            click(p);
            SetPort(gWin);
            InvalRect(&gWin->portRect);
        }
        break;
    }
    case keyDown: {
        char c = (char)(ev.message & charCodeMask);
        if (c == 'q' && (ev.modifiers & cmdKey)) { gQuit = true; break; }
        if (gTyping && gState != ST_BUSY) {
            long n = (long) strlen(gQuery);
            if (c == '\r' || c == 3) {              /* Return or Enter */
                gTyping = false;
                if (gQuery[0]) loadList();
            } else if (c == 8) {                     /* Backspace */
                if (n > 0) gQuery[n-1] = '\0';
            } else if (c >= ' ' && n < (long) sizeof(gQuery) - 1) {
                gQuery[n] = c; gQuery[n+1] = '\0';
            }
            SetPort(gWin); InvalRect(&gWin->portRect);
        }
        break;
    }
    }
}

int main(void)
{
    Rect bounds;

    InitGraf(&qd.thePort); InitFonts(); InitWindows(); InitMenus();
    TEInit(); InitDialogs(0L); InitCursor();

    SetRect(&bounds, 0, 0, WIN_W, WIN_H);
    OffsetRect(&bounds, (qd.screenBits.bounds.right - WIN_W) / 2,
                        (qd.screenBits.bounds.bottom - WIN_H) / 2 - 10);
    gWin = NewWindow(0L, &bounds, "\pThe Garden", true, documentProc,
                     (WindowPtr)-1L, true, 0);
    SetPort(gWin);
    logOpen();
    logLine("The Garden, on Mac OS 9");

    if (!GDTCP_Ensure()) {
        setStatus("No MacTCP: is TCP/IP set up?");
        gState = ST_FAILED;
    } else {
        unsigned long t0;
        setStatus("Looking up macintoshgarden.org...");
        GDDNS_Clear();
        gGardenIP = 0;
        if (GDDNS_Begin("macintoshgarden.org", GDDNS_DEFAULT_SERVER)) {
            t0 = TickCount();
            while (GDDNS_State() == GDDNS_BUSY) {
                GDDNS_Idle();
                pump();
                if (TickCount() - t0 > 60UL * 15UL) break;
            }
            if (GDDNS_State() == GDDNS_DONE) gGardenIP = GDDNS_Address();
        }
        if (!gGardenIP) {
            GDDNS_Clear();
            setStatus("First resolver silent; trying another...");
            if (GDDNS_Begin("macintoshgarden.org", GDDNS_ALT_SERVER)) {
                t0 = TickCount();
                while (GDDNS_State() == GDDNS_BUSY) {
                    GDDNS_Idle();
                    pump();
                    if (TickCount() - t0 > 60UL * 15UL) break;
                }
                if (GDDNS_State() == GDDNS_DONE) gGardenIP = GDDNS_Address();
            }
        }
        GDDNS_Clear();
        if (gGardenIP) {
            GDCompat_Init();
            logLine(GDCompat_HostText());
            gSectionIdx = SEC_FEATURED;
            loadList();
        } else {
            setStatus("Could not resolve macintoshgarden.org.");
            gState = ST_FAILED;
        }
    }

    while (!gQuit) {
        if (gPending != REQ_NONE) {
            GDHTTP_Idle();
            if (GDHTTP_State() != GDHTTP_BUSY) fetchFinished();
        }
        pump();
    }
    if (gLogRef) { FSClose(gLogRef); gLogRef = 0; FlushVol(0L, 0); }
    return 0;
}
