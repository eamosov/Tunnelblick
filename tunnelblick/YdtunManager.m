/*
 *  YdtunManager.m
 *  Tunnelblick
 *
 *  Manages the ydtun (Telemost/WebRTC) proxy process for wrapping OpenVPN traffic.
 */

#import "YdtunManager.h"
#import "helper.h"
#import "defines.h"
#import "TBUserDefaults.h"

#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>

extern TBUserDefaults * gTbDefaults;

@implementation YdtunManager

@synthesize telemostUrls;
@synthesize tunnelKey;
@synthesize forceTcpRelay;
@synthesize logLevel;
@synthesize localPort;
@synthesize apiPort;
@synthesize isRunning;
@synthesize logBlock;

- (void) logMessage: (NSString *) msg {
    NSLog(@"YdtunManager: %@", msg);
    if ( logBlock ) {
        logBlock([NSString stringWithFormat: @"*ydtun: %@", msg]);
    }
}

// Extracts telemost_ key and remaining parts from a line.
// Supports three formats:
//   "telemost_key value ..."              (bare format)
//   "setenv telemost_key value ..."       (setenv format)
//   "setenv-safe telemost_key value ..."  (setenv-safe format)
// Returns nil if the line is not a telemost_ directive.
+ (NSArray *) telemostPartsFromLine: (NSString *) trimmedLine {

    NSArray * parts = [trimmedLine componentsSeparatedByCharactersInSet: [NSCharacterSet whitespaceCharacterSet]];
    NSMutableArray * nonEmpty = [NSMutableArray array];
    for ( NSString * p in parts ) {
        if ( [p length] > 0 ) [nonEmpty addObject: p];
    }
    if ( [nonEmpty count] < 2 ) return nil;

    // "setenv telemost_key value ..." or "setenv-safe telemost_key value ..."
    NSString * first = [nonEmpty objectAtIndex: 0];
    if (   ( [first isEqualToString: @"setenv"] || [first isEqualToString: @"setenv-safe"] )
        && [nonEmpty count] >= 3
        && [[nonEmpty objectAtIndex: 1] hasPrefix: @"telemost_"] ) {
        return [nonEmpty subarrayWithRange: NSMakeRange(1, [nonEmpty count] - 1)];
    }

    // "telemost_key value ..."
    if ( [first hasPrefix: @"telemost_"] ) {
        return [[nonEmpty copy] autorelease];
    }

    return nil;
}

// Returns YES if the trimmed line is a telemost_ directive (bare or setenv).
+ (BOOL) isYdtunDirective: (NSString *) trimmedLine {

    if ( [trimmedLine hasPrefix: @"telemost_"] ) return YES;

    if ( [trimmedLine hasPrefix: @"setenv "] || [trimmedLine hasPrefix: @"setenv-safe "] ) {
        NSArray * parts = [trimmedLine componentsSeparatedByCharactersInSet: [NSCharacterSet whitespaceCharacterSet]];
        NSMutableArray * nonEmpty = [NSMutableArray array];
        for ( NSString * p in parts ) {
            if ( [p length] > 0 ) [nonEmpty addObject: p];
        }
        if ( [nonEmpty count] >= 2 ) {
            NSString * envName = [nonEmpty objectAtIndex: 1];
            if ( [envName hasPrefix: @"telemost_"] ) return YES;
        }
    }

    return NO;
}

