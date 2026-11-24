// XHighestQuality.m
// Force X (Twitter) to start every video at the highest available quality.
//
// Target: X 12.46 (bundle com.atebits.Tweetie2), iOS 15+.
// Injection: TrollFools / TrollStore dylib injection.
//
// The tweak combines four independent layers:
//   1. TAV quality state: choose the highest static endpoint from the playlist.
//   2. Player quality selector: replace the "auto" endpoint with 1080p.
//   3. AVPlayerItem: remove bitrate/resolution caps X installs on top.
//   4. T1VideoBitRateManager: remove X's 2.5 Mbps autoplay cap.

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>
#import <limits.h>

static BOOL gAVHooked = NO;
static BOOL gStateHooked = NO;
static BOOL gStateInitHooked = NO;
static BOOL gStateSelectedHooked = NO;
static BOOL gControlHooked = NO;
static BOOL gControlInitHooked = NO;
static BOOL gControlEndpointHooked = NO;
static BOOL gBitrateHooked = NO;
static NSInteger gInstallAttempts = 0;

#pragma mark - Logging

static void XHQLog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSLog(@"[XHighestQuality] %@", msg);
}

#pragma mark - Small ObjC helpers

static BOOL XHQHookInstance(Class cls, const char *selName, IMP newIMP, IMP *outOldIMP) {
    if (!cls) return NO;
    SEL sel = sel_registerName(selName);
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return NO;

    IMP old = method_getImplementation(method);
    const char *types = method_getTypeEncoding(method);
    if (class_replaceMethod(cls, sel, newIMP, types) == NULL) {
        // class_replaceMethod returns the previous IMP only when it adds a method.
        // A NULL return does not necessarily mean failure for existing methods,
        // so verify by reading the method back.
        Method check = class_getInstanceMethod(cls, sel);
        if (!check || method_getImplementation(check) != newIMP) return NO;
    }
    if (outOldIMP) *outOldIMP = old;
    return YES;
}

static long long XHQEndpointValue(id endpoint) {
    if (!endpoint) return -1;
    SEL sel = sel_registerName("enumValue");
    if (![endpoint respondsToSelector:sel]) return -1;
    return ((long long (*)(id, SEL))objc_msgSend)(endpoint, sel);
}

static BOOL XHQEndpointIsStatic(id endpoint) {
    if (!endpoint) return NO;
    SEL sel = sel_registerName("isStatic");
    if (![endpoint respondsToSelector:sel]) return NO;
    return ((BOOL (*)(id, SEL))objc_msgSend)(endpoint, sel);
}

// Build a static 1080p endpoint if the playlist did not give us one.
static id XHQMake1080Endpoint(void) {
    Class qualityClass = objc_getClass("TAVVideoQuality");
    Class endpointClass = objc_getClass("TAVVideoQualityEndpoint");
    if (!qualityClass || !endpointClass) return nil;

    id quality = ((id (*)(id, SEL, CGSize))objc_msgSend)(
        [qualityClass alloc],
        sel_registerName("initWithResolution:"),
        CGSizeMake(1920.0, 1080.0));
    if (!quality) return nil;

    id endpoint = ((id (*)(id, SEL, id))objc_msgSend)(
        [endpointClass alloc],
        sel_registerName("initStaticQuality:"),
        quality);
    return endpoint;
}

// Prefer 1080p, then the highest endpoint at or below 1080p, then the highest
// endpoint available. Auto endpoints use sentinel values outside 144...4320.
static id XHQBestEndpoint(id availableEndpoints) {
    if (!availableEndpoints) return nil;

    NSSet *set = nil;
    if ([availableEndpoints isKindOfClass:[NSSet class]]) {
        set = (NSSet *)availableEndpoints;
    } else if ([availableEndpoints isKindOfClass:[NSArray class]]) {
        set = [NSSet setWithArray:(NSArray *)availableEndpoints];
    } else if ([availableEndpoints respondsToSelector:sel_registerName("allObjects")]) {
        NSArray *objects = ((id (*)(id, SEL))objc_msgSend)(availableEndpoints, sel_registerName("allObjects"));
        if ([objects isKindOfClass:[NSArray class]]) set = [NSSet setWithArray:objects];
    }
    if (!set.count) return nil;

    id bestAtMost1080 = nil;
    long long bestAtMost1080Value = -1;
    id bestAny = nil;
    long long bestAnyValue = -1;

    for (id endpoint in set) {
        long long value = XHQEndpointValue(endpoint);
        if (value < 144 || value > 4320) continue; // skip auto / unknown sentinels

        if (value <= 1080 && value > bestAtMost1080Value) {
            bestAtMost1080Value = value;
            bestAtMost1080 = endpoint;
        }
        if (value > bestAnyValue) {
            bestAnyValue = value;
            bestAny = endpoint;
        }
    }

    if (bestAtMost1080) return bestAtMost1080;
    return bestAny;
}

