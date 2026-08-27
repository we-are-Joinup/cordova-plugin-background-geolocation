//
//  MAURDistanceFilterLocationProvider.m
//  BackgroundGeolocation
//
//  Created by Marian Hello on 14/09/2016.
//  Copyright © 2016 mauron85. All rights reserved.
//

#import "MAURDistanceFilterLocationProvider.h"
#import "MAURLogging.h"

#define SYSTEM_VERSION_EQUAL_TO(v)                  ([[[UIDevice currentDevice] systemVersion] compare:v options:NSNumericSearch] == NSOrderedSame)
#define SYSTEM_VERSION_GREATER_THAN(v)              ([[[UIDevice currentDevice] systemVersion] compare:v options:NSNumericSearch] == NSOrderedDescending)
#define SYSTEM_VERSION_GREATER_THAN_OR_EQUAL_TO(v)  ([[[UIDevice currentDevice] systemVersion] compare:v options:NSNumericSearch] != NSOrderedAscending)
#define SYSTEM_VERSION_LESS_THAN(v)                 ([[[UIDevice currentDevice] systemVersion] compare:v options:NSNumericSearch] == NSOrderedAscending)
#define SYSTEM_VERSION_LESS_THAN_OR_EQUAL_TO(v)     ([[[UIDevice currentDevice] systemVersion] compare:v options:NSNumericSearch] != NSOrderedDescending)

#define LOCATION_DENIED         "User denied use of location services."
#define LOCATION_RESTRICTED     "Application's use of location services is restricted."
#define LOCATION_NOT_DETERMINED "User undecided on application's use of location services."

static NSString * const TAG = @"DistanceFilterLocationProvider";
static NSString * const Domain = @"com.marianhello";


enum {
    maxLocationWaitTimeInSeconds = 15,
    maxLocationAgeInSeconds = 30,
    // defaults when config.interval / config.fastestInterval are not set
    defaultResendIntervalInSeconds = 90,
    defaultResendFallbackInSeconds = 60
};

@interface MAURDistanceFilterLocationProvider () <CLLocationManagerDelegate>
@end

@implementation MAURDistanceFilterLocationProvider {
    BOOL isUpdatingLocation;
    BOOL isAcquiringStationaryLocation;
    BOOL isAcquiringSpeed;
    BOOL isStarted;
    
    CLCircularRegion *stationaryRegion;
    NSDate *stationarySince;

    MAUROperationalMode operationMode;
    NSDate *aquireStartTime;

    NSDate *lastLocationAt;   // last CoreLocation delivery (GPS alive)
    NSDate *lastEmittedAt;    // last position actually sent to the delegate
    NSDate *kickedAt;
    MAURLocation *lastReportedLocation;
    NSTimer *watchdogTimer;

    CLLocationManager *locationManager;

    // configurable options
    MAURConfig *_config;
}


- (instancetype) init
{
    self = [super init];
    
    if (self) {
        isUpdatingLocation = NO;
        isAcquiringStationaryLocation = NO;
        isAcquiringSpeed = NO;
        stationaryRegion = nil;
        isStarted = NO;
    }

    return self;
}

- (void) onCreate {
    locationManager = [[CLLocationManager alloc] init];
    locationManager.allowsBackgroundLocationUpdates = YES;
    // required for reliable background sessions of When-In-Use authorized apps
    locationManager.showsBackgroundLocationIndicator = YES;
    locationManager.delegate = self;
}

/**
 * configure provider
 * @param {Config} configuration
 * @param {NSError} optional error
 */
- (BOOL) onConfigure:(MAURConfig*)config error:(NSError * __autoreleasing *)outError
{
    DDLogVerbose(@"%@ configure", TAG);
    _config = config;

    locationManager.pausesLocationUpdatesAutomatically = [_config pauseLocationUpdates];
    locationManager.activityType = [_config decodeActivityType];
    locationManager.distanceFilter = _config.distanceFilter.integerValue; // meters
    locationManager.desiredAccuracy = [_config decodeDesiredAccuracy];
    
    return YES;
}

/**
 * Turn on background geolocation
 */
