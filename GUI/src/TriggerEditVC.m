#import "TriggerEditVC.h"

#import "ExprInput.h"
#import "HexValue.h"
#import <objc/runtime.h>

#define TRIGGER_PATCH_SIZE 0x10
#define TRIGGER_SCAN_DEFAULT 0x100
#define TRIGGER_SCAN_MAX 0x1000

static BOOL TriggerLimitTextValid(NSString *text, NSInteger *value) {
    if (![text isKindOfClass:[NSString class]] || text.length == 0) return NO;
    NSCharacterSet *bad = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    if ([text rangeOfCharacterFromSet:bad].location != NSNotFound) return NO;
    NSInteger n = text.integerValue;
    if (value) *value = n;
    return n >= 1 && n <= 16;
}

@interface TriggerFieldCell : UITableViewCell
@property(nonatomic, strong) UITextField *field;
@end

@implementation TriggerFieldCell
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

typedef NS_ENUM(NSInteger, TriggerMatch) {
    TriggerMatchNotNull, TriggerMatchBytes, TriggerMatchCstr, TriggerMatchU64,
};
typedef NS_ENUM(NSInteger, TriggerWhere) { TriggerWherePrefix, TriggerWhereContains };
typedef NS_ENUM(NSInteger, TriggerRow) {
    TriggerRowExpr, TriggerRowAddress, TriggerRowLimit, TriggerRowMatch, TriggerRowWhere,
    TriggerRowValue, TriggerRowScan,
};

@interface TriggerEditVC () <UITextFieldDelegate>
@property(nonatomic, strong) NSMutableDictionary *trigger;
@property(nonatomic, assign) unsigned long long start;
@property(nonatomic, assign) unsigned long long end;
@property(nonatomic, assign) BOOL customLimit;
@end

@implementation TriggerEditVC

- (instancetype)initWithTrigger:(NSMutableDictionary *)trigger
                           start:(unsigned long long)start
                             end:(unsigned long long)end
                     customLimit:(BOOL)customLimit {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _trigger = trigger;
        _start = start;
        _end = end;
        _customLimit = customLimit;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"触发条件";
    self.tableView.rowHeight = 52;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:@"确定" style:UIBarButtonItemStyleDone
               target:self action:@selector(done)];
    if (self.trigger[@"triggerMatch"] == nil) self.trigger[@"triggerMatch"] = @"notnull";
    if (self.trigger[@"triggerLimit"] == nil) self.trigger[@"triggerLimit"] = @1;
    id address = self.trigger[@"triggerAddress"];
    if ([address isKindOfClass:[NSNumber class]]) {
        self.trigger[@"triggerAddress"] = [NSString stringWithFormat:@"0x%llx",
                                            [address unsignedLongLongValue]];
    }
    [self beginEditingTarget:self.trigger];
}

- (TriggerMatch)match {
    NSString *v = self.trigger[@"triggerMatch"];
    if ([v isEqualToString:@"bytes"]) return TriggerMatchBytes;
    if ([v isEqualToString:@"cstr"]) return TriggerMatchCstr;
    if ([v isEqualToString:@"u64"]) return TriggerMatchU64;
    return TriggerMatchNotNull;
}

- (TriggerWhere)where {
    NSString *v = self.trigger[@"triggerWhere"];
    if ([v isEqualToString:@"contains"]) return TriggerWhereContains;
    if ([v isEqualToString:@"prefix"]) return TriggerWherePrefix;
    return [self match] == TriggerMatchCstr ? TriggerWhereContains : TriggerWherePrefix;
}

- (unsigned long long)scan {
    unsigned long long n = HexValueFromJSON(self.trigger[@"triggerScan"]);
    return n ? n : TRIGGER_SCAN_DEFAULT;
}

- (NSArray<NSNumber *> *)rows {
    TriggerMatch m = [self match];
    NSMutableArray *rows = [@[ @(TriggerRowExpr), @(TriggerRowAddress) ] mutableCopy];
    if (self.customLimit) [rows addObject:@(TriggerRowLimit)];
    [rows addObject:@(TriggerRowMatch)];
    if (m == TriggerMatchNotNull) {
        return rows;
    }
    if (m == TriggerMatchU64) {
        [rows addObject:@(TriggerRowValue)];
        return rows;
    }
    [rows addObject:@(TriggerRowWhere)];
    [rows addObject:@(TriggerRowValue)];
    if ([self where] == TriggerWhereContains) [rows addObject:@(TriggerRowScan)];
    return rows;
}

- (NSString *)matchLabel {
    switch ([self match]) {
        case TriggerMatchBytes: return @"字节";
        case TriggerMatchCstr: return @"字符串";
        case TriggerMatchU64: return @"u64";
        default: return @"非空";
    }
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)[self rows].count;
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return @"判断规则";
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return @"判断地址留空表示 Trace 起始地址。地址可低于起始地址或大于等于结束地址，但不能落在起始与结束之间。";
}

