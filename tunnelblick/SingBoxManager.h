/*
 *  SingBoxManager.h
 *  Tunnelblick
 *
 *  Manages the sing-box VLESS/Reality proxy process for wrapping OpenVPN traffic.
 */

#import <Foundation/Foundation.h>

@interface SingBoxManager : NSObject {
    NSTask       * singBoxTask;
    unsigned int   localPort;
    NSString     * configFilePath;
    NSString     * singBoxBinaryPath;
    NSString     * ovpnTempConfigPath;
    BOOL           isRunning;
}

// Sing-box connection parameters (parsed from .ovpn sb_* directives)
@property (nonatomic, copy)   NSString * overrideAddress;
@property (nonatomic, copy)   NSString * overridePort;
@property (nonatomic, copy)   NSString * serverPort;
@property (nonatomic, copy)   NSString * uuid;
@property (nonatomic, copy)   NSString * tlsServerName;
@property (nonatomic, copy)   NSString * tlsPublicKey;
@property (nonatomic, copy)   NSString * tlsShortId;
@property (nonatomic, copy)   NSString * originalRemoteAddress;
@property (nonatomic, copy)   NSString * originalRemotePort;

// SOCKS proxy parameters
@property (nonatomic, assign) BOOL       socksEnabled;
@property (nonatomic, copy)   NSString * socksHost;
@property (nonatomic, copy)   NSString * socksPort;
@property (nonatomic, copy)   NSString * socksUsername;
@property (nonatomic, copy)   NSString * socksPassword;

@property (nonatomic, readonly) unsigned int localPort;
@property (nonatomic, readonly) BOOL isRunning;

// Extract sb_ key and parts from a line. Supports both "sb_key value" and "setenv sb_key value".
// Returns nil if the line is not an sb_ directive.
+ (NSArray *) sbPartsFromLine: (NSString *) trimmedLine;

// Returns YES if the line is a Tunnelblick custom directive (sb_* or tb_*, bare or setenv).
+ (BOOL) isTunnelblickDirective: (NSString *) trimmedLine;

// Parse sb_*/tb_* directives from OpenVPN config string. Returns YES if sb_enable is true.
// Supports both bare "sb_key value" and "setenv sb_key value" / "setenv tb_key value" formats.
+ (BOOL) parseSingBoxDirectivesFromConfig: (NSString *) configContents
                          intoPreferences: (NSMutableDictionary *) prefs;

// Strip sb_*/tb_* lines from config content and return cleaned config.
// Also extracts the original 'remote' address/port.
+ (NSString *) stripSingBoxDirectivesFromConfig: (NSString *) configContents
                              remoteAddress: (NSString **) remoteAddr
                                 remotePort: (NSString **) remotePort;

// Create a modified config with remote replaced for sing-box proxy
+ (NSString *) modifyConfigForSingBox: (NSString *) configContents
                        singBoxPort: (unsigned int) port;

// Initialize with sing-box parameters from preferences
- (instancetype) initWithDisplayName: (NSString *) displayName;

// Start the sing-box process. Returns the local port, or 0 on failure.
- (unsigned int) start;

// Stop the sing-box process.
- (void) stop;

// Generate the sing-box JSON configuration
- (NSString *) generateConfig;

@end
