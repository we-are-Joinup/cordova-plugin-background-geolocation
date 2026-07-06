//
//  MAURLocationSessionManager.m
//  BackgroundGeolocation
//

#import <CoreLocation/CoreLocation.h>
#import "MAURLocationSessionManager.h"
#import "MAURLogging.h"

static NSString * const TAG = @"MAURLocationSessionManager";

@implementation MAURLocationSessionManager {
    // CLBackgroundActivitySession on iOS 17+, nil otherwise
    id _backgroundActivitySession;
}

+ (instancetype) sharedInstance
{
    static MAURLocationSessionManager *instance = nil;
    static dispatch_once_t predicate;
    dispatch_once(&predicate, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

- (void) startSession
{
#if defined(__IPHONE_17_0) && __IPHONE_OS_VERSION_MAX_ALLOWED >= 170000
    if (@available(iOS 17.0, *)) {
        @synchronized (self) {
            if (_backgroundActivitySession != nil) {
                return;
            }
            DDLogInfo(@"%@ starting CLBackgroundActivitySession", TAG);
            _backgroundActivitySession = [CLBackgroundActivitySession backgroundActivitySession];
        }
    }
#endif
}

- (void) stopSession
{
#if defined(__IPHONE_17_0) && __IPHONE_OS_VERSION_MAX_ALLOWED >= 170000
    if (@available(iOS 17.0, *)) {
        @synchronized (self) {
            if (_backgroundActivitySession == nil) {
                return;
            }
            DDLogInfo(@"%@ invalidating CLBackgroundActivitySession", TAG);
            [(CLBackgroundActivitySession *)_backgroundActivitySession invalidate];
            _backgroundActivitySession = nil;
        }
    }
#endif
}

@end