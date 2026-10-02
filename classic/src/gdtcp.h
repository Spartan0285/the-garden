/*
 * gdtcp - one TCP conversation at a time, over MacTCP, without blocking.
 *
 * The asynchronous state machine (PBControlAsync + polling ioResult from the
 * event loop) is the one from the System 7 Garden client, which has been
 * running on device for months.  What is different here: it connects to an
 * arbitrary address rather than a fixed host alias, it sends an arbitrary
 * block of bytes rather than one line, and it reads until the far end closes
 * rather than looking for a protocol terminator.
 *
 * MacTCP, not Open Transport: Retro68 ships no Open Transport headers or
 * libraries at all, the parameter blocks below are declared here rather than
 * included from anywhere, and Mac OS 9 still answers them through Open
 * Transport's MacTCP compatibility.  The same code therefore runs on System 7
 * through Mac OS 9.
 */
#ifndef GDTCP_H
#define GDTCP_H

#include <MacTypes.h>

enum {
    GDTCP_IDLE = 0,   /* free                                              */
    GDTCP_BUSY,       /* connecting, sending or reading                    */
    GDTCP_DONE,       /* the far end closed: buffer holds the whole reply  */
    GDTCP_ERROR       /* refused, timed out, or the driver complained      */
};

typedef struct GDTCPConn GDTCPConn;

/* Opens the .IPP driver once.  False means there is no MacTCP here. */
Boolean GDTCP_Ensure(void);

/* The one connection.  A second would want a second receive buffer, and
 * nothing in this app asks two questions at once. */
GDTCPConn *GDTCP_Conn(void);

/* Connect to ip:port and send `len` bytes.  False if it is already busy. */
Boolean GDTCP_Begin(GDTCPConn *c, UInt32 ip, unsigned short port,
                    const char *request, long len);

/* Advance the state machine.  Call this often from the event loop. */
void GDTCP_Idle(void);

short GDTCP_State(GDTCPConn *c);
char *GDTCP_Data(GDTCPConn *c);    /* NUL-terminated; valid when DONE       */
long  GDTCP_Len(GDTCPConn *c);
long  GDTCP_Received(GDTCPConn *c);  /* bytes so far, for a progress line   */

/* Why the last attempt failed: the OSErr, and the step that returned it
 * ("create", "open", "send", "recv").  Guessing from a boolean is no way to
 * debug a stack this old. */
short       GDTCP_LastErr(void);
const char *GDTCP_LastStep(void);

/* Finish successfully now, keeping what has arrived.  For a reply that frames
 * its own length - DNS over TCP does - waiting for the far end to hang up
 * would mean waiting out the whole timeout, because a resolver keeps the
 * connection open for the next question. */
void GDTCP_FinishEarly(GDTCPConn *c);

void GDTCP_Abort(GDTCPConn *c);
void GDTCP_Clear(GDTCPConn *c);    /* DONE/ERROR -> IDLE, ready for reuse   */

#endif /* GDTCP_H */
