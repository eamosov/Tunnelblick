/*
 *  StatusCheckController.m
 *  Tunnelblick
 *
 *  Status page showing network reachability checks.
 */

#import "StatusCheckController.h"
#import <sys/socket.h>
#import <netinet/in.h>
#import <netdb.h>
#import <arpa/inet.h>

@implementation StatusCheckResult

@synthesize serviceName, reachable, checking, ipAddress, errorMessage, latencyMs;

- (void) dealloc {
    self.serviceName = nil;
    self.ipAddress = nil;
    self.errorMessage = nil;
    [super dealloc];
}

@end

// -----------------------------------------------------------------------

static StatusCheckController * sharedInstance = nil;

@implementation StatusCheckController

+ (StatusCheckController *) sharedController {

    if ( ! sharedInstance ) {
        sharedInstance = [[StatusCheckController alloc] init];
    }
    return sharedInstance;
}

- (instancetype) init {

    self = [super init];
    if ( ! self ) return nil;

    statusWindow = nil;
    httpTableView = nil;
    pingTableView = nil;
    lastUpdateLabel = nil;
    refreshTimer = nil;
    isActive = NO;

    httpResults = [[NSMutableArray alloc] init];
    pingResults = [[NSMutableArray alloc] init];

    // Initialize HTTP service entries
    NSArray * services = @[@"tunnelblick.net/ipinfo", @"ifconfig.me", @"yandex.ru/internet", @"api.ipify.org"];
    for ( NSString * name in services ) {
        StatusCheckResult * r = [[[StatusCheckResult alloc] init] autorelease];
        r.serviceName = name;
        r.checking = YES;
        r.reachable = NO;
        [httpResults addObject: r];
    }

    // Initialize ping host entries from preferences (empty by default)
    [self reloadPingHosts];

    return self;
}

- (void) dealloc {

    [self stopChecking];
    [httpResults release];
    [pingResults release];
    [statusWindow release];
    [super dealloc];
}

