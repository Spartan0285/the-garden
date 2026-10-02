/*
 * gdhttp - one HTTP GET, for a Mac that has to do its own fetching.
 *
 * The request is HTTP/1.0 with a Host header.  That is deliberate: the Garden
 * answers such a request with "Connection: close", no chunked encoding and no
 * Content-Length, so the body is simply everything up to the close - which is
 * the one framing a classic Mac can implement in a few lines and get right.
 *
 * There is no TLS here and none is needed: macintoshgarden.org serves the same
 * pages over plain HTTP.  That is the whole reason this app can talk to the
 * site itself rather than through a helper on a modern machine, which is what
 * the System 7 client had to do.
 */
#ifndef GDHTTP_H
#define GDHTTP_H

#include <MacTypes.h>
#include "gdtcp.h"

enum {
    GDHTTP_IDLE = 0,
    GDHTTP_BUSY,
    GDHTTP_DONE,     /* status and body are readable                        */
    GDHTTP_ERROR     /* never connected, or the reply was not HTTP          */
};

/* Begin a GET.  `host` goes in the Host header, `ip` is where to connect -
 * they are separate because a name has to be resolved somewhere, and until
 * the resolver is in, a known address can be passed straight in. */
Boolean GDHTTP_Get(const char *host, UInt32 ip, unsigned short port,
                   const char *path);

/* The same GET, but the body goes to an open file as it arrives rather than
 * into memory.  The headers are still read first - they are small - and only
 * what follows them is written out. */
Boolean GDHTTP_GetToFile(const char *host, UInt32 ip, unsigned short port,
                         const char *path, short fileRef);
long    GDHTTP_Downloaded(void);     /* bytes written so far */

void  GDHTTP_Idle(void);
short GDHTTP_State(void);

short GDHTTP_Status(void);     /* 200, 404, ... valid when DONE              */
char *GDHTTP_Body(void);       /* NUL-terminated                             */
long  GDHTTP_BodyLen(void);
long  GDHTTP_Received(void);   /* bytes in so far, for a progress line       */
char *GDHTTP_Header(const char *name, char *out, long outMax);

void  GDHTTP_Abort(void);
void  GDHTTP_Clear(void);

#endif /* GDHTTP_H */
