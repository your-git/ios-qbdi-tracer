#import "TraceEditVC.h"
#import "ConfigStore.h"
#import "WatchEditVC.h"
#import "ExprInput.h"
#import "HexValue.h"
#import <objc/runtime.h>

/* 带右侧输入框的 cell */
@interface FieldCell : UITableViewCell
@property (nonatomic, strong) UITextField *field;
@end
@implementation FieldCell
- (instancetype)initWithReuseIdentifier:(NSString *)rid {
    self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:rid];
    if (self) {
        _field = [[UITextField alloc] init];
        _field.textAlignment = NSTextAlignmentRight;
        _field.translatesAutoresizingMaskIntoConstraints = NO;
        _field.clearButtonMode = UITextFieldViewModeWhileEditing;
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

/* logMask 那一栏已从界面上去掉,统一用「指令 + 向量寄存器」。
 * 字段本身保留在 JSON 里(引擎照旧读它),只是不再让用户选。 */
#define TRACE_DEFAULT_LOGMASK 17 /* LOG_INST(1) | LOG_VREG(16) */

/* trace 区间下限:Dobby 的补丁覆盖 [start, start+0x10),区间比它短的话
 * end 落在补丁区里,QBDI 永远跑不到 end,会一路执行到崩(见 DESIGN.md §4.4)。
 * 与 Engine/src/qbdi_trace.h 的 QBDI_PATCH_SIZE 对应。 */
#define TRACE_MIN_RANGE 0x10

static unsigned long long HexValue(id v);

@interface TraceEditVC () <UITextFieldDelegate>
@property (nonatomic, strong) NSMutableDictionary *item;
@property (nonatomic, assign) BOOL isNew;
- (void)addressFieldChanged:(UITextField *)field;
- (BOOL)triggerAddressValue:(unsigned long long)value
                     reason:(NSString **)reason;
@end

@implementation TraceEditVC

- (instancetype)initWithItem:(NSMutableDictionary *)item isNew:(BOOL)isNew {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _item = item;
        _isNew = isNew;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = _isNew ? @"添加 Trace" : @"编辑 Trace";
    /* 统一行高:所有 cell(输入框行 / 开关行)一样高,舒展一点 */
    self.tableView.rowHeight = 52.0;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:@"完成"
                style:UIBarButtonItemStyleDone
               target:self
               action:@selector(done)];

    /* 先把字段规范化(logMask 统一成默认值、数字字段统一成 NSNumber),再拍快照 —— */
    /* 顺序反了会把这些自动改写当成"用户改了东西",一返回就误弹「放弃修改」 */
    self.item[@"logMask"] = @(TRACE_DEFAULT_LOGMASK);
    for (NSString *k in @[ @"count", @"delaySecs" ]) {
        id v = self.item[k];
        if (![v isKindOfClass:[NSNumber class]]) {
            self.item[k] = @([v respondsToSelector:@selector(integerValue)]
                                 ? [v integerValue] : 0);
        }
    }
    [self beginEditingTarget:self.item];
}

/* watch 的改动不跟着 trace 一起回滚:在 watch 页点过「确定」就算定了 */
- (NSSet<NSString *> *)snapshotExcludedKeys {
    return [NSSet setWithObject:@"watches"];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}

#pragma mark - 触发条件

/* 与 JSON 里 triggerMatch 的取值一一对应(引擎侧是 Engine/src/config.h 的 TrigMatch) */
typedef NS_ENUM(NSInteger, TrigMatchKind) {
    TrigMatchNotNull = 0,
    TrigMatchBytes,
    TrigMatchCstr,
    TrigMatchU64,
};

static NSString *TrigMatchKey(TrigMatchKind k) {
    switch (k) {
        case TrigMatchBytes: return @"bytes";
        case TrigMatchCstr:  return @"cstr";
        case TrigMatchU64:   return @"u64";
        case TrigMatchNotNull: break;
    }
    return @"notnull";
}

static NSString *TrigMatchLabel(TrigMatchKind k) {
    switch (k) {
        case TrigMatchBytes: return @"字节";
        case TrigMatchCstr:  return @"字符串";
        case TrigMatchU64:   return @"u64";
        case TrigMatchNotNull: break;
    }
    return @"非空";
}