- (void) createWindow {

    if ( statusWindow ) return;

    CGFloat windowWidth  = 520;
    CGFloat windowHeight = 460;
    CGFloat margin = 10;

    NSRect frame = NSMakeRect(200, 200, windowWidth, windowHeight);
    statusWindow = [[NSWindow alloc] initWithContentRect: frame
                                                styleMask: (NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable)
                                                  backing: NSBackingStoreBuffered
                                                    defer: NO];
    [statusWindow setTitle: @"Network Status"];
    [statusWindow setReleasedWhenClosed: NO];
    [statusWindow setMinSize: NSMakeSize(420, 360)];

    NSView * contentView = [statusWindow contentView];
    CGFloat contentWidth = windowWidth - margin * 2;

    // Layout from edges inward.  Cocoa coords: Y = 0 is bottom.

    // --- Top-pinned elements ---

    CGFloat topY = windowHeight - margin - 20;

    // Last update label
    lastUpdateLabel = [[[NSTextField alloc] initWithFrame: NSMakeRect(margin, topY, contentWidth, 20)] autorelease];
    [lastUpdateLabel setEditable: NO];
    [lastUpdateLabel setBordered: NO];
    [lastUpdateLabel setBackgroundColor: [NSColor clearColor]];
    [lastUpdateLabel setStringValue: @"Last update: --:--:--"];
    [lastUpdateLabel setFont: [NSFont systemFontOfSize: 12]];
    [lastUpdateLabel setAutoresizingMask: NSViewMinYMargin | NSViewWidthSizable];
    [contentView addSubview: lastUpdateLabel];

    topY -= 25;

    // HTTP Services label
    NSTextField * httpLabel = [[[NSTextField alloc] initWithFrame: NSMakeRect(margin, topY, contentWidth, 20)] autorelease];
    [httpLabel setEditable: NO];
    [httpLabel setBordered: NO];
    [httpLabel setBackgroundColor: [NSColor clearColor]];
    [httpLabel setStringValue: @"HTTP Services"];
    [httpLabel setFont: [NSFont boldSystemFontOfSize: 13]];
    [httpLabel setAutoresizingMask: NSViewMinYMargin | NSViewWidthSizable];
    [contentView addSubview: httpLabel];

    topY -= 5;  // gap before table

    // --- Bottom-pinned elements ---

    CGFloat bottomY = margin;

    // Refresh button
    NSButton * refreshButton = [[[NSButton alloc] initWithFrame: NSMakeRect(margin, bottomY, 100, 30)] autorelease];
    [refreshButton setTitle: @"Refresh"];
    [refreshButton setBezelStyle: NSBezelStyleRounded];
    [refreshButton setTarget: self];
    [refreshButton setAction: @selector(refreshNow:)];
    [refreshButton setAutoresizingMask: NSViewMaxYMargin];
    [contentView addSubview: refreshButton];

    bottomY += 40;

    // Ping table
    CGFloat pingTableHeight = 100;
    NSScrollView * pingScroll = [[[NSScrollView alloc] initWithFrame: NSMakeRect(margin, bottomY, contentWidth, pingTableHeight)] autorelease];
    [pingScroll setHasVerticalScroller: YES];
    [pingScroll setBorderType: NSBezelBorder];
    [pingScroll setAutoresizingMask: NSViewMaxYMargin | NSViewWidthSizable];

    pingTableView = [[[NSTableView alloc] initWithFrame: [[pingScroll contentView] bounds]] autorelease];
    [pingTableView setColumnAutoresizingStyle: NSTableViewLastColumnOnlyAutoresizingStyle];

    NSTableColumn * pcol1 = [[[NSTableColumn alloc] initWithIdentifier: @"indicator"] autorelease];
    [pcol1 setWidth: 30];
    [pcol1 setResizingMask: NSTableColumnNoResizing];
    [[pcol1 headerCell] setStringValue: @""];
    [pingTableView addTableColumn: pcol1];

    NSTableColumn * pcol2 = [[[NSTableColumn alloc] initWithIdentifier: @"name"] autorelease];
    [pcol2 setWidth: 140];
    [pcol2 setResizingMask: NSTableColumnUserResizingMask];
    [[pcol2 headerCell] setStringValue: @"Host"];
    [pingTableView addTableColumn: pcol2];

    NSTableColumn * pcol3 = [[[NSTableColumn alloc] initWithIdentifier: @"status"] autorelease];
    [pcol3 setWidth: 180];
    [pcol3 setResizingMask: NSTableColumnUserResizingMask];
    [[pcol3 headerCell] setStringValue: @"Status"];
    [pingTableView addTableColumn: pcol3];

    NSTableColumn * pcol4 = [[[NSTableColumn alloc] initWithIdentifier: @"ip"] autorelease];
    [pcol4 setWidth: 140];
    [pcol4 setResizingMask: NSTableColumnAutoresizingMask];
    [[pcol4 headerCell] setStringValue: @"IP Address"];
    [pingTableView addTableColumn: pcol4];

    [pingTableView setDataSource: self];
    [pingTableView setDelegate: self];
    [pingScroll setDocumentView: pingTableView];
    [contentView addSubview: pingScroll];

    bottomY += pingTableHeight + 5;

    // Ping label + Edit button
    NSTextField * pingLabel = [[[NSTextField alloc] initWithFrame: NSMakeRect(margin, bottomY, 200, 20)] autorelease];
    [pingLabel setEditable: NO];
    [pingLabel setBordered: NO];
    [pingLabel setBackgroundColor: [NSColor clearColor]];
    [pingLabel setStringValue: @"Ping (TCP:443)"];
    [pingLabel setFont: [NSFont boldSystemFontOfSize: 13]];
    [pingLabel setAutoresizingMask: NSViewMaxYMargin | NSViewWidthSizable];
    [contentView addSubview: pingLabel];

    NSButton * editButton = [[[NSButton alloc] initWithFrame: NSMakeRect(windowWidth - margin - 60, bottomY, 60, 20)] autorelease];
    [editButton setTitle: @"Edit\u2026"];
    [editButton setBezelStyle: NSBezelStyleInline];
    [editButton setTarget: self];
    [editButton setAction: @selector(editPingHosts:)];
    [editButton setAutoresizingMask: NSViewMaxYMargin | NSViewMinXMargin];
    [contentView addSubview: editButton];

    bottomY += 25;

    // --- HTTP table fills remaining space ---

    CGFloat httpTableHeight = topY - bottomY;
    NSScrollView * httpScroll = [[[NSScrollView alloc] initWithFrame: NSMakeRect(margin, bottomY, contentWidth, httpTableHeight)] autorelease];
    [httpScroll setHasVerticalScroller: YES];
    [httpScroll setBorderType: NSBezelBorder];
    [httpScroll setAutoresizingMask: NSViewHeightSizable | NSViewWidthSizable];

    httpTableView = [[[NSTableView alloc] initWithFrame: [[httpScroll contentView] bounds]] autorelease];
    [httpTableView setColumnAutoresizingStyle: NSTableViewLastColumnOnlyAutoresizingStyle];

    NSTableColumn * col1 = [[[NSTableColumn alloc] initWithIdentifier: @"indicator"] autorelease];
    [col1 setWidth: 30];
    [col1 setResizingMask: NSTableColumnNoResizing];
    [[col1 headerCell] setStringValue: @""];
    [httpTableView addTableColumn: col1];

    NSTableColumn * col2 = [[[NSTableColumn alloc] initWithIdentifier: @"name"] autorelease];
    [col2 setWidth: 140];
    [col2 setResizingMask: NSTableColumnUserResizingMask];
    [[col2 headerCell] setStringValue: @"Service"];
    [httpTableView addTableColumn: col2];

    NSTableColumn * col3 = [[[NSTableColumn alloc] initWithIdentifier: @"status"] autorelease];
    [col3 setWidth: 180];
    [col3 setResizingMask: NSTableColumnUserResizingMask];
    [[col3 headerCell] setStringValue: @"Status"];
    [httpTableView addTableColumn: col3];

    NSTableColumn * col4 = [[[NSTableColumn alloc] initWithIdentifier: @"ip"] autorelease];
    [col4 setWidth: 140];
    [col4 setResizingMask: NSTableColumnAutoresizingMask];
    [[col4 headerCell] setStringValue: @"IP Address"];
    [httpTableView addTableColumn: col4];

    [httpTableView setDataSource: self];
    [httpTableView setDelegate: self];
    [httpScroll setDocumentView: httpTableView];
    [contentView addSubview: httpScroll];
}

