#include "gddns.h"
#include "gdtcp.h"
#include <Events.h>
#include <string.h>

static short  gState;
static UInt32 gAddr;
static long   gQueryLen;

/* Build a query for one A record.  The name goes in as length-prefixed
 * labels: "macintoshgarden.org" becomes 15 m a c ... 3 o r g 0. */
static long buildQuery(const char *host, char *out, long outMax)
{
    long  n = 0;
    const char *p = host;

    if (outMax < 2 + 12 + 5) return 0;

    n = 2;                                  /* room for the TCP length */
    out[n++] = 0x47; out[n++] = 0x44;       /* id: "GD"                 */
    out[n++] = 0x01; out[n++] = 0x00;       /* recursion desired        */
    out[n++] = 0x00; out[n++] = 0x01;       /* one question             */
    out[n++] = 0x00; out[n++] = 0x00;       /* no answers               */
    out[n++] = 0x00; out[n++] = 0x00;       /* no authority             */
    out[n++] = 0x00; out[n++] = 0x00;       /* no additional            */

    while (*p) {
        const char *dot = strchr(p, '.');
        long len = dot ? (long)(dot - p) : (long) strlen(p);
        if (len <= 0 || len > 63 || n + len + 1 >= outMax) return 0;
        out[n++] = (char) len;
        memcpy(out + n, p, len);
        n += len;
        if (!dot) break;
        p = dot + 1;
    }
    if (n + 5 > outMax) return 0;
    out[n++] = 0x00;                        /* root label               */
    out[n++] = 0x00; out[n++] = 0x01;       /* type A                   */
    out[n++] = 0x00; out[n++] = 0x01;       /* class IN                 */

    out[0] = (char) ((n - 2) >> 8);         /* the length DNS-over-TCP wants */
    out[1] = (char) ((n - 2) & 0xFF);
    return n;
}

Boolean GDDNS_Begin(const char *hostname, UInt32 serverIp)
{
    char query[320];
    gAddr = 0;
    gQueryLen = buildQuery(hostname, query, sizeof(query));
    if (gQueryLen == 0) { gState = GDDNS_ERROR; return false; }

    GDTCP_Clear(GDTCP_Conn());
    if (!GDTCP_Begin(GDTCP_Conn(), serverIp, 53, query, gQueryLen)) {
        gState = GDDNS_ERROR;
        return false;
    }
    gState = GDDNS_BUSY;
    return true;
}

/* Step over a name, which may end in a compression pointer rather than a
 * root label.  Returns the offset just past it, or -1 if it runs off. */
static long skipName(const unsigned char *m, long len, long at)
{
    while (at < len) {
        unsigned char c = m[at];
        if (c == 0) return at + 1;
        if ((c & 0xC0) == 0xC0) return at + 2;      /* pointer: two bytes */
        at += c + 1;
    }
    return -1;
}

static void parseReply(const unsigned char *m, long len)
{
    long  at, i;
    short qd, an;

    if (len < 2 + 12) { gState = GDDNS_ERROR; return; }
    m += 2; len -= 2;                       /* drop the TCP length prefix */

    if ((m[3] & 0x0F) != 0) { gState = GDDNS_ERROR; return; }   /* RCODE */
    qd = (short)((m[4] << 8) | m[5]);
    an = (short)((m[6] << 8) | m[7]);
    if (an < 1) { gState = GDDNS_ERROR; return; }

    at = 12;
    for (i = 0; i < qd; i++) {              /* step over the questions */
        at = skipName(m, len, at);
        if (at < 0 || at + 4 > len) { gState = GDDNS_ERROR; return; }
        at += 4;
    }

    for (i = 0; i < an; i++) {
        short type, rdlen;
        at = skipName(m, len, at);
        if (at < 0 || at + 10 > len) break;
        type  = (short)((m[at] << 8) | m[at+1]);
        rdlen = (short)((m[at+8] << 8) | m[at+9]);
        at += 10;
        if (at + rdlen > len) break;
        if (type == 1 && rdlen == 4) {      /* an A record: done */
            gAddr = ((UInt32) m[at] << 24) | ((UInt32) m[at+1] << 16) |
                    ((UInt32) m[at+2] << 8) | (UInt32) m[at+3];
            gState = GDDNS_DONE;
            return;
        }
        at += rdlen;                        /* a CNAME, most likely */
    }
    gState = GDDNS_ERROR;                   /* answers, but no address */
}

void GDDNS_Idle(void)
{
    GDTCPConn *c = GDTCP_Conn();
    short s;

    if (gState != GDDNS_BUSY) return;
    GDTCP_Idle();
    s = GDTCP_State(c);

    if (s == GDTCP_BUSY) {
        /* The reply says how long it is; stop as soon as it is all here
         * rather than waiting for a resolver that means to stay connected. */
        long n = GDTCP_Received(c);
        if (n >= 2) {
            const unsigned char *p = (const unsigned char *) GDTCP_Data(c);
            long want = 2 + (long)((p[0] << 8) | p[1]);
            if (n >= want) GDTCP_FinishEarly(c);
        }
        return;
    }
    if (s == GDTCP_DONE)
        parseReply((const unsigned char *) GDTCP_Data(c), GDTCP_Len(c));
    else if (s == GDTCP_ERROR)
        gState = GDDNS_ERROR;
}

short  GDDNS_State(void)   { return gState; }
UInt32 GDDNS_Address(void) { return gAddr; }

void GDDNS_Clear(void)
{
    /* A query abandoned part way - a resolver that never answered - leaves the
     * connection in use, and GDTCP_Clear only frees an idle one.  Everything
     * afterwards then fails to start, with no error to show for it. */
    if (gState == GDDNS_BUSY)
        GDTCP_Abort(GDTCP_Conn());
    GDTCP_Clear(GDTCP_Conn());
    gState = GDDNS_IDLE;
    gAddr  = 0;
}