#pragma mark - AVPlayerItem caps

static void (*gOrigSetPeakBitrate)(id, SEL, double);
static void (*gOrigSetExpensivePeakBitrate)(id, SEL, double);
static void (*gOrigSetMaxResolution)(id, SEL, CGSize);
static void (*gOrigSetExpensiveMaxResolution)(id, SEL, CGSize);
static void (*gOrigSetNonDecreasing)(id, SEL, BOOL);
static void (*gOrigSetStartsOnFirstEligible)(id, SEL, BOOL);
static void (*gOrigSetAllowsRaisedResolution)(id, SEL, BOOL);

static void XHQSetPeakBitrate(id self, SEL _cmd, double value) {
    (void)value;
    if (gOrigSetPeakBitrate) gOrigSetPeakBitrate(self, _cmd, 0.0);
}

static void XHQSetExpensivePeakBitrate(id self, SEL _cmd, double value) {
    (void)value;
    if (gOrigSetExpensivePeakBitrate) gOrigSetExpensivePeakBitrate(self, _cmd, 0.0);
}

static void XHQSetMaxResolution(id self, SEL _cmd, CGSize value) {
    (void)value;
    // CGSizeZero means "no resolution cap" to AVPlayerItem.
    if (gOrigSetMaxResolution) gOrigSetMaxResolution(self, _cmd, CGSizeZero);
}

static void XHQSetExpensiveMaxResolution(id self, SEL _cmd, CGSize value) {
    (void)value;
    if (gOrigSetExpensiveMaxResolution) gOrigSetExpensiveMaxResolution(self, _cmd, CGSizeZero);
}

static void XHQSetNonDecreasing(id self, SEL _cmd, BOOL value) {
    (void)value;
    if (gOrigSetNonDecreasing) gOrigSetNonDecreasing(self, _cmd, YES);
}

// Private AVPlayerItem switches used by X's TAV player.
// startsOnFirstEligibleVariant makes playback begin on the first (usually lowest)
// variant, which defeats a "highest quality from the start" tweak.
static void XHQSetStartsOnFirstEligible(id self, SEL _cmd, BOOL value) {
    (void)value;
    if (gOrigSetStartsOnFirstEligible) gOrigSetStartsOnFirstEligible(self, _cmd, NO);
}

static void XHQSetAllowsRaisedResolution(id self, SEL _cmd, BOOL value) {
    (void)value;
    if (gOrigSetAllowsRaisedResolution) gOrigSetAllowsRaisedResolution(self, _cmd, YES);
}

static void XHQInstallAVHooks(void) {
    if (gAVHooked) return;
    Class cls = objc_getClass("AVPlayerItem");
    if (!cls) return;

    XHQHookInstance(cls, "setPreferredPeakBitRate:", (IMP)XHQSetPeakBitrate, (IMP *)&gOrigSetPeakBitrate);
    XHQHookInstance(cls, "setPreferredPeakBitRateForExpensiveNetworks:", (IMP)XHQSetExpensivePeakBitrate, (IMP *)&gOrigSetExpensivePeakBitrate);
    XHQHookInstance(cls, "setPreferredMaximumResolution:", (IMP)XHQSetMaxResolution, (IMP *)&gOrigSetMaxResolution);
    XHQHookInstance(cls, "setPreferredMaximumResolutionForExpensiveNetworks:", (IMP)XHQSetExpensiveMaxResolution, (IMP *)&gOrigSetExpensiveMaxResolution);
    XHQHookInstance(cls, "setIsNonDecreasingPreferredPeakBitrateCapEnabled:", (IMP)XHQSetNonDecreasing, (IMP *)&gOrigSetNonDecreasing);
    XHQHookInstance(cls, "setStartsOnFirstEligibleVariant:", (IMP)XHQSetStartsOnFirstEligible, (IMP *)&gOrigSetStartsOnFirstEligible);
    XHQHookInstance(cls, "setAllowsRaisedMaximumResolution:", (IMP)XHQSetAllowsRaisedResolution, (IMP *)&gOrigSetAllowsRaisedResolution);

    gAVHooked = YES;
    XHQLog(@"AVPlayerItem caps hooked");
}

