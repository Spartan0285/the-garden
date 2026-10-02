#include "gdtcp.h"
#include <Devices.h>
#include <MacMemory.h>
#include <Events.h>
#include <string.h>

/* ---- MacTCP parameter blocks ---------------------------------------------
 * Declared here because Retro68 has no MacTCP headers.  The shapes are the
 * ones the System 7 Garden client has been using against a real stack.
 */
/* Classic Mac OS parameter blocks are laid out for a 68k, two-byte aligned.
 * On PowerPC GCC aligns pointers to four, which pads ioNamePtr from offset 18
 * to 20 and shifts every field after it - the driver then reads nonsense and
 * answers -21, badUnitErr.  The 68k build never noticed, its natural alignment
 * being two already.  Everything the Device Manager sees must be packed. */
#pragma pack(push, 2)

typedef UInt32          ip_addr;
typedef unsigned short  tcp_port;
typedef unsigned long   StreamPtr;
typedef ProcPtr         TCPIOCompletionUPP;
typedef ProcPtr         TCPNotifyUPP;

enum { TCPCreate = 30, TCPActiveOpen = 32, TCPSend = 34, TCPRcv = 37,
       TCPClose = 38, TCPRelease = 42 };

/* The far end hanging up is how a reply ends, so these are success here. */
enum { connectionClosing = -23005, connectionTerminated = -23008,
       commandTimeout = -23006 };

struct TCPCreatePB {
    Ptr           rcvBuff;
    unsigned long rcvBuffLen;
    TCPNotifyUPP  notifyProc;
    Ptr           userDataPtr;
};

struct TCPOpenPB {
    SInt8    ulpTimeoutValue;
    SInt8    ulpTimeoutAction;
    SInt8    validityFlags;
    SInt8    commandTimeoutValue;
    ip_addr  remoteHost;
    tcp_port remotePort;
    ip_addr  localHost;
    tcp_port localPort;
    SInt8    tosFlags;
    SInt8    precedence;
    Boolean  dontFrag;
    SInt8    timeToLive;
    SInt8    security;
    SInt8    optionCnt;
    SInt8    options[40];
    Ptr      userDataPtr;
};

typedef struct wdsEntry { unsigned short length; Ptr ptr; } wdsEntry;

struct TCPSendPB {
    SInt8   ulpTimeoutValue;
    SInt8   ulpTimeoutAction;
    SInt8   validityFlags;
    Boolean pushFlag;
    Boolean urgentFlag;
    SInt8   filler;
    Ptr     wdsPtr;
    Ptr     userDataPtr;
};

struct TCPReceivePB {
    SInt8          commandTimeoutValue;
    Boolean        markFlag;
    Boolean        urgentFlag;
    SInt8          filler;
    Ptr            rcvBuff;
    unsigned short rcvBuffLen;
    Ptr            rdsPtr;
    unsigned short rdsLength;
    unsigned short secondTimeStamp;
    Ptr            userDataPtr;
};

struct TCPClosePB {
    SInt8 ulpTimeoutValue;
    SInt8 ulpTimeoutAction;
    SInt8 validityFlags;
    SInt8 filler;
    Ptr   userDataPtr;
};

struct TCPiopb {
    SInt8              fill12[12];
    TCPIOCompletionUPP ioCompletion;
    short              ioResult;
    Ptr                ioNamePtr;
    short              ioVRefNum;
    short              ioCRefNum;
    short              csCode;
    StreamPtr          tcpStream;
    union {
        struct TCPCreatePB  create;
        struct TCPOpenPB    open;
        struct TCPSendPB    send;
        struct TCPReceivePB receive;
        struct TCPClosePB   close;
        char                reserved[128];
    } csParam;
};
typedef struct TCPiopb TCPiopb;

#pragma pack(pop)

/* ---- tuning (60 ticks to the second) ------------------------------------- */
#define RCVBUF_SIZE   16384   /* MacTCP's own stream buffer                   */
#define SCRATCH_SIZE   4096   /* handed to one TCPRcv                         */
#define RESP_INITIAL  32768   /* a Garden page is about 30k                   */
#define OPEN_TIMEOUT    900   /* ~15 s: this is the open internet, not a host
                               * alias two microseconds away                  */
#define IO_TIMEOUT     3600   /* ~60 s without a byte arriving                */
#define REQ_MAX         512

enum { CST_IDLE = 0, CST_OPENING, CST_SENDING, CST_RECEIVING,
       CST_DONE, CST_ERROR };

