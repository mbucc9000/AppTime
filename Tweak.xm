// AppTime — tracks how long each app is on screen (unlocked, screen on) on iOS 6.
//
// Runs in SpringBoard only. Every hook just calls ATResample(), which asks SpringBoard
// "what's in front right now?" and, if that changed, books the elapsed time to the
// previous app. Missing one hook therefore can't corrupt anything: the next event (or the
// 60 s checkpoint) re-samples and corrects it. Elapsed time uses mach_absolute_time, which
// doesn't advance while the device sleeps; day buckets use the wall clock and are split at
// local midnight.

#import <UIKit/UIKit.h>
#import <mach/mach_time.h>
#import <notify.h>
#import "ATShared.h"

@interface SBApplication : NSObject
- (NSString *)displayIdentifier;
- (NSString *)displayName;
@end

@interface SpringBoard : UIApplication
- (SBApplication *)_accessibilityFrontMostApplication;
- (BOOL)isLocked;
@end

static NSMutableDictionary *gDays;     // dayKey -> { id -> seconds }
static NSMutableDictionary *gTotals;   // id -> seconds
static NSMutableDictionary *gNames;    // id -> display name
static NSDate *gSince;

static NSString *gCurrent;             // id being timed; nil while locked
static double gStart;                  // ATNow() at last switch/checkpoint
static dispatch_source_t gTimer;

static void ATLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[AppTime] %@", msg);

    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], msg];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary *attrs = [fm attributesOfItemAtPath:AT_LOG_PATH error:nil];
    if (!attrs || [attrs fileSize] > 256 * 1024) {
        [fm createFileAtPath:AT_LOG_PATH contents:nil attributes:nil];
    }
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:AT_LOG_PATH];
    [fh seekToEndOfFile];
    [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
}

static double ATNow(void) {
    static mach_timebase_info_data_t tb;
    if (tb.denom == 0) {
        mach_timebase_info(&tb);
    }
    return (double)mach_absolute_time() * tb.numer / tb.denom / 1e9;
}

#pragma mark - Storage

static NSMutableDictionary *ATMutableDict(id obj) {
    return [obj isKindOfClass:[NSDictionary class]] ? [obj mutableCopy] : [NSMutableDictionary dictionary];
}

static void ATLoad(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:AT_DATA_PATH];
    gDays = [NSMutableDictionary dictionary];
    NSDictionary *days = d[@"days"];
    if ([days isKindOfClass:[NSDictionary class]]) {
        for (NSString *key in days) {
            gDays[key] = ATMutableDict(days[key]);
        }
    }
    gTotals = ATMutableDict(d[@"totals"]);
    gNames = ATMutableDict(d[@"names"]);
    gNames[AT_HOME_ID] = @"Home Screen";
    gSince = [d[@"since"] isKindOfClass:[NSDate class]] ? d[@"since"] : [NSDate date];
}

static void ATPrune(void) {
    NSDate *cutoffDate = [NSDate dateWithTimeIntervalSinceNow:-(double)AT_KEEP_DAYS * 86400];
    NSString *cutoff = ATDayKey(cutoffDate);
    for (NSString *key in [gDays allKeys]) {
        if ([key compare:cutoff] == NSOrderedAscending) {
            [gDays removeObjectForKey:key];
        }
    }
}

static void ATSave(void) {
    ATPrune();
    NSDictionary *d = @{ @"version": @1, @"since": gSince, @"days": gDays,
                         @"totals": gTotals, @"names": gNames };
    [[NSFileManager defaultManager] createDirectoryAtPath:AT_DATA_DIR
                              withIntermediateDirectories:YES attributes:nil error:nil];
    if (![d writeToFile:AT_DATA_PATH atomically:YES]) {
        ATLog(@"save FAILED (%@)", AT_DATA_PATH);
    }
    notify_post(AT_NOTIFY_SAVED);
}

static void ATAdd(NSMutableDictionary *dict, NSString *ident, double secs) {
    dict[ident] = @([dict[ident] doubleValue] + secs);
}

// Books time since gStart to gCurrent, split across local midnights, and restarts the clock.
static void ATCommit(double now) {
    double elapsed = now - gStart;
    gStart = now;
    if (!gCurrent || elapsed <= 0) {
        return;
    }
    ATAdd(gTotals, gCurrent, elapsed);

    NSDate *end = [NSDate date];
    double remaining = elapsed;
    while (remaining > 0) {
        NSDate *dayStart = nil;
        [ATCalendar() rangeOfUnit:NSDayCalendarUnit startDate:&dayStart interval:NULL forDate:end];
        double part = MIN(remaining, [end timeIntervalSinceDate:dayStart]);
        if (part > 0) {
            NSString *key = ATDayKey(dayStart);
            NSMutableDictionary *day = gDays[key];
            if (!day) {
                day = gDays[key] = [NSMutableDictionary dictionary];
            }
            ATAdd(day, gCurrent, part);
            remaining -= part;
        }
        end = [dayStart dateByAddingTimeInterval:-0.001];
    }
}

