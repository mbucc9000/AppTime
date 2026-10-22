// AppTime Settings pane — Settings > App Time.
// Reads usage.plist written by the SpringBoard tracker. On appear it asks SpringBoard to
// flush the in-progress session, and redraws whenever SpringBoard reports a save.

#import <UIKit/UIKit.h>
#import <notify.h>
#import "../ATShared.h"

@interface PSSpecifier : NSObject
+ (id)preferenceSpecifierNamed:(NSString *)name target:(id)target set:(SEL)set get:(SEL)get
                        detail:(Class)detail cell:(int)cell edit:(Class)edit;
+ (id)groupSpecifierWithName:(NSString *)name;
+ (id)emptyGroupSpecifier;
- (void)setProperty:(id)value forKey:(NSString *)key;
- (id)propertyForKey:(NSString *)key;
- (void)setValues:(NSArray *)values titles:(NSArray *)titles;
@end

@interface PSViewController : UIViewController
@end

@interface PSListController : PSViewController {
    NSArray *_specifiers;
}
- (void)reloadSpecifiers;
- (int)indexForIndexPath:(NSIndexPath *)indexPath;
- (PSSpecifier *)specifierAtIndex:(int)index;
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath;
@end

@interface PSTableCell : UITableViewCell
+ (int)cellTypeFromString:(NSString *)string;
@end

@interface UIImage (AppTimePrivate)
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bundleID format:(int)format scale:(float)scale;
@end

enum { ATRangeToday = 0, ATRangeWeek = 1, ATRangeAll = 2 };

// Resolve Preferences cell types by name instead of trusting enum values.
static int ATCellType(NSString *name, int fallback) {
    Class cls = NSClassFromString(@"PSTableCell");
    if ([cls respondsToSelector:@selector(cellTypeFromString:)]) {
        return [cls cellTypeFromString:name];
    }
    return fallback;
}

@interface ATRootListController : PSListController <UIAlertViewDelegate> {
    int _range;
    int _savedToken;
    BOOL _registered;
    BOOL _visible;
    NSMutableDictionary *_icons;
}
@end

@implementation ATRootListController

// PreferenceLoader may build us with initForContentSize: rather than init, so set up lazily.
- (void)registerForSaves {
    if (_registered) {
        return;
    }
    __weak ATRootListController *weakSelf = self;
    _registered = (notify_register_dispatch(AT_NOTIFY_SAVED, &_savedToken, dispatch_get_main_queue(), ^(int token) {
        ATRootListController *s = weakSelf;
        if (s && s->_visible) {
            [s reloadData];
        }
    }) == NOTIFY_STATUS_OK);
}

- (void)dealloc {
    if (_registered) {
        notify_cancel(_savedToken);
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self registerForSaves];
    _visible = YES;
    notify_post(AT_NOTIFY_FLUSH);   // SpringBoard books the running session, then posts "saved"
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    _visible = NO;
}

- (void)reloadData {
    _specifiers = nil;
    [self reloadSpecifiers];
}

#pragma mark - Data

- (NSDictionary *)usageForRange:(int)range data:(NSDictionary *)data {
    if (range == ATRangeAll) {
        return data[@"totals"];
    }
    NSDictionary *days = data[@"days"];
    if (range == ATRangeToday) {
        return days[ATDayKey([NSDate date])];
    }
    NSMutableDictionary *sum = [NSMutableDictionary dictionary];
    for (int i = 0; i < 7; i++) {
        NSDictionary *day = days[ATDayKey([NSDate dateWithTimeIntervalSinceNow:-86400.0 * i])];
        for (NSString *ident in day) {
            sum[ident] = @([sum[ident] doubleValue] + [day[ident] doubleValue]);
        }
    }
    return sum;
}

- (UIImage *)iconFor:(NSString *)ident {
    if ([ident isEqualToString:AT_HOME_ID]) {
        return nil;
    }
    if (!_icons) {
        _icons = [NSMutableDictionary dictionary];
    }
    UIImage *icon = _icons[ident];
    if (!icon && [UIImage respondsToSelector:@selector(_applicationIconImageForBundleIdentifier:format:scale:)]) {
        UIImage *raw = [UIImage _applicationIconImageForBundleIdentifier:ident format:0
                                                                   scale:[UIScreen mainScreen].scale];
        if (raw) {
            // Normalise to the 29pt Settings icon size whatever format 0 turns out to be.
            UIGraphicsBeginImageContextWithOptions(CGSizeMake(29, 29), NO, 0);
            [raw drawInRect:CGRectMake(0, 0, 29, 29)];
            icon = UIGraphicsGetImageFromCurrentImageContext();
            UIGraphicsEndImageContext();
            _icons[ident] = icon;
        }
    }
    return icon;
}

#pragma mark - Specifiers

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self buildSpecifiers];
    }
    return _specifiers;
}

