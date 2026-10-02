/*
 * The Garden (classic) - first milestone: prove a Mac can fetch a Garden page
 * by itself, over plain HTTP, with no helper on the other side.
 *
 * It draws its own log rather than using Retro68's console, which is C++ and
 * so out of reach of a C-only toolchain.  A window and DrawText are enough to
 * read the answer off the screen, which is all this milestone needs.
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
#include <string.h>
#include <stdio.h>

#include <Files.h>
#include <Multiverse.h>   /* FindFolder lives here, not in a Folders.h */

/* Retro68 declares FindFolder but not the constants that go with it. */
#define kOnSystemDisk          ((short) 0x8000)
#define kCreateFolder          true
#define kPreferencesFolderType 'pref'

#include "gdhttp.h"
#include "gddns.h"
#include "gdparse.h"

/* macintoshgarden.org.  A literal address while the resolver is still to be
 * written: this milestone is about the transport.  The Host header is what
 * actually selects the site, and the server is happy with that. */
#define GARDEN_IP   0x3E74E48FUL        /* 62.116.228.143 */
#define GARDEN_HOST "macintoshgarden.org"

#define kGeneva    3
#define MAXLINES  24
#define LINE_H    14

static char      gLines[MAXLINES][96];
static short     gCount;
static WindowPtr gWin;
static short     gLogRef;          /* the transcript, 0 when there is none */
static long      gUpdates;         /* update events actually received      */
static long      gDraws;           /* times drawAll ran                    */

/* Everything the window says is also written beside the application, because
 * the window cannot be read from another machine: screencapture over ssh does
 * not work on these Macs, so a file is the only way a test run reports back. */
static void logOpen(void)
{
    short  vRef = 0;
    long   dirID = 0;
    FSSpec spec;
    OSErr  err;

    /* The Preferences folder, not "the default volume".  Volume 0 is whatever
     * the Finder last set, which was the disk image while the app lived on
     * one; from anywhere else it can land on the startup disk's root, and
     * under Mac OS X that is not writable - so the transcript silently never
     * appeared and the run looked like a crash. */
    if (FindFolder(kOnSystemDisk, kPreferencesFolderType, kCreateFolder,
                   &vRef, &dirID) != noErr) {
        vRef = 0; dirID = 0;
    }
    if (FSMakeFSSpec(vRef, dirID, "\pGardenNet.log", &spec) != noErr &&
        FSMakeFSSpec(vRef, dirID, "\pGardenNet.log", &spec) != fnfErr) {
        /* fall back to wherever we are */
        if (FSMakeFSSpec(0, 0, "\pGardenNet.log", &spec) != noErr) return;
    }
    (void) FSpDelete(&spec);
    err = FSpCreate(&spec, 'ttxt', 'TEXT', 0 /* system script */);
    if (err != noErr && err != dupFNErr) return;
    if (FSpOpenDF(&spec, fsWrPerm, &gLogRef) != noErr)
        gLogRef = 0;
}

static void logWrite(const char *s)
{
    long n;
    if (!gLogRef) return;
    n = (long) strlen(s);
    if (n) (void) FSWrite(gLogRef, &n, s);
    n = 1;
    (void) FSWrite(gLogRef, &n, "\r");      /* classic line ending */
    (void) FlushVol(0L, 0);                 /* survive a hang or a crash */
}

static void logLine(const char *s)
{
    if (gCount >= MAXLINES) {           /* scroll by forgetting the oldest */
        short i;
        for (i = 1; i < MAXLINES; i++)
            memcpy(gLines[i-1], gLines[i], sizeof(gLines[0]));
        gCount = MAXLINES - 1;
    }
    strncpy(gLines[gCount], s, sizeof(gLines[0]) - 1);
    gLines[gCount][sizeof(gLines[0]) - 1] = '\0';
    gCount++;
    logWrite(s);
    if (gWin) {
        SetPort(gWin);
        InvalRect(&gWin->portRect);
    }
}