- (BOOL) onStart:(NSError * __autoreleasing *)outError
{
    DDLogInfo(@"%@ will start", TAG);

    CLAuthorizationStatus authStatus = locationManager.authorizationStatus;

    if (authStatus == kCLAuthorizationStatusDenied) {
        if (outError != NULL) {
            NSDictionary *errorDictionary = @{
                                              NSLocalizedDescriptionKey: NSLocalizedString(@LOCATION_DENIED, nil)
                                              };

            *outError = [NSError errorWithDomain:Domain code:MAURBGPermissionDenied userInfo:errorDictionary];
        }

        return NO;
    }

    if (authStatus == kCLAuthorizationStatusRestricted) {
        if (outError != NULL) {
            NSDictionary *errorDictionary = @{
                                              NSLocalizedDescriptionKey: NSLocalizedString(@LOCATION_RESTRICTED, nil)
                                              };
            *outError = [NSError errorWithDomain:Domain code:MAURBGPermissionDenied userInfo:errorDictionary];
        }

        return NO;
    }

    // we do startUpdatingLocation even though we might not get permissions granted
    // we can stop later on when recieved callback on user denial
    if (authStatus == kCLAuthorizationStatusNotDetermined) {
        DDLogVerbose(@"%@ requestAlwaysAuthorization", TAG);
        [locationManager requestAlwaysAuthorization];
    } else if (authStatus == kCLAuthorizationStatusAuthorizedWhenInUse) {
        // ask user to upgrade to Always, so tracking survives app suspension.
        // The system shows this prompt at most once, subsequent calls are no-ops.
        DDLogVerbose(@"%@ requestAlwaysAuthorization (upgrade from WhenInUse)", TAG);
        [locationManager requestAlwaysAuthorization];
    }

    [self switchMode:MAURForegroundMode];

    isStarted = YES;
    [self startWatchdog];

    return YES;
}

/**
 * In-process watchdog: CoreLocation can silently stop delivering updates
 * after some time in background (observed on iOS 26 after ~12min), and delivers
 * nothing while stationary under a distance filter. A repeating timer keeps a
 * heartbeat in the log and enforces a position cadence, driven by config:
 * - interval (ms, default 60s): when no position was sent for this long,
 *   force a fresh fix even while stationary;
 * - fastestInterval (ms, default 30s): when the forced fix does not arrive
 *   within this window (e.g. no GPS signal), re-send the previous position.
 */
- (NSTimeInterval) resendIntervalInSeconds
{
    if ([_config hasInterval]) {
        return MAX(_config.interval.doubleValue / 1000.0, 10);
    }
    return defaultResendIntervalInSeconds;
}

- (NSTimeInterval) resendFallbackInSeconds
{
    if ([_config hasFastestInterval]) {
        return MAX(_config.fastestInterval.doubleValue / 1000.0, 5);
    }
    return defaultResendFallbackInSeconds;
}

/**
 * minimum time between positions sent to the delegate (fastestInterval).
 * Without it, a watchdog kick (distanceFilter=None until the regular filter
 * is restored) or fast distance-filter crossings emit several positions
 * within seconds.
 */
- (NSTimeInterval) minSecondsBetweenUpdates
{
    if ([_config hasFastestInterval]) {
        return MAX(_config.fastestInterval.doubleValue / 1000.0, 5);
    }
    // small default that only suppresses bursts
    return 5;
}

- (void) startWatchdog
{
    [self stopWatchdog];
    lastLocationAt = [NSDate date];
    lastEmittedAt = nil; // first fix after start is never throttled
    kickedAt = nil;

    NSTimeInterval tick = MIN([self resendIntervalInSeconds], [self resendFallbackInSeconds]) / 2;
    tick = MAX(MIN(tick, 30), 5);
    watchdogTimer = [NSTimer scheduledTimerWithTimeInterval:tick
                                                     target:self
                                                   selector:@selector(onWatchdogTick:)
                                                   userInfo:nil
                                                    repeats:YES];
}

- (void) stopWatchdog
{
    if (watchdogTimer != nil) {
        [watchdogTimer invalidate];
        watchdogTimer = nil;
    }
}