- (NSArray *)buildSpecifiers {
    Class PSS = NSClassFromString(@"PSSpecifier");
    int segmentCell = ATCellType(@"PSSegmentCell", 9);
    int titleValueCell = ATCellType(@"PSTitleValueCell", 4);
    int staticTextCell = ATCellType(@"PSStaticTextCell", 7);
    int buttonCell = ATCellType(@"PSButtonCell", 13);

    NSDictionary *data = [NSDictionary dictionaryWithContentsOfFile:AT_DATA_PATH];
    NSDictionary *names = data[@"names"];
    NSDictionary *usage = [self usageForRange:_range data:data];
    NSArray *idents = [[usage allKeys] sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
        return [usage[b] compare:usage[a]];
    }];

    NSMutableArray *specs = [NSMutableArray array];

    [specs addObject:[PSS emptyGroupSpecifier]];
    PSSpecifier *seg = [PSS preferenceSpecifierNamed:@"Range" target:self set:@selector(setRange:specifier:)
                                                 get:@selector(range:) detail:Nil cell:segmentCell edit:Nil];
    [seg setValues:@[ @(ATRangeToday), @(ATRangeWeek), @(ATRangeAll) ]
            titles:@[ @"Today", @"Last 7 Days", @"All Time" ]];
    [specs addObject:seg];

    double total = 0;
    for (NSString *ident in idents) {
        total += [usage[ident] doubleValue];
    }
    NSArray *headers = @[ @"Today", @"Last 7 Days", @"All Time" ];
    PSSpecifier *group = [PSS groupSpecifierWithName:headers[_range]];
    NSString *footer = [NSString stringWithFormat:@"Total: %@", ATFormatDuration(total)];
    if (_range == ATRangeWeek) {
        footer = [footer stringByAppendingFormat:@"  ·  Daily average: %@", ATFormatDuration(total / 7)];
    } else if (_range == ATRangeAll && [data[@"since"] isKindOfClass:[NSDate class]]) {
        footer = [footer stringByAppendingFormat:@"\nTracking since %@",
                  [NSDateFormatter localizedStringFromDate:data[@"since"] dateStyle:NSDateFormatterMediumStyle
                                                 timeStyle:NSDateFormatterShortStyle]];
    }
    [group setProperty:footer forKey:@"footerText"];
    [specs addObject:group];

    for (NSString *ident in idents) {
        double secs = [usage[ident] doubleValue];
        if (secs < 1) {
            continue;
        }
        NSString *name = names[ident] ?: ident;
        PSSpecifier *row = [PSS preferenceSpecifierNamed:name target:self set:NULL get:@selector(duration:)
                                                  detail:Nil cell:titleValueCell edit:Nil];
        [row setProperty:@(secs) forKey:@"atSeconds"];
        UIImage *icon = [self iconFor:ident];
        if (icon) {
            [row setProperty:icon forKey:@"iconImage"];
        }
        [specs addObject:row];
    }
    if (specs.count == 3) {
        [specs addObject:[PSS preferenceSpecifierNamed:@"Nothing recorded yet" target:self set:NULL get:NULL
                                                detail:Nil cell:staticTextCell edit:Nil]];
    }

    PSSpecifier *resetGroup = [PSS emptyGroupSpecifier];
    [resetGroup setProperty:@"Only counts time while the screen is on and unlocked. "
                            @"Daily history is kept for 60 days; All Time is kept until you reset."
                     forKey:@"footerText"];
    [specs addObject:resetGroup];
    PSSpecifier *reset = [PSS preferenceSpecifierNamed:@"Reset All Data" target:self set:NULL get:NULL
                                                detail:Nil cell:buttonCell edit:Nil];
    [reset setProperty:@"reset" forKey:@"atAction"];
    [specs addObject:reset];

    return specs;
}

- (id)range:(PSSpecifier *)spec {
    return @(_range);
}

- (void)setRange:(id)value specifier:(PSSpecifier *)spec {
    _range = [value intValue];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self reloadData];
    });
}

- (id)duration:(PSSpecifier *)spec {
    return ATFormatDuration([[spec propertyForKey:@"atSeconds"] doubleValue]);
}

#pragma mark - Reset

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    PSSpecifier *spec = [self specifierAtIndex:[self indexForIndexPath:indexPath]];
    if ([[spec propertyForKey:@"atAction"] isEqual:@"reset"]) {
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Reset App Time?"
                                                        message:@"This erases all recorded usage."
                                                       delegate:self
                                              cancelButtonTitle:@"Cancel"
                                              otherButtonTitles:@"Reset", nil];
        [alert show];
        return;
    }
    [super tableView:tableView didSelectRowAtIndexPath:indexPath];
}

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex {
    if (buttonIndex != alertView.cancelButtonIndex) {
        notify_post(AT_NOTIFY_RESET);   // SpringBoard owns the file; it resets and posts "saved"
    }
}

@end
