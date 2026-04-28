/*
 *  SingBoxManager.m
 *  Tunnelblick
 *
 *  Manages the sing-box VLESS/Reality proxy process for wrapping OpenVPN traffic.
 */

#import "SingBoxManager.h"
#import "helper.h"
#import "defines.h"
#import "TBUserDefaults.h"

#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>

extern TBUserDefaults * gTbDefaults;

@implementation SingBoxManager

@synthesize overrideAddress;
@synthesize overridePort;
@synthesize serverPort;
@synthesize uuid;
@synthesize tlsServerName;
@synthesize tlsPublicKey;
@synthesize tlsShortId;
@synthesize originalRemoteAddress;
@synthesize originalRemotePort;
@synthesize originalProto;
@synthesize socksEnabled;
@synthesize socksHost;
@synthesize socksPort;
@synthesize socksUsername;
@synthesize socksPassword;
@synthesize localPort;
@synthesize isRunning;
@synthesize logBlock;

- (void) logMessage: (NSString *) msg {
    NSLog(@"SingBoxManager: %@", msg);
    if ( logBlock ) {
        logBlock([NSString stringWithFormat: @"*sing-box: %@", msg]);
    }
}

// Extracts sb_ key and remaining parts from a line.
// Supports three formats:
//   "sb_key value ..."              (legacy bare format)
//   "setenv sb_key value ..."       (preferred setenv format)
//   "setenv-safe sb_key value ..."  (alternative setenv-safe format)
// Returns nil if the line is not an sb_ directive.
+ (NSArray *) sbPartsFromLine: (NSString *) trimmedLine {

    NSArray * parts = [trimmedLine componentsSeparatedByCharactersInSet: [NSCharacterSet whitespaceCharacterSet]];
    NSMutableArray * nonEmpty = [NSMutableArray array];
    for ( NSString * p in parts ) {
        if ( [p length] > 0 ) [nonEmpty addObject: p];
    }
    if ( [nonEmpty count] < 2 ) return nil;

    // "setenv sb_key value ..." or "setenv-safe sb_key value ..."
    NSString * first = [nonEmpty objectAtIndex: 0];
    if (   ( [first isEqualToString: @"setenv"] || [first isEqualToString: @"setenv-safe"] )
        && [nonEmpty count] >= 3
        && [[nonEmpty objectAtIndex: 1] hasPrefix: @"sb_"] ) {
        // Return array starting from sb_key (drop "setenv"/"setenv-safe")
        return [nonEmpty subarrayWithRange: NSMakeRange(1, [nonEmpty count] - 1)];
    }

    // "sb_key value ..."
    if ( [first hasPrefix: @"sb_"] ) {
        return [[nonEmpty copy] autorelease];
    }

    return nil;
}

// Returns YES if the trimmed line is a custom directive (sb_*, tb_*, or telemost_*, bare or setenv).
+ (BOOL) isTunnelblickDirective: (NSString *) trimmedLine {

    if ( [trimmedLine hasPrefix: @"sb_"] ) return YES;
    if ( [trimmedLine hasPrefix: @"telemost_"] ) return YES;

    if ( [trimmedLine hasPrefix: @"setenv "] || [trimmedLine hasPrefix: @"setenv-safe "] ) {
        NSArray * parts = [trimmedLine componentsSeparatedByCharactersInSet: [NSCharacterSet whitespaceCharacterSet]];
        NSMutableArray * nonEmpty = [NSMutableArray array];
        for ( NSString * p in parts ) {
            if ( [p length] > 0 ) [nonEmpty addObject: p];
        }
        if ( [nonEmpty count] >= 2 ) {
            NSString * envName = [nonEmpty objectAtIndex: 1];
            if ( [envName hasPrefix: @"sb_"] || [envName hasPrefix: @"tb_"] || [envName hasPrefix: @"telemost_"] ) return YES;
        }
    }

    return NO;
}