+ (BOOL) parseYdtunDirectivesFromConfig: (NSString *) configContents
                         intoPreferences: (NSMutableDictionary *) prefs {

    if ( ! configContents ) return NO;

    NSArray * lines = [configContents componentsSeparatedByString: @"\n"];
    BOOL ydEnable = NO;

    for ( NSString * line in lines ) {
        NSString * trimmed = [line stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceAndNewlineCharacterSet]];

        NSArray * tmParts = [self telemostPartsFromLine: trimmed];
        if ( tmParts && [tmParts count] >= 2 ) {
            NSString * key = [tmParts objectAtIndex: 0];
            NSString * value = [tmParts objectAtIndex: 1];

            if ( [key isEqualToString: @"telemost_enable"] ) {
                ydEnable = ( [value caseInsensitiveCompare: @"true"] == NSOrderedSame
                            || [value isEqualToString: @"1"] );
            } else if ( [key isEqualToString: @"telemost_cc_url"] ) {
                [prefs setObject: value forKey: @"ydtunTelemostUrls"];
            } else if ( [key isEqualToString: @"telemost_tunnel_key"] ) {
                [prefs setObject: value forKey: @"ydtunTunnelKey"];
            } else if ( [key isEqualToString: @"telemost_force_tcp_relay"] ) {
                BOOL force = ( [value caseInsensitiveCompare: @"true"] == NSOrderedSame
                              || [value isEqualToString: @"1"] );
                [prefs setObject: [NSNumber numberWithBool: force] forKey: @"ydtunForceTcpRelay"];
            } else if ( [key isEqualToString: @"telemost_log_level"] ) {
                [prefs setObject: [NSNumber numberWithInt: [value intValue]] forKey: @"ydtunLogLevel"];
            }
        }
    }

    return ydEnable;
}

- (instancetype) initWithDisplayName: (NSString *) displayName {

    self = [super init];
    if ( ! self ) return nil;

    localPort = 0;
    apiPort = 0;
    isRunning = NO;
    ydtunTask = nil;

    // Find ydtun binary in app bundle Resources
    ydtunBinaryPath = [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent: @"ydtun"];
    [ydtunBinaryPath retain];

    // Load parameters from preferences
    NSString * prefix = [displayName stringByAppendingString: @"-"];

    self.telemostUrls = [gTbDefaults stringForKey: [prefix stringByAppendingString: @"ydtunTelemostUrls"]];
    self.tunnelKey = [gTbDefaults stringForKey: [prefix stringByAppendingString: @"ydtunTunnelKey"]];
    self.forceTcpRelay = [gTbDefaults boolForKey: [prefix stringByAppendingString: @"ydtunForceTcpRelay"]];
    self.logLevel = (int)[gTbDefaults unsignedIntForKey: [prefix stringByAppendingString: @"ydtunLogLevel"]
                                                   default: 0
                                                       min: 0
                                                       max: 2];
    return self;
}

- (void) dealloc {

    [self stop];
    [ydtunBinaryPath release];
    self.telemostUrls = nil;
    self.tunnelKey = nil;
    self.logBlock = nil;
    [super dealloc];
}

- (unsigned int) findFreePort {

    int sock = socket(AF_INET, SOCK_STREAM, 0);
    if ( sock < 0 ) {
        [self logMessage: @"Failed to create socket for finding free port"];
        return 0;
    }

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = 0; // Let OS assign

    if ( bind(sock, (struct sockaddr *)&addr, sizeof(addr)) < 0 ) {
        close(sock);
        [self logMessage: @"Failed to bind socket for finding free port"];
        return 0;
    }

    socklen_t len = sizeof(addr);
    if ( getsockname(sock, (struct sockaddr *)&addr, &len) < 0 ) {
        close(sock);
        [self logMessage: @"Failed to get socket name for finding free port"];
        return 0;
    }

    unsigned int port = ntohs(addr.sin_port);
    close(sock);
    return port;
}

- (BOOL) probePort: (unsigned int) port {

    int sock = socket(AF_INET, SOCK_STREAM, 0);
    if ( sock < 0 ) return NO;

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons(port);

    int result = connect(sock, (struct sockaddr *)&addr, sizeof(addr));
    close(sock);
    return (result == 0);
}

// OpenVPN HARD_RESET handshake probe — see SingBoxManager.m for protocol details.
// Telemost always carries OpenVPN over TCP (helper rewrites proto), so we only need the TCP variant here.
#define YDTUN_OPENVPN_HARD_RESET_CLIENT_V2_OPCODE_BYTE ((uint8_t)0x38)
#define YDTUN_OPENVPN_HARD_RESET_SERVER_V2_OPCODE_BYTE ((uint8_t)0x40)
#define YDTUN_OPENVPN_HARD_RESET_V2_PAYLOAD_LEN        ((size_t)14)