struct GDTCPConn {
    short         cst;
    short         pubState;
    StreamPtr     stream;
    Ptr           rcvBuff;
    TCPiopb       pb;
    char          scratch[SCRATCH_SIZE];
    char          req[REQ_MAX];
    long          reqLen;
    wdsEntry      wds[2];
    Handle        resp;
    long          respLen;
    unsigned long stateStart;
};

static short      gRefNum;
static short      gLastErr;
static const char *gLastStep = "";

short       GDTCP_LastErr(void)  { return gLastErr; }
const char *GDTCP_LastStep(void) { return gLastStep; }
static Boolean   gReady;
static Boolean   gTried;
static GDTCPConn gConn;
static Boolean   gInited;

GDTCPConn *GDTCP_Conn(void) { return &gConn; }
short GDTCP_State(GDTCPConn *c) { return c->pubState; }
long  GDTCP_Len(GDTCPConn *c)   { return c->respLen; }
long  GDTCP_Received(GDTCPConn *c) { return c->respLen; }
char *GDTCP_Data(GDTCPConn *c)  { return c->resp ? *c->resp : (char *)0; }

Boolean GDTCP_Ensure(void)
{
    Str255 drvName;
    short  refNum;

    if (!gInited) {
        gInited = true;
        memset(&gConn, 0, sizeof(gConn));
        gConn.cst = CST_IDLE;
        gConn.pubState = GDTCP_IDLE;
    }
    if (gReady) return true;
    if (!gTried) {
        gTried = true;
        drvName[0] = 4; drvName[1] = '.';
        drvName[2] = 'I'; drvName[3] = 'P'; drvName[4] = 'P';
        if (OpenDriver(drvName, &refNum) == noErr)
            gRefNum = refNum;
    }
    if (!gRefNum) return false;
    if (!gConn.rcvBuff) {
        gConn.rcvBuff = NewPtrClear(RCVBUF_SIZE);
        if (!gConn.rcvBuff) return false;
    }
    if (!gConn.resp) {
        gConn.resp = NewHandle(RESP_INITIAL);
        if (!gConn.resp) return false;
    }
    gReady = true;
    return true;
}

static void releaseStream(GDTCPConn *c)
{
    if (c->stream) {
        memset(&c->pb, 0, sizeof(c->pb));
        c->pb.ioCRefNum = gRefNum;
        c->pb.csCode    = TCPClose;
        c->pb.tcpStream = c->stream;
        (void) PBControlSync((ParmBlkPtr)&c->pb);

        memset(&c->pb, 0, sizeof(c->pb));
        c->pb.ioCRefNum = gRefNum;
        c->pb.csCode    = TCPRelease;
        c->pb.tcpStream = c->stream;
        (void) PBControlSync((ParmBlkPtr)&c->pb);
    }
    c->stream = 0;
}

static void finish(GDTCPConn *c, Boolean ok)
{
    releaseStream(c);
    c->cst      = ok ? CST_DONE : CST_ERROR;
    c->pubState = ok ? GDTCP_DONE : GDTCP_ERROR;
    if (c->resp) {
        if (c->respLen >= GetHandleSize(c->resp))
            SetHandleSize(c->resp, c->respLen + 1);
        if (GetHandleSize(c->resp) > c->respLen)
            (*c->resp)[c->respLen] = '\0';
    }
}

Boolean GDTCP_Begin(GDTCPConn *c, UInt32 ip, unsigned short port,
                    const char *request, long len)
{
    if (!GDTCP_Ensure()) return false;
    if (c->cst != CST_IDLE) return false;
    if (len <= 0 || len > REQ_MAX) return false;

    memcpy(c->req, request, len);
    c->reqLen  = len;
    c->respLen = 0;

    /* Creating the stream is local and instant, so it is done synchronously;
     * everything that waits on the network is asynchronous. */
    memset(&c->pb, 0, sizeof(c->pb));
    c->pb.ioCRefNum = gRefNum;
    c->pb.csCode    = TCPCreate;
    c->pb.csParam.create.rcvBuff    = c->rcvBuff;
    c->pb.csParam.create.rcvBuffLen = RCVBUF_SIZE;
    gLastErr = PBControlSync((ParmBlkPtr)&c->pb);
    if (gLastErr != noErr) {
        gLastStep = "create";
        c->cst = CST_ERROR; c->pubState = GDTCP_ERROR;
        return false;
    }
    c->stream = c->pb.tcpStream;

    memset(&c->pb, 0, sizeof(c->pb));
    c->pb.ioCRefNum = gRefNum;
    c->pb.csCode    = TCPActiveOpen;
    c->pb.tcpStream = c->stream;
    c->pb.csParam.open.ulpTimeoutValue  = 15;
    c->pb.csParam.open.ulpTimeoutAction = 1;          /* give up, don't hang */
    c->pb.csParam.open.validityFlags    = (SInt8) 0xC0;
    c->pb.csParam.open.remoteHost = (ip_addr) ip;
    c->pb.csParam.open.remotePort = port;
    c->pb.csParam.open.localPort  = 0;
    gLastErr = PBControlAsync((ParmBlkPtr)&c->pb);
    if (gLastErr != noErr) {
        gLastStep = "open";
        finish(c, false);
        return false;
    }
    c->stateStart = TickCount();
    c->cst        = CST_OPENING;
    c->pubState   = GDTCP_BUSY;
    return true;
}