+ (BOOL) parseSingBoxDirectivesFromConfig: (NSString *) configContents
                          intoPreferences: (NSMutableDictionary *) prefs {

    if ( ! configContents ) return NO;

    NSArray * lines = [configContents componentsSeparatedByString: @"\n"];
    BOOL sbEnable = NO;

    for ( NSString * line in lines ) {
        NSString * trimmed = [line stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceAndNewlineCharacterSet]];

        // Parse sb_* directives (both bare and setenv formats)
        NSArray * sbParts = [self sbPartsFromLine: trimmed];
        if ( sbParts && [sbParts count] >= 2 ) {
            NSString * key = [sbParts objectAtIndex: 0];
            NSString * value = [sbParts objectAtIndex: 1];

            if ( [key isEqualToString: @"sb_enable"] ) {
                sbEnable = ( [value caseInsensitiveCompare: @"true"] == NSOrderedSame
                            || [value isEqualToString: @"1"] );
            } else if ( [key isEqualToString: @"sb_override_address"] ) {
                [prefs setObject: value forKey: @"singBoxOverrideAddress"];
            } else if ( [key isEqualToString: @"sb_override_port"] ) {
                [prefs setObject: value forKey: @"singBoxOverridePort"];
            } else if ( [key isEqualToString: @"sb_server_port"] ) {
                [prefs setObject: value forKey: @"singBoxServerPort"];
            } else if ( [key isEqualToString: @"sb_uuid"] ) {
                [prefs setObject: value forKey: @"singBoxUUID"];
            } else if ( [key isEqualToString: @"sb_tls_server_name"] ) {
                [prefs setObject: value forKey: @"singBoxTlsServerName"];
            } else if ( [key isEqualToString: @"sb_tls_public_key"] ) {
                [prefs setObject: value forKey: @"singBoxTlsPublicKey"];
            } else if ( [key isEqualToString: @"sb_tls_short_id"] ) {
                [prefs setObject: value forKey: @"singBoxTlsShortId"];
            } else if ( [key isEqualToString: @"sb_ws_server_name"] ) {
                [prefs setObject: value forKey: @"singBoxWsServerName"];
            } else if ( [key isEqualToString: @"sb_ws_path"] ) {
                [prefs setObject: value forKey: @"singBoxWsPath"];
            } else if ( [key isEqualToString: @"sb_hy2_password"] ) {
                [prefs setObject: value forKey: @"singBoxHy2Password"];
            } else if ( [key isEqualToString: @"sb_hy2_server_name"] ) {
                [prefs setObject: value forKey: @"singBoxHy2ServerName"];
            } else if ( [key isEqualToString: @"sb_hy2_obfs_type"] ) {
                [prefs setObject: value forKey: @"singBoxHy2ObfsType"];
            } else if ( [key isEqualToString: @"sb_hy2_obfs_password"] ) {
                [prefs setObject: value forKey: @"singBoxHy2ObfsPassword"];
            } else if ( [key isEqualToString: @"sb_socks_enabled"] ) {
                BOOL enabled = ( [value caseInsensitiveCompare: @"true"] == NSOrderedSame
                                || [value isEqualToString: @"1"] );
                [prefs setObject: [NSNumber numberWithBool: enabled] forKey: @"singBoxSocksEnabled"];
            } else if ( [key isEqualToString: @"sb_socks_host"] ) {
                [prefs setObject: value forKey: @"singBoxSocksHost"];
            } else if ( [key isEqualToString: @"sb_socks_port"] ) {
                [prefs setObject: value forKey: @"singBoxSocksPort"];
            } else if ( [key isEqualToString: @"sb_socks_username"] ) {
                [prefs setObject: value forKey: @"singBoxSocksUsername"];
            } else if ( [key isEqualToString: @"sb_socks_password"] ) {
                [prefs setObject: value forKey: @"singBoxSocksPassword"];
            } else if ( [key isEqualToString: @"sb_socks_proxy"] ) {
                // Legacy format: sb_socks_proxy host port [username password]
                if ( [sbParts count] >= 3 ) {
                    [prefs setObject: [sbParts objectAtIndex: 1] forKey: @"singBoxSocksHost"];
                    [prefs setObject: [sbParts objectAtIndex: 2] forKey: @"singBoxSocksPort"];
                }
                if ( [sbParts count] >= 5 ) {
                    [prefs setObject: [sbParts objectAtIndex: 3] forKey: @"singBoxSocksUsername"];
                    [prefs setObject: [sbParts objectAtIndex: 4] forKey: @"singBoxSocksPassword"];
                }
            }
            continue;
        }

        // Parse tb_* directives via setenv/setenv-safe (e.g. "setenv tb_allow_manual_dns_override true")
        if ( [trimmed hasPrefix: @"setenv "] || [trimmed hasPrefix: @"setenv-safe "] ) {
            NSArray * parts = [trimmed componentsSeparatedByCharactersInSet: [NSCharacterSet whitespaceCharacterSet]];
            NSMutableArray * nonEmpty = [NSMutableArray array];
            for ( NSString * p in parts ) {
                if ( [p length] > 0 ) [nonEmpty addObject: p];
            }
            if ( [nonEmpty count] >= 3 && [[nonEmpty objectAtIndex: 1] hasPrefix: @"tb_"] ) {
                NSString * tbKey = [nonEmpty objectAtIndex: 1];
                NSString * tbValue = [nonEmpty objectAtIndex: 2];

                if ( [tbKey isEqualToString: @"tb_allow_manual_dns_override"] ) {
                    BOOL allow = ( [tbValue caseInsensitiveCompare: @"true"] == NSOrderedSame
                                  || [tbValue isEqualToString: @"1"] );
                    [prefs setObject: [NSNumber numberWithBool: allow] forKey: @"allowChangesToManuallySetNetworkSettings"];
                }
            }
        }
    }

    return sbEnable;
}