/* 期望值出现在哪儿 */
typedef NS_ENUM(NSInteger, TrigWhereKind) {
    TrigWherePrefix = 0,
    TrigWhereContains,
};

/* 「触发条件」段的行(顺序即显示顺序,按匹配方式伸缩) */
typedef NS_ENUM(NSInteger, TrigRowKind) {
    TrigRowExpr = 0,
    TrigRowAddress,
    TrigRowMatch,
    TrigRowWhere,
    TrigRowValue,
    TrigRowScan,
    TrigRowClear,
};

#define TRIG_SCAN_DEFAULT 0x100  /* 同 Engine/src/config.h 的 TRIG_DEF_SCAN */
#define TRIG_SCAN_MAX     0x1000 /* 同 TRIG_MAX_SCAN */

/* 配了取址表达式才算开了条件 */
- (BOOL)hasTrigger {
    id e = self.item[@"triggerExpr"];
    return [e isKindOfClass:[NSString class]] && [e length] > 0;
}

- (TrigMatchKind)triggerMatch {
    NSString *m = self.item[@"triggerMatch"];
    if ([m isEqualToString:@"bytes"]) return TrigMatchBytes;
    if ([m isEqualToString:@"cstr"])  return TrigMatchCstr;
    if ([m isEqualToString:@"u64"])   return TrigMatchU64;
    return TrigMatchNotNull;
}

/* 缺省按直觉给:字符串=包含,字节=开头(与引擎 load_trigger 一致) */
- (TrigWhereKind)triggerWhere {
    NSString *w = self.item[@"triggerWhere"];
    if ([w isEqualToString:@"contains"]) return TrigWhereContains;
    if ([w isEqualToString:@"prefix"])   return TrigWherePrefix;
    return [self triggerMatch] == TrigMatchCstr ? TrigWhereContains
                                                : TrigWherePrefix;
}

- (unsigned long long)triggerScan {
    id v = self.item[@"triggerScan"];
    if (v == nil) return TRIG_SCAN_DEFAULT;
    unsigned long long n = HexValueFromJSON(v);
    return n ? n : TRIG_SCAN_DEFAULT;
}

/* 当前该显示哪几行 */
- (NSArray<NSNumber *> *)triggerRows {
    if (![self hasTrigger]) {
        return @[ @(TrigRowExpr) ];
    }
    TrigMatchKind k = [self triggerMatch];
    if (k == TrigMatchNotNull) {
        return @[ @(TrigRowExpr), @(TrigRowAddress), @(TrigRowMatch),
                  @(TrigRowClear) ];
    }
    if (k == TrigMatchU64) {
        return @[ @(TrigRowExpr), @(TrigRowAddress), @(TrigRowMatch),
                  @(TrigRowValue), @(TrigRowClear) ];
    }
    /* 字节 / 字符串:多一个「匹配位置」,选了「包含」再多一个「最长读取」 */
    NSMutableArray *rows = [@[ @(TrigRowExpr), @(TrigRowAddress),
                               @(TrigRowMatch), @(TrigRowWhere),
                               @(TrigRowValue) ] mutableCopy];
    if ([self triggerWhere] == TrigWhereContains) {
        [rows addObject:@(TrigRowScan)];
    }
    [rows addObject:@(TrigRowClear)];
    return rows;
}

