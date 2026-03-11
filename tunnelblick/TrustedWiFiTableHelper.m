/*
 *  TrustedWiFiTableHelper.m
 *  Tunnelblick
 *
 *  Helper for the Trusted WiFi management panel's table view.
 */

#import "TrustedWiFiTableHelper.h"
#import "TrustedWiFiManager.h"

@implementation TrustedWiFiTableHelper

@synthesize tableView;
@synthesize ssidField;

- (instancetype) initWithSSIDs: (NSMutableArray *) ssids displayName: (NSString *) name {

    self = [super init];
    if ( ! self ) return nil;

    ssidList = [ssids retain];
    displayName = [name retain];
    tableView = nil;
    ssidField = nil;

    return self;
}

- (void) dealloc {

    [ssidList release];
    [displayName release];
    [super dealloc];
}

#pragma mark - NSTableViewDataSource

- (NSInteger) numberOfRowsInTableView: (NSTableView *) tv {

    (void) tv;
    return (NSInteger)[ssidList count];
}

- (id)            tableView: (NSTableView *) tv
  objectValueForTableColumn: (NSTableColumn *) tableColumn
                        row: (NSInteger) row {

    (void) tv;
    (void) tableColumn;
    if ( row < 0 || row >= (NSInteger)[ssidList count] ) return nil;
    return [ssidList objectAtIndex: (NSUInteger)row];
}

#pragma mark - Actions

- (IBAction) addCurrentWiFi: (id) sender {

    (void) sender;
    NSString * currentSSID = [TrustedWiFiManager currentWiFiSSID];
    if ( ! currentSSID ) return;

    // Check for duplicate
    for ( NSString * existing in ssidList ) {
        if ( [existing caseInsensitiveCompare: currentSSID] == NSOrderedSame ) {
            return;
        }
    }

    [TrustedWiFiManager addTrustedSSID: currentSSID forDisplayName: displayName];
    [ssidList addObject: currentSSID];
    [tableView reloadData];
}

- (IBAction) addManualSSID: (id) sender {

    (void) sender;
    NSString * ssid = [[ssidField stringValue] stringByTrimmingCharactersInSet:
                        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ( ! ssid || [ssid length] == 0 ) return;

    // Check for duplicate
    for ( NSString * existing in ssidList ) {
        if ( [existing caseInsensitiveCompare: ssid] == NSOrderedSame ) {
            return;
        }
    }

    [TrustedWiFiManager addTrustedSSID: ssid forDisplayName: displayName];
    [ssidList addObject: ssid];
    [tableView reloadData];
    [ssidField setStringValue: @""];
}

- (IBAction) removeSelectedSSID: (id) sender {

    (void) sender;
    NSInteger row = [tableView selectedRow];
    if ( row < 0 || row >= (NSInteger)[ssidList count] ) return;

    NSString * ssid = [ssidList objectAtIndex: (NSUInteger)row];
    [TrustedWiFiManager removeTrustedSSID: ssid forDisplayName: displayName];
    [ssidList removeObjectAtIndex: (NSUInteger)row];
    [tableView reloadData];
}

#pragma mark - NSWindowDelegate

- (void) windowWillClose: (NSNotification *) notification {

    (void) notification;
    [NSApp stopModal];
}

@end
