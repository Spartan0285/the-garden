/*
 * gdcompat - will this run on this Mac?
 *
 * The same question the OS X version asks, from the other side of the divide.
 * There it has to worry about Rosetta and whether Classic is installed; here
 * the Mac *is* the classic one, so what matters is: does this want Mac OS X
 * (which this machine will never have), does it want a PowerPC when this is a
 * 68k, or is it Windows software that wandered in.
 *
 * And the same honesty about what a badge means: it speaks for the processor
 * and the system version, not for whether this particular Mac has the memory
 * or the speed.
 */
#ifndef GDCOMPAT_H
#define GDCOMPAT_H

#include <MacTypes.h>

typedef enum {
    GDC_UNKNOWN = 0,
    GDC_INCOMPATIBLE,     /* another kind of computer entirely      */
    GDC_NEEDS_OSX,        /* Mac OS X software; not on this machine */
    GDC_NEEDS_PPC,        /* PowerPC software on a 68k Mac          */
    GDC_EMULATED,         /* 68k software on a PowerPC: runs        */
    GDC_NATIVE            /* made for this kind of Mac              */
} GDCVerdict;

void        GDCompat_Init(void);        /* reads this Mac, once */
Boolean     GDCompat_IsPPC(void);
short       GDCompat_SystemVersion(void);   /* 0x0901 for Mac OS 9.1 */
const char *GDCompat_HostText(void);        /* "PowerPC Mac, Mac OS 9.2" */

GDCVerdict  GDCompat_Verdict(const char *systems, const char *arch,
                             const char *fileName);
const char *GDCompat_Label(GDCVerdict v);   /* badge text */

#endif /* GDCOMPAT_H */