- (void) reloadPingHosts {

    [pingResults removeAllObjects];

    NSArray * hosts = [[NSUserDefaults standardUserDefaults] arrayForKey: @"statusCheckPingHosts"];
    if ( ! hosts ) {
        hosts = @[];
    }

    for ( NSString * name in hosts ) {
        if ( ! [name isKindOfClass: [NSString class]] || [name length] == 0 ) continue;
        StatusCheckResult * r = [[[StatusCheckResult alloc] init] autorelease];
        r.serviceName = name;
        r.checking = YES;
        r.reachable = NO;
        [pingResults addObject: r];
    }

    if ( pingTableView ) {
        [pingTableView reloadData];
    }
}

- (void) editPingHosts: (id) sender {

    (void) sender;

    NSAlert * alert = [[[NSAlert alloc] init] autorelease];
    [alert setMessageText: @"Edit Ping Hosts"];
    [alert setInformativeText: @"Enter one hostname per line (TCP port 443 will be used):"];
    [alert addButtonWithTitle: @"Save"];
    [alert addButtonWithTitle: @"Cancel"];

    NSScrollView * accessoryScroll = [[[NSScrollView alloc] initWithFrame: NSMakeRect(0, 0, 300, 150)] autorelease];
    [accessoryScroll setHasVerticalScroller: YES];
    [accessoryScroll setBorderType: NSBezelBorder];

    NSTextView * textView = [[[NSTextView alloc] initWithFrame: NSMakeRect(0, 0, 300, 150)] autorelease];
    [textView setMinSize: NSMakeSize(0, 150)];
    [textView setMaxSize: NSMakeSize(FLT_MAX, FLT_MAX)];
    [[textView textContainer] setWidthTracksTextView: YES];
    [textView setAutoresizingMask: NSViewWidthSizable];
    [textView setFont: [NSFont systemFontOfSize: 13]];

    // Populate with current hosts
    NSMutableString * hostsText = [NSMutableString string];
    for ( StatusCheckResult * r in pingResults ) {
        [hostsText appendFormat: @"%@\n", r.serviceName];
    }
    [textView setString: hostsText];

    [accessoryScroll setDocumentView: textView];
    [alert setAccessoryView: accessoryScroll];

    if ( [alert runModal] == NSAlertFirstButtonReturn ) {
        NSString * text = [textView string];
        NSArray * lines = [text componentsSeparatedByCharactersInSet: [NSCharacterSet newlineCharacterSet]];
        NSMutableArray * hosts = [NSMutableArray array];
        for ( NSString * line in lines ) {
            NSString * trimmed = [line stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if ( [trimmed length] > 0 ) {
                [hosts addObject: trimmed];
            }
        }
        [[NSUserDefaults standardUserDefaults] setObject: hosts forKey: @"statusCheckPingHosts"];
        [self reloadPingHosts];
        [self performChecks];
    }
}

- (void) showWindow {

    [self createWindow];
    [statusWindow makeKeyAndOrderFront: nil];
    [self startChecking];
}

- (void) startChecking {

    if ( isActive ) return;
    isActive = YES;

    [self performChecks];
    refreshTimer = [NSTimer scheduledTimerWithTimeInterval: 5.0
                                                    target: self
                                                  selector: @selector(performChecks)
                                                  userInfo: nil
                                                   repeats: YES];
}

- (void) stopChecking {

    isActive = NO;
    if ( refreshTimer ) {
        [refreshTimer invalidate];
        refreshTimer = nil;
    }
}

- (void) refreshNow: (id) sender {
    (void) sender;
    [self performChecks];
}

- (void) performChecks {

    for ( NSUInteger i = 0; i < [httpResults count]; i++ ) {
        StatusCheckResult * result = [httpResults objectAtIndex: i];
        result.checking = YES;
        [self performSelectorInBackground: @selector(checkHTTPService:) withObject: [NSNumber numberWithUnsignedInteger: i]];
    }

    for ( NSUInteger i = 0; i < [pingResults count]; i++ ) {
        StatusCheckResult * result = [pingResults objectAtIndex: i];
        result.checking = YES;
        [self performSelectorInBackground: @selector(checkPingHost:) withObject: [NSNumber numberWithUnsignedInteger: i]];
    }
}

- (void) checkHTTPService: (NSNumber *) indexNum {

    NSAutoreleasePool * pool = [[NSAutoreleasePool alloc] init];

    NSUInteger index = [indexNum unsignedIntegerValue];
    StatusCheckResult * result = [httpResults objectAtIndex: index];
    NSString * name = result.serviceName;

    NSString * urlString = nil;
    if ( [name isEqualToString: @"tunnelblick.net/ipinfo"] ) {
        urlString = @"https://tunnelblick.net/ipinfo";
    } else if ( [name isEqualToString: @"ifconfig.me"] ) {
        urlString = @"https://ifconfig.me/all.json";
    } else if ( [name isEqualToString: @"yandex.ru/internet"] ) {
        urlString = @"https://yandex.ru/internet/";
    } else if ( [name isEqualToString: @"api.ipify.org"] ) {
        urlString = @"https://api.ipify.org/?format=json";
    }

    if ( ! urlString ) {
        [pool drain];
        return;
    }

    NSDate * start = [NSDate date];
    NSURL * url = [NSURL URLWithString: urlString];
    NSMutableURLRequest * request = [NSMutableURLRequest requestWithURL: url
                                                           cachePolicy: NSURLRequestReloadIgnoringLocalCacheData
                                                       timeoutInterval: 5.0];
    if ( [name isEqualToString: @"tunnelblick.net/ipinfo"] ) {
        [request setValue: @"Tunnelblick ipInfoChecker: StatusCheck" forHTTPHeaderField: @"User-Agent"];
    } else {
        [request setValue: @"curl/7.0" forHTTPHeaderField: @"User-Agent"];
    }

    NSURLResponse * response = nil;
    NSError * error = nil;
    NSData * data = [NSURLConnection sendSynchronousRequest: request returningResponse: &response error: &error];

    NSTimeInterval latency = [[NSDate date] timeIntervalSinceDate: start] * 1000.0;

    NSString * ip = nil;
    BOOL success = NO;

    if ( data && ! error ) {
        NSHTTPURLResponse * httpResponse = (NSHTTPURLResponse *) response;
        if ( [httpResponse statusCode] == 200 ) {
            success = YES;
            NSString * body = [[[NSString alloc] initWithData: data encoding: NSUTF8StringEncoding] autorelease];

            if ( [name isEqualToString: @"tunnelblick.net/ipinfo"] ) {
                // Response format: "IP,PORT,SERVER_IP"
                NSArray * parts = [body componentsSeparatedByString: @","];
                if ( [parts count] >= 1 ) {
                    ip = [[parts objectAtIndex: 0] stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceAndNewlineCharacterSet]];
                }
            } else if ( [name isEqualToString: @"ifconfig.me"] ) {
                ip = [self extractJSONValue: @"ip_addr" fromString: body];
            } else if ( [name isEqualToString: @"yandex.ru/internet"] ) {
                ip = [self extractRegex: @"\"v4\"\\s*:\\s*\"([^\"]+)\"" fromString: body];
            } else if ( [name isEqualToString: @"api.ipify.org"] ) {
                ip = [self extractJSONValue: @"ip" fromString: body];
            }
        }
    }

    NSDictionary * resultDict = @{
        @"index": indexNum,
        @"success": [NSNumber numberWithBool: success],
        @"latency": [NSNumber numberWithDouble: latency],
        @"ip": ip ? ip : @"",
        @"error": error ? [error localizedDescription] : @""
    };
    [self performSelectorOnMainThread: @selector(updateHTTPResult:) withObject: resultDict waitUntilDone: NO];

    [pool drain];
}