static void ydtun_build_hard_reset_payload(uint8_t out[YDTUN_OPENVPN_HARD_RESET_V2_PAYLOAD_LEN]) {
    memset(out, 0, YDTUN_OPENVPN_HARD_RESET_V2_PAYLOAD_LEN);
    out[0] = YDTUN_OPENVPN_HARD_RESET_CLIENT_V2_OPCODE_BYTE;
    arc4random_buf(out + 1, 8);
}

static long long ydtun_remaining_ms(uint64_t deadlineNs, long long maxMs) {
    uint64_t nowNs = clock_gettime_nsec_np(CLOCK_MONOTONIC);
    if ( nowNs >= deadlineNs ) return 0;
    long long remMs = (long long)((deadlineNs - nowNs) / 1000000ULL);
    if ( maxMs >= 0 && remMs > maxMs ) remMs = maxMs;
    return remMs;
}

- (BOOL) probeOpenVPNTcpPort: (unsigned int) port {

    uint64_t deadlineNs = clock_gettime_nsec_np(CLOCK_MONOTONIC) + 2ULL * 1000000000ULL;

    int sock = socket(AF_INET, SOCK_STREAM, 0);
    if ( sock < 0 ) return NO;

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons(port);

    long long connectMs = ydtun_remaining_ms(deadlineNs, 2000);
    if ( connectMs == 0 ) { close(sock); return NO; }
    struct timeval tv;
    tv.tv_sec = (time_t)(connectMs / 1000);
    tv.tv_usec = (suseconds_t)((connectMs % 1000) * 1000);
    setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

    if ( connect(sock, (struct sockaddr *)&addr, sizeof(addr)) != 0 ) {
        close(sock);
        return NO;
    }

    uint8_t packet[2 + YDTUN_OPENVPN_HARD_RESET_V2_PAYLOAD_LEN];
    uint16_t lenBE = htons((uint16_t)YDTUN_OPENVPN_HARD_RESET_V2_PAYLOAD_LEN);
    memcpy(packet, &lenBE, 2);
    ydtun_build_hard_reset_payload(packet + 2);

    long long writeMs = ydtun_remaining_ms(deadlineNs, 1000);
    if ( writeMs == 0 ) { close(sock); return NO; }
    tv.tv_sec = (time_t)(writeMs / 1000);
    tv.tv_usec = (suseconds_t)((writeMs % 1000) * 1000);
    setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

    if ( send(sock, packet, sizeof(packet), 0) != (ssize_t)sizeof(packet) ) {
        close(sock);
        return NO;
    }

    long long readMs = ydtun_remaining_ms(deadlineNs, -1);
    if ( readMs == 0 ) { close(sock); return NO; }
    tv.tv_sec = (time_t)(readMs / 1000);
    tv.tv_usec = (suseconds_t)((readMs % 1000) * 1000);
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    uint8_t buf[3];
    size_t filled = 0;
    while ( filled < sizeof(buf) ) {
        ssize_t n = recv(sock, buf + filled, sizeof(buf) - filled, 0);
        if ( n <= 0 ) { close(sock); return NO; }
        filled += (size_t)n;
    }
    close(sock);

    return ( buf[2] == YDTUN_OPENVPN_HARD_RESET_SERVER_V2_OPCODE_BYTE );
}

- (BOOL) waitForPort: (unsigned int) port timeout: (NSTimeInterval) timeout {

    NSDate * deadline = [NSDate dateWithTimeIntervalSinceNow: timeout];

    while ( [[NSDate date] compare: deadline] == NSOrderedAscending ) {
        if ( ydtunTask && ! [ydtunTask isRunning] ) {
            [self logMessage: @"ydtun process died while waiting for port"];
            return NO;
        }

        if ( [self probePort: port] ) {
            return YES;
        }

        [[NSRunLoop currentRunLoop] runUntilDate: [NSDate dateWithTimeIntervalSinceNow: 0.2]];
    }

    [self logMessage: [NSString stringWithFormat: @"Timed out waiting for port %u", port]];
    return NO;
}