#pragma mark - TAV quality state

static id (*gOrigStateInit)(id, SEL, id, id, id, CGSize, id);
static id (*gOrigStateSelectedEndpoint)(id, SEL);

static id XHQStateInit(id self, SEL _cmd, id selected, id available, id cache, CGSize maxResolution, id reason) {
    // Only pick an endpoint that actually exists in the playlist here. The
    // selectedQualityEndpoint getter handles the case where only auto exists.
    id best = XHQBestEndpoint(available);
    if (best) selected = best;

    return gOrigStateInit(self, _cmd, selected, available, cache, maxResolution, reason);
}

// If the state was created with auto selected, report the best static endpoint
// from the playlist. An explicit static selection (720p etc.) is preserved.
static id XHQStateSelectedEndpoint(id self, SEL _cmd) {
    if (!gOrigStateSelectedEndpoint) return XHQMake1080Endpoint();
    id current = gOrigStateSelectedEndpoint(self, _cmd);
    if (XHQEndpointIsStatic(current)) return current;

    SEL availableSel = sel_registerName("availableEndpoints");
    id available = nil;
    if ([self respondsToSelector:availableSel]) {
        available = ((id (*)(id, SEL))objc_msgSend)(self, availableSel);
    }

    id best = XHQBestEndpoint(available);
    if (!best) best = XHQMake1080Endpoint();
    return best ?: current;
}

static void XHQInstallStateHook(void) {
    if (gStateInitHooked && gStateSelectedHooked) {
        gStateHooked = YES;
        return;
    }

    Class cls = objc_getClass("TAVVideoQualityState");
    if (!cls) return;

    if (!gStateInitHooked) {
        gStateInitHooked = XHQHookInstance(cls,
                                           "initWithSelectedQualityEndpoint:availableEndpoints:cacheEndpoint:maxResolution:mutationReason:",
                                           (IMP)XHQStateInit,
                                           (IMP *)&gOrigStateInit);
    }
    if (!gStateSelectedHooked) {
        gStateSelectedHooked = XHQHookInstance(cls,
                                               "selectedQualityEndpoint",
                                               (IMP)XHQStateSelectedEndpoint,
                                               (IMP *)&gOrigStateSelectedEndpoint);
    }

    gStateHooked = gStateInitHooked && gStateSelectedHooked;
    if (gStateHooked) XHQLog(@"TAVVideoQualityState hooked");
}

#pragma mark - TAV quality selector control state

static id (*gOrigControlInit)(id, SEL, id, BOOL, id);
static id (*gOrigControlEndpoint)(id, SEL);

static id XHQControlInit(id self, SEL _cmd, id endpoint, BOOL staticEndpointsEnabled, id reason) {
    // Keep an explicit static quality selected by the user; only replace auto.
    if (!XHQEndpointIsStatic(endpoint)) {
        id best = XHQMake1080Endpoint();
        if (best) endpoint = best;
    }
    return gOrigControlInit(self, _cmd, endpoint, staticEndpointsEnabled, reason);
}

static id XHQControlEndpoint(id self, SEL _cmd) {
    if (!gOrigControlEndpoint) return XHQMake1080Endpoint();
    id endpoint = gOrigControlEndpoint(self, _cmd);
    if (!XHQEndpointIsStatic(endpoint)) {
        id best = XHQMake1080Endpoint();
        if (best) return best;
    }
    return endpoint;
}