- (void) updateHTTPResult: (NSDictionary *) dict {

    NSUInteger index = [[dict objectForKey: @"index"] unsignedIntegerValue];
    if ( index >= [httpResults count] ) return;

    StatusCheckResult * result = [httpResults objectAtIndex: index];
    result.checking = NO;
    result.reachable = [[dict objectForKey: @"success"] boolValue];
    result.latencyMs = [[dict objectForKey: @"latency"] doubleValue];
    result.ipAddress = [dict objectForKey: @"ip"];
    result.errorMessage = [dict objectForKey: @"error"];

    [httpTableView reloadData];
    [self updateTimestamp];
}

- (void) checkPingHost: (NSNumber *) indexNum {

    NSAutoreleasePool * pool = [[NSAutoreleasePool alloc] init];

    NSUInteger index = [indexNum unsignedIntegerValue];
    StatusCheckResult * result = [pingResults objectAtIndex: index];
    NSString * host = result.serviceName;

    NSDate * start = [NSDate date];
    BOOL success = NO;
    NSString * resolvedIP = nil;

    struct addrinfo hints, *res;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;

    int status = getaddrinfo([host UTF8String], "443", &hints, &res);
    if ( status == 0 && res ) {
        struct sockaddr_in * addr = (struct sockaddr_in *) res->ai_addr;
        char ipStr[INET_ADDRSTRLEN];
        inet_ntop(AF_INET, &(addr->sin_addr), ipStr, INET_ADDRSTRLEN);
        resolvedIP = [NSString stringWithUTF8String: ipStr];

        int sock = socket(AF_INET, SOCK_STREAM, 0);
        if ( sock >= 0 ) {
            struct timeval tv;
            tv.tv_sec = 3;
            tv.tv_usec = 0;
            setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

            if ( connect(sock, res->ai_addr, res->ai_addrlen) == 0 ) {
                success = YES;
            }
            close(sock);
        }
        freeaddrinfo(res);
    }

    NSTimeInterval latency = [[NSDate date] timeIntervalSinceDate: start] * 1000.0;

    NSDictionary * resultDict = @{
        @"index": indexNum,
        @"success": [NSNumber numberWithBool: success],
        @"latency": [NSNumber numberWithDouble: latency],
        @"ip": resolvedIP ? resolvedIP : @""
    };
    [self performSelectorOnMainThread: @selector(updatePingResult:) withObject: resultDict waitUntilDone: NO];

    [pool drain];
}