// Like waitForPort:, but verifies OpenVPN reachability end-to-end through the ydtun proxy
// by performing the HARD_RESET handshake. This catches the case where ydtun's local listener
// accepts connections but the real OpenVPN server is not yet reachable through KCP/WebRTC.
- (BOOL) waitForOpenVPNHandshake: (unsigned int) port timeout: (NSTimeInterval) timeout {

    NSDate * deadline = [NSDate dateWithTimeIntervalSinceNow: timeout];

    while ( [[NSDate date] compare: deadline] == NSOrderedAscending ) {
        if ( ydtunTask && ! [ydtunTask isRunning] ) {
            [self logMessage: @"ydtun process died while waiting for OpenVPN handshake"];
            return NO;
        }

        if ( [self probeOpenVPNTcpPort: port] ) {
            return YES;
        }

        [[NSRunLoop currentRunLoop] runUntilDate: [NSDate dateWithTimeIntervalSinceNow: 0.5]];
    }

    [self logMessage: [NSString stringWithFormat: @"Timed out waiting for OpenVPN handshake on port %u", port]];
    return NO;
}

// Synchronous HTTP GET request. Returns response body string or nil on failure.
- (NSString *) httpGetSync: (NSString *) urlString timeout: (NSTimeInterval) timeout {

    NSURL * url = [NSURL URLWithString: urlString];
    if ( ! url ) return nil;

    NSMutableURLRequest * request = [NSMutableURLRequest requestWithURL: url];
    [request setHTTPMethod: @"GET"];
    [request setTimeoutInterval: timeout];

    __block NSData * responseData = nil;
    __block NSError * responseError = nil;
    __block NSInteger statusCode = 0;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    NSURLSessionDataTask * task = [[NSURLSession sharedSession]
        dataTaskWithRequest: request
          completionHandler: ^(NSData * data, NSURLResponse * response, NSError * error) {
              responseData = [data retain];
              responseError = [error retain];
              if ( [response isKindOfClass: [NSHTTPURLResponse class]] ) {
                  statusCode = [(NSHTTPURLResponse *)response statusCode];
              }
              dispatch_semaphore_signal(sem);
          }];
    [task resume];

    // Wait with run loop spinning to keep UI responsive
    while ( dispatch_semaphore_wait(sem, DISPATCH_TIME_NOW) != 0 ) {
        [[NSRunLoop currentRunLoop] runUntilDate: [NSDate dateWithTimeIntervalSinceNow: 0.1]];
    }
    dispatch_release(sem);

    if ( responseError ) {
        [self logMessage: [NSString stringWithFormat: @"HTTP GET %@ failed: %@", urlString, responseError]];
        [responseError release];
        [responseData release];
        return nil;
    }

    if ( statusCode != 200 ) {
        [self logMessage: [NSString stringWithFormat: @"HTTP GET %@ returned status %ld", urlString, (long)statusCode]];
        [responseData release];
        return nil;
    }

    NSString * body = nil;
    if ( responseData ) {
        body = [[[NSString alloc] initWithData: responseData encoding: NSUTF8StringEncoding] autorelease];
        [responseData release];
    }
    return body;
}

// Wait for KCP tunnel readiness via ydtun API.
// The /alive/kcp endpoint blocks server-side for up to 120 seconds while establishing WebRTC/KCP.
- (BOOL) waitForKcpAlive {

    [self logMessage: [NSString stringWithFormat: @"Waiting for KCP tunnel readiness on API port %u...", apiPort]];

    NSString * urlString = [NSString stringWithFormat: @"http://127.0.0.1:%u/alive/kcp", apiPort];
    NSString * body = [self httpGetSync: urlString timeout: 130.0];

    if ( ! body ) {
        [self logMessage: @"KCP alive check failed (no response)"];
        return NO;
    }

    // Parse JSON for "alive": true
    NSData * jsonData = [body dataUsingEncoding: NSUTF8StringEncoding];
    NSError * error = nil;
    NSDictionary * json = [NSJSONSerialization JSONObjectWithData: jsonData options: 0 error: &error];
    if ( ! json || error ) {
        [self logMessage: [NSString stringWithFormat: @"KCP alive check: failed to parse JSON: %@", error]];
        return NO;
    }

    BOOL alive = [[json objectForKey: @"alive"] boolValue];
    if ( alive ) {
        [self logMessage: @"KCP tunnel is alive"];
    } else {
        [self logMessage: [NSString stringWithFormat: @"KCP tunnel is NOT alive (response: %@)", body]];
    }
    return alive;
}

