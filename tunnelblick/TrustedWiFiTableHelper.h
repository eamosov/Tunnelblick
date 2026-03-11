/*
 *  TrustedWiFiTableHelper.h
 *  Tunnelblick
 *
 *  Helper for the Trusted WiFi management panel's table view.
 */

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

@interface TrustedWiFiTableHelper : NSObject <NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate> {
    NSMutableArray * ssidList;
    NSString       * displayName;
    NSTableView    * tableView;
    NSTextField    * ssidField;
}

@property (nonatomic, assign) NSTableView * tableView;
@property (nonatomic, assign) NSTextField * ssidField;

- (instancetype) initWithSSIDs: (NSMutableArray *) ssids displayName: (NSString *) name;
- (IBAction) addCurrentWiFi: (id) sender;
- (IBAction) addManualSSID: (id) sender;
- (IBAction) removeSelectedSSID: (id) sender;

@end
