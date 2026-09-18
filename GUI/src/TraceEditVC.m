#import "TraceEditVC.h"
#import "ConfigStore.h"
#import "ExprInput.h"
#import "HexValue.h"
#import "TriggerEditVC.h"
#import "WatchEditVC.h"
#import <objc/runtime.h>

#define TRACE_DEFAULT_LOGMASK 17
#define TRACE_MIN_RANGE 0x10

static BOOL TraceCountTextValid(NSString *text, NSInteger *value) {
    if (![text isKindOfClass:[NSString class]] || text.length == 0) return NO;
    NSCharacterSet *bad = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    if ([text rangeOfCharacterFromSet:bad].location != NSNotFound) return NO;
    NSInteger n = text.integerValue;
    if (value) *value = n;
    return n >= 1 && n <= 16;
}

@interface TraceFieldCell : UITableViewCell
@property(nonatomic, strong) UITextField *field;
@end
@implementation TraceFieldCell
- (instancetype)init {
    self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    if (self) {
        _field = [UITextField new];
        _field.textAlignment = NSTextAlignmentRight;
        _field.clearButtonMode = UITextFieldViewModeWhileEditing;
        _field.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_field];
        [NSLayoutConstraint activateConstraints:@[
            [_field.leadingAnchor constraintEqualToAnchor:self.contentView.centerXAnchor],
            [_field.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
            [_field.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],
            [_field.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor],
        ]];
        self.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    return self;
}
@end

@interface TraceEditVC () <UITextFieldDelegate>
@property(nonatomic, strong) NSMutableDictionary *item;
@property(nonatomic, assign) BOOL isNew;
@end

@implementation TraceEditVC
- (instancetype)initWithItem:(NSMutableDictionary *)item isNew:(BOOL)isNew {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) { _item = item; _isNew = isNew; }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.isNew ? @"添加 Trace" : @"编辑 Trace";
    self.tableView.rowHeight = 52;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:@"完成" style:UIBarButtonItemStyleDone target:self action:@selector(done)];
    self.item[@"logMask"] = @(TRACE_DEFAULT_LOGMASK);
    for (NSString *key in @[ @"count", @"delaySecs" ]) {
        id v = self.item[key];
        if (![v isKindOfClass:[NSNumber class]]) {
            NSInteger fallback = [key isEqualToString:@"count"] ? 1 : 0;
            self.item[key] = @([v respondsToSelector:@selector(integerValue)]
                                   ? [v integerValue] : fallback);
        }
    }
    for (NSString *key in @[ @"start", @"end" ]) {
        id v = self.item[key];
        if ([v isKindOfClass:[NSNumber class]]) {
            self.item[key] = [NSString stringWithFormat:@"0x%llx",
                              [v unsignedLongLongValue]];
        }
    }
    if (![self.item[@"triggers"] isKindOfClass:[NSMutableArray class]]) {
        NSArray *old = [self.item[@"triggers"] isKindOfClass:[NSArray class]] ? self.item[@"triggers"] : @[];
        NSMutableArray *copy = [NSMutableArray array];
        for (NSDictionary *tr in old) if ([tr isKindOfClass:[NSDictionary class]]) [copy addObject:[tr mutableCopy]];
        self.item[@"triggers"] = copy;
    }
    NSMutableArray *triggers = self.item[@"triggers"];
    for (NSUInteger i = 0; i < triggers.count; i++) {
        NSMutableDictionary *trigger = [triggers[i] isKindOfClass:[NSMutableDictionary class]]
                                           ? triggers[i] : [triggers[i] mutableCopy];
        if (trigger[@"triggerLimit"] == nil) trigger[@"triggerLimit"] = @1;
        if (trigger != nil) triggers[i] = trigger;
    }
    if (self.item[@"triggerConsume"] == nil) self.item[@"triggerConsume"] = @"repeat";
    [self beginEditingTarget:self.item];
}