static void XHQInstallControlHook(void) {
    if (gControlInitHooked && gControlEndpointHooked) {
        gControlHooked = YES;
        return;
    }

    Class cls = objc_getClass("TAVPlayerTechnologyQualitySelectionControlState");
    if (!cls) return;

    if (!gControlInitHooked) {
        gControlInitHooked = XHQHookInstance(cls,
                                             "initVideoQualityEndpoint:staticEndpointsEnabled:mutationReason:",
                                             (IMP)XHQControlInit,
                                             (IMP *)&gOrigControlInit);
    }
    if (!gControlEndpointHooked) {
        gControlEndpointHooked = XHQHookInstance(cls,
                                                 "videoQualityEndpoint",
                                                 (IMP)XHQControlEndpoint,
                                                 (IMP *)&gOrigControlEndpoint);
    }

    gControlHooked = gControlInitHooked && gControlEndpointHooked;
    if (gControlHooked) XHQLog(@"TAVPlayerTechnologyQualitySelectionControlState hooked");
}

#pragma mark - T1VideoBitRateManager

static double (*gOrigPeakBitrate)(id, SEL, BOOL);
static double (*gOrigMp4Bitrate)(id, SEL, BOOL);
static double (*gOrigHighQualityBitrate)(id, SEL, id);
static double (*gOrigHighQualityWiFiBitrate)(id, SEL, id);

static double XHQPeakBitrate(id self, SEL _cmd, BOOL autoplaying) {
    (void)self; (void)_cmd; (void)autoplaying;
    return 0.0; // no preferred peak cap
}

static double XHQMp4Bitrate(id self, SEL _cmd, BOOL autoplaying) {
    (void)self; (void)_cmd; (void)autoplaying;
    return 1.0e9; // choose the highest MP4 variant
}

static double XHQHighQualityBitrate(id self, SEL _cmd, id accountID) {
    (void)self; (void)_cmd; (void)accountID;
    return 1.0e9;
}

static double XHQHighQualityWiFiBitrate(id self, SEL _cmd, id accountID) {
    (void)self; (void)_cmd; (void)accountID;
    return 1.0e9;
}

static void XHQInstallBitrateHooks(void) {
    if (gBitrateHooked) return;
    Class cls = objc_getClass("T1VideoBitRateManager");
    if (!cls) return;

    XHQHookInstance(cls, "currentPreferredPeakBitRateWithAutoplaying:", (IMP)XHQPeakBitrate, (IMP *)&gOrigPeakBitrate);
    XHQHookInstance(cls, "currentBitrateForMp4VariantSelectionWithAutoplaying:", (IMP)XHQMp4Bitrate, (IMP *)&gOrigMp4Bitrate);
    XHQHookInstance(cls, "_t1_autoplayBitRateForHighQualityForAccountID:", (IMP)XHQHighQualityBitrate, (IMP *)&gOrigHighQualityBitrate);
    XHQHookInstance(cls, "_t1_autoplayBitRateForHighQualityWiFiForAccountID:", (IMP)XHQHighQualityWiFiBitrate, (IMP *)&gOrigHighQualityWiFiBitrate);

    gBitrateHooked = YES;
    XHQLog(@"T1VideoBitRateManager hooked");
}

#pragma mark - Install / retry

static void XHQInstallAll(void) {
    XHQInstallAVHooks();
    XHQInstallStateHook();
    XHQInstallControlHook();
    XHQInstallBitrateHooks();

    BOOL done = gAVHooked && gStateHooked && gControlHooked && gBitrateHooked;
    if (done) {
        XHQLog(@"all hooks installed");
        return;
    }

    if (gInstallAttempts++ >= 100) {
        XHQLog(@"gave up waiting for classes (AV=%d state=%d control=%d bitrate=%d)",
               gAVHooked, gStateHooked, gControlHooked, gBitrateHooked);
        return;
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        XHQInstallAll();
    });
}

__attribute__((constructor))
static void XHighestQualityInit(void) {
    XHQLog(@"loading");
    dispatch_async(dispatch_get_main_queue(), ^{
        XHQInstallAll();
    });
}