#pragma mark - Sampling

static NSString *ATFrontIdentifier(void) {
    SpringBoard *sb = (SpringBoard *)[UIApplication sharedApplication];
    if ([sb respondsToSelector:@selector(isLocked)] && [sb isLocked]) {
        return nil;
    }
    SBApplication *app = nil;
    if ([sb respondsToSelector:@selector(_accessibilityFrontMostApplication)]) {
        app = [sb _accessibilityFrontMostApplication];
    }
    NSString *ident = [app displayIdentifier];
    if (!ident.length) {
        return AT_HOME_ID;
    }
    NSString *name = [app displayName];
    if (name.length && ![gNames[ident] isEqualToString:name]) {
        gNames[ident] = name;
    }
    return ident;
}

static void ATCheckpoint(NSString *why);

static void ATUpdateTimer(void) {
    if (gCurrent && !gTimer) {
        gTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(gTimer, dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC),
                                  60 * NSEC_PER_SEC, 5 * NSEC_PER_SEC);
        dispatch_source_set_event_handler(gTimer, ^{
            ATCheckpoint(@"timer");
        });
        dispatch_resume(gTimer);
    } else if (!gCurrent && gTimer) {
        dispatch_source_cancel(gTimer);
        gTimer = nil;
    }
}

static void ATResample(NSString *why) {
    NSString *front = ATFrontIdentifier();
    if (front == gCurrent || [front isEqualToString:gCurrent]) {
        return;
    }
    double now = ATNow();
    double spent = gCurrent ? now - gStart : 0;
    ATLog(@"%@ -> %@  (+%@ [%@])", gCurrent ?: @"(locked)", front ?: @"(locked)",
          ATFormatDuration(spent), why);
    ATCommit(now);
    gCurrent = [front copy];
    ATUpdateTimer();
    ATSave();
}

static void ATCheckpoint(NSString *why) {
    ATResample(why);
    ATCommit(ATNow());
    ATSave();
}

static void ATReset(void) {
    [gDays removeAllObjects];
    [gTotals removeAllObjects];
    gSince = [NSDate date];
    gStart = ATNow();
    ATLog(@"reset all data");
    ATSave();
}

// Hooks fire mid-transition, so sample now and again once SpringBoard has settled.
static void ATResampleSoon(NSString *why) {
    dispatch_async(dispatch_get_main_queue(), ^{
        ATResample(why);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        ATResample(why);
    });
}

static void ATDarwinCallback(CFNotificationCenterRef center, void *observer, CFStringRef name,
                             const void *object, CFDictionaryRef userInfo) {
    NSString *n = [(__bridge NSString *)name copy];
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([n isEqualToString:@(AT_NOTIFY_FLUSH)]) {
            ATCheckpoint(@"flush");
        } else if ([n isEqualToString:@(AT_NOTIFY_RESET)]) {
            ATReset();
        } else {
            ATResampleSoon(n);
        }
    });
}

#pragma mark - Hooks

%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    ATResampleSoon(@"launch");
}

- (void)frontDisplayDidChange {
    %orig;
    ATResampleSoon(@"frontDisplayDidChange");
}

%end

%hook SBApplication

- (void)didActivate {
    %orig;
    ATResampleSoon(@"didActivate");
}

- (void)didDeactivateForEventsOnly:(BOOL)eventsOnly {
    %orig;
    ATResampleSoon(@"didDeactivate");
}

- (void)didSuspend {
    %orig;
    ATResampleSoon(@"didSuspend");
}

- (void)didExitWithInfo:(id)info type:(int)type {
    %orig;
    ATResampleSoon(@"didExit");
}

%end

%ctor {
    @autoreleasepool {
        ATLoad();
        gStart = ATNow();
        ATLog(@"=== AppTime 1.0.0 loaded (%lu days on file, tracking since %@) ===",
              (unsigned long)gDays.count, gSince);

        CFNotificationCenterRef dc = CFNotificationCenterGetDarwinNotifyCenter();
        NSArray *names = @[ @"com.apple.springboard.lockstate",
                            @"com.apple.springboard.lockcomplete",
                            @"com.apple.springboard.hasBlankedScreen",
                            @(AT_NOTIFY_FLUSH), @(AT_NOTIFY_RESET) ];
        for (NSString *name in names) {
            CFNotificationCenterAddObserver(dc, NULL, ATDarwinCallback, (__bridge CFStringRef)name,
                                            NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        }
    }
}