// Non-blocking health check via /status endpoint.
- (BOOL) checkAlive {

    if ( apiPort == 0 ) return NO;

    NSString * urlString = [NSString stringWithFormat: @"http://127.0.0.1:%u/status", apiPort];
    NSString * body = [self httpGetSync: urlString timeout: 2.0];

    if ( ! body ) return NO;

    NSData * jsonData = [body dataUsingEncoding: NSUTF8StringEncoding];
    NSDictionary * json = [NSJSONSerialization JSONObjectWithData: jsonData options: 0 error: nil];
    if ( ! json ) return NO;

    return [[json objectForKey: @"alive"] boolValue];
}

- (unsigned int) start {

    [self stop]; // Stop any existing instance

    // Validate required fields
    if ( ! self.telemostUrls || [self.telemostUrls length] == 0 ) {
        [self logMessage: @"Cannot start — telemostUrls is empty"];
        return 0;
    }

    // Find two free ports: one for proxy, one for API
    localPort = [self findFreePort];
    if ( localPort == 0 ) {
        [self logMessage: @"Failed to find a free port for proxy"];
        return 0;
    }

    apiPort = [self findFreePort];
    if ( apiPort == 0 ) {
        [self logMessage: @"Failed to find a free port for API"];
        localPort = 0;
        return 0;
    }

    if ( localPort == apiPort ) {
        [self logMessage: [NSString stringWithFormat: @"proxy and API ports collided (%u), retrying API port", localPort]];
        apiPort = [self findFreePort];
        if ( apiPort == 0 || apiPort == localPort ) {
            [self logMessage: @"failed to get unique API port"];
            localPort = 0;
            apiPort = 0;
            return 0;
        }
    }

    [self logMessage: [NSString stringWithFormat: @"Using proxy port %u, API port %u", localPort, apiPort]];

    // Check if binary exists
    if ( ! [[NSFileManager defaultManager] fileExistsAtPath: ydtunBinaryPath] ) {
        [self logMessage: [NSString stringWithFormat: @"ydtun binary not found at %@", ydtunBinaryPath]];
        localPort = 0;
        apiPort = 0;
        return 0;
    }

    // Build command-line arguments
    NSMutableArray * args = [NSMutableArray arrayWithObjects:
        @"--no-color",
        @"--mode", @"port-forward",
        @"--pf-listen", [NSString stringWithFormat: @"127.0.0.1:%u", localPort],
        @"--api-addr", [NSString stringWithFormat: @"127.0.0.1:%u", apiPort],
        @"--telemost-urls", self.telemostUrls,
        nil];

    if ( self.tunnelKey && [self.tunnelKey length] > 0 ) {
        [args addObject: @"--tunnel-key"];
        [args addObject: self.tunnelKey];
    }

    if ( self.forceTcpRelay ) {
        [args addObject: @"--force-tcp-relay"];
    }

    if ( self.logLevel == 1 ) {
        [args addObject: @"-v"];
    } else if ( self.logLevel >= 2 ) {
        [args addObject: @"-vv"];
    }

    [self logMessage: [NSString stringWithFormat: @"ydtun binary at %@", ydtunBinaryPath]];
    [self logMessage: [NSString stringWithFormat: @"arguments: %@", args]];

    // Launch ydtun process
    ydtunTask = [[NSTask alloc] init];
    [ydtunTask setLaunchPath: ydtunBinaryPath];
    [ydtunTask setArguments: args];

    // Set environment
    NSMutableDictionary * env = [NSMutableDictionary dictionaryWithDictionary: [[NSProcessInfo processInfo] environment]];
    NSString * rustLogLevel = ( self.logLevel >= 2 ) ? @"ydtun=trace"
                             : ( self.logLevel == 1 ) ? @"ydtun=debug"
                             :                          @"ydtun=info";
    [env setObject: rustLogLevel forKey: @"RUST_LOG"];
    [ydtunTask setEnvironment: env];

    // Capture output for logging
    NSPipe * outputPipe = [NSPipe pipe];
    [ydtunTask setStandardOutput: outputPipe];
    [ydtunTask setStandardError: outputPipe];

    NSFileHandle * readHandle = [outputPipe fileHandleForReading];
    [readHandle waitForDataInBackgroundAndNotify];
    [[NSNotificationCenter defaultCenter] addObserver: self
                                             selector: @selector(ydtunOutputReceived:)
                                                 name: NSFileHandleDataAvailableNotification
                                               object: readHandle];

    @try {
        [ydtunTask launch];
    } @catch (NSException * exception) {
        [self logMessage: [NSString stringWithFormat: @"Failed to launch ydtun: %@", exception]];
        [ydtunTask release];
        ydtunTask = nil;
        localPort = 0;
        apiPort = 0;
        return 0;
    }

    [self logMessage: [NSString stringWithFormat: @"ydtun launched with PID %d", [ydtunTask processIdentifier]]];

    // Step 1: Wait for API port to become available (10s timeout)
    if ( ! [self waitForPort: apiPort timeout: 10.0] ) {
        [self logMessage: [NSString stringWithFormat: @"API port %u did not become available in time", apiPort]];
        [self stop];
        return 0;
    }
    [self logMessage: [NSString stringWithFormat: @"API port %u is ready", apiPort]];

    // Step 2: Wait for KCP tunnel readiness (blocks up to 130s)
    if ( ! [self waitForKcpAlive] ) {
        [self logMessage: @"KCP tunnel did not become ready"];
        [self stop];
        return 0;
    }

    // Step 3: Verify end-to-end OpenVPN reachability through the proxy (30s timeout).
    // A simple TCP connect succeeds as soon as ydtun binds the port, even before the
    // upstream server is reachable — do the real HARD_RESET handshake instead.
    if ( ! [self waitForOpenVPNHandshake: localPort timeout: 30.0] ) {
        [self logMessage: [NSString stringWithFormat: @"OpenVPN handshake via proxy port %u failed", localPort]];
        [self stop];
        return 0;
    }

    [self logMessage: [NSString stringWithFormat: @"ydtun is ready on proxy port %u", localPort]];
    isRunning = YES;

    return localPort;
}