- (TriggerFieldCell *)field:(NSString *)key label:(NSString *)label placeholder:(NSString *)ph {
    TriggerFieldCell *c = [TriggerFieldCell new];
    c.textLabel.text = label;
    c.field.placeholder = ph;
    c.field.delegate = self;
    c.field.keyboardType = UIKeyboardTypeASCIICapable;
    id v = self.trigger[key];
    c.field.text = [v isKindOfClass:[NSString class]] ? v : [v description];
    objc_setAssociatedObject(c.field, "triggerKey", key, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if ([key isEqualToString:@"triggerLimit"]) {
        c.field.keyboardType = UIKeyboardTypeNumberPad;
        [c.field addTarget:self action:@selector(triggerFieldChanged:)
          forControlEvents:UIControlEventEditingChanged];
    } else if ([key isEqualToString:@"triggerAddress"] || [key isEqualToString:@"triggerScan"]) {
        AttachHexKeyboard(c.field);
        [c.field addTarget:self action:@selector(triggerFieldChanged:)
          forControlEvents:UIControlEventEditingChanged];
    }
    return c;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip {
    TriggerRow row = (TriggerRow)[[self rows][ip.row] integerValue];
    if (row == TriggerRowAddress) {
        return [self field:@"triggerAddress" label:@"判断地址" placeholder:@"默认：起始地址"];
    }
    if (row == TriggerRowLimit) {
        return [self field:@"triggerLimit" label:@"触发次数上限" placeholder:@"1–16"];
    }
    if (row == TriggerRowValue) {
        NSString *ph = [self match] == TriggerMatchBytes ? @"08a48c90" :
                       [self match] == TriggerMatchCstr ? @"key" : @"0x...";
        return [self field:@"triggerValue" label:@"期望值" placeholder:ph];
    }
    if (row == TriggerRowScan) {
        TriggerFieldCell *c = [self field:@"triggerScan" label:@"最长读取(0x)" placeholder:@"0x100"];
        c.field.text = [NSString stringWithFormat:@"0x%llx", [self scan]];
        return c;
    }
    UITableViewCell *c = [[UITableViewCell alloc]
        initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    if (row == TriggerRowExpr) {
        c.textLabel.text = @"取址表达式";
        c.detailTextLabel.text = [self.trigger[@"triggerExpr"] length]
                                     ? self.trigger[@"triggerExpr"] : @"未设置";
        c.detailTextLabel.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular];
    } else if (row == TriggerRowMatch) {
        c.textLabel.text = @"匹配方式";
        c.detailTextLabel.text = [self matchLabel];
    } else {
        c.textLabel.text = @"匹配位置";
        c.detailTextLabel.text = [self where] == TriggerWhereContains ? @"包含" : @"开头";
    }
    return c;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tableView deselectRowAtIndexPath:ip animated:YES];
    TriggerRow row = (TriggerRow)[[self rows][ip.row] integerValue];
    if (row == TriggerRowExpr) {
        __weak typeof(self) weakSelf = self;
        ExprPrompt(self, self.trigger[@"triggerExpr"] ?: @"", ^(NSString *expr) {
            weakSelf.trigger[@"triggerExpr"] = expr;
            [weakSelf.tableView reloadData];
            [weakSelf updatePopGesture];
        });
        return;
    }
    if (row != TriggerRowMatch && row != TriggerRowWhere) return;
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:(row == TriggerRowMatch ? @"匹配方式" : @"匹配位置")
                         message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray *labels = row == TriggerRowMatch ? @[ @"非空", @"字节", @"字符串", @"u64" ]
                                             : @[ @"开头", @"包含" ];
    NSArray *keys = row == TriggerRowMatch ? @[ @"notnull", @"bytes", @"cstr", @"u64" ]
                                           : @[ @"prefix", @"contains" ];
    for (NSUInteger i = 0; i < labels.count; i++) {
        NSString *key = keys[i];
        [sheet addAction:[UIAlertAction actionWithTitle:labels[i]
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *a) {
            NSString *fieldKey = row == TriggerRowMatch ? @"triggerMatch" : @"triggerWhere";
            self.trigger[fieldKey] = key;
            [self.tableView reloadData];
            [self updatePopGesture];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = [tableView cellForRowAtIndexPath:ip];
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)triggerFieldChanged:(UITextField *)field {
    NSString *key = objc_getAssociatedObject(field, "triggerKey");
    NSString *text = [field.text stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    unsigned long long value = 0;
    BOOL valid = NO;
    if ([key isEqualToString:@"triggerLimit"]) {
        NSInteger limit = 0;
        valid = TriggerLimitTextValid(text, &limit);
        self.trigger[key] = valid ? @(limit) : (text ?: @"");
    } else if ([key isEqualToString:@"triggerAddress"] && text.length == 0) {
        valid = YES;
        [self.trigger removeObjectForKey:key];
    } else if (HexParseInput(text, &value)) {
        if ([key isEqualToString:@"triggerAddress"]) {
            unsigned long long distance = value > self.start ? value - self.start
                                                              : self.start - value;
            valid = !(value > self.start && value < self.end) &&
                    (value == self.start || distance >= TRIGGER_PATCH_SIZE);
        } else {
            valid = value > 0 && value <= TRIGGER_SCAN_MAX;
        }
        self.trigger[key] = text;
    } else {
        self.trigger[key] = text ?: @"";
    }
    field.textColor = valid ? [UIColor labelColor] : [UIColor systemRedColor];
    [self updatePopGesture];
}

- (void)textFieldDidEndEditing:(UITextField *)field {
    NSString *key = objc_getAssociatedObject(field, "triggerKey");
    if (key == nil) return;
    NSString *text = [field.text stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([key isEqualToString:@"triggerLimit"]) {
        NSInteger limit = 0;
        self.trigger[key] = TriggerLimitTextValid(text, &limit) ? @(limit)
                                                                : (text ?: @"");
    } else if ([key isEqualToString:@"triggerAddress"]) {
        if (text.length == 0) {
            [self.trigger removeObjectForKey:key];
        } else {
            unsigned long long n = 0;
            if (HexParseInput(text, &n)) text = [NSString stringWithFormat:@"0x%llx", n];
            self.trigger[key] = text;
            field.text = text;
        }
    } else if ([key isEqualToString:@"triggerScan"]) {
        unsigned long long n = 0;
        if (HexParseInput(text, &n) && n > 0) {
            self.trigger[key] = [NSString stringWithFormat:@"0x%llx", n];
        }
        field.text = [NSString stringWithFormat:@"0x%llx", [self scan]];
    } else {
        self.trigger[key] = field.text ?: @"";
    }
    [self updatePopGesture];
}

- (BOOL)textFieldShouldReturn:(UITextField *)field {
    [field resignFirstResponder];
    return YES;
}

- (void)alert:(NSString *)title message:(NSString *)message {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:message
        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)done {
    [self.view endEditing:YES];
    if (self.customLimit &&
        !TriggerLimitTextValid([self.trigger[@"triggerLimit"] description], NULL)) {
        [self alert:@"触发次数上限无效" message:@"触发次数上限必须是 1–16 的整数。"];
        return;
    }
    NSString *expr = self.trigger[@"triggerExpr"];
    if (!ExprSyntaxOK(expr)) {
        [self alert:@"触发条件无效" message:@"请填写有效的取址表达式。"];
        return;
    }
    NSString *addressText = [self.trigger[@"triggerAddress"] isKindOfClass:[NSString class]]
                                ? self.trigger[@"triggerAddress"]
                                : [self.trigger[@"triggerAddress"] description];
    if (addressText.length) {
        unsigned long long address = 0;
        if (!HexParseInput(addressText, &address)) {
            [self alert:@"判断地址无效" message:@"判断地址只能包含 0X、0-9 和 A-F。"];
            return;
        }
        if (address > self.start && address < self.end) {
            [self alert:@"判断地址无效" message:@"判断地址不能位于 Trace 起始地址与结束地址之间。"];
            return;
        }
        unsigned long long distance = address > self.start ? address - self.start : self.start - address;
        if (address != self.start && distance < TRIGGER_PATCH_SIZE) {
            [self alert:@"判断地址无效" message:@"判断地址与起始地址至少要相差 0x10。"];
            return;
        }
        self.trigger[@"triggerAddress"] = [NSString stringWithFormat:@"0x%llx", address];
    }
    NSString *v = [(self.trigger[@"triggerValue"] ?: @"")
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    TriggerMatch m = [self match];
    NSUInteger needleBytes = 0;
    if (m == TriggerMatchBytes) {
        NSCharacterSet *sep = [NSCharacterSet characterSetWithCharactersInString:@" \t:,"];
        NSString *hex = [[[v componentsSeparatedByCharactersInSet:sep]
            componentsJoinedByString:@""] lowercaseString];
        NSCharacterSet *bad = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet];
        if (hex.length == 0 || hex.length % 2 || hex.length > 64 ||
            [hex rangeOfCharacterFromSet:bad].location != NSNotFound) {
            [self alert:@"期望值无效" message:@"字节必须是 1–32 字节的成对十六进制字符。"];
            return;
        }
        needleBytes = hex.length / 2;
    } else if (m == TriggerMatchCstr) {
        NSUInteger bytes = [v lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        if (bytes == 0 || bytes > 32) {
            [self alert:@"期望值无效" message:@"字符串必须是 1–32 个 UTF-8 字节。"];
            return;
        }
        needleBytes = bytes;
    } else if (m == TriggerMatchU64) {
        unsigned long long ignored = 0;
        if (v.length == 0 || !HexParseInput(v, &ignored)) {
            [self alert:@"期望值无效" message:@"u64 必须是十六进制数值。"];
            return;
        }
    }
    if ((m == TriggerMatchBytes || m == TriggerMatchCstr) &&
        [self where] == TriggerWhereContains) {
        unsigned long long scan = [self scan];
        if (scan == 0 || scan > TRIGGER_SCAN_MAX) {
            [self alert:@"最长读取无效" message:@"最长读取范围是 0x1–0x1000。"];
            return;
        }
        if (scan < needleBytes) {
            [self alert:@"最长读取太小" message:@"最长读取必须能容纳完整的期望值。"];
            return;
        }
    }
    if (self.onDone) self.onDone();
    [self.navigationController popViewControllerAnimated:YES];
}

@end
