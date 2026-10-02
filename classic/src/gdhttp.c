#include "gdhttp.h"
#include <string.h>
#include <stdio.h>

static short  gState;
static short  gStatus;
static char  *gBody;
static long   gBodyLen;
static char  *gHead;        /* points into the connection's buffer          */
static long   gHeadLen;

short GDHTTP_State(void)  { return gState; }
short GDHTTP_Status(void) { return gStatus; }
char *GDHTTP_Body(void)   { return gBody; }
long  GDHTTP_BodyLen(void){ return gBodyLen; }
long  GDHTTP_Received(void) { return GDTCP_Received(GDTCP_Conn()); }

Boolean GDHTTP_Get(const char *host, UInt32 ip, unsigned short port,
                   const char *path)
{
    char req[512];
    long n;

    if (gState == GDHTTP_BUSY) return false;
    gStatus = 0; gBody = 0; gBodyLen = 0; gHead = 0; gHeadLen = 0;

    GDTCP_Clear(GDTCP_Conn());

    /* HTTP/1.0 on purpose - see the note in the header.  Identity encoding is
     * asked for explicitly so no gzip arrives: there is nothing here to
     * inflate it with. */
    n = (long) sprintf(req,
            "GET %s HTTP/1.0\r\n"
            "Host: %s\r\n"
            "User-Agent: TheGarden-Classic/0.1 (Mac OS)\r\n"
            "Accept: text/html\r\n"
            "Accept-Encoding: identity\r\n"
            "Connection: close\r\n"
            "\r\n",
            path, host);

    if (!GDTCP_Begin(GDTCP_Conn(), ip, port, req, n)) {
        gState = GDHTTP_ERROR;
        return false;
    }
    gState = GDHTTP_BUSY;
    return true;
}

/* Split the reply into headers and body, and read the status code.
 * Returns false if it does not look like HTTP at all. */
static Boolean parseReply(char *data, long len)
{
    long i;
    if (len < 12) return false;
    if (memcmp(data, "HTTP/", 5) != 0) return false;

    /* "HTTP/1.1 200 OK" - the code follows the first space. */
    for (i = 0; i < len && data[i] != ' '; i++) ;
    if (i + 3 >= len) return false;
    gStatus = (short) ((data[i+1] - '0') * 100 +
                       (data[i+2] - '0') * 10 +
                       (data[i+3] - '0'));

    /* Headers end at the first blank line.  Tolerate bare LF as well as CRLF:
     * it costs two lines here and saves a mystery later. */
    for (i = 0; i + 1 < len; i++) {
        if (data[i] == '\n' && data[i+1] == '\n') {
            gHead = data; gHeadLen = i;
            gBody = data + i + 2; gBodyLen = len - (i + 2);
            return true;
        }
        if (i + 3 < len && data[i] == '\r' && data[i+1] == '\n' &&
            data[i+2] == '\r' && data[i+3] == '\n') {
            gHead = data; gHeadLen = i;
            gBody = data + i + 4; gBodyLen = len - (i + 4);
            return true;
        }
    }
    return false;                      /* headers never ended */
}

void GDHTTP_Idle(void)
{
    GDTCPConn *c = GDTCP_Conn();
    short s;

    if (gState != GDHTTP_BUSY) return;
    GDTCP_Idle();
    s = GDTCP_State(c);
    if (s == GDTCP_DONE) {
        gState = parseReply(GDTCP_Data(c), GDTCP_Len(c)) ? GDHTTP_DONE
                                                         : GDHTTP_ERROR;
    } else if (s == GDTCP_ERROR) {
        gState = GDHTTP_ERROR;
    }
}

/* Copy one header's value out, NUL-terminated.  Case-insensitive on the name,
 * because servers are not consistent about it. */
char *GDHTTP_Header(const char *name, char *out, long outMax)
{
    long i, nameLen = (long) strlen(name);
    out[0] = '\0';
    if (!gHead) return out;
    for (i = 0; i < gHeadLen; i++) {
        if (i == 0 || gHead[i-1] == '\n') {
            long j;
            for (j = 0; j < nameLen && i + j < gHeadLen; j++) {
                char a = gHead[i+j], b = name[j];
                if (a >= 'A' && a <= 'Z') a = (char)(a + 32);
                if (b >= 'A' && b <= 'Z') b = (char)(b + 32);
                if (a != b) break;
            }
            if (j == nameLen && i + j < gHeadLen && gHead[i+j] == ':') {
                long k = i + j + 1, o = 0;
                while (k < gHeadLen && (gHead[k] == ' ' || gHead[k] == '\t')) k++;
                while (k < gHeadLen && gHead[k] != '\r' && gHead[k] != '\n' &&
                       o < outMax - 1)
                    out[o++] = gHead[k++];
                out[o] = '\0';
                return out;
            }
        }
    }
    return out;
}

void GDHTTP_Abort(void)
{
    GDTCP_Abort(GDTCP_Conn());
    gState = GDHTTP_ERROR;
}

void GDHTTP_Clear(void)
{
    GDTCP_Clear(GDTCP_Conn());
    gState = GDHTTP_IDLE;
    gStatus = 0; gBody = 0; gBodyLen = 0; gHead = 0; gHeadLen = 0;
}
