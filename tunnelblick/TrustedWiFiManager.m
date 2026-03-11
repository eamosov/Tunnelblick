/*
 *  TrustedWiFiManager.m
 *  Tunnelblick
 *
 *  Manages trusted WiFi networks.
 */

#import "TrustedWiFiManager.h"
#import "TBUserDefaults.h"
#import "defines.h"

extern TBUserDefaults * gTbDefaults;

static TrustedWiFiManager * sharedInstance = nil;

@implementation TrustedWiFiManager

@synthesize currentSSID;
@synthesize isPausedForTrustedWifi;
@synthesize locationAuthorized;

+ (TrustedWiFiManager *) sharedManager {

    if ( ! sharedInstance ) {
        sharedInstance = [[TrustedWiFiManager alloc] init];
    }
    return sharedInstance;
}

+ (void) requestLocationAuthorization {

    TrustedWiFiManager * mgr = [self sharedManager];

    if ( ! mgr->locationManager ) {
        mgr->locationManager = [[CLLocationManager alloc] init];
        [mgr->locationManager setDelegate: mgr];
    }

    CLAuthorizationStatus status;
    if ( @available(macOS 11.0, *) ) {
        status = [mgr->locationManager authorizationStatus];
    } else {
        status = [CLLocationManager authorizationStatus];
    }

    if ( status == kCLAuthorizationStatusNotDetermined ) {
        NSLog(@"TrustedWiFiManager: Requesting location authorization for WiFi SSID access");
        [mgr->locationManager requestWhenInUseAuthorization];
    } else if ( status == kCLAuthorizationStatusAuthorizedAlways
                || status == kCLAuthorizationStatusAuthorized ) {
        mgr->locationAuthorized = YES;
        NSLog(@"TrustedWiFiManager: Location already authorized");
    } else {
        NSLog(@"TrustedWiFiManager: Location authorization denied (status=%d). Trusted WiFi SSID detection will not work.", (int)status);
    }
}

- (void) locationManagerDidChangeAuthorization: (CLLocationManager *) manager {

    CLAuthorizationStatus status;
    if ( @available(macOS 11.0, *) ) {
        status = [manager authorizationStatus];
    } else {
        status = [CLLocationManager authorizationStatus];
    }

    if ( status == kCLAuthorizationStatusAuthorizedAlways
         || status == kCLAuthorizationStatusAuthorized ) {
        locationAuthorized = YES;
        NSLog(@"TrustedWiFiManager: Location authorization granted - WiFi SSID access enabled");
    } else if ( status == kCLAuthorizationStatusDenied
                || status == kCLAuthorizationStatusRestricted ) {
        locationAuthorized = NO;
        NSLog(@"TrustedWiFiManager: Location authorization denied - WiFi SSID will not be available");
    }
}

+ (NSString *) currentWiFiSSID {

    CWWiFiClient * client = [CWWiFiClient sharedWiFiClient];
    if ( ! client ) return nil;

    CWInterface * interface = [client interface];
    if ( ! interface ) return nil;

    NSString * ssid = [interface ssid];
    if ( ! ssid || [ssid length] == 0 ) return nil;

    return ssid;
}

+ (BOOL) isSSIDTrusted: (NSString *) ssid forDisplayName: (NSString *) displayName {

    if ( ! ssid || [ssid length] == 0 ) return NO;

    NSArray * trustedList = [self trustedWiFiListForDisplayName: displayName];
    if ( ! trustedList || [trustedList count] == 0 ) return NO;

    for ( NSString * trusted in trustedList ) {
        if ( [trusted caseInsensitiveCompare: ssid] == NSOrderedSame ) {
            return YES;
        }
    }

    return NO;
}

+ (NSArray *) trustedWiFiListForDisplayName: (NSString *) displayName {

    NSString * key = [displayName stringByAppendingString: @"-trustedWiFiSSIDs"];
    NSArray * list = [gTbDefaults arrayForKey: key];
    return list;
}

+ (void) addTrustedSSID: (NSString *) ssid forDisplayName: (NSString *) displayName {

    if ( ! ssid || [ssid length] == 0 ) return;

    NSString * key = [displayName stringByAppendingString: @"-trustedWiFiSSIDs"];
    NSArray * existing = [gTbDefaults arrayForKey: key];
    NSMutableArray * list = existing ? [NSMutableArray arrayWithArray: existing] : [NSMutableArray array];

    // Don't add duplicates
    for ( NSString * item in list ) {
        if ( [item caseInsensitiveCompare: ssid] == NSOrderedSame ) {
            return;
        }
    }

    [list addObject: ssid];
    [gTbDefaults setObject: list forKey: key];
    NSLog(@"TrustedWiFiManager: Added '%@' to trusted WiFi list for %@", ssid, displayName);
}