- (void) stop {

    [[NSNotificationCenter defaultCenter] removeObserver: self
                                                    name: NSFileHandleDataAvailableNotification
                                                  object: nil];

    if ( ydtunTask && [ydtunTask isRunning] ) {
        [self logMessage: [NSString stringWithFormat: @"Stopping ydtun (PID %d)", [ydtunTask processIdentifier]]];
        [ydtunTask terminate];

        // Wait briefly for termination
        dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC);
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);

        NSTask * taskRef = [ydtunTask retain];
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [taskRef waitUntilExit];
            dispatch_semaphore_signal(sem);
            [taskRef release];
        });

        if ( dispatch_semaphore_wait(sem, timeout) != 0 ) {
            [self logMessage: @"ydtun did not exit gracefully, force killing"];
            kill([ydtunTask processIdentifier], SIGKILL);
        }

        dispatch_release(sem);
    }

    if ( ydtunTask ) {
        [ydtunTask release];
        ydtunTask = nil;
    }

    localPort = 0;
    apiPort = 0;
    isRunning = NO;
}

- (void) ydtunOutputReceived: (NSNotification *) notification {

    NSFileHandle * handle = [notification object];
    NSData * data = [handle availableData];

    if ( [data length] > 0 ) {
        NSString * output = [[NSString alloc] initWithData: data encoding: NSUTF8StringEncoding];
        if ( output ) {
            // Split into lines and log each one (ydtun outputs multi-line chunks)
            NSArray * lines = [output componentsSeparatedByString: @"\n"];
            for ( NSString * line in lines ) {
                NSString * trimmed = [line stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if ( [trimmed length] > 0 ) {
                    [self logMessage: trimmed];
                }
            }
            [output release];
        }
        [handle waitForDataInBackgroundAndNotify];
    }
}

@end