- (void) onWatchdogTick:(NSTimer*)timer
{
    if (!isStarted || !isUpdatingLocation) {
        return;
    }

    NSTimeInterval sinceLastLocation = lastLocationAt != nil ? -[lastLocationAt timeIntervalSinceNow] : -1;
    // cadence is measured against what was actually sent; before anything
    // was emitted, fall back to the last delivery/start time
    NSDate *sentRef = lastEmittedAt != nil ? lastEmittedAt : lastLocationAt;
    NSTimeInterval sinceLastSent = sentRef != nil ? -[sentRef timeIntervalSinceNow] : -1;
    UIApplicationState appState = [UIApplication sharedApplication].applicationState;
    DDLogDebug(@"%@ watchdog: appState=%ld secondsSinceLastFix=%.0f secondsSinceLastSent=%.0f kickPending=%d",
               TAG, (long)appState, sinceLastLocation, sinceLastSent, kickedAt != nil);

    if (kickedAt == nil) {
        if (sinceLastSent > [self resendIntervalInSeconds]) {
            DDLogInfo(@"%@ watchdog: no position sent for %.0fs, forcing a fresh fix", TAG, sinceLastSent);
            [locationManager stopUpdatingLocation];
            // force a delivery even while stationary; the configured filter is
            // restored by the regular distance-filter logic on the next fix
            locationManager.distanceFilter = kCLDistanceFilterNone;
            [locationManager startUpdatingLocation];
            kickedAt = [NSDate date];
        }
        return;
    }

    if (-[kickedAt timeIntervalSinceNow] > [self resendFallbackInSeconds]) {
        // no fresh fix arrived after the kick; re-send previous known position
        kickedAt = nil;
        lastEmittedAt = [NSDate date];

        if (lastReportedLocation == nil) {
            DDLogWarn(@"%@ watchdog: no fix after kick and no previous position to re-send", TAG);
            return;
        }

        DDLogInfo(@"%@ watchdog: no fix after kick, re-sending previous position", TAG);
        if ([_config isDebugging]) {
            [self notify:@"Watchdog: re-sending previous position"];
        }

        MAURLocation *heartbeat = [lastReportedLocation copy];
        heartbeat.time = [NSDate date];
        [super.delegate onLocationChanged:heartbeat];
    }
}

/**
 * Turn it off
 */
- (BOOL) onStop:(NSError * __autoreleasing *)outError
{
    DDLogInfo(@"%@ stop", TAG);

    [self stopWatchdog];
    [self stopUpdatingLocation];
    [self stopMonitoringSignificantLocationChanges];
    [self stopMonitoringForRegion];

    isStarted = NO;

    return YES;
}

- (void) onSwitchMode:(MAUROperationalMode)mode
{
    [self switchMode:mode];
}

/**
 * toggle between foreground and background operation mode
 */
- (void) switchMode:(MAUROperationalMode)mode
{
    DDLogInfo(@"%@ switchMode %lu", TAG, (unsigned long)mode);
    
    operationMode = mode;
    
    if (operationMode == MAURForegroundMode || !_config.saveBatteryOnBackground) {
        isAcquiringSpeed = YES;
        isAcquiringStationaryLocation = NO;
        [self stopMonitoringForRegion];
        [self stopMonitoringSignificantLocationChanges];
    } else if (operationMode == MAURBackgroundMode) {
        isAcquiringSpeed = NO;
        isAcquiringStationaryLocation = YES;
        [self startMonitoringSignificantLocationChanges];
    }
    
    aquireStartTime = [NSDate date];
    lastLocationAt = [NSDate date];
    lastEmittedAt = nil; // position after a mode switch is never throttled
    kickedAt = nil;

    // Crank up the GPS power temporarily to get a good fix on our current location
    [self stopUpdatingLocation];
    locationManager.distanceFilter = kCLDistanceFilterNone;
    locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation;
    [self startUpdatingLocation];
}