static void respAppend(GDTCPConn *c, const char *p, long n)
{
    long need = c->respLen + n + 1;
    if (need > GetHandleSize(c->resp)) {
        long grow = GetHandleSize(c->resp) * 2;
        if (grow < need) grow = need;
        SetHandleSize(c->resp, grow);
        if (MemError() != noErr) return;     /* out of memory: keep what fits */
    }
    BlockMove(p, *c->resp + c->respLen, n);
    c->respLen += n;
}

static void startReceive(GDTCPConn *c)
{
    memset(&c->pb, 0, sizeof(c->pb));
    c->pb.ioCRefNum = gRefNum;
    c->pb.csCode    = TCPRcv;
    c->pb.tcpStream = c->stream;
    c->pb.csParam.receive.commandTimeoutValue = 0;    /* the ULP timer rules */
    c->pb.csParam.receive.rcvBuff    = c->scratch;
    c->pb.csParam.receive.rcvBuffLen = SCRATCH_SIZE;
    if (PBControlAsync((ParmBlkPtr)&c->pb) != noErr) {
        finish(c, c->respLen > 0);
        return;
    }
    c->stateStart = TickCount();
    c->cst        = CST_RECEIVING;
}

void GDTCP_Idle(void)
{
    GDTCPConn *c = &gConn;
    OSErr      r;

    if (c->cst == CST_IDLE || c->cst == CST_DONE || c->cst == CST_ERROR)
        return;

    r = c->pb.ioResult;
    if (r > 0) {                                  /* still in flight          */
        unsigned long limit = (c->cst == CST_OPENING) ? OPEN_TIMEOUT : IO_TIMEOUT;
        if (TickCount() - c->stateStart > limit) {
            /* Nothing has moved for long enough; a reply already half read is
             * worth keeping, an unanswered connection is not. */
            finish(c, c->cst == CST_RECEIVING && c->respLen > 0);
        }
        return;
    }

    switch (c->cst) {
    case CST_OPENING:
        if (r != noErr) { gLastErr = r; gLastStep = "connect"; finish(c, false); return; }
        c->wds[0].length = (unsigned short) c->reqLen;
        c->wds[0].ptr    = c->req;
        c->wds[1].length = 0;
        c->wds[1].ptr    = 0;
        memset(&c->pb, 0, sizeof(c->pb));
        c->pb.ioCRefNum = gRefNum;
        c->pb.csCode    = TCPSend;
        c->pb.tcpStream = c->stream;
        c->pb.csParam.send.ulpTimeoutValue  = 30;
        c->pb.csParam.send.ulpTimeoutAction = 1;
        c->pb.csParam.send.validityFlags    = (SInt8) 0xC0;
        c->pb.csParam.send.pushFlag         = true;
        c->pb.csParam.send.wdsPtr           = (Ptr) c->wds;
        if (PBControlAsync((ParmBlkPtr)&c->pb) != noErr) { finish(c, false); return; }
        c->stateStart = TickCount();
        c->cst        = CST_SENDING;
        break;

    case CST_SENDING:
        if (r != noErr) { gLastErr = r; gLastStep = "send"; finish(c, false); return; }
        startReceive(c);
        break;

    case CST_RECEIVING:
        if (r == noErr) {
            unsigned short got = c->pb.csParam.receive.rcvBuffLen;
            if (got > 0) respAppend(c, c->scratch, (long) got);
            startReceive(c);
        } else if (r == connectionClosing || r == connectionTerminated) {
            /* The far end hung up, which with "Connection: close" is exactly
             * how a complete reply ends. */
            finish(c, true);
        } else {
            finish(c, c->respLen > 0);
        }
        break;
    }
}

void GDTCP_Abort(GDTCPConn *c)
{
    if (c->cst == CST_IDLE) return;
    finish(c, false);
}

void GDTCP_Clear(GDTCPConn *c)
{
    if (c->cst == CST_DONE || c->cst == CST_ERROR) {
        c->cst      = CST_IDLE;
        c->pubState = GDTCP_IDLE;
        c->respLen  = 0;
    }
}