- (NSSet<NSString *> *)snapshotExcludedKeys {
    return [NSSet setWithObjects:@"watches", @"triggers", nil];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 5; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return @[ @"目标 App", @"模块与地址(十六进制)", @"选项", @"触发条件(可选)", @"监视(watch)" ][section];
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 1) return @"结束地址至少要比起始地址大 0x10。";
    if (section == 2) return @"Trace 次数允许 1–16 次。";
    if (section == 3) return @"没有条件时为无条件 Trace；有多条时，满足任意一条即可。相同判断地址共享一个 Hook。";
    return nil;
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 1;
    if (section == 1) return 3;
    if (section == 2) return 3;
    if (section == 3) return (NSInteger)[self.item[@"triggers"] count] + 2;
    return (NSInteger)[self.item[@"watches"] count] + 1;
}

- (TraceFieldCell *)field:(NSString *)key label:(NSString *)label placeholder:(NSString *)placeholder numeric:(BOOL)numeric {
    TraceFieldCell *c = [TraceFieldCell new];
    c.textLabel.text = label;
    c.field.placeholder = placeholder;
    c.field.delegate = self;
    c.field.keyboardType = numeric ? UIKeyboardTypeNumberPad : UIKeyboardTypeASCIICapable;
    id v = self.item[key];
    c.field.text = [v isKindOfClass:[NSString class]] ? v : [v description];
    objc_setAssociatedObject(c.field, "traceKey", key, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(c.field, "traceNumeric", @(numeric), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [c.field addTarget:self action:@selector(fieldChanged:) forControlEvents:UIControlEventEditingChanged];
    if ([key isEqualToString:@"start"] || [key isEqualToString:@"end"]) AttachHexKeyboard(c.field);
    return c;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section == 0) {
        UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
        c.textLabel.text = @"App";
        c.detailTextLabel.text = [self.item[@"appName"] length] ? self.item[@"appName"] : self.item[@"bundleId"];
        c.selectionStyle = UITableViewCellSelectionStyleNone;
        return c;
    }
    if (ip.section == 1) {
        return [self field:@[ @"module", @"start", @"end" ][ip.row]
                      label:@[ @"模块名", @"起始地址", @"结束地址" ][ip.row]
                placeholder:@[ @"ModuleName", @"0x...", @"0x..." ][ip.row] numeric:NO];
    }
    if (ip.section == 2) {
        if (ip.row == 0) return [self field:@"delaySecs" label:@"延迟(秒)" placeholder:@"0" numeric:YES];
        if (ip.row == 1) return [self field:@"count" label:@"Trace 次数" placeholder:@"1–16" numeric:YES];
        UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        c.textLabel.text = @"仅记录模块内指令";
        c.selectionStyle = UITableViewCellSelectionStyleNone;
        UISwitch *sw = [UISwitch new];
        sw.on = [self.item[@"moduleOnly"] boolValue];
        [sw addTarget:self action:@selector(moduleOnlyChanged:) forControlEvents:UIControlEventValueChanged];
        c.accessoryView = sw;
        return c;
    }
    if (ip.section == 3) {
        NSMutableArray *triggers = self.item[@"triggers"];
        if (ip.row == 0) {
            UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
            c.textLabel.text = @"触发消耗策略";
            NSString *policy = self.item[@"triggerConsume"];
            c.detailTextLabel.text = [policy isEqual:@"once"] ? @"仅一次"
                                   : [policy isEqual:@"custom"] ? @"自定义"
                                                                 : @"可重复";
            c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            return c;
        }
        if (ip.row == (NSInteger)triggers.count + 1) {
            UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
            c.textLabel.text = @"+ 添加触发条件";
            c.textLabel.textColor = [UIColor systemBlueColor];
            return c;
        }
        NSDictionary *tr = triggers[ip.row - 1];
        UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        NSString *rawAddress = [tr[@"triggerAddress"] isKindOfClass:[NSString class]]
                                   ? tr[@"triggerAddress"] : [tr[@"triggerAddress"] description];
        NSString *address = rawAddress.length ? rawAddress : @"起始地址";
        c.textLabel.text = [NSString stringWithFormat:@"%@ · %@", address, tr[@"triggerExpr"] ?: @""];
        NSDictionary *names = @{ @"notnull": @"非空", @"bytes": @"字节", @"cstr": @"字符串", @"u64": @"u64" };
        NSString *match = names[tr[@"triggerMatch"] ?: @"notnull"];
        if ([self.item[@"triggerConsume"] isEqual:@"custom"]) {
            NSInteger limit = [tr[@"triggerLimit"] integerValue];
            if (limit < 1) limit = 1;
            c.detailTextLabel.text = [NSString stringWithFormat:@"%@ · 上限 %ld 次",
                                      match, (long)limit];
        } else {
            c.detailTextLabel.text = match;
        }
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return c;
    }
    NSMutableArray *watches = self.item[@"watches"];
    if (ip.row == (NSInteger)watches.count) {
        UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        c.textLabel.text = @"+ 添加监视";
        c.textLabel.textColor = [UIColor systemBlueColor];
        return c;
    }
    NSDictionary *w = watches[ip.row];
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    NSString *addr = [w[@"expr"] length] ? w[@"expr"] : (w[@"reg"] ?: @"?");
    c.textLabel.text = [NSString stringWithFormat:@"%@ %@ %@", addr, w[@"action"] ?: @"", [w[@"label"] length] ? w[@"label"] : @""];
    c.detailTextLabel.text = [NSString stringWithFormat:@"%@ @ %@", w[@"module"] ?: @"", w[@"offset"] ?: @""];
    c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return c;
}

- (void)fieldChanged:(UITextField *)field {
    NSString *key = objc_getAssociatedObject(field, "traceKey");
    NSString *text = [field.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([key isEqualToString:@"count"]) {
        field.textColor = TraceCountTextValid(text, NULL) ? [UIColor labelColor]
                                                         : [UIColor systemRedColor];
    } else if ([key isEqualToString:@"start"] || [key isEqualToString:@"end"]) {
        unsigned long long n = 0;
        field.textColor = HexParseInput(text, &n) ? [UIColor labelColor] : [UIColor systemRedColor];
    }
    [self updatePopGesture];
}
- (void)textFieldDidEndEditing:(UITextField *)field {
    NSString *key = objc_getAssociatedObject(field, "traceKey");
    if (key == nil) return;
    if ([key isEqualToString:@"start"] || [key isEqualToString:@"end"]) {
        unsigned long long n = 0;
        if (HexParseInput(field.text, &n)) field.text = [NSString stringWithFormat:@"0x%llx", n];
        self.item[key] = field.text ?: @"";
    } else if ([objc_getAssociatedObject(field, "traceNumeric") boolValue]) {
        NSInteger n = 0;
        if ([key isEqualToString:@"count"] && !TraceCountTextValid(field.text, &n)) {
            self.item[key] = field.text ?: @"";
        } else {
            self.item[key] = @([key isEqualToString:@"count"] ? n
                                                               : field.text.integerValue);
        }
    } else self.item[key] = field.text ?: @"";
    [self fieldChanged:field];
}
- (BOOL)textFieldShouldReturn:(UITextField *)field {
    [field resignFirstResponder];
    return YES;
}
- (void)moduleOnlyChanged:(UISwitch *)sw { self.item[@"moduleOnly"] = @(sw.on); [self updatePopGesture]; }

- (void)pickPolicy:(UITableViewCell *)source {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"触发消耗策略" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray *labels = @[ @"仅一次", @"可重复", @"自定义" ];
    NSArray *keys = @[ @"once", @"repeat", @"custom" ];
    for (NSUInteger i = 0; i < labels.count; i++) {
        NSString *key = keys[i];
        [sheet addAction:[UIAlertAction actionWithTitle:labels[i] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            self.item[@"triggerConsume"] = key;
            [self.tableView reloadData]; [self updatePopGesture];
            if ([key isEqualToString:@"custom"]) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    UIAlertController *notice = [UIAlertController
                        alertControllerWithTitle:@"自定义触发次数"
                                         message:@"请进入每一条触发条件的编辑页面，设置该条件的“触发次数上限”。新条件和旧配置的默认上限都是 1 次。"
                                  preferredStyle:UIAlertControllerStyleAlert];
                    [notice addAction:[UIAlertAction actionWithTitle:@"知道了"
                                                               style:UIAlertActionStyleDefault
                                                             handler:nil]];
                    [self presentViewController:notice animated:YES completion:nil];
                });
            }
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = source;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tableView deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == 3) {
        NSMutableArray *triggers = self.item[@"triggers"];
        if (ip.row == 0) { [self pickPolicy:[tableView cellForRowAtIndexPath:ip]]; return; }
        BOOL adding = ip.row == (NSInteger)triggers.count + 1;
        NSMutableDictionary *tr;
        if (adding) {
            tr = [@{ @"triggerAddress": @"", @"triggerExpr": @"", @"triggerMatch": @"notnull",
                     @"triggerValue": @"", @"triggerWhere": @"prefix", @"triggerScan": @"0x100" } mutableCopy];
            tr[@"triggerLimit"] = @1;
            NSDictionary *first = triggers.firstObject;
            if (first != nil) {
                if (first[@"triggerAddress"] != nil) tr[@"triggerAddress"] = first[@"triggerAddress"];
                if (first[@"triggerExpr"] != nil) tr[@"triggerExpr"] = first[@"triggerExpr"];
            }
        } else tr = triggers[ip.row - 1];
        unsigned long long start = 0, end = 0;
        HexParseInput([self.item[@"start"] description], &start);
        HexParseInput([self.item[@"end"] description], &end);
        BOOL customLimit = [self.item[@"triggerConsume"] isEqual:@"custom"];
        TriggerEditVC *vc = [[TriggerEditVC alloc] initWithTrigger:tr start:start
                                                               end:end
                                                       customLimit:customLimit];
        __weak typeof(self) weakSelf = self;
        vc.onDone = ^{ if (adding) [triggers addObject:tr]; [weakSelf.tableView reloadData]; };
        [self.navigationController pushViewController:vc animated:YES];
        return;
    }
    if (ip.section != 4) return;
    NSMutableArray *watches = self.item[@"watches"];
    BOOL adding = ip.row == (NSInteger)watches.count;
    NSMutableDictionary *watch = adding
        ? [@{ @"module": self.item[@"module"] ?: @"", @"offset": @"0x0", @"reg": @"x0",
              @"action": @"cstr", @"size": @"0x0", @"label": @"" } mutableCopy]
        : watches[ip.row];
    WatchEditVC *vc = [[WatchEditVC alloc] initWithWatch:watch];
    __weak typeof(self) weakSelf = self;
    vc.onDone = ^{ if (adding) [watches addObject:watch]; [weakSelf.tableView reloadData]; };
    [self.navigationController pushViewController:vc animated:YES];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
    NSMutableArray *array = nil;
    NSInteger index = -1;
    if (ip.section == 3) { array = self.item[@"triggers"]; index = ip.row - 1; }
    else if (ip.section == 4) { array = self.item[@"watches"]; index = ip.row; }
    if (index < 0 || index >= (NSInteger)array.count) return nil;
    __weak typeof(self) weakSelf = self;
    UIContextualAction *del = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"删除" handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
        [array removeObjectAtIndex:index]; [weakSelf.tableView reloadData]; done(YES);
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[ del ]];
}

