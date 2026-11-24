// macOS-only harness for the runtime logic. It defines the same Objective-C
// class/method names X uses, loads the tweak, and verifies every hook.

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <limits.h>

static int gFailures = 0;

static void Check(BOOL condition, NSString *what) {
    if (condition) {
        fprintf(stdout, "PASS  %s\n", what.UTF8String);
    } else {
        fprintf(stdout, "FAIL  %s\n", what.UTF8String);
        gFailures++;
    }
}

#pragma mark - Fake X classes

@interface TAVVideoQuality : NSObject
@property (nonatomic) CGSize resolution;
- (instancetype)initWithResolution:(CGSize)resolution;
@end

@implementation TAVVideoQuality
- (instancetype)initWithResolution:(CGSize)resolution {
    self = [super init];
    if (self) _resolution = resolution;
    return self;
}
@end

@interface TAVVideoQualityEndpoint : NSObject
@property (nonatomic) long long enumValue;
@property (nonatomic, strong) TAVVideoQuality *videoQuality;
@property (nonatomic) BOOL isStatic;
- (instancetype)initStaticQuality:(TAVVideoQuality *)quality;
- (instancetype)initWithValue:(long long)value isStatic:(BOOL)isStatic;
@end

@implementation TAVVideoQualityEndpoint
- (instancetype)initStaticQuality:(TAVVideoQuality *)quality {
    self = [super init];
    if (self) {
        _videoQuality = quality;
        _enumValue = (long long)quality.resolution.height;
        _isStatic = YES;
    }
    return self;
}
- (instancetype)initWithValue:(long long)value isStatic:(BOOL)isStatic {
    self = [super init];
    if (self) {
        _enumValue = value;
        _isStatic = isStatic;
        _videoQuality = [[TAVVideoQuality alloc] initWithResolution:CGSizeMake(0, (CGFloat)value)];
    }
    return self;
}
@end

@interface TAVVideoQualityState : NSObject
@property (nonatomic, strong) TAVVideoQualityEndpoint *selectedQualityEndpoint;
@property (nonatomic, copy) NSSet *availableEndpoints;
@property (nonatomic, strong) TAVVideoQualityEndpoint *cacheEndpoint;
@property (nonatomic) CGSize maxResolution;
@property (nonatomic, copy) NSString *mutationReason;
- (instancetype)initWithSelectedQualityEndpoint:(TAVVideoQualityEndpoint *)selected
                             availableEndpoints:(NSSet *)available
                                  cacheEndpoint:(TAVVideoQualityEndpoint *)cache
                                  maxResolution:(CGSize)maxResolution
                                 mutationReason:(NSString *)reason;
@end

@implementation TAVVideoQualityState
- (instancetype)initWithSelectedQualityEndpoint:(TAVVideoQualityEndpoint *)selected
                             availableEndpoints:(NSSet *)available
                                  cacheEndpoint:(TAVVideoQualityEndpoint *)cache
                                  maxResolution:(CGSize)maxResolution
                                 mutationReason:(NSString *)reason {
    self = [super init];
    if (self) {
        _selectedQualityEndpoint = selected;
        _availableEndpoints = [available copy];
        _cacheEndpoint = cache;
        _maxResolution = maxResolution;
        _mutationReason = [reason copy];
    }
    return self;
}
@end

@interface TAVPlayerTechnologyQualitySelectionControlState : NSObject
@property (nonatomic, strong) TAVVideoQualityEndpoint *videoQualityEndpoint;
- (instancetype)initVideoQualityEndpoint:(TAVVideoQualityEndpoint *)endpoint
                 staticEndpointsEnabled:(BOOL)enabled
                         mutationReason:(NSString *)reason;
@end

@implementation TAVPlayerTechnologyQualitySelectionControlState
- (instancetype)initVideoQualityEndpoint:(TAVVideoQualityEndpoint *)endpoint
                 staticEndpointsEnabled:(BOOL)enabled
                         mutationReason:(NSString *)reason {
    self = [super init];
    if (self) _videoQualityEndpoint = endpoint;
    return self;
}
@end

@interface T1VideoBitRateManager : NSObject
@end

@implementation T1VideoBitRateManager
- (double)currentPreferredPeakBitRateWithAutoplaying:(BOOL)autoplaying { return 2500000.0; }
- (double)currentBitrateForMp4VariantSelectionWithAutoplaying:(BOOL)autoplaying { return 2500000.0; }
- (double)_t1_autoplayBitRateForHighQualityForAccountID:(id)accountID { return 2500000.0; }
- (double)_t1_autoplayBitRateForHighQualityWiFiForAccountID:(id)accountID { return 2500000.0; }
@end

#pragma mark - Test