+ (NSString *) stripSingBoxDirectivesFromConfig: (NSString *) configContents
                              remoteAddress: (NSString **) remoteAddr
                                 remotePort: (NSString **) remotePort
                                      proto: (NSString **) proto {

    if ( ! configContents ) return configContents;

    NSMutableArray * cleanedLines = [NSMutableArray array];
    NSArray * lines = [configContents componentsSeparatedByString: @"\n"];

    for ( NSString * line in lines ) {
        NSString * trimmed = [line stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceAndNewlineCharacterSet]];

        if ( [self isTunnelblickDirective: trimmed] ) {
            continue; // skip sb_*/tb_ directives (both bare and setenv)
        }

        // Extract remote address/port (and proto suffix, if present on the remote line)
        if ( [trimmed hasPrefix: @"remote "] ) {
            NSArray * parts = [trimmed componentsSeparatedByCharactersInSet: [NSCharacterSet whitespaceCharacterSet]];
            // Filter empty strings from split
            NSMutableArray * nonEmpty = [NSMutableArray array];
            for ( NSString * p in parts ) {
                if ( [p length] > 0 ) [nonEmpty addObject: p];
            }
            if ( [nonEmpty count] >= 2 && remoteAddr ) {
                *remoteAddr = [nonEmpty objectAtIndex: 1];
            }
            if ( [nonEmpty count] >= 3 && remotePort ) {
                *remotePort = [nonEmpty objectAtIndex: 2];
            }
            if ( [nonEmpty count] >= 4 && proto && *proto == nil ) {
                NSString * p = [[nonEmpty objectAtIndex: 3] lowercaseString];
                if ( [p hasPrefix: @"tcp"] ) {
                    *proto = @"tcp";
                } else if ( [p hasPrefix: @"udp"] ) {
                    *proto = @"udp";
                }
            }
        }

        // Extract top-level 'proto' directive (lower priority than a per-remote proto suffix
        // only captures if not already set).
        if ( [trimmed hasPrefix: @"proto "] && proto && *proto == nil ) {
            NSArray * parts = [trimmed componentsSeparatedByCharactersInSet: [NSCharacterSet whitespaceCharacterSet]];
            NSMutableArray * nonEmpty = [NSMutableArray array];
            for ( NSString * p in parts ) {
                if ( [p length] > 0 ) [nonEmpty addObject: p];
            }
            if ( [nonEmpty count] >= 2 ) {
                NSString * p = [[nonEmpty objectAtIndex: 1] lowercaseString];
                if ( [p hasPrefix: @"tcp"] ) {
                    *proto = @"tcp";
                } else if ( [p hasPrefix: @"udp"] ) {
                    *proto = @"udp";
                }
            }
        }

        [cleanedLines addObject: line];
    }

    return [cleanedLines componentsJoinedByString: @"\n"];
}