- (void) locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray *)locations
{
    DDLogDebug(@"%@ didUpdateLocations (operationMode: %lu)", TAG, (unsigned long)operationMode);

    lastLocationAt = [NSDate date];
    kickedAt = nil;
    
    MAUROperationalMode actAsInMode = operationMode;
    
    if (actAsInMode == MAURBackgroundMode) {
        if ([_config saveBatteryOnBackground] == NO) actAsInMode = MAURForegroundMode;
    }
    
    if (actAsInMode == MAURForegroundMode) {
        if (!isUpdatingLocation) [self startUpdatingLocation];
    }
    
    if (actAsInMode == MAURBackgroundMode) {
        if (!isAcquiringStationaryLocation && !stationaryRegion) {
            // Perhaps our GPS signal was interupted, re-acquire a stationaryLocation now.
            [self switchMode:operationMode];
        }
    }
    
    
    MAURLocation *bestLocation = nil;
    for (CLLocation *location in locations) {
        MAURLocation *bgloc = [MAURLocation fromCLLocation:location];
        
        // test the age of the location measurement to determine if the measurement is cached
        // in most cases you will not want to rely on cached measurements
        DDLogDebug(@"Location age %f", [bgloc locationAge]);
        if ([bgloc locationAge] > maxLocationAgeInSeconds || ![bgloc hasAccuracy] || ![bgloc hasTime]) {
            continue;
        }
        
        if (bestLocation == nil) {
            bestLocation = bgloc;
            continue;
        }
        
        if ([bgloc isBetterLocation:bestLocation]) {
            DDLogInfo(@"Better location found: %@", bgloc);
            bestLocation = bgloc;
        }
    }
    
    if (bestLocation == nil) {
        return;
    }
    
    // test the measurement to see if it is more accurate than the previous measurement
    if (isAcquiringStationaryLocation) {
        DDLogDebug(@"%@ acquiring stationary location, accuracy: %@", TAG, bestLocation.accuracy);
        if ([_config isDebugging]) {
            AudioServicesPlaySystemSound (acquiringLocationSound);
        }
        
        if ([bestLocation.accuracy doubleValue] <= [_config.desiredAccuracy doubleValue]) {
            DDLogDebug(@"%@ found most accurate stationary before timeout", TAG);
        } else if (-[aquireStartTime timeIntervalSinceNow] < maxLocationWaitTimeInSeconds) {
            // we still have time to aquire better location
            return;
        }
        
        isAcquiringStationaryLocation = NO;
        [self stopUpdatingLocation]; //saving power while monitoring region
        
        MAURLocation *stationaryLocation = [bestLocation copy];
        stationaryLocation.radius = _config.stationaryRadius;
        stationaryLocation.time = stationarySince;
        [self startMonitoringStationaryRegion:stationaryLocation];
        lastReportedLocation = stationaryLocation;
        lastEmittedAt = [NSDate date];
        // fire onStationary @event for Javascript.
        [super.delegate onStationaryChanged:stationaryLocation];
    } else if (isAcquiringSpeed) {
        if ([_config isDebugging]) {
            AudioServicesPlaySystemSound (acquiringLocationSound);
        }
        
        if ([bestLocation.accuracy doubleValue] <= [_config.desiredAccuracy doubleValue]) {
            DDLogDebug(@"%@ found most accurate location before timeout", TAG);
        } else if (-[aquireStartTime timeIntervalSinceNow] < maxLocationWaitTimeInSeconds) {
            // we still have time to aquire better location
            return;
        }
        
        if ([_config isDebugging]) {
            [self notify:@"Aggressive monitoring engaged"];
        }
        
        // We should have a good sample for speed now, power down our GPS as configured by user.
        isAcquiringSpeed = NO;
        locationManager.desiredAccuracy = _config.desiredAccuracy.integerValue;
        locationManager.distanceFilter = [self calculateDistanceFilter:[bestLocation.speed floatValue]];
        [self startUpdatingLocation];
        
    } else if (actAsInMode == MAURForegroundMode) {
        // Adjust distanceFilter incrementally based upon current speed
        float newDistanceFilter = [self calculateDistanceFilter:[bestLocation.speed floatValue]];
        if (newDistanceFilter != locationManager.distanceFilter) {
            DDLogInfo(@"%@ updated distanceFilter, new: %f, old: %f", TAG, newDistanceFilter, locationManager.distanceFilter);
            locationManager.distanceFilter = newDistanceFilter;
            [self startUpdatingLocation];
        }
    } else if ([self locationIsBeyondStationaryRegion:bestLocation]) {
        if ([_config isDebugging]) {
            [self notify:@"Manual stationary exit-detection"];
        }
        [self switchMode:operationMode];
    }
    
    // always remember the freshest fix, even when its emission is throttled,
    // so watchdog re-sends carry the newest known position
    lastReportedLocation = bestLocation;

    NSTimeInterval sinceLastEmitted = lastEmittedAt != nil ? -[lastEmittedAt timeIntervalSinceNow] : DBL_MAX;
    if (sinceLastEmitted < [self minSecondsBetweenUpdates]) {
        DDLogDebug(@"%@ update skipped, only %.0fs since previous one (fastestInterval)", TAG, sinceLastEmitted);
        return;
    }

    lastEmittedAt = [NSDate date];
    [super.delegate onLocationChanged:bestLocation];
}