static void drawAll(void)
{
    short i;
    Rect  r;
    if (!gWin) return;
    gDraws++;
    SetPort(gWin);
    r = gWin->portRect;
    /* Say what every one of these should be rather than trusting what the
     * port was left holding.  EraseRect was plainly working - the window came
     * out white - while DrawText showed nothing, which is what a white
     * foreground or a subtractive text mode looks like. */
    PenNormal();
    ForeColor(blackColor);
    BackColor(whiteColor);
    TextMode(srcOr);
    TextFace(0);
    EraseRect(&r);
    TextFont(kGeneva);
    TextSize(9);
    for (i = 0; i < gCount; i++) {
        MoveTo(8, 16 + i * LINE_H);
        DrawText(gLines[i], 0, (short) strlen(gLines[i]));
    }
}

static void pump(void);

/* Count the dark pixels where the first lines of text should be.  QuickDraw
 * can be asked what it actually put on the screen, which beats waiting for
 * someone to photograph it: zero here means the text is not being drawn, and
 * a few hundred means it is. */
static long inkPixels(void)
{
    long n = 0;
    short x, y;
    if (!gWin) return -1;
    SetPort(gWin);
    for (y = 6; y < 6 + LINE_H * 3; y++)
        for (x = 8; x < 400; x += 2)
            if (GetPixel(x, y)) n++;
    return n;
}

static void ipText(UInt32 ip, char *out)
{
    sprintf(out, "%lu.%lu.%lu.%lu",
            (unsigned long)((ip >> 24) & 0xFF), (unsigned long)((ip >> 16) & 0xFF),
            (unsigned long)((ip >> 8) & 0xFF),  (unsigned long)(ip & 0xFF));
}

/* Show the result for a moment, then quit.  A test run has to let go of the
 * volume it was launched from, or the next build cannot replace it - and an
 * app that never quits means killing all of Classic to get it back. */
static void finishAndQuit(void)
{
    unsigned long until = TickCount() + 60UL * 20UL;   /* twenty seconds */
    char note[96];

    /* Draw once directly, not waiting to be asked.  If the window is blank
     * even after this, the drawing is at fault; if this fixes it, the update
     * events are. */
    drawAll();
    while (TickCount() < until)
        pump();
    sprintf(note, "[window: %ld updates, %ld draws, %ld ink, port %d x %d, lines %d]",
            gUpdates, gDraws, inkPixels(),
            (int)(gWin ? gWin->portRect.right - gWin->portRect.left : -1),
            (int)(gWin ? gWin->portRect.bottom - gWin->portRect.top : -1),
            (int) gCount);
    logWrite(note);
    if (gLogRef) { FSClose(gLogRef); gLogRef = 0; FlushVol(0L, 0); }
    ExitToShell();
}

static void pump(void)
{
    EventRecord ev;
    if (WaitNextEvent(everyEvent, &ev, 1L, (RgnHandle)0)) {
        switch (ev.what) {
        case updateEvt:
            gUpdates++;
            BeginUpdate((WindowPtr) ev.message);
            drawAll();
            EndUpdate((WindowPtr) ev.message);
            break;
        case mouseDown: {
            WindowPtr w;
            short part = FindWindow(ev.where, &w);
            if (part == inDrag)
                DragWindow(w, ev.where, &qd.screenBits.bounds);
            break;
        }
        }
    }
}