+ (void) removeTrustedSSID: (NSString *) ssid forDisplayName: (NSString *) displayName {

    if ( ! ssid || [ssid length] == 0 ) return;

    NSString * key = [displayName stringByAppendingString: @"-trustedWiFiSSIDs"];
    NSArray * existing = [gTbDefaults arrayForKey: key];
    if ( ! existing ) return;

    NSMutableArray * list = [NSMutableArray arrayWithArray: existing];
    NSMutableIndexSet * toRemove = [NSMutableIndexSet indexSet];

    for ( NSUInteger i = 0; i < [list count]; i++ ) {
        if ( [[list objectAtIndex: i] caseInsensitiveCompare: ssid] == NSOrderedSame ) {
            [toRemove addIndex: i];
        }
    }

    [list removeObjectsAtIndexes: toRemove];
    [gTbDefaults setObject: list forKey: key];
    NSLog(@"TrustedWiFiManager: Removed '%@' from trusted WiFi list for %@", ssid, displayName);
}

+ (BOOL) shouldPauseVPNForDisplayName: (NSString *) displayName {

    NSArray * trustedList = [self trustedWiFiListForDisplayName: displayName];
    if ( ! trustedList || [trustedList count] == 0 ) {
        NSLog(@"TrustedWiFiManager: shouldPauseVPN: NO - no trusted list for '%@'", displayName);
        return NO;
    }

    NSString * ssid = [self currentWiFiSSID];
    if ( ! ssid ) {
        NSLog(@"TrustedWiFiManager: shouldPauseVPN: NO - current SSID is nil (trustedList=%@)", trustedList);
        return NO;
    }

    BOOL result = [self isSSIDTrusted: ssid forDisplayName: displayName];
    NSLog(@"TrustedWiFiManager: shouldPauseVPN: %@ - SSID='%@' trustedList=%@ for '%@'",
          result ? @"YES" : @"NO", ssid, trustedList, displayName);
    return result;
}

+ (BOOL) isLocationAuthorizationNeededForDisplayName: (NSString *) displayName {

    NSArray * trustedList = [self trustedWiFiListForDisplayName: displayName];
    if ( ! trustedList || [trustedList count] == 0 ) return NO;

    TrustedWiFiManager * mgr = [self sharedManager];

    if ( ! mgr->locationManager ) {
        mgr->locationManager = [[CLLocationManager alloc] init];
        [mgr->locationManager setDelegate: mgr];
    }

    CLAuthorizationStatus status;
    if ( @available(macOS 11.0, *) ) {
        status = [mgr->locationManager authorizationStatus];
    } else {
        status = [CLLocationManager authorizationStatus];
    }

    return ( status != kCLAuthorizationStatusAuthorizedAlways
             && status != kCLAuthorizationStatusAuthorized );
}

- (instancetype) init {

    self = [super init];
    if ( ! self ) return nil;

    wifiClient = nil;
    locationManager = nil;
    currentSSID = nil;
    isPausedForTrustedWifi = NO;
    locationAuthorized = NO;

    return self;
}

- (void) dealloc {

    [self stopMonitoring];
    if ( locationManager ) {
        [locationManager setDelegate: nil];
        [locationManager release];
    }
    [currentSSID release];
    [super dealloc];
}

- (void) startMonitoring {

    if ( wifiClient ) return; // Already monitoring

    // Ensure location authorization is requested
    [[self class] requestLocationAuthorization];

    wifiClient = [[CWWiFiClient sharedWiFiClient] retain];

    @try {
        [wifiClient setDelegate: self];
        [wifiClient startMonitoringEventWithType: CWEventTypeSSIDDidChange error: nil];

        // Get initial SSID
        NSString * ssid = [[self class] currentWiFiSSID];
        [currentSSID release];
        currentSSID = [ssid retain];

        NSLog(@"TrustedWiFiManager: Started monitoring WiFi. Current SSID: %@", currentSSID ? currentSSID : @"(none)");
    } @catch (NSException * exception) {
        NSLog(@"TrustedWiFiManager: Failed to start monitoring: %@", exception);
    }
}

- (void) stopMonitoring {

    if ( ! wifiClient ) return;

    @try {
        [wifiClient stopMonitoringAllEventsAndReturnError: nil];
        [wifiClient setDelegate: nil];
    } @catch (NSException * exception) {
        NSLog(@"TrustedWiFiManager: Error stopping monitoring: %@", exception);
    }

    [wifiClient release];
    wifiClient = nil;

    NSLog(@"TrustedWiFiManager: Stopped monitoring WiFi");
}

- (void) ssidDidChangeForWiFiInterfaceWithName: (NSString *) interfaceName {

    NSString * newSSID = [[self class] currentWiFiSSID];

    NSLog(@"TrustedWiFiManager: WiFi SSID changed from '%@' to '%@' on interface %@",
          currentSSID ? currentSSID : @"(none)",
          newSSID ? newSSID : @"(none)",
          interfaceName);

    [currentSSID release];
    currentSSID = [newSSID retain];

    // Post notification so VPNConnection can check trusted WiFi status
    [[NSNotificationCenter defaultCenter] postNotificationName: @"TBTrustedWiFiSSIDChanged"
                                                        object: self
                                                      userInfo: newSSID ? @{@"ssid": newSSID} : nil];
}

@end
