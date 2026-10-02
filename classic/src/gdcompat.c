#include "gdcompat.h"
#include <Multiverse.h>
#include <string.h>
#include <stdio.h>

static Boolean gIsPPC;
static short   gSysVersion = 0x0900;
static char    gHostText[48];
static Boolean gInited;

/* Case-insensitive substring, because the Garden's wording is not uniform. */
static Boolean has(const char *hay, const char *needle)
{
    long hl, nl, i, j;
    if (!hay || !needle) return false;
    hl = (long) strlen(hay); nl = (long) strlen(needle);
    for (i = 0; i + nl <= hl; i++) {
        for (j = 0; j < nl; j++) {
            char a = hay[i+j], b = needle[j];
            if (a >= 'A' && a <= 'Z') a = (char)(a + 32);
            if (b >= 'A' && b <= 'Z') b = (char)(b + 32);
            if (a != b) break;
        }
        if (j == nl) return true;
    }
    return false;
}

void GDCompat_Init(void)
{
    long r = 0;
    if (gInited) return;
    gInited = true;

    if (Gestalt(gestaltSysArchitecture, &r) == noErr)
        gIsPPC = (r == gestaltPowerPC);
    r = 0;
    if (Gestalt(gestaltSystemVersion, &r) == noErr && r)
        gSysVersion = (short) (r & 0xFFFF);

    sprintf(gHostText, "%s Mac, Mac OS %d.%d",
            gIsPPC ? "PowerPC" : "68k",
            (int)((gSysVersion >> 8) & 0xF) + ((gSysVersion >> 12) & 0xF) * 10,
            (int)((gSysVersion >> 4) & 0xF));
}

Boolean     GDCompat_IsPPC(void)         { return gIsPPC; }
short       GDCompat_SystemVersion(void) { return gSysVersion; }
const char *GDCompat_HostText(void)      { return gHostText; }

GDCVerdict GDCompat_Verdict(const char *systems, const char *arch,
                            const char *fileName)
{
    Boolean osx, classic, windows, ppc, m68k;

    if (!gInited) GDCompat_Init();

    osx     = has(systems, "os x") || has(systems, "macos") ||
              has(systems, "mac os 10");
    classic = has(systems, "system ") || has(systems, "mac os 7") ||
              has(systems, "mac os 8") || has(systems, "mac os 9");
    windows = has(systems, "windows") || has(systems, "dos") ||
              has(fileName, ".exe");
    ppc     = has(arch, "ppc") || has(arch, "powerpc");
    m68k    = has(arch, "68k");

    /* A file named for one processor overrules the item's own line. */
    if (has(fileName, "ppc") || has(fileName, "powerpc")) { ppc = true; m68k = false; }
    else if (has(fileName, "68k")) { m68k = true; ppc = false; }

    if (windows && !classic && !osx) return GDC_INCOMPATIBLE;
    if (osx && !classic)             return GDC_NEEDS_OSX;

    if (gIsPPC) {
        /* A PowerPC Mac runs 68k code through the emulator built into it, so
         * the only thing it cannot manage is software for a newer system. */
        if (m68k && !ppc) return GDC_EMULATED;
        if (classic || ppc || m68k) return GDC_NATIVE;
    } else {
        if (ppc && !m68k) return GDC_NEEDS_PPC;
        if (classic || m68k) return GDC_NATIVE;
    }
    if (classic) return GDC_NATIVE;
    return GDC_UNKNOWN;
}

const char *GDCompat_Label(GDCVerdict v)
{
    switch (v) {
    case GDC_NATIVE:       return "Compatible with this Mac";
    case GDC_EMULATED:     return "Compatible (68k)";
    case GDC_NEEDS_PPC:    return "Needs a PowerPC Mac";
    case GDC_NEEDS_OSX:    return "Needs Mac OS X";
    case GDC_INCOMPATIBLE: return "Not for this Mac";
    default:               return "Compatibility unknown";
    }
}