int main(void)
{
    Rect bounds;
    char msg[96];
    unsigned long started;
    UInt32 gardenIP = GARDEN_IP;

    InitGraf(&qd.thePort);
    InitFonts();
    InitWindows();
    InitMenus();
    TEInit();
    InitDialogs(0L);
    InitCursor();

    SetRect(&bounds, 20, 44, 500, 44 + MAXLINES * LINE_H + 16);
    gWin = NewWindow(0L, &bounds, "\pThe Garden - transport test", true,
                     documentProc, (WindowPtr)-1L, true, 0);
    SetPort(gWin);

    logOpen();
    logLine("The Garden - classic client, transport test");
    logLine("");

    if (!GDTCP_Ensure()) {
        logLine("No MacTCP: the .IPP driver would not open.");
        logLine("Is TCP/IP configured, and the machine on a network?");
        finishAndQuit();
    }
    logLine("MacTCP is open.");

    /* Resolve, rather than trusting the address baked in above.  The mirrors
     * sit behind Cloudflare, where one address is a poor thing to rely on. */
    {
        static const char *names[2];
        UInt32 resolved[2];
        short  k;
        names[0] = GARDEN_HOST;
        names[1] = "old.mac.gdn";          /* the mirror that serves downloads */

        for (k = 0; k < 2; k++) {
            unsigned long started2;
            resolved[k] = 0;
            GDDNS_Clear();
            if (!GDDNS_Begin(names[k], GDDNS_DEFAULT_SERVER)) {
                sprintf(msg, "DNS %s: could not ask", names[k]);
                logLine(msg);
                GDDNS_Clear();
                continue;
            }
            started2 = TickCount();
            while (GDDNS_State() == GDDNS_BUSY) {
                GDDNS_Idle();
                pump();
                if (TickCount() - started2 > 60UL * 15UL) break;
            }
            if (GDDNS_State() != GDDNS_DONE) {
                /* The first resolver said nothing.  Tidy up after it - an
                 * abandoned query holds the connection - and ask another. */
                logLine("  first resolver silent, trying 8.8.8.8");
                GDDNS_Clear();
                if (GDDNS_Begin(names[k], GDDNS_ALT_SERVER)) {
                    started2 = TickCount();
                    while (GDDNS_State() == GDDNS_BUSY) {
                        GDDNS_Idle();
                        pump();
                        if (TickCount() - started2 > 60UL * 15UL) break;
                    }
                }
            }
            if (GDDNS_State() == GDDNS_DONE) {
                char ip[20];
                resolved[k] = GDDNS_Address();
                ipText(resolved[k], ip);
                sprintf(msg, "DNS %s -> %s  (%ld ticks)", names[k], ip,
                        (long)(TickCount() - started2));
            } else {
                sprintf(msg, "DNS %s failed (%s, OSErr %d)", names[k],
                        GDTCP_LastStep(), (int) GDTCP_LastErr());
            }
            logLine(msg);
        }
        gardenIP = resolved[0] ? resolved[0] : GARDEN_IP;
        if (!resolved[0])
            logLine("Falling back to the built-in address.");
    }
    GDDNS_Clear();

    sprintf(msg, "GET http://%s/apps/all", GARDEN_HOST);
    logLine(msg);

    if (!GDHTTP_Get(GARDEN_HOST, gardenIP, 80, "/apps/all")) {
        sprintf(msg, "Could not start: %s failed, OSErr %d",
                GDTCP_LastStep(), (int) GDTCP_LastErr());
        logLine(msg);
        finishAndQuit();
    }

    started = TickCount();
    while (GDHTTP_State() == GDHTTP_BUSY) {
        GDHTTP_Idle();
        pump();
        if (TickCount() - started > 60UL * 120UL) {    /* two minutes */
            GDHTTP_Abort();
            break;
        }
    }

    if (GDHTTP_State() != GDHTTP_DONE) {
        sprintf(msg, "Failed after %ld bytes (%s, OSErr %d).",
                GDHTTP_Received(), GDTCP_LastStep(), (int) GDTCP_LastErr());
        logLine(msg);
        logLine("Nothing came back, or what did was not HTTP.");
        finishAndQuit();
    }

    sprintf(msg, "HTTP %d   (%ld ticks)", (int) GDHTTP_Status(),
            (long)(TickCount() - started));
    logLine(msg);
    {
        char hdr[64];
        GDHTTP_Header("Server", hdr, sizeof(hdr));
        sprintf(msg, "Server: %s", hdr);
        logLine(msg);
        GDHTTP_Header("Content-Type", hdr, sizeof(hdr));
        sprintf(msg, "Content-Type: %s", hdr);
        logLine(msg);
    }
    sprintf(msg, "Body: %ld bytes", GDHTTP_BodyLen());
    logLine(msg);

    /* Pull the rows out, which is what a list of software actually needs. */
    {
        static GDItemRow rows[GDP_MAX_ITEMS];
        short n, i;
        n = GDParse_Listing(GDHTTP_Body(), GDHTTP_BodyLen(), rows, GDP_MAX_ITEMS);
        sprintf(msg, "Parsed %d rows:", (int) n);
        logLine(msg);
        for (i = 0; i < n; i++) {
            sprintf(msg, "  %-26.26s %-18.18s %s",
                    rows[i].title, rows[i].category, rows[i].year);
            logLine(msg);
        }
    }

    logLine("");
    logLine("Done.");
    finishAndQuit();
    return 0;
}
