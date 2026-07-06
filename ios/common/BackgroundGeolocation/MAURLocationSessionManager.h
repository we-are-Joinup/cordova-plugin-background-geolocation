//
//  MAURLocationSessionManager.h
//  BackgroundGeolocation
//
//  Holds a CLBackgroundActivitySession (iOS 17+) for the whole tracking
//  lifetime. Since iOS 17 an app without "Always" authorization stops
//  receiving location updates some time after entering background unless
//  such a session is active. On older iOS versions this class is a no-op.
//

#import <Foundation/Foundation.h>

@interface MAURLocationSessionManager : NSObject

+ (instancetype) sharedInstance;

/**
 * Starts a background activity session if none is active.
 * Must be called while the app is in foreground, or immediately
 * after a background launch (e.g. relaunch on significant location change),
 * otherwise the session will not become active.
 */
- (void) startSession;

/**
 * Invalidates the current session (if any).
 */
- (void) stopSession;

@end