+ (NSString *) modifyConfigForSingBox: (NSString *) configContents
                        singBoxPort: (unsigned int) port {

    if ( ! configContents || port == 0 ) return configContents;

    NSMutableArray * resultLines = [NSMutableArray array];
    NSArray * lines = [configContents componentsSeparatedByString: @"\n"];
    BOOL remoteReplaced = NO;

    for ( NSString * line in lines ) {
        NSString * trimmed = [line stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceAndNewlineCharacterSet]];

        // Remove sb_*/tb_ directives (both bare and setenv)
        if ( [SingBoxManager isTunnelblickDirective: trimmed] ) {
            continue;
        }

        // Replace first 'remote' directive
        if ( [trimmed hasPrefix: @"remote "] && ! remoteReplaced ) {
            [resultLines addObject: [NSString stringWithFormat: @"remote 127.0.0.1 %u tcp-client", port]];
            remoteReplaced = YES;
            continue;
        }

        // Replace 'proto' directive to force TCP
        if ( [trimmed hasPrefix: @"proto "] ) {
            [resultLines addObject: @"proto tcp"];
            continue;
        }

        [resultLines addObject: line];
    }

    return [resultLines componentsJoinedByString: @"\n"];
}

- (instancetype) initWithDisplayName: (NSString *) displayName {

    self = [super init];
    if ( ! self ) return nil;

    localPort = 0;
    isRunning = NO;
    singBoxTask = nil;
    configFilePath = nil;
    ovpnTempConfigPath = nil;

    // Find sing-box binary in app bundle Resources
    singBoxBinaryPath = [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent: @"sing-box"];
    [singBoxBinaryPath retain];

    // Load parameters from preferences
    NSString * prefix = [displayName stringByAppendingString: @"-"];

    self.overrideAddress = [gTbDefaults stringForKey: [prefix stringByAppendingString: @"singBoxOverrideAddress"]];
    self.overridePort = [gTbDefaults stringForKey: [prefix stringByAppendingString: @"singBoxOverridePort"]];
    self.serverPort = [gTbDefaults stringForKey: [prefix stringByAppendingString: @"singBoxServerPort"]];
    self.uuid = [gTbDefaults stringForKey: [prefix stringByAppendingString: @"singBoxUUID"]];
    self.tlsServerName = [gTbDefaults stringForKey: [prefix stringByAppendingString: @"singBoxTlsServerName"]];
    self.tlsPublicKey = [gTbDefaults stringForKey: [prefix stringByAppendingString: @"singBoxTlsPublicKey"]];
    self.tlsShortId = [gTbDefaults stringForKey: [prefix stringByAppendingString: @"singBoxTlsShortId"]];
    self.originalRemoteAddress = [gTbDefaults stringForKey: [prefix stringByAppendingString: @"singBoxOriginalRemoteAddress"]];
    self.originalRemotePort = [gTbDefaults stringForKey: [prefix stringByAppendingString: @"singBoxOriginalRemotePort"]];
    self.originalProto = [gTbDefaults stringForKey: [prefix stringByAppendingString: @"singBoxOriginalProto"]];

    self.socksEnabled = [gTbDefaults boolForKey: [prefix stringByAppendingString: @"singBoxSocksEnabled"]];
    self.socksHost = [gTbDefaults stringForKey: [prefix stringByAppendingString: @"singBoxSocksHost"]];
    self.socksPort = [gTbDefaults stringForKey: [prefix stringByAppendingString: @"singBoxSocksPort"]];
    self.socksUsername = [gTbDefaults stringForKey: [prefix stringByAppendingString: @"singBoxSocksUsername"]];
    self.socksPassword = [gTbDefaults stringForKey: [prefix stringByAppendingString: @"singBoxSocksPassword"]];

    return self;
}