- (UITableViewCell *)triggerCellForRow:(NSInteger)row {
    TrigRowKind kind =
        (TrigRowKind)[[self triggerRows][row] integerValue];
    TrigMatchKind k = [self triggerMatch];

    if (kind == TrigRowClear) {
        UITableViewCell *c = [[UITableViewCell alloc]
            initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        c.textLabel.text = @"改为无条件";
        c.textLabel.textAlignment = NSTextAlignmentCenter;
        c.textLabel.textColor = [UIColor systemRedColor];
        return c;
    }

    if (kind == TrigRowValue) {
        FieldCell *c = [self fieldCellKey:@"triggerValue"
                                    label:@"期望值"
                              placeholder:(k == TrigMatchBytes ? @"08a48c90"
                                           : k == TrigMatchCstr ? @"api"
                                                                : @"0x...")
                                  numeric:NO];
        c.field.font = [UIFont monospacedSystemFontOfSize:15
                                                   weight:UIFontWeightRegular];
        return c;
    }
    if (kind == TrigRowAddress) {
        FieldCell *c = [self fieldCellKey:@"triggerAddress"
                                    label:@"判断地址"
                              placeholder:@"默认：起始地址"
                                  numeric:NO];
        c.field.font = [UIFont monospacedSystemFontOfSize:15
                                                   weight:UIFontWeightRegular];
        return c;
    }
    if (kind == TrigRowScan) {
        FieldCell *c = [self fieldCellKey:@"triggerScan"
                                    label:@"最长读取(0x)"
                              placeholder:@"0x100"
                                  numeric:NO];
        c.field.font = [UIFont monospacedSystemFontOfSize:15
                                                   weight:UIFontWeightRegular];
        /* 缺省值也要显示出来,不然看着像没设置 */
        c.field.text = [NSString stringWithFormat:@"0x%llx", [self triggerScan]];
        return c;
    }

    UITableViewCell *c = [[UITableViewCell alloc]
        initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    if (kind == TrigRowExpr) {
        c.textLabel.text = @"取址表达式";
        NSString *e = self.item[@"triggerExpr"];
        c.detailTextLabel.text = [e length] ? e : @"无条件";
        c.detailTextLabel.font =
            [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular];
        c.detailTextLabel.adjustsFontSizeToFitWidth = YES;
        c.detailTextLabel.minimumScaleFactor = 0.7;
        if (![self hasTrigger]) {
            c.detailTextLabel.textColor = [UIColor tertiaryLabelColor];
        }
    } else if (kind == TrigRowMatch) {
        c.textLabel.text = @"匹配方式";
        c.detailTextLabel.text = TrigMatchLabel(k);
    } else {
        c.textLabel.text = @"匹配位置";
        c.detailTextLabel.text =
            [self triggerWhere] == TrigWhereContains ? @"包含" : @"开头";
    }
    c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return c;
}

- (void)pickTriggerWhere {
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:@"匹配位置"
                         message:nil
                  preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray *labels = @[ @"开头", @"包含" ];
    NSArray *keys = @[ @"prefix", @"contains" ];
    for (NSUInteger i = 0; i < labels.count; i++) {
        NSString *key = keys[i];
        [sheet addAction:[UIAlertAction actionWithTitle:labels[i]
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *a) {
                  self.item[@"triggerWhere"] = key;
                  [self.tableView reloadData];
                  [self updatePopGesture];
              }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    NSUInteger whereRow = [[self triggerRows] indexOfObject:@(TrigRowWhere)];
    sheet.popoverPresentationController.sourceView =
        [self.tableView cellForRowAtIndexPath:
            [NSIndexPath indexPathForRow:(NSInteger)whereRow inSection:3]];
    [self presentViewController:sheet animated:YES completion:nil];
}

/* 点「取址表达式」那行:弹表达式输入框。清空 = 关掉条件。 */
- (void)promptTriggerExpr {
    __weak typeof(self) weakSelf = self;
    ExprPrompt(self, self.item[@"triggerExpr"] ?: @"", ^(NSString *expr) {
        typeof(self) me = weakSelf;
        if (me == nil) return;
        me.item[@"triggerExpr"] = expr;
        /* 第一次开条件时给个默认匹配方式,省一步操作 */
        if (me.item[@"triggerMatch"] == nil) {
            me.item[@"triggerMatch"] = @"notnull";
        }
        [me.tableView reloadData];
        [me updatePopGesture];
    });
}

/* 表达式那行的左滑:清掉条件(ExprPrompt 里语法校验不让提交空串,所以单独给个入口) */
- (void)clearTrigger {
    [self.item removeObjectForKey:@"triggerExpr"];
    [self.item removeObjectForKey:@"triggerMatch"];
    [self.item removeObjectForKey:@"triggerValue"];
    [self.item removeObjectForKey:@"triggerWhere"];
    [self.item removeObjectForKey:@"triggerScan"];
    [self.item removeObjectForKey:@"triggerAddress"];
    [self.tableView reloadData];
    [self updatePopGesture];
}

- (void)pickTriggerMatch {
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:@"匹配方式"
                         message:nil
                  preferredStyle:UIAlertControllerStyleActionSheet];
    TrigMatchKind all[] = { TrigMatchNotNull, TrigMatchBytes, TrigMatchCstr,
                            TrigMatchU64 };
    for (size_t i = 0; i < sizeof(all) / sizeof(all[0]); i++) {
        TrigMatchKind k = all[i];
        [sheet addAction:[UIAlertAction actionWithTitle:TrigMatchLabel(k)
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *a) {
                  self.item[@"triggerMatch"] = TrigMatchKey(k);
                  [self.tableView reloadData];
                  [self updatePopGesture];
              }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    NSUInteger matchRow = [[self triggerRows] indexOfObject:@(TrigRowMatch)];
    sheet.popoverPresentationController.sourceView =
        [self.tableView cellForRowAtIndexPath:
            [NSIndexPath indexPathForRow:(NSInteger)matchRow inSection:3]];
    [self presentViewController:sheet animated:YES completion:nil];
}

#pragma mark - 字段布局

/* section: 0=App 信息(只读) 1=地址 2=选项 3=触发条件 4=watches
 * (曾经的 logMask 多选段已去掉;改这里记得同步下面所有 section 判断) */
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 5;
}

- (NSString *)tableView:(UITableView *)tableView
    titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case 0: return @"目标 App";
        case 1: return @"模块与地址(十六进制)";
        case 2: return @"选项";
        case 3: return @"触发条件(可选)";
        case 4: return @"监视(watch)";
    }
    return nil;
}

- (NSString *)tableView:(UITableView *)tableView
    titleForFooterInSection:(NSInteger)section {
    if (section == 1) {
        return @"结束地址至少要比起始地址大 0x10。";
    }
    if (section == 3) {
        if (![self hasTrigger]) {
            return @"留空 = 每次命中都 trace。填了表达式后,只有内存内容匹配时才记录,"
                   @"不匹配的调用完全不写 trace 文件,并会继续等待后续匹配。";
        }
        NSString *addressNote =
            @"判断地址留空=起始地址；自定义地址不能在起始与结束之间，"
            @"低于起始时至少间隔 0x10。命中后等待同一线程下一次到达起始地址。\n\n";
        BOOL contains = [self triggerWhere] == TrigWhereContains;
        if ([self triggerMatch] == TrigMatchBytes) {
            NSString *detail = contains
                ? @"从这个地址最多读「最长读取」个字节,在里面搜这串字节。"
                  @"字节按内存顺序写 —— 和 hexdump 里看到的顺序一致。例:08a48c90"
                : @"只比开头:读这串字节那么长,逐字节相等才算命中。"
                  @"按内存顺序写,和 hexdump 里看到的一致。例:08a48c90";
            return [addressNote stringByAppendingString:detail];
        }
        if ([self triggerMatch] == TrigMatchCstr) {
            NSString *detail = contains
                ? @"先把字符串完整读出来(读到 \0 为止、最多「最长读取」个字节),"
                  @"再看里面是否包含这段文字。"
                : @"只比开头:字符串以这段文字开头才算命中。例:https://";
            return [addressNote stringByAppendingString:detail];
        }
        if ([self triggerMatch] == TrigMatchU64) {
            return [addressNote stringByAppendingString:
                @"读 8 字节按小端当整数比较。注意和「字节」相反:"
                @"内存里的 08 a4 8c 90 81 04 10 02 在这里要写成 0x02100481908ca408。"];
        }
        return [addressNote stringByAppendingString:
            @"地址可读且非 0 就算命中 —— 用来滤掉那些 (null) 的调用。"];
    }
    return nil;
}

- (NSInteger)tableView:(UITableView *)tableView
    numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case 0: return 1;                 /* app 名 */
        case 1: return 3;                 /* module / start / end */
        case 2: return 2;                 /* delaySecs / moduleOnly(count 固定隐藏) */
        case 3: return (NSInteger)[self triggerRows].count;
        case 4: return (NSInteger)[self.item[@"watches"] count] + 1; /* +添加 */
    }
    return 0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section == 0) {
        UITableViewCell *c = [[UITableViewCell alloc]
            initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
        c.textLabel.text = @"App";
        NSString *app = [self.item[@"appName"] length] ? self.item[@"appName"]
                                                       : self.item[@"bundleId"];
        c.detailTextLabel.text = app;
        c.selectionStyle = UITableViewCellSelectionStyleNone;
        return c;
    }
    if (ip.section == 1) {
        NSArray *keys = @[ @"module", @"start", @"end" ];
        NSArray *labels = @[ @"模块名", @"起始地址", @"结束地址" ];
        NSArray *ph = @[ @"ModuleName", @"0x...", @"0x..." ];
        return [self fieldCellKey:keys[ip.row]
                            label:labels[ip.row]
                      placeholder:ph[ip.row]
                          numeric:NO];
    }
    if (ip.section == 2) {
        if (ip.row == 0) {
            return [self fieldCellKey:@"delaySecs" label:@"延迟(秒)"
                          placeholder:@"0" numeric:YES];
        }
        /* moduleOnly switch */
        UITableViewCell *c = [[UITableViewCell alloc]
            initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        c.textLabel.text = @"仅记录模块内指令";
        c.selectionStyle = UITableViewCellSelectionStyleNone;
        UISwitch *sw = [UISwitch new];
        sw.on = [self.item[@"moduleOnly"] boolValue];
        [sw addTarget:self action:@selector(moduleOnlyChanged:)
            forControlEvents:UIControlEventValueChanged];
        c.accessoryView = sw;
        return c;
    }
    if (ip.section == 3) {
        return [self triggerCellForRow:ip.row];
    }
    /* section 4: watches */
    NSArray *watches = self.item[@"watches"];
    if (ip.row == (NSInteger)watches.count) {
        UITableViewCell *c = [[UITableViewCell alloc]
            initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        c.textLabel.text = @"+ 添加监视";
        c.textLabel.textColor = [UIColor systemBlueColor];
        return c;
    }
    NSDictionary *w = watches[ip.row];
    UITableViewCell *c = [[UITableViewCell alloc]
        initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    /* 有取址表达式就显示表达式,否则显示寄存器名 —— 否则配了表达式在列表里看不出来 */
    NSString *addr = [w[@"expr"] length] ? w[@"expr"] : (w[@"reg"] ?: @"?");
    c.textLabel.text = [NSString stringWithFormat:@"%@ %@ %@",
                        addr, w[@"action"] ?: @"",
                        [w[@"label"] length] ? w[@"label"] : @""];
    c.detailTextLabel.text = [NSString stringWithFormat:@"%@ @ %@",
                              w[@"module"] ?: @"", w[@"offset"] ?: @""];
    c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return c;
}

- (FieldCell *)fieldCellKey:(NSString *)key
                      label:(NSString *)label
                placeholder:(NSString *)ph
                    numeric:(BOOL)numeric {
    FieldCell *c = [[FieldCell alloc] initWithReuseIdentifier:nil];
    c.textLabel.text = label;
    c.field.placeholder = ph;
    c.field.delegate = self;
    c.field.keyboardType =
        numeric ? UIKeyboardTypeNumberPad : UIKeyboardTypeASCIICapable;
    id v = self.item[key];
    c.field.text = [v isKindOfClass:[NSString class]]
                       ? v
                       : [v respondsToSelector:@selector(stringValue)]
                             ? [v stringValue]
                             : @"";
    /* 用 key 关联到输入框,失焦时回写 */
    objc_setAssociatedObject(c.field, "cfgKey", key,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(c.field, "numeric", @(numeric),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if ([key isEqualToString:@"start"] || [key isEqualToString:@"end"] ||
        [key isEqualToString:@"triggerAddress"]) {
        AttachHexKeyboard(c.field);
        [c.field addTarget:self action:@selector(addressFieldChanged:)
          forControlEvents:UIControlEventEditingChanged];
    }
    return c;
}

#pragma mark - 输入回写

- (void)textFieldDidEndEditing:(UITextField *)tf {
    NSString *key = objc_getAssociatedObject(tf, "cfgKey");
    if (key == nil) return;
    if ([key isEqualToString:@"start"] || [key isEqualToString:@"end"] ||
        [key isEqualToString:@"triggerAddress"]) {
        NSString *text = [tf.text stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([key isEqualToString:@"triggerAddress"] && text.length == 0) {
            [self.item removeObjectForKey:key];
            tf.text = @"";
        } else {
            unsigned long long value = 0;
            if (HexParseInput(text, &value)) {
                NSString *normalized = [NSString stringWithFormat:@"0x%llx", value];
                self.item[key] = normalized;
                tf.text = normalized;
            } else {
                self.item[key] = text ?: @"";
            }
        }
        [self addressFieldChanged:tf];
        return;
    }
    if ([key isEqualToString:@"triggerScan"]) {
        /* 一律按十六进制读,写回时带 0x —— 与 watch 的 size 同一套规则 */
        unsigned long long n = 0;
        if (HexParseInput(tf.text, &n) && n > 0) {
            if (n > TRIG_SCAN_MAX) n = TRIG_SCAN_MAX;
            self.item[key] = [NSString stringWithFormat:@"0x%llx", n];
        }
        /* 非法/空就回填上次的合法值,不静默变 0 */
        tf.text = [NSString stringWithFormat:@"0x%llx", [self triggerScan]];
        [self updatePopGesture];
        return;
    }
    BOOL numeric = [objc_getAssociatedObject(tf, "numeric") boolValue];
    if (numeric) {
        self.item[key] = @([tf.text integerValue]);
    } else {
        self.item[key] = tf.text ?: @"";
    }
    [self updatePopGesture];
}

- (BOOL)triggerAddressValue:(unsigned long long)value
                     reason:(NSString **)reason {
    unsigned long long start = HexValue(self.item[@"start"]);
    unsigned long long end = HexValue(self.item[@"end"]);
    if (value > start && value < end) {
        if (reason) *reason = @"判断地址不能位于起始地址与结束地址之间。";
        return NO;
    }
    if (value < start && start - value < TRACE_MIN_RANGE) {
        if (reason) {
            *reason = [NSString stringWithFormat:
                @"判断地址与起始地址太近。Dobby Hook 至少需要间隔 0x%x 字节。",
                TRACE_MIN_RANGE];
        }
        return NO;
    }
    return YES;
}

- (void)addressFieldChanged:(UITextField *)field {
    NSString *key = objc_getAssociatedObject(field, "cfgKey");
    if (key.length == 0) return;
    NSString *text = [field.text stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([key isEqualToString:@"triggerAddress"] && text.length == 0) {
        [self.item removeObjectForKey:key];
        field.textColor = [UIColor labelColor];
    } else {
        self.item[key] = text ?: @"";
        unsigned long long value = 0;
        BOOL valid = text.length > 0 && HexParseInput(text, &value);
        if (valid && [key isEqualToString:@"triggerAddress"]) {
            valid = [self triggerAddressValue:value reason:nil];
        }
        field.textColor = valid ? [UIColor labelColor] : [UIColor systemRedColor];
    }
    [self updatePopGesture];
}

- (BOOL)textFieldShouldReturn:(UITextField *)tf {
    [tf resignFirstResponder];
    return YES;
}

- (void)moduleOnlyChanged:(UISwitch *)sw {
    self.item[@"moduleOnly"] = @(sw.on);
    [self updatePopGesture];
}

#pragma mark - 选择

- (void)tableView:(UITableView *)tableView
    didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tableView deselectRowAtIndexPath:ip animated:YES];

    if (ip.section == 3) {
        switch ((TrigRowKind)[[self triggerRows][ip.row] integerValue]) {
            case TrigRowExpr:  [self promptTriggerExpr]; break;
            case TrigRowMatch: [self pickTriggerMatch]; break;
            case TrigRowWhere: [self pickTriggerWhere]; break;
            case TrigRowClear: [self clearTrigger]; break;
            default: break; /* 输入框行,不用处理点击 */
        }
        return;
    }

    if (ip.section == 4) {
        NSMutableArray *watches = self.item[@"watches"];
        NSMutableDictionary *w;
        BOOL isNewWatch = (ip.row == (NSInteger)watches.count);
        if (isNewWatch) {
            /* size 写成 "0x0" 字符串:新格式一律带 0x 前缀,与旧版裸十进制区分 */
            w = [@{ @"module": self.item[@"module"] ?: @"",
                    @"offset": @"0x0", @"reg": @"x0",
                    @"action": @"cstr", @"size": @"0x0", @"label": @"" } mutableCopy];
        } else {
            w = watches[ip.row];
        }
        WatchEditVC *wv = [[WatchEditVC alloc] initWithWatch:w];
        __weak typeof(self) weakSelf = self;
        wv.onDone = ^{
            if (isNewWatch) {
                [watches addObject:w];
            }
            [weakSelf.tableView reloadData];
        };
        [self.navigationController pushViewController:wv animated:YES];
    }
}

/* 左滑:触发条件那行=清除条件,watch 行=删除 */
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section == 3) {
        if ((TrigRowKind)[[self triggerRows][ip.row] integerValue] != TrigRowExpr ||
            ![self hasTrigger]) {
            return nil;
        }
        __weak typeof(self) weakSelf = self;
        UIContextualAction *clr = [UIContextualAction
            contextualActionWithStyle:UIContextualActionStyleDestructive
                                title:@"清除条件"
                              handler:^(UIContextualAction *a, UIView *v,
                                        void (^done)(BOOL)) {
                  [weakSelf clearTrigger];
                  done(YES);
              }];
        return [UISwipeActionsConfiguration configurationWithActions:@[ clr ]];
    }
    if (ip.section != 4) return nil;
    NSMutableArray *watches = self.item[@"watches"];
    if (ip.row >= (NSInteger)watches.count) return nil;
    __weak typeof(self) weakSelf = self;
    UIContextualAction *del = [UIContextualAction
        contextualActionWithStyle:UIContextualActionStyleDestructive
                            title:@"删除"
                          handler:^(UIContextualAction *a, UIView *v,
                                    void (^done)(BOOL)) {
              [watches removeObjectAtIndex:ip.row];
              [weakSelf.tableView reloadData];
              done(YES);
          }];
    return [UISwipeActionsConfiguration configurationWithActions:@[ del ]];
}

#pragma mark - 完成

/* "0x1234" / "1234" → 数值(与引擎 parse_hex 同规则:一律十六进制) */
static unsigned long long HexValue(id v) {
    if ([v isKindOfClass:[NSNumber class]]) return [v unsignedLongLongValue];
    if (![v isKindOfClass:[NSString class]]) return 0;
    return strtoull([v UTF8String], NULL, 16);
}

- (void)alert:(NSString *)title msg:(NSString *)msg {
    UIAlertController *ac =
        [UIAlertController alertControllerWithTitle:title
                                            message:msg
                                     preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好"
                                           style:UIAlertActionStyleDefault
                                         handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)done {
    [self.view endEditing:YES]; /* 触发所有 textFieldDidEndEditing 回写 */

    /* 区间太短的话引擎那边会直接拒掉(见 Engine/src/engine.m),这里先挡一道,
     * 省掉"装上、跑一遍、翻日志"才知道配错了的一轮 */
    NSString *startText = [self.item[@"start"] description];
    NSString *endText = [self.item[@"end"] description];
    unsigned long long start = 0, end = 0;
    if (startText.length == 0 || endText.length == 0 ||
        !HexParseInput(startText, &start) || !HexParseInput(endText, &end)) {
        [self alert:@"地址无效"
                msg:@"起始地址和结束地址只能包含 0X、0-9 和 A-F。"];
        return;
    }
    if (end <= start) {
        [self alert:@"地址无效" msg:@"结束地址必须大于起始地址。"];
        return;
    }
    if (end - start < TRACE_MIN_RANGE) {
        [self alert:@"区间太短"
                msg:[NSString stringWithFormat:
                                  @"结束地址至少要比起始地址大 0x%x(当前 0x%llx)。\n\n"
                                  @"Dobby 的 hook 补丁会覆盖起始地址往后 0x%x 字节,"
                                  @"区间比它短时 trace 停不下来,会一直跑到崩。",
                                  TRACE_MIN_RANGE, end - start, TRACE_MIN_RANGE]];
        return;
    }

    /* 触发条件:表达式语法 + 期望值格式,配错了引擎会拒掉整条 trace,这里先挡 */
    if ([self hasTrigger]) {
        id triggerAddress = self.item[@"triggerAddress"];
        if ([triggerAddress isKindOfClass:[NSString class]] &&
            [triggerAddress length] > 0) {
            unsigned long long address = 0;
            if (!HexParseInput(triggerAddress, &address)) {
                [self alert:@"判断地址无效"
                        msg:@"判断地址只能包含 0X、0-9 和 A-F。"];
                return;
            }
            NSString *reason = nil;
            if (![self triggerAddressValue:address reason:&reason]) {
                [self alert:@"判断地址无效" msg:reason];
                return;
            }
        }
        NSString *expr = self.item[@"triggerExpr"];
        if (!ExprSyntaxOK(expr)) {
            [self alert:@"触发条件无效"
                    msg:[NSString stringWithFormat:@"取址表达式「%@」语法不对。", expr]];
            return;
        }
        NSString *v = [(self.item[@"triggerValue"] ?: @"")
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        TrigMatchKind k = [self triggerMatch];
        if (k == TrigMatchBytes) {
            /* 分隔符与引擎 load_trigger 保持一致:空格/tab/冒号/逗号都忽略 */
            NSCharacterSet *seps =
                [NSCharacterSet characterSetWithCharactersInString:@" \t:,"];
            NSString *hex = [[[v componentsSeparatedByCharactersInSet:seps]
                componentsJoinedByString:@""] lowercaseString];
            NSCharacterSet *bad = [[NSCharacterSet
                characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet];
            if (hex.length == 0) {
                [self alert:@"期望值为空" msg:@"选了「字节」就得填要比较的字节,例:08a48c90"];
                return;
            }
            if ([hex rangeOfCharacterFromSet:bad].location != NSNotFound) {
                [self alert:@"期望值无效" msg:@"「字节」只能填十六进制字符(0-9 a-f),空格随便加。"];
                return;
            }
            if (hex.length % 2 != 0) {
                [self alert:@"期望值无效"
                        msg:[NSString stringWithFormat:
                                          @"「字节」要成对写(当前 %lu 个十六进制字符,少一位)。",
                                          (unsigned long)hex.length]];
                return;
            }
            if (hex.length / 2 > 32) {
                [self alert:@"期望值过长" msg:@"最多比较 32 个字节。"];
                return;
            }
        } else if (k == TrigMatchCstr) {
            if (v.length == 0 || v.length > 32) {
                [self alert:@"期望值无效" msg:@"「字符串」要填 1–32 个字符。"];
                return;
            }
        } else if (k == TrigMatchU64) {
            if (v.length == 0) {
                [self alert:@"期望值为空" msg:@"选了「u64」就得填要比较的数值,例:0x02100481908ca408"];
                return;
            }
        }
        /* 「包含」时窗口必须装得下要找的东西,否则永远搜不到 */
        if ((k == TrigMatchBytes || k == TrigMatchCstr) &&
            [self triggerWhere] == TrigWhereContains) {
            unsigned long long scan = [self triggerScan];
            if (scan > TRIG_SCAN_MAX) {
                [self alert:@"最长读取过大"
                        msg:[NSString stringWithFormat:@"最多 0x%x 字节。", TRIG_SCAN_MAX]];
                return;
            }
            NSCharacterSet *seps =
                [NSCharacterSet characterSetWithCharactersInString:@" \t:,"];
            unsigned long long need =
                (k == TrigMatchBytes)
                    ? [[v componentsSeparatedByCharactersInSet:seps]
                          componentsJoinedByString:@""].length / 2
                    : [v lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
            if (scan < need) {
                [self alert:@"最长读取太小"
                        msg:[NSString stringWithFormat:
                                          @"要找的东西有 0x%llx 字节,但只读 0x%llx 字节 —— "
                                          @"永远搜不到。把「最长读取」调大。",
                                          need, scan]];
                return;
            }
        }
    }

    ConfigStore *store = [ConfigStore shared];
    if (self.isNew) {
        [store.items addObject:self.item];
        self.isNew = NO;
    }
    BOOL ok = [store save];
    NSString *msg = ok ? @"配置已保存,请重开目标 App 生效"
                       : @"保存失败(检查配置目录权限)";
    UIAlertController *ac =
        [UIAlertController alertControllerWithTitle:(ok ? @"完成" : @"错误")
                                            message:msg
                                     preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好"
                                           style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *a) {
              [self.navigationController popToRootViewControllerAnimated:YES];
          }]];
    [self presentViewController:ac animated:YES completion:nil];
}

@end