/**
 * Called when user exits their stationary radius (ie: they walked ~50m away from their last recorded location.
 *
 */
- (void) locationManager:(CLLocationManager *)manager didExitRegion:(CLCircularRegion *)region
{
    CLLocationDistance radius = [region radius];
    CLLocationCoordinate2D coordinate = [region center];
    
    DDLogDebug(@"%@ didExitRegion {%f,%f,%f}", TAG, coordinate.latitude, coordinate.longitude, radius);
    if ([_config isDebugging]) {
        AudioServicesPlaySystemSound (exitRegionSound);
        [self notify:@"Exit stationary region"];
    }
    [self switchMode:operationMode];
}

- (void) locationManagerDidPauseLocationUpdates:(CLLocationManager *)manager
{
    DDLogDebug(@"%@ location updates paused", TAG);
    if ([_config isDebugging]) {
        [self notify:@"Location updates paused"];
    }
}

- (void) locationManagerDidResumeLocationUpdates:(CLLocationManager *)manager
{
    DDLogDebug(@"%@ location updates resumed", TAG);
    if ([_config isDebugging]) {
        [self notify:@"Location updates resumed b"];
    }
}

- (void) locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error
{
    DDLogError(@"%@ didFailWithError: %@", TAG, error);
    if ([_config isDebugging]) {
        AudioServicesPlaySystemSound (locationErrorSound);
        [self notify:[NSString stringWithFormat:@"Location error: %@", error.localizedDescription]];
    }
    
    switch(error.code) {
        case kCLErrorLocationUnknown:
        case kCLErrorNetwork:
        case kCLErrorRegionMonitoringDenied:
        case kCLErrorRegionMonitoringSetupDelayed:
        case kCLErrorRegionMonitoringResponseDelayed:
        case kCLErrorGeocodeFoundNoResult:
        case kCLErrorGeocodeFoundPartialResult:
        case kCLErrorGeocodeCanceled:
            break;
        case kCLErrorDenied:
            break;
    }
    
    if (self.delegate && [self.delegate respondsToSelector:@selector(onError:)]) {
        NSDictionary *errorDictionary = @{
                                          NSUnderlyingErrorKey : error
                                          };
        NSError *outError = [NSError errorWithDomain:Domain code:MAURBGServiceError userInfo:errorDictionary];
        
        [self.delegate onError:outError];
    }
}

- (void) locationManagerDidChangeAuthorization:(CLLocationManager *)manager
{
    [self handleAuthorizationStatusChange:manager.authorizationStatus];
}

- (void) handleAuthorizationStatusChange:(CLAuthorizationStatus)status
{
    DDLogInfo(@"LocationManager didChangeAuthorizationStatus %u", status);
    if ([_config isDebugging]) {
        [self notify:[NSString stringWithFormat:@"Authorization status changed %u", status]];
    }
    
    switch(status) {
        case kCLAuthorizationStatusRestricted:
        case kCLAuthorizationStatusDenied:
            if (self.delegate && [self.delegate respondsToSelector:@selector(onAuthorizationChanged:)]) {
                [self.delegate onAuthorizationChanged:MAURLocationAuthorizationDenied];
            }
            break;
        case kCLAuthorizationStatusAuthorizedAlways:
            if (self.delegate && [self.delegate respondsToSelector:@selector(onAuthorizationChanged:)]) {
                [self.delegate onAuthorizationChanged:MAURLocationAuthorizationAlways];
            }
            break;
        case kCLAuthorizationStatusAuthorizedWhenInUse:
            if (self.delegate && [self.delegate respondsToSelector:@selector(onAuthorizationChanged:)]) {
                [self.delegate onAuthorizationChanged:MAURLocationAuthorizationForeground];
            }
            break;
        default:
            break;
    }
}

