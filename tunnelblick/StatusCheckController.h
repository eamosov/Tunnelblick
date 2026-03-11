/*
 *  StatusCheckController.h
 *  Tunnelblick
 *
 *  Status page showing network reachability checks (HTTP services and ping).
 */

#import <Cocoa/Cocoa.h>

@interface StatusCheckResult : NSObject

@property (nonatomic, copy) NSString * serviceName;
@property (nonatomic, assign) BOOL reachable;
@property (nonatomic, assign) BOOL checking;
@property (nonatomic, copy) NSString * ipAddress;
@property (nonatomic, copy) NSString * errorMessage;
@property (nonatomic, assign) NSTimeInterval latencyMs;

@end

@interface StatusCheckController : NSObject <NSTableViewDataSource, NSTableViewDelegate> {
    NSWindow       * statusWindow;
    NSTableView    * httpTableView;
    NSTableView    * pingTableView;
    NSTextField    * lastUpdateLabel;
    NSMutableArray * httpResults;
    NSMutableArray * pingResults;
    NSTimer        * refreshTimer;
    BOOL             isActive;
}

+ (StatusCheckController *) sharedController;

- (void) showWindow;
- (void) startChecking;
- (void) stopChecking;

@end
