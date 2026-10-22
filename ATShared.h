// AppTime — shared between the SpringBoard tracker and the Settings pane.

#import <Foundation/Foundation.h>

#define AT_DATA_DIR      @"/var/mobile/Library/AppTime"
#define AT_DATA_PATH     @"/var/mobile/Library/AppTime/usage.plist"
#define AT_LOG_PATH      @"/var/mobile/AppTime.log"

// Darwin notifications: pane -> SpringBoard (flush, reset), SpringBoard -> pane (saved).
#define AT_NOTIFY_FLUSH  "com.mbucc9000.apptime/flush"
#define AT_NOTIFY_RESET  "com.mbucc9000.apptime/reset"
#define AT_NOTIFY_SAVED  "com.mbucc9000.apptime/saved"

// Time on the home screen / folders is filed under SpringBoard's own id.
#define AT_HOME_ID       @"com.apple.springboard"
#define AT_KEEP_DAYS     60

// usage.plist layout:
//   since  : NSDate            when tracking started (or was last reset)
//   days   : { "yyyy-MM-dd" : { displayIdentifier : seconds } }   last AT_KEEP_DAYS days
//   totals : { displayIdentifier : seconds }                        all time
//   names  : { displayIdentifier : display name }

static inline NSCalendar *ATCalendar(void) {
    static NSCalendar *cal;
    if (!cal) {
        cal = [[NSCalendar alloc] initWithCalendarIdentifier:NSGregorianCalendar];
        cal.timeZone = [NSTimeZone localTimeZone];
    }
    return cal;
}

static inline NSString *ATDayKey(NSDate *date) {
    static NSDateFormatter *fmt;
    if (!fmt) {
        fmt = [[NSDateFormatter alloc] init];
        fmt.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
        fmt.calendar = ATCalendar();
        fmt.timeZone = [NSTimeZone localTimeZone];
        fmt.dateFormat = @"yyyy-MM-dd";
    }
    return [fmt stringFromDate:date];
}

static inline NSString *ATFormatDuration(double seconds) {
    long s = (long)seconds;
    if (s < 60) {
        return [NSString stringWithFormat:@"%lds", s];
    }
    long h = s / 3600, m = (s % 3600) / 60;
    if (h == 0) {
        return [NSString stringWithFormat:@"%ldm", m];
    }
    return [NSString stringWithFormat:@"%ldh %02ldm", h, m];
}
