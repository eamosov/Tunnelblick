/*
 *  TrustedWiFiManager.h
 *  Tunnelblick
 *
 *  Manages trusted WiFi networks - automatically pauses VPN when connected
 *  to a trusted WiFi network and resumes when disconnected.
 */

#import <Foundation/Foundation.h>
#import <CoreWLAN/CoreWLAN.h>
#import <CoreLocation/CoreLocation.h>

@class VPNConnection;

@interface TrustedWiFiManager : NSObject <CWEventDelegate, CLLocationManagerDelegate> {
    CWWiFiClient      * wifiClient;
    CLLocationManager * locationManager;
    NSString          * currentSSID;
    BOOL                isPausedForTrustedWifi;
    BOOL                locationAuthorized;
}

@property (nonatomic, readonly) NSString * currentSSID;
@property (nonatomic, readonly) BOOL isPausedForTrustedWifi;
@property (nonatomic, readonly) BOOL locationAuthorized;

// Request location authorization (needed for SSID access on macOS 14+)
+ (void) requestLocationAuthorization;

// Get the current WiFi SSID (nil if not connected to WiFi or no location permission)
+ (NSString *) currentWiFiSSID;

// Check if the given SSID is in the trusted list for the given connection
+ (BOOL) isSSIDTrusted: (NSString *) ssid forDisplayName: (NSString *) displayName;

// Get the trusted WiFi list for a connection
+ (NSArray *) trustedWiFiListForDisplayName: (NSString *) displayName;

// Add an SSID to the trusted list
+ (void) addTrustedSSID: (NSString *) ssid forDisplayName: (NSString *) displayName;

// Remove an SSID from the trusted list
+ (void) removeTrustedSSID: (NSString *) ssid forDisplayName: (NSString *) displayName;

// Check if VPN should be paused (currently on trusted WiFi)
+ (BOOL) shouldPauseVPNForDisplayName: (NSString *) displayName;

// Check if location authorization is needed but not granted (trusted WiFi configured but SSID unavailable)
+ (BOOL) isLocationAuthorizationNeededForDisplayName: (NSString *) displayName;

// Shared instance for location management
+ (TrustedWiFiManager *) sharedManager;

// Start monitoring WiFi changes
- (void) startMonitoring;

// Stop monitoring WiFi changes
- (void) stopMonitoring;

@end