- (void) updatePingResult: (NSDictionary *) dict {

    NSUInteger index = [[dict objectForKey: @"index"] unsignedIntegerValue];
    if ( index >= [pingResults count] ) return;

    StatusCheckResult * result = [pingResults objectAtIndex: index];
    result.checking = NO;
    result.reachable = [[dict objectForKey: @"success"] boolValue];
    result.latencyMs = [[dict objectForKey: @"latency"] doubleValue];
    result.ipAddress = [dict objectForKey: @"ip"];

    [pingTableView reloadData];
    [self updateTimestamp];
}

- (void) updateTimestamp {

    NSDateFormatter * fmt = [[[NSDateFormatter alloc] init] autorelease];
    [fmt setDateFormat: @"HH:mm:ss"];
    NSString * ts = [fmt stringFromDate: [NSDate date]];
    [lastUpdateLabel setStringValue: [NSString stringWithFormat: @"Last update: %@", ts]];
}

// MARK: - Table View Data Source

- (NSInteger) numberOfRowsInTableView: (NSTableView *) tableView {

    if ( tableView == httpTableView ) {
        return (NSInteger)[httpResults count];
    } else if ( tableView == pingTableView ) {
        return (NSInteger)[pingResults count];
    }
    return 0;
}

- (id) tableView: (NSTableView *) tableView objectValueForTableColumn: (NSTableColumn *) tableColumn row: (NSInteger) row {

    NSArray * results = (tableView == httpTableView) ? httpResults : pingResults;
    if ( row < 0 || (NSUInteger)row >= [results count] ) return @"";

    StatusCheckResult * result = [results objectAtIndex: (NSUInteger)row];
    NSString * colId = [tableColumn identifier];

    if ( [colId isEqualToString: @"name"] ) {
        return result.serviceName;
    } else if ( [colId isEqualToString: @"status"] ) {
        if ( result.checking ) return @"Checking...";
        if ( result.reachable ) {
            return [NSString stringWithFormat: @"Reachable (%.0f ms)", result.latencyMs];
        }
        return result.errorMessage ? [NSString stringWithFormat: @"Unreachable: %@", result.errorMessage] : @"Unreachable";
    } else if ( [colId isEqualToString: @"ip"] ) {
        return result.ipAddress ? result.ipAddress : @"";
    } else if ( [colId isEqualToString: @"indicator"] ) {
        if ( result.checking ) return @"\xe2\x9a\xab";  // black circle
        return result.reachable ? @"\xf0\x9f\x9f\xa2" : @"\xf0\x9f\x94\xb4";  // green/red circle
    }

    return @"";
}

// MARK: - JSON Parsing Helpers

- (NSString *) extractJSONValue: (NSString *) key fromString: (NSString *) json {

    if ( ! json ) return nil;

    NSString * pattern = [NSString stringWithFormat: @"\"%@\"\\s*:\\s*\"([^\"]+)\"", key];
    return [self extractRegex: pattern fromString: json];
}

- (NSString *) extractRegex: (NSString *) pattern fromString: (NSString *) string {

    if ( ! string || ! pattern ) return nil;

    NSError * error = nil;
    NSRegularExpression * regex = [NSRegularExpression regularExpressionWithPattern: pattern
                                                                           options: 0
                                                                             error: &error];
    if ( error || ! regex ) return nil;

    NSTextCheckingResult * match = [regex firstMatchInString: string
                                                     options: 0
                                                       range: NSMakeRange(0, [string length])];
    if ( ! match || [match numberOfRanges] < 2 ) return nil;

    NSRange range = [match rangeAtIndex: 1];
    if ( range.location == NSNotFound ) return nil;

    return [string substringWithRange: range];
}

@end