- (void)alert:(NSString *)title message:(NSString *)message {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (BOOL)validateTriggersWithStart:(unsigned long long)start end:(unsigned long long)end {
    NSArray *triggers = self.item[@"triggers"];
    NSMutableArray<NSNumber *> *addresses = [NSMutableArray array];
    for (NSUInteger i = 0; i < triggers.count; i++) {
        NSDictionary *tr = triggers[i];
        if ([self.item[@"triggerConsume"] isEqual:@"custom"] &&
            !TraceCountTextValid([tr[@"triggerLimit"] description], NULL)) {
            [self alert:@"触发次数上限无效"
                message:[NSString stringWithFormat:
                    @"第 %lu 条触发条件的次数上限必须是 1–16。",
                    (unsigned long)i + 1]];
            return NO;
        }
        if (!ExprSyntaxOK(tr[@"triggerExpr"])) {
            [self alert:@"触发条件无效" message:[NSString stringWithFormat:@"第 %lu 条触发条件的取址表达式无效。", (unsigned long)i + 1]]; return NO;
        }
        unsigned long long address = start;
        NSString *rawAddress = [tr[@"triggerAddress"] isKindOfClass:[NSString class]]
                                   ? tr[@"triggerAddress"] : [tr[@"triggerAddress"] description];
        if (rawAddress.length && !HexParseInput(rawAddress, &address)) {
            [self alert:@"判断地址无效" message:[NSString stringWithFormat:@"第 %lu 条触发条件的地址无效。", (unsigned long)i + 1]]; return NO;
        }
        if (address > start && address < end) {
            [self alert:@"判断地址无效" message:[NSString stringWithFormat:@"第 %lu 条触发条件的地址不能位于起始与结束地址之间。", (unsigned long)i + 1]]; return NO;
        }
        unsigned long long ds = address > start ? address - start : start - address;
        if (address != start && ds < TRACE_MIN_RANGE) {
            [self alert:@"Hook 距离不足" message:[NSString stringWithFormat:@"第 %lu 条触发地址与起始地址至少要相差 0x10。", (unsigned long)i + 1]]; return NO;
        }
        for (NSUInteger j = 0; j < addresses.count; j++) {
            unsigned long long other = addresses[j].unsignedLongLongValue;
            unsigned long long d = address > other ? address - other : other - address;
            if (address != other && d < TRACE_MIN_RANGE) {
                [self alert:@"Hook 距离不足" message:[NSString stringWithFormat:@"第 %lu 条与第 %lu 条触发地址不同，必须至少相差 0x10；完全相同则可共享 Hook。", (unsigned long)j + 1, (unsigned long)i + 1]]; return NO;
            }
        }
        [addresses addObject:@(address)];
    }
    return YES;
}

- (void)done {
    [self.view endEditing:YES];
    unsigned long long start = 0, end = 0;
    if (!HexParseInput([self.item[@"start"] description], &start) || !HexParseInput([self.item[@"end"] description], &end)) {
        [self alert:@"地址无效" message:@"起始地址和结束地址只能包含 0X、0-9 和 A-F。"]; return;
    }
    if (end <= start || end - start < TRACE_MIN_RANGE) {
        [self alert:@"Trace 区间无效" message:@"结束地址必须至少比起始地址大 0x10。"]; return;
    }
    NSString *countText = [self.item[@"count"] description];
    if (!TraceCountTextValid(countText, NULL)) {
        [self alert:@"Trace 次数无效" message:@"Trace 次数必须是 1–16 的整数。"]; return;
    }
    if (![self validateTriggersWithStart:start end:end]) return;
    ConfigStore *store = [ConfigStore shared];
    BOOL appended = self.isNew;
    if (appended) [store.items addObject:self.item];
    if (![store save]) {
        if (appended) [store.items removeObjectIdenticalTo:self.item];
        [self alert:@"错误" message:@"保存失败(检查配置目录权限)。"]; return;
    }
    self.isNew = NO;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"完成" message:@"配置已保存，请重开目标 App 生效。" preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        [self.navigationController popToRootViewControllerAnimated:YES];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}
@end