- (void) dealloc {

    [self stop];
    [singBoxBinaryPath release];
    [configFilePath release];
    [ovpnTempConfigPath release];
    self.overrideAddress = nil;
    self.overridePort = nil;
    self.serverPort = nil;
    self.uuid = nil;
    self.tlsServerName = nil;
    self.tlsPublicKey = nil;
    self.tlsShortId = nil;
    self.originalRemoteAddress = nil;
    self.originalRemotePort = nil;
    self.originalProto = nil;
    self.socksHost = nil;
    self.socksPort = nil;
    self.socksUsername = nil;
    self.socksPassword = nil;
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

// OpenVPN opcode bytes (upper 5 bits of first control-packet byte).
// HARD_RESET_CLIENT_V2 = opcode 7 << 3 = 0x38
// HARD_RESET_SERVER_V2 = opcode 8 << 3 = 0x40
#define OPENVPN_HARD_RESET_CLIENT_V2_OPCODE_BYTE ((uint8_t)0x38)
#define OPENVPN_HARD_RESET_SERVER_V2_OPCODE_BYTE ((uint8_t)0x40)
#define OPENVPN_HARD_RESET_V2_PAYLOAD_LEN        ((size_t)14)

// Build a 14-byte HARD_RESET_CLIENT_V2 payload (no transport framing).
// Layout: [opcode/key_id(1)] [session_id(8, random)] [packet_id_array_len=0(1)] [message_packet_id=0(4 BE)]
static void singbox_build_hard_reset_payload(uint8_t out[OPENVPN_HARD_RESET_V2_PAYLOAD_LEN]) {
    memset(out, 0, OPENVPN_HARD_RESET_V2_PAYLOAD_LEN);
    out[0] = OPENVPN_HARD_RESET_CLIENT_V2_OPCODE_BYTE;
    arc4random_buf(out + 1, 8);
    // bytes [9..14] already zero
}

// Returns ms remaining until deadline, clamped to [0, maxMs].
static long long singbox_remaining_ms(uint64_t deadlineNs, long long maxMs) {
    uint64_t nowNs = clock_gettime_nsec_np(CLOCK_MONOTONIC);
    if ( nowNs >= deadlineNs ) return 0;
    long long remMs = (long long)((deadlineNs - nowNs) / 1000000ULL);
    if ( maxMs >= 0 && remMs > maxMs ) remMs = maxMs;
    return remMs;
}

// TCP OpenVPN handshake probe: connect, send length-prefixed HARD_RESET_CLIENT_V2,
// expect HARD_RESET_SERVER_V2 opcode byte within the deadline.
- (BOOL) probeOpenVPNTcpPort: (unsigned int) port deadlineNs: (uint64_t) deadlineNs {

    int sock = socket(AF_INET, SOCK_STREAM, 0);
    if ( sock < 0 ) return NO;

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons(port);

    // Use blocking sockets with SO_SNDTIMEO / SO_RCVTIMEO driven by the deadline.
    long long connectMs = singbox_remaining_ms(deadlineNs, 2000);
    if ( connectMs == 0 ) { close(sock); return NO; }
    struct timeval tv;
    tv.tv_sec = (time_t)(connectMs / 1000);
    tv.tv_usec = (suseconds_t)((connectMs % 1000) * 1000);
    setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

    if ( connect(sock, (struct sockaddr *)&addr, sizeof(addr)) != 0 ) {
        close(sock);
        return NO;
    }

    // Build 16-byte packet: 2-byte length prefix (14, BE) + 14-byte payload
    uint8_t packet[2 + OPENVPN_HARD_RESET_V2_PAYLOAD_LEN];
    uint16_t lenBE = htons((uint16_t)OPENVPN_HARD_RESET_V2_PAYLOAD_LEN);
    memcpy(packet, &lenBE, 2);
    singbox_build_hard_reset_payload(packet + 2);

    long long writeMs = singbox_remaining_ms(deadlineNs, 1000);
    if ( writeMs == 0 ) { close(sock); return NO; }
    tv.tv_sec = (time_t)(writeMs / 1000);
    tv.tv_usec = (suseconds_t)((writeMs % 1000) * 1000);
    setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

    ssize_t sent = send(sock, packet, sizeof(packet), 0);
    if ( sent != (ssize_t)sizeof(packet) ) {
        close(sock);
        return NO;
    }

    long long readMs = singbox_remaining_ms(deadlineNs, -1);
    if ( readMs == 0 ) { close(sock); return NO; }
    tv.tv_sec = (time_t)(readMs / 1000);
    tv.tv_usec = (suseconds_t)((readMs % 1000) * 1000);
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    // Need 2 bytes length prefix + 1 byte opcode = 3 bytes minimum
    uint8_t buf[3];
    size_t filled = 0;
    while ( filled < sizeof(buf) ) {
        ssize_t n = recv(sock, buf + filled, sizeof(buf) - filled, 0);
        if ( n <= 0 ) { close(sock); return NO; }
        filled += (size_t)n;
    }
    close(sock);

    return ( buf[2] == OPENVPN_HARD_RESET_SERVER_V2_OPCODE_BYTE );
}

// UDP OpenVPN handshake probe: send HARD_RESET_CLIENT_V2 datagram, expect HARD_RESET_SERVER_V2 back.
- (BOOL) probeOpenVPNUdpPort: (unsigned int) port deadlineNs: (uint64_t) deadlineNs {

    int sock = socket(AF_INET, SOCK_DGRAM, 0);
    if ( sock < 0 ) return NO;

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons(port);

    if ( connect(sock, (struct sockaddr *)&addr, sizeof(addr)) != 0 ) {
        close(sock);
        return NO;
    }

    long long writeMs = singbox_remaining_ms(deadlineNs, 1000);
    if ( writeMs == 0 ) { close(sock); return NO; }
    struct timeval tv;
    tv.tv_sec = (time_t)(writeMs / 1000);
    tv.tv_usec = (suseconds_t)((writeMs % 1000) * 1000);
    setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

    uint8_t payload[OPENVPN_HARD_RESET_V2_PAYLOAD_LEN];
    singbox_build_hard_reset_payload(payload);

    if ( send(sock, payload, sizeof(payload), 0) != (ssize_t)sizeof(payload) ) {
        close(sock);
        return NO;
    }

    long long readMs = singbox_remaining_ms(deadlineNs, -1);
    if ( readMs == 0 ) { close(sock); return NO; }
    tv.tv_sec = (time_t)(readMs / 1000);
    tv.tv_usec = (suseconds_t)((readMs % 1000) * 1000);
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    uint8_t buf[1500];
    ssize_t n = recv(sock, buf, sizeof(buf), 0);
    close(sock);
    if ( n < 1 ) return NO;

    return ( buf[0] == OPENVPN_HARD_RESET_SERVER_V2_OPCODE_BYTE );
}

- (BOOL) probePort: (unsigned int) port {

    // Per-attempt deadline: 2 seconds for the full handshake round-trip.
    uint64_t deadlineNs = clock_gettime_nsec_np(CLOCK_MONOTONIC) + 2ULL * 1000000000ULL;

    BOOL wantUdp = ( self.originalProto && [[self.originalProto lowercaseString] isEqualToString: @"udp"] );
    if ( wantUdp ) {
        return [self probeOpenVPNUdpPort: port deadlineNs: deadlineNs];
    }
    return [self probeOpenVPNTcpPort: port deadlineNs: deadlineNs];
}

- (BOOL) waitForPort: (unsigned int) port timeout: (NSTimeInterval) timeout {

    // Poll for port readiness while keeping the run loop alive so UI doesn't freeze.
    NSDate * deadline = [NSDate dateWithTimeIntervalSinceNow: timeout];

    while ( [[NSDate date] compare: deadline] == NSOrderedAscending ) {
        // Check if process is still running
        if ( singBoxTask && ! [singBoxTask isRunning] ) {
            [self logMessage: @"sing-box process died while waiting for port"];
            return NO;
        }

        if ( [self probePort: port] ) {
            return YES;
        }

        // Run the main run loop briefly to keep UI responsive while waiting
        [[NSRunLoop currentRunLoop] runUntilDate: [NSDate dateWithTimeIntervalSinceNow: 0.2]];
    }

    [self logMessage: [NSString stringWithFormat: @"Timed out waiting for port %u", port]];
    return NO;
}

- (NSString *) generateConfig {

    unsigned int effectiveOverridePort = 1194;
    if ( self.overridePort && [self.overridePort length] > 0 ) {
        effectiveOverridePort = (unsigned int)[self.overridePort intValue];
    } else if ( self.originalRemotePort && [self.originalRemotePort length] > 0 ) {
        effectiveOverridePort = (unsigned int)[self.originalRemotePort intValue];
    }

    unsigned int effectiveServerPort = 443;
    if ( self.serverPort && [self.serverPort length] > 0 ) {
        effectiveServerPort = (unsigned int)[self.serverPort intValue];
    }

    NSString * serverAddress = self.originalRemoteAddress;
    if ( ! serverAddress || [serverAddress length] == 0 ) {
        serverAddress = self.overrideAddress;
    }

    NSString * overrideAddr = self.overrideAddress;
    if ( ! overrideAddr || [overrideAddr length] == 0 ) {
        overrideAddr = serverAddress;
    }

    // Build VLESS outbound
    NSMutableDictionary * vlessOutbound = [NSMutableDictionary dictionaryWithDictionary: @{
        @"type": @"vless",
        @"tag": @"vless-out",
        @"server": serverAddress ? serverAddress : @"",
        @"server_port": [NSNumber numberWithUnsignedInt: effectiveServerPort],
        @"uuid": self.uuid ? self.uuid : @"",
        @"flow": @"",
        @"tls": @{
            @"enabled": @YES,
            @"server_name": self.tlsServerName ? self.tlsServerName : @"",
            @"reality": @{
                @"enabled": @YES,
                @"public_key": self.tlsPublicKey ? self.tlsPublicKey : @"",
                @"short_id": self.tlsShortId ? self.tlsShortId : @""
            },
            @"utls": @{
                @"enabled": @YES,
                @"fingerprint": @"chrome"
            }
        }
    }];

    // Build outbounds array
    NSMutableArray * outbounds = [NSMutableArray array];

    if ( self.socksEnabled && self.socksHost && [self.socksHost length] > 0 ) {
        // Add detour to VLESS outbound to route through SOCKS proxy
        [vlessOutbound setObject: @"socks-proxy" forKey: @"detour"];

        // Build SOCKS proxy outbound
        NSMutableDictionary * socksOutbound = [NSMutableDictionary dictionaryWithDictionary: @{
            @"type": @"socks",
            @"tag": @"socks-proxy",
            @"server": self.socksHost,
            @"server_port": [NSNumber numberWithUnsignedInt: (unsigned int)([self.socksPort intValue] ?: 1080)]
        }];

        if ( self.socksUsername && [self.socksUsername length] > 0 ) {
            [socksOutbound setObject: self.socksUsername forKey: @"username"];
            if ( self.socksPassword ) {
                [socksOutbound setObject: self.socksPassword forKey: @"password"];
            }
        }

        [outbounds addObject: vlessOutbound];
        [outbounds addObject: socksOutbound];

        [self logMessage: [NSString stringWithFormat: @"SOCKS proxy enabled via %@:%@", self.socksHost, self.socksPort]];
    } else {
        [outbounds addObject: vlessOutbound];
    }

    // Use NSJSONSerialization to produce valid JSON (properly escapes special characters)
    NSDictionary * config = @{
        @"log": @{ @"level": @"warn" },
        @"inbounds": @[
            @{
                @"type": @"direct",
                @"listen": @"127.0.0.1",
                @"listen_port": [NSNumber numberWithUnsignedInt: localPort],
                @"network": ( self.originalProto && [self.originalProto length] > 0 ) ? self.originalProto : @"tcp",
                @"override_address": overrideAddr ? overrideAddr : @"",
                @"override_port": [NSNumber numberWithUnsignedInt: effectiveOverridePort]
            }
        ],
        @"outbounds": outbounds
    };

    NSError * error = nil;
    NSData * jsonData = [NSJSONSerialization dataWithJSONObject: config
                                                       options: NSJSONWritingPrettyPrinted
                                                         error: &error];
    if ( ! jsonData ) {
        [self logMessage: [NSString stringWithFormat: @"Failed to serialize config to JSON: %@", error]];
        return nil;
    }

    return [[[NSString alloc] initWithData: jsonData encoding: NSUTF8StringEncoding] autorelease];
}

- (unsigned int) start {

    [self stop]; // Stop any existing instance

    // Find free port
    localPort = [self findFreePort];
    if ( localPort == 0 ) {
        [self logMessage: @"Failed to find a free port"];
        return 0;
    }

    [self logMessage: [NSString stringWithFormat: @"Using local port %u", localPort]];

    // Generate config
    NSString * config = [self generateConfig];
    if ( ! config ) {
        [self logMessage: @"Failed to generate config"];
        localPort = 0;
        return 0;
    }

    // Write config to temp file
    NSString * tempDir = NSTemporaryDirectory();
    configFilePath = [[tempDir stringByAppendingPathComponent:
                       [NSString stringWithFormat: @"tunnelblick_singbox_%u.json", localPort]] retain];

    NSError * error = nil;
    if ( ! [config writeToFile: configFilePath atomically: YES encoding: NSUTF8StringEncoding error: &error] ) {
        [self logMessage: [NSString stringWithFormat: @"Failed to write config to %@: %@", configFilePath, error]];
        localPort = 0;
        return 0;
    }

    [self logMessage: [NSString stringWithFormat: @"Config written to %@", configFilePath]];
    [self logMessage: [NSString stringWithFormat: @"sing-box binary at %@", singBoxBinaryPath]];

    // Check if binary exists
    if ( ! [[NSFileManager defaultManager] fileExistsAtPath: singBoxBinaryPath] ) {
        [self logMessage: [NSString stringWithFormat: @"sing-box binary not found at %@", singBoxBinaryPath]];
        localPort = 0;
        return 0;
    }

    // Launch sing-box process
    singBoxTask = [[NSTask alloc] init];
    [singBoxTask setLaunchPath: singBoxBinaryPath];
    [singBoxTask setArguments: @[@"run", @"-c", configFilePath]];

    // Capture output for logging
    NSPipe * outputPipe = [NSPipe pipe];
    [singBoxTask setStandardOutput: outputPipe];
    [singBoxTask setStandardError: outputPipe];

    // Read output in background
    NSFileHandle * readHandle = [outputPipe fileHandleForReading];
    [readHandle waitForDataInBackgroundAndNotify];
    [[NSNotificationCenter defaultCenter] addObserver: self
                                             selector: @selector(singBoxOutputReceived:)
                                                 name: NSFileHandleDataAvailableNotification
                                               object: readHandle];

    @try {
        [singBoxTask launch];
    } @catch (NSException * exception) {
        [self logMessage: [NSString stringWithFormat: @"Failed to launch sing-box: %@", exception]];
        [singBoxTask release];
        singBoxTask = nil;
        localPort = 0;
        return 0;
    }

    [self logMessage: [NSString stringWithFormat: @"sing-box launched with PID %d", [singBoxTask processIdentifier]]];

    // Wait for port to become available
    if ( ! [self waitForPort: localPort timeout: 10.0] ) {
        [self logMessage: [NSString stringWithFormat: @"Port %u did not become available in time", localPort]];
        [self stop];
        return 0;
    }

    [self logMessage: [NSString stringWithFormat: @"sing-box is ready on port %u", localPort]];
    isRunning = YES;

    // Record the expected temp ovpn config path so we can clean it up on stop
    [ovpnTempConfigPath release];
    ovpnTempConfigPath = [[NSString stringWithFormat: @"/tmp/tunnelblick_sidecar_%u.ovpn", localPort] retain];

    return localPort;
}

- (void) stop {

    [[NSNotificationCenter defaultCenter] removeObserver: self
                                                    name: NSFileHandleDataAvailableNotification
                                                  object: nil];

    if ( singBoxTask && [singBoxTask isRunning] ) {
        [self logMessage: [NSString stringWithFormat: @"Stopping sing-box (PID %d)", [singBoxTask processIdentifier]]];
        [singBoxTask terminate];

        // Wait briefly for termination
        dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC);
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);

        NSTask * taskRef = [singBoxTask retain];
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [taskRef waitUntilExit];
            dispatch_semaphore_signal(sem);
            [taskRef release];
        });

        if ( dispatch_semaphore_wait(sem, timeout) != 0 ) {
            // Force kill if still running
            [self logMessage: @"sing-box did not exit gracefully, force killing"];
            kill([singBoxTask processIdentifier], SIGKILL);
        }

        dispatch_release(sem);
    }

    if ( singBoxTask ) {
        [singBoxTask release];
        singBoxTask = nil;
    }

    // Clean up temp sing-box JSON config file
    if ( configFilePath ) {
        [[NSFileManager defaultManager] removeItemAtPath: configFilePath error: nil];
        [configFilePath release];
        configFilePath = nil;
    }

    // Clean up temp OpenVPN config file created by tunnelblick-helper
    if ( ovpnTempConfigPath ) {
        [[NSFileManager defaultManager] removeItemAtPath: ovpnTempConfigPath error: nil];
        [ovpnTempConfigPath release];
        ovpnTempConfigPath = nil;
    }

    localPort = 0;
    isRunning = NO;
}

- (void) singBoxOutputReceived: (NSNotification *) notification {

    NSFileHandle * handle = [notification object];
    NSData * data = [handle availableData];

    if ( [data length] > 0 ) {
        NSString * output = [[NSString alloc] initWithData: data encoding: NSUTF8StringEncoding];
        if ( output ) {
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
