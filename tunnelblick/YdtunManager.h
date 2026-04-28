/*
 *  YdtunManager.h
 *  Tunnelblick
 *
 *  Manages the ydtun (Telemost/WebRTC) proxy process for wrapping OpenVPN traffic.
 *  Architecture: OpenVPN -> TCP -> 127.0.0.1:{localPort} -> ydtun -> WebRTC/KCP -> Telemost TURN -> VPN server
 */

#import <Foundation/Foundation.h>

@interface YdtunManager : NSObject {
    NSTask       * ydtunTask;
    unsigned int   localPort;     // Port-forward proxy port (OpenVPN connects here)
    unsigned int   apiPort;       // API port for health checks and KCP status
    NSString     * ydtunBinaryPath;
    BOOL           isRunning;
}

// Ydtun connection parameters (parsed from .ovpn telemost_* directives)
@property (nonatomic, copy)   NSString * telemostUrls;         // Required: comma-separated Telemost meeting URLs
@property (nonatomic, copy)   NSString * tunnelKey;            // Optional: encryption key (hex or passphrase) for ChaCha20
@property (nonatomic, assign) BOOL       forceTcpRelay;        // Optional: force TURN TCP relay instead of UDP
@property (nonatomic, assign) int        logLevel;             // Optional: 0=info, 1=debug, 2=trace
@property (nonatomic, copy)   void (^logBlock)(NSString *);    // Optional: callback for writing to VPNConnection journal

@property (nonatomic, readonly) unsigned int localPort;
@property (nonatomic, readonly) unsigned int apiPort;
@property (nonatomic, readonly) BOOL isRunning;

// Extract telemost_ key and parts from a line. Supports both "telemost_key value" and "setenv telemost_key value".
// Returns nil if the line is not a telemost_ directive.
+ (NSArray *) telemostPartsFromLine: (NSString *) trimmedLine;

// Returns YES if the line is a telemost_ directive (bare or setenv).
+ (BOOL) isYdtunDirective: (NSString *) trimmedLine;

// Parse telemost_* directives from OpenVPN config string. Returns YES if telemost_enable is true,
// but does not store that value in preferences; GUI mode selection is controlled by Connection Type.
+ (BOOL) parseYdtunDirectivesFromConfig: (NSString *) configContents
                         intoPreferences: (NSMutableDictionary *) prefs;

// Initialize with ydtun parameters from preferences
- (instancetype) initWithDisplayName: (NSString *) displayName;

// Start the ydtun process. Returns the local proxy port, or 0 on failure.
// This includes waiting for API port, KCP readiness, and proxy port.
- (unsigned int) start;

// Stop the ydtun process.
- (void) stop;

// Check if KCP tunnel is alive (non-blocking, for health display). Returns YES if alive.
- (BOOL) checkAlive;

@end
