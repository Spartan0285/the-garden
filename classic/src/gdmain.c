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

#include "gdhttp.h"

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

/* Everything the window says is also written beside the application, because
 * the window cannot be read from another machine: screencapture over ssh does
 * not work on these Macs, so a file is the only way a test run reports back. */
static void logOpen(void)
{
    OSErr err;
    (void) FSDelete("\pGardenNet.log", 0);
    err = Create("\pGardenNet.log", 0, 'ttxt', 'TEXT');
    if (err != noErr && err != dupFNErr) return;
    if (FSOpen("\pGardenNet.log", 0, &gLogRef) != noErr)
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
    SetPort(gWin);
    r = gWin->portRect;
    EraseRect(&r);
    TextFont(kGeneva);
    TextSize(9);
    for (i = 0; i < gCount; i++) {
        MoveTo(8, 16 + i * LINE_H);
        DrawText(gLines[i], 0, (short) strlen(gLines[i]));
    }
}

static void pump(void);

/* Show the result for a moment, then quit.  A test run has to let go of the
 * volume it was launched from, or the next build cannot replace it - and an
 * app that never quits means killing all of Classic to get it back. */
static void finishAndQuit(void)
{
    unsigned long until = TickCount() + 60UL * 20UL;   /* twenty seconds */
    while (TickCount() < until)
        pump();
    if (gLogRef) { FSClose(gLogRef); gLogRef = 0; FlushVol(0L, 0); }
    ExitToShell();
}

static void pump(void)
{
    EventRecord ev;
    if (WaitNextEvent(everyEvent, &ev, 1L, (RgnHandle)0)) {
        switch (ev.what) {
        case updateEvt:
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

    sprintf(msg, "GET http://%s/apps/all", GARDEN_HOST);
    logLine(msg);

    if (!GDHTTP_Get(GARDEN_HOST, GARDEN_IP, 80, "/apps/all")) {
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

    /* The landmark the listing parser will key on.  Ten of them means the page
     * arrived whole and is the page we think it is. */
    {
        long i, n = 0, len = GDHTTP_BodyLen();
        const char *b = GDHTTP_Body();
        for (i = 0; b && i + 12 < len; i++)
            if (memcmp(b + i, "game-preview", 12) == 0) n++;
        sprintf(msg, "\"game-preview\" blocks: %ld%s", n,
                n == 10 ? "   (ten, as a listing has)" : "");
        logLine(msg);
    }

    logLine("");
    logLine("Done.");
    finishAndQuit();
    return 0;
}