- (void) stopUpdatingLocation
{
    if (isUpdatingLocation) {
        [locationManager stopUpdatingLocation];
        isUpdatingLocation = NO;
    }
}

- (void) startUpdatingLocation
{
    if (!isUpdatingLocation) {
        [locationManager startUpdatingLocation];
        isUpdatingLocation = YES;
    }
}

- (void) onTerminate
{
    if (isStarted && !_config.stopOnTerminate) {
        [locationManager startMonitoringSignificantLocationChanges];
    }
}

- (void) startMonitoringSignificantLocationChanges
{
    [locationManager startMonitoringSignificantLocationChanges];
}

- (void) stopMonitoringSignificantLocationChanges
{
    [locationManager stopMonitoringSignificantLocationChanges];
}

/**
 * Creates a new circle around user and region-monitors it for exit
 */
- (void) startMonitoringStationaryRegion:(MAURLocation*)location {
    CLLocationCoordinate2D coord = [location coordinate];
    DDLogDebug(@"%@ startMonitoringStationaryRegion {%f,%f,%@}", TAG, coord.latitude, coord.longitude, _config.stationaryRadius);
    
    if ([_config isDebugging]) {
        AudioServicesPlaySystemSound (acquiredLocationSound);
        [self notify:[NSString stringWithFormat:@"Monitoring region {%f,%f,%@}", location.coordinate.latitude, location.coordinate.longitude, _config.stationaryRadius]];
    }
    
    [self stopMonitoringForRegion];
    stationaryRegion = [[CLCircularRegion alloc] initWithCenter: coord radius:_config.stationaryRadius.integerValue identifier:@"DistanceFilterProvider stationary region"];
    stationaryRegion.notifyOnExit = YES;
    [locationManager startMonitoringForRegion:stationaryRegion];
    stationarySince = [NSDate date];
}

- (void) stopMonitoringForRegion
{
    if (stationaryRegion != nil) {
        [locationManager stopMonitoringForRegion:stationaryRegion];
        stationaryRegion = nil;
        stationarySince = nil;
    }
}

/**
 * Calculates distanceFilter by rounding speed to nearest 5 and multiplying by 10.  Clamped at 1km max.
 */
- (float) calculateDistanceFilter:(float)speed
{
    float newDistanceFilter = _config.distanceFilter.integerValue;
    if (speed < 100) {
        // (rounded-speed-to-nearest-5) / 2)^2
        // eg 5.2 becomes (5/2)^2
        newDistanceFilter = pow((5.0 * floorf(fabsf(speed) / 5.0 + 0.5f)), 2) + _config.distanceFilter.integerValue;
    }
    return (newDistanceFilter < 1000) ? newDistanceFilter : 1000;
}

/**
 * Manual stationary location his-testing.  This seems to help stationary-exit detection in some places where the automatic geo-fencing doesn't
 */
- (BOOL) locationIsBeyondStationaryRegion:(MAURLocation*)location
{
    CLLocationCoordinate2D regionCenter = [stationaryRegion center];
    BOOL containsCoordinate = [stationaryRegion containsCoordinate:[location coordinate]];
    
    DDLogVerbose(@"%@ location {%@,%@} region {%f,%f,%f} contains: %d",
                 TAG,
                 location.latitude, location.longitude, regionCenter.latitude, regionCenter.longitude,
                 [stationaryRegion radius], containsCoordinate);
    
    return !containsCoordinate;
}

- (void) notify:(NSString*)message
{
    [super notify:message];
}

- (void) onDestroy {
    DDLogInfo(@"Destroying %@ ", TAG);
    [self onStop:nil];
}

- (void) dealloc
{
    //    locationController.delegate = nil;
}

@end
