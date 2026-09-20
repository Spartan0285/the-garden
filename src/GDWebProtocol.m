#import "GDWebProtocol.h"
#import "GDHTTP.h"
#import <CoreServices/CoreServices.h>
#include <dlfcn.h>

/* "text/html; charset=utf-8" -> "text/html" and "utf-8". */
static void splitContentType(NSString *value, NSString **type, NSString **encoding)
{
    NSArray *parts = [value componentsSeparatedByString:@";"];
    unsigned i;

    *type = nil;
    *encoding = nil;
    if ([parts count] == 0)
        return;
    *type = [[[parts objectAtIndex:0] stringByTrimmingCharactersInSet:
                 [NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    for (i = 1; i < [parts count]; i++) {
        NSString *p = [[parts objectAtIndex:i] stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([[p lowercaseString] hasPrefix:@"charset="]) {
            *encoding = [p substringFromIndex:8];
            *encoding = [*encoding stringByTrimmingCharactersInSet:
                            [NSCharacterSet characterSetWithCharactersInString:@"\"'"]];
        }
    }
}

@implementation GDWebProtocol

+ (void) install
{
    static BOOL installed;
    if (!installed) {
        installed = YES;
        [NSURLProtocol registerClass:self];
    }
}

+ (BOOL) canInitWithRequest:(NSURLRequest *)r
{
    NSString *scheme = [[[r URL] scheme] lowercaseString];
    NSString *method = [r HTTPMethod];

    if (!([scheme isEqualToString:@"https"] || [scheme isEqualToString:@"http"]))
        return NO;
    /* GDHTTP speaks GET and POST; anything else stays with Foundation. */
    return method == nil || [method isEqualToString:@"GET"] ||
           [method isEqualToString:@"POST"];
}

+ (NSURLRequest *) canonicalRequestForRequest:(NSURLRequest *)r { return r; }

- (void) startLoading
{
    NSURLRequest *r = [self request];
    NSMutableDictionary *headers = [[[r allHTTPHeaderFields] mutableCopy] autorelease];

    /* curl works these out itself, and WebKit's versions would be wrong for
     * the transfer we actually make. */
    [headers removeObjectForKey:@"Content-Length"];
    [headers removeObjectForKey:@"Accept-Encoding"];
    [headers removeObjectForKey:@"Connection"];
    [headers removeObjectForKey:@"Host"];

    request_ = [[GDHTTPRequest requestWithURL:[r URL]] retain];
    if ([[r HTTPMethod] isEqualToString:@"POST"] && [r HTTPBody] != nil)
        [request_ setPostBody:[r HTTPBody]];
    [request_ setRequestHeaders:headers];
    [request_ setWantsResponseHeaders:YES];
    /* The site's session is the whole point of a web view here. */
    [request_ setUsesSession:YES];
    [request_ setDelegate:self];
    [request_ start];
}

- (void) httpRequestDidFinish:(GDHTTPRequest *)r
{
    NSDictionary *fields = [r responseHeaders];
    NSString *type = nil, *encoding = nil;
    NSURL *responseURL;
    GDHTTPURLResponse *response;

    if (r != request_)
        return;
    if ([r isCancelled]) {
        [request_ setDelegate:nil];
        [request_ release];
        request_ = nil;
        return;
    }
    if ([r error] != nil && [[r data] length] == 0) {
        NSDictionary *info = [NSDictionary dictionaryWithObject:[r error]
                                                         forKey:NSLocalizedDescriptionKey];
        [[self client] URLProtocol:self didFailWithError:
            [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCannotConnectToHost
                            userInfo:info]];
        [request_ setDelegate:nil];
        [request_ release];
        request_ = nil;
        return;
    }

    /* libcurl followed any redirects, so the answer belongs to the URL it
     * ended at: relative links in the page resolve against that. */
    responseURL = [r effectiveURL] != nil ? [NSURL URLWithString:[r effectiveURL]] : [r url];
    if (responseURL == nil)
        responseURL = [r url];
    splitContentType([r contentType] ?: @"application/octet-stream", &type, &encoding);
    response = [[[GDHTTPURLResponse alloc] initWithURL:responseURL
                                            statusCode:(int)[r statusCode] ?: 200
                                          headerFields:(fields ?: [NSDictionary dictionary])
                                              MIMEType:type
                                         contentLength:(long long)[[r data] length]
                                          textEncoding:encoding] autorelease];
    [[self client] URLProtocol:self didReceiveResponse:response
            cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    if ([[r data] length] > 0)
        [[self client] URLProtocol:self didLoadData:[r data]];
    [[self client] URLProtocolDidFinishLoading:self];

    [request_ setDelegate:nil];
    [request_ release];
    request_ = nil;
}

- (void) stopLoading
{
    if (request_ != nil) {
        [request_ setDelegate:nil];
        [request_ cancel];
        [request_ release];
        request_ = nil;
    }
}

- (void) dealloc
{
    [request_ setDelegate:nil];
    [request_ release];
    [super dealloc];
}

@end

/* CFNetwork's own response type: private, but there from Leopard on. */
typedef const struct __CFURLResponse *GDURLResponseRef;
typedef GDURLResponseRef (*GDCreateWithHTTPResponse)(CFAllocatorRef, CFURLRef, CFHTTPMessageRef, int);
typedef void (*GDSetMIMEType)(GDURLResponseRef, CFStringRef);
typedef void (*GDSetExpectedContentLength)(GDURLResponseRef, SInt64);

@interface NSHTTPURLResponse (GDPrivate)
- (id) _initWithCFURLResponse:(GDURLResponseRef)response;
@end

/* From Leopard on, Foundation hands WebKit a response rebuilt from the
 * CFNetwork response underneath ours, and a subclass's own fields do not
 * survive that: WebKit would see status 0 and no headers.  A response built on
 * a real CFNetwork message carries them through.  NULL where that is not
 * possible, as on Tiger, whose WebKit reads -allHeaderFields directly. */
static GDURLResponseRef createBackingResponse(NSURL *URL, int statusCode, NSDictionary *fields,
                                              NSString *MIMEType, long long contentLength)
{
    static BOOL looked = NO;
    static GDCreateWithHTTPResponse createWithHTTPResponse = NULL;
    static GDSetMIMEType setMIMEType = NULL;
    static GDSetExpectedContentLength setExpectedContentLength = NULL;
    CFHTTPMessageRef message;
    GDURLResponseRef response;
    NSEnumerator *names;
    NSString *name;

    if (!looked) {
        looked = YES;
        if ([NSHTTPURLResponse instancesRespondToSelector:@selector(_initWithCFURLResponse:)]) {
            createWithHTTPResponse = (GDCreateWithHTTPResponse)
                dlsym(RTLD_DEFAULT, "CFURLResponseCreateWithHTTPResponse");
            setMIMEType = (GDSetMIMEType)dlsym(RTLD_DEFAULT, "CFURLResponseSetMIMEType");
            setExpectedContentLength = (GDSetExpectedContentLength)
                dlsym(RTLD_DEFAULT, "CFURLResponseSetExpectedContentLength");
        }
    }
    if (createWithHTTPResponse == NULL || setMIMEType == NULL || setExpectedContentLength == NULL)
        return NULL;

    message = CFHTTPMessageCreateResponse(kCFAllocatorDefault, statusCode, NULL, kCFHTTPVersion1_1);
    if (message == NULL)
        return NULL;
    names = [fields keyEnumerator];
    while ((name = [names nextObject]) != nil)
        CFHTTPMessageSetHeaderFieldValue(message, (CFStringRef)name,
                                         (CFStringRef)[fields objectForKey:name]);
    response = createWithHTTPResponse(kCFAllocatorDefault, (CFURLRef)URL, message, 0);
    CFRelease(message);
    if (response == NULL)
        return NULL;
    setMIMEType(response, (CFStringRef)MIMEType);
    setExpectedContentLength(response, contentLength);
    return response;
}

@implementation GDHTTPURLResponse

- (id) initWithURL:(NSURL *)aURL
        statusCode:(int)aStatusCode
      headerFields:(NSDictionary *)fields
          MIMEType:(NSString *)MIMEType
     contentLength:(long long)contentLength
      textEncoding:(NSString *)encoding
{
    GDURLResponseRef backing = createBackingResponse(aURL, aStatusCode, fields,
                                                     MIMEType, contentLength);

    if (backing != NULL) {
        self = [super _initWithCFURLResponse:backing];
        CFRelease(backing);
    } else {
        self = [super initWithURL:aURL MIMEType:MIMEType
            expectedContentLength:(int)contentLength textEncodingName:encoding];
    }
    if (self == nil)
        return nil;
    responseStatusCode = aStatusCode;
    responseHeaderFields = [fields copy];
    return self;
}

- (void) dealloc
{
    [responseHeaderFields release];
    [super dealloc];
}

/* A response never changes once made, and Leopard's Foundation would copy it
 * by rebuilding it from its CFNetwork counterpart, losing the fields here. */
- (id) copyWithZone:(NSZone *)zone { return [self retain]; }

- (int) statusCode { return responseStatusCode; }
- (NSDictionary *) allHeaderFields { return responseHeaderFields; }

@end
