#import "GDUtil.h"

NSString *GDUniquePath(NSString *dir, NSString *name)
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *base = [name stringByDeletingPathExtension];
    NSString *ext = [name pathExtension];
    NSString *p = [dir stringByAppendingPathComponent:name];
    int n = 2;
    while ([fm fileExistsAtPath:p]) {
        NSString *cand = [NSString stringWithFormat:@"%@ %d", base, n++];
        if ([ext length])
            cand = [cand stringByAppendingPathExtension:ext];
        p = [dir stringByAppendingPathComponent:cand];
    }
    return p;
}
