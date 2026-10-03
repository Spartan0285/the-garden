/*
 * GDReports - whether a title actually ran, as reported by the people who
 * installed it.
 *
 * The badge is worked out from the Garden's "Architecture:" line, the file's
 * "For ..." line and what this Mac is.  It is a good guess, and a guess is
 * what it stays until somebody runs the thing.  So: a title you installed
 * asks you once whether it ran, and every item page shows what the answers
 * add up to - "Ran for 12 people on a Mac like yours" beside our opinion.
 *
 * Nothing is sent unless Yes or No is pressed.  What goes is the title, the
 * file it came from, the same coarse description of this Mac that the badge
 * is worked out from, and the answer.  The server keeps counts, not reports:
 * there is no record of an individual answer, so there is nothing to tie two
 * of them together.
 */
#import <Foundation/Foundation.h>

/* An item page's figures arrived; the view redraws. */
extern NSString *GDReportsChangedNotification;

@interface GDReports : NSObject

/* The answer to the question, sent once.  variant is the file it was
 * installed from, or nil. */
+ (void) report:(BOOL)ran forPath:(NSString *)path variant:(NSString *)variant;

/* Has this copy already answered for this title? */
+ (BOOL) hasAnswered:(NSString *)path;

/* What the answers add up to, for the item page: a sentence, or nil when
 * nothing is known yet.  Asks the server the first time and posts
 * GDReportsChangedNotification when the answer arrives. */
+ (NSString *) summaryFor:(NSString *)path;

/* How many said it ran on a Mac like this one, and how many said it did not;
 * -1 when we have not been told. */
+ (int) ranHereFor:(NSString *)path;
+ (int) failedHereFor:(NSString *)path;

@end
