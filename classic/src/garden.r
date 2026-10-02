/*
 * garden.r - resources for The Garden.
 *
 *   SIZE (-1): without this the application takes Retro68's default partition,
 *   which is too small to be relied on - and a Mac OS that will not give an
 *   application the memory it asks for simply refuses to open it, with a
 *   dialog and nothing else to show for it.
 *
 *   What it needs: MacTCP's 16K receive buffer, a response Handle that grows
 *   with the page (the front page's feed is 81K, and doubling means 128K), a
 *   page of parsed rows and one parsed item.  2 MB preferred leaves room for
 *   a long search result; 1 MB is enough to work in.
 */

#include "Processes.r"

resource 'SIZE' (-1) {
    reserved,
    acceptSuspendResumeEvents,
    reserved,
    canBackground,
    multiFinderAware,
    backgroundAndForeground,
    dontGetFrontClicks,
    ignoreChildDiedEvents,
    is32BitCompatible,
    isHighLevelEventAware,
    onlyLocalHLEvents,
    notStationeryAware,
    dontUseTextEditServices,
    reserved, reserved, reserved,
    2048 * 1024,
    1024 * 1024
};