static TAVVideoQualityEndpoint *Endpoint(long long value, BOOL isStatic) {
    return [[TAVVideoQualityEndpoint alloc] initWithValue:value isStatic:isStatic];
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "usage: %s /path/to/XHighestQuality.dylib\n", argv[0]);
            return 2;
        }

        void *handle = dlopen(argv[1], RTLD_NOW);
        if (!handle) {
            fprintf(stderr, "dlopen failed: %s\n", dlerror());
            return 2;
        }

        // Let the constructor's main-queue install/retry run.
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];

        TAVVideoQualityEndpoint *autoEndpoint = Endpoint(LLONG_MAX, NO);
        TAVVideoQualityEndpoint *e320 = Endpoint(320, YES);
        TAVVideoQualityEndpoint *e720 = Endpoint(720, YES);
        TAVVideoQualityEndpoint *e1080 = Endpoint(1080, YES);
        NSSet *available = [NSSet setWithObjects:e320, e720, e1080, nil];

        // 1. State initializer should pick 1080.
        TAVVideoQualityState *state = [[TAVVideoQualityState alloc]
            initWithSelectedQualityEndpoint:autoEndpoint
                         availableEndpoints:available
                              cacheEndpoint:nil
                              maxResolution:CGSizeZero
                             mutationReason:@"test"];
        Check(state.selectedQualityEndpoint.enumValue == 1080, @"state init picks 1080p");

        // 2. State getter should turn auto into 1080.
        state.selectedQualityEndpoint = autoEndpoint;
        Check(state.selectedQualityEndpoint.enumValue == 1080, @"state getter replaces auto with 1080p");

        // 3. An explicit static choice must be preserved.
        state.selectedQualityEndpoint = e720;
        Check(state.selectedQualityEndpoint.enumValue == 720, @"state getter preserves explicit 720p");

        // 3b. If only auto exists, the getter should synthesize a 1080p endpoint.
        state.availableEndpoints = [NSSet setWithObject:autoEndpoint];
        state.selectedQualityEndpoint = autoEndpoint;
        Check(state.selectedQualityEndpoint.enumValue == 1080, @"state getter synthesizes 1080p when only auto exists");

        // 4. Control state initializer should replace auto with 1080.
        TAVPlayerTechnologyQualitySelectionControlState *control =
            [[TAVPlayerTechnologyQualitySelectionControlState alloc]
                initVideoQualityEndpoint:autoEndpoint
                 staticEndpointsEnabled:YES
                         mutationReason:@"test"];
        Check(control.videoQualityEndpoint.enumValue == 1080, @"control init picks 1080p");

        // 5. AVPlayerItem caps are neutralized.
        AVPlayerItem *item = [AVPlayerItem playerItemWithURL:[NSURL fileURLWithPath:@"/tmp/xhq-test.mp4"]];
        item.preferredPeakBitRate = 2500000.0;
        Check(item.preferredPeakBitRate == 0.0, @"preferredPeakBitRate is 0");

        item.preferredMaximumResolution = CGSizeMake(1920, 1080);
        Check(CGSizeEqualToSize(item.preferredMaximumResolution, CGSizeZero), @"preferredMaximumResolution is CGSizeZero");

        item.preferredPeakBitRateForExpensiveNetworks = 2500000.0;
        Check(item.preferredPeakBitRateForExpensiveNetworks == 0.0, @"preferredPeakBitRateForExpensiveNetworks is 0");

        item.preferredMaximumResolutionForExpensiveNetworks = CGSizeMake(1920, 1080);
        Check(CGSizeEqualToSize(item.preferredMaximumResolutionForExpensiveNetworks, CGSizeZero), @"preferredMaximumResolutionForExpensiveNetworks is CGSizeZero");

        item.startsOnFirstEligibleVariant = YES;
        Check(item.startsOnFirstEligibleVariant == NO, @"startsOnFirstEligibleVariant is NO");

        // 6. T1VideoBitRateManager caps are neutralized.
        T1VideoBitRateManager *bitrate = [T1VideoBitRateManager new];
        Check([bitrate currentPreferredPeakBitRateWithAutoplaying:YES] == 0.0, @"peak bitrate hook returns 0");
        Check([bitrate currentBitrateForMp4VariantSelectionWithAutoplaying:YES] == 1.0e9, @"mp4 bitrate hook returns 1e9");
        Check([bitrate _t1_autoplayBitRateForHighQualityForAccountID:@"x"] == 1.0e9, @"high-quality bitrate hook returns 1e9");
        Check([bitrate _t1_autoplayBitRateForHighQualityWiFiForAccountID:@"x"] == 1.0e9, @"high-quality Wi-Fi bitrate hook returns 1e9");

        fprintf(stdout, "\n%s (%d failure%s)\n",
                gFailures == 0 ? "ALL TESTS PASSED" : "TESTS FAILED",
                gFailures, gFailures == 1 ? "" : "s");
        dlclose(handle);
        return gFailures == 0 ? 0 : 1;
    }
}
