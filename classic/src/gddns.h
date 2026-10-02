/*
 * gddns - turn a host name into an address, over DNS.
 *
 * Over TCP, not UDP, so it reuses the connection engine that already works
 * rather than adding a second one: a DNS query carried on TCP is the same
 * message with a two-byte length in front of it, and every resolver accepts
 * it.
 *
 * It asks a resolver by address, because the machine's own resolver cannot be
 * read from here: MacTCP keeps that in its preferences, Open Transport knows
 * it through calls Retro68 has no headers for, and the classic DNR glue wants
 * a MacTCP control panel that Mac OS 9 does not have.  So the server is a
 * setting, and it defaults to a public one.  On a network that will not let a
 * machine talk to an outside resolver this needs changing; there is nowhere
 * better to read it from yet.
 */
#ifndef GDDNS_H
#define GDDNS_H

#include <MacTypes.h>

#define GDDNS_DEFAULT_SERVER 0x01010101UL      /* 1.1.1.1 */

enum { GDDNS_IDLE = 0, GDDNS_BUSY, GDDNS_DONE, GDDNS_ERROR };

Boolean GDDNS_Begin(const char *hostname, UInt32 serverIp);
void    GDDNS_Idle(void);
short   GDDNS_State(void);
UInt32  GDDNS_Address(void);     /* the A record, valid when DONE */
void    GDDNS_Clear(void);

#endif /* GDDNS_H */
