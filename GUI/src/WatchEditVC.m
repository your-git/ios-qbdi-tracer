#import "WatchEditVC.h"
#import "ExprInput.h"
#import "HexValue.h"
#import <objc/runtime.h>

static NSArray *RegNames(void) {
    NSMutableArray *a = [NSMutableArray array];
    for (int i = 0; i <= 28; i++) [a addObject:[NSString stringWithFormat:@"x%d", i]];
    [a addObjectsFromArray:@[ @"fp", @"lr", @"sp" ]];
    return a;
}
static NSArray *ActionNames(void) {
    /* 引擎仍保留 objc/po 兼容旧 JSON，但新配置不再暴露这个不稳定选项。 */
    return @[ @"cstr", @"utf8", @"u32", @"u64", @"hexdump" ];
}

#pragma mark -

@interface WEFieldCell : UITableViewCell
@property (nonatomic, strong) UITextField *field;
@end
@implementation WEFieldCell
- (instancetype)initWithReuseIdentifier:(NSString *)rid {
    self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:rid];
    if (self) {
        _field = [UITextField new];
        _field.textAlignment = NSTextAlignmentRight;
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

@interface WatchEditVC () <UITextFieldDelegate>
@property (nonatomic, strong) NSMutableDictionary *watch;
- (void)hexAddressChanged:(UITextField *)field;
@end

@implementation WatchEditVC

- (instancetype)initWithWatch:(NSMutableDictionary *)watch {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) { _watch = watch; }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"监视";
    /* 统一行高,与添加 Trace 界面一致 */
    self.tableView.rowHeight = 52.0;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:@"确定" style:UIBarButtonItemStyleDone
               target:self action:@selector(commit)];

    /* 先把 size 规范成 "0x..."(旧配置里是裸十进制数字),再拍快照 —— 顺序反了的话
     * 光是光标进出过 size 框就会被当成"用户改了东西",一返回就误弹「放弃修改」 */
    self.watch[@"size"] = HexDisplay(self.watch[@"size"]);
    [self beginEditingTarget:self.watch];
}

/* 当前取址方式的显示文本:有表达式显示表达式,否则显示寄存器名 */
- (NSString *)addressDisplay {
    id e = self.watch[@"expr"];
    if ([e isKindOfClass:[NSString class]] && [e length] > 0) return e;
    id r = self.watch[@"reg"];
    return [r isKindOfClass:[NSString class]] && [r length] ? r : @"x0";
}

- (BOOL)isHexdump {
    return [self.watch[@"action"] isEqualToString:@"hexdump"];
}

/* 行:0 module / 1 offset / 2 reg|expr / 3 action / 4 size / 5 label */
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s { return 6; }

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    return @"取址表达式:寄存器 ± 十六进制偏移,[] 表示解引用。"
           @"例 x0-0x110、sp+0x40、[x0+0x10]、[[x0+8]+0x10]-4。"
           @"表达式算出的是起始地址,怎么读由「输出形式」决定。";
}

- (UITableViewCell *)tableView:(UITableView *)tv
         cellForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.row == 2 || ip.row == 3) {
        UITableViewCell *c = [[UITableViewCell alloc]
            initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
        c.textLabel.text = (ip.row == 2) ? @"寄存器/取址表达式" : @"输出形式";
        if (ip.row == 2) {
            /* 表达式可能比寄存器名长得多,给它等宽字体并允许缩放 */
            c.detailTextLabel.text = [self addressDisplay];
            c.detailTextLabel.font =
                [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular];
            c.detailTextLabel.adjustsFontSizeToFitWidth = YES;
            c.detailTextLabel.minimumScaleFactor = 0.7;
        } else {
            c.detailTextLabel.text = self.watch[@"action"];
        }
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return c;
    }
    NSArray *keys = @[ @"module", @"offset", @"", @"", @"size", @"label" ];
    NSArray *labels = @[ @"模块名", @"监视地址", @"", @"",
                         self.isHexdump ? @"dump 长度(0x)" : @"读取上限(0x,0=不截断)",
                         @"标签" ];
    NSArray *ph = @[ @"ModuleName", @"0x...", @"", @"", @"0x0", @"url" ];
    NSString *key = keys[ip.row];
    WEFieldCell *c = [[WEFieldCell alloc] initWithReuseIdentifier:nil];
    c.textLabel.text = labels[ip.row];
    c.field.placeholder = ph[ip.row];
    c.field.delegate = self;
    /* size 现在也是十六进制,得能打出 a-f 和 x,不能再用 NumberPad */
    c.field.keyboardType = UIKeyboardTypeASCIICapable;
    c.field.autocorrectionType = UITextAutocorrectionTypeNo;
    c.field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    BOOL isSize = [key isEqualToString:@"size"];
    if (isSize) {
        c.field.text = HexDisplay(self.watch[@"size"]);
    } else {
        id v = self.watch[key];
        c.field.text = [v isKindOfClass:[NSString class]]
                           ? v : ([v respondsToSelector:@selector(stringValue)]
                                      ? [v stringValue] : @"");
    }
    objc_setAssociatedObject(c.field, "k", key, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if ([key isEqualToString:@"offset"]) {
        AttachHexKeyboard(c.field);
        [c.field addTarget:self action:@selector(hexAddressChanged:)
          forControlEvents:UIControlEventEditingChanged];
    }
    return c;
}

- (void)textFieldDidEndEditing:(UITextField *)tf {
    NSString *k = objc_getAssociatedObject(tf, "k");
    if (k.length == 0) return;
    if ([k isEqualToString:@"offset"]) {
        NSString *text = [tf.text stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        unsigned long long n = 0;
        if (text.length > 0 && HexParseInput(text, &n)) {
            NSString *normalized = [NSString stringWithFormat:@"0x%llx", n];
            self.watch[k] = normalized;
            tf.text = normalized;
        } else {
            self.watch[k] = text ?: @"";
        }
        [self hexAddressChanged:tf];
        return;
    }
    if ([k isEqualToString:@"size"]) {
        unsigned long long n = 0;
        if (HexParseInput(tf.text, &n)) {
            /* 写回 JSON 时一律带 0x,好和旧版的裸十进制区分开 */
            self.watch[@"size"] = [NSString stringWithFormat:@"0x%llx", n];
        }
        /* 非法输入不动配置,把上次的合法值回填,避免静默变成 0(=不截断) */
        tf.text = HexDisplay(self.watch[@"size"]);
        [self updatePopGesture];
        return;
    }
    self.watch[k] = tf.text ?: @"";
    [self updatePopGesture];
}

- (void)hexAddressChanged:(UITextField *)field {
    NSString *text = [field.text stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    unsigned long long value = 0;
    BOOL valid = text.length > 0 && HexParseInput(text, &value);
    self.watch[@"offset"] = text ?: @"";
    field.textColor = valid ? [UIColor labelColor] : [UIColor systemRedColor];
    [self updatePopGesture];
}
- (BOOL)textFieldShouldReturn:(UITextField *)tf { [tf resignFirstResponder]; return YES; }

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.row != 2 && ip.row != 3) return;
    BOOL isAddr = (ip.row == 2);
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:(isAddr ? @"选择寄存器" : @"选择输出形式")
                         message:nil
                  preferredStyle:UIAlertControllerStyleActionSheet];
    if (isAddr) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"✎ 输入取址表达式…"
                                                 style:UIAlertActionStyleDefault
                                               handler:^(UIAlertAction *a) {
                  [self promptExpr];
              }]];
    }
    NSArray *opts = isAddr ? RegNames() : ActionNames();
    NSString *key = isAddr ? @"reg" : @"action";
    for (NSString *o in opts) {
        [sheet addAction:[UIAlertAction actionWithTitle:o
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *a) {
                  self.watch[key] = o;
                  if (isAddr) {
                      /* 选了寄存器就必须清掉表达式,否则引擎按 expr 优先,
                       * 会表现成"选了寄存器却没生效" */
                      [self.watch removeObjectForKey:@"expr"];
                  }
                  [self.tableView reloadData];
                  [self updatePopGesture];
              }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    sheet.popoverPresentationController.sourceView =
        [tv cellForRowAtIndexPath:ip];
    [self presentViewController:sheet animated:YES completion:nil];
}

#pragma mark - 表达式输入弹窗

- (void)promptExpr {
    __weak typeof(self) weakSelf = self;
    ExprPrompt(self, [self addressDisplay], ^(NSString *expr) {
        typeof(self) s = weakSelf;
        if (s == nil) return;
        s.watch[@"expr"] = expr;
        /* 同步基寄存器:装旧版引擎的设备读不懂 expr,reg 缺失会让整条 watch
         * 被静默丢弃;留着基寄存器至少能退化成"打印该寄存器的值" */
        NSString *base = ExprBaseReg(expr);
        if (base.length) s.watch[@"reg"] = base;
        [s.tableView reloadData];
        [s updatePopGesture];
    });
}

- (void)commit {
    [self.view endEditing:YES];
    NSString *offset = [self.watch[@"offset"] description];
    unsigned long long ignored = 0;
    if (offset.length == 0 || !HexParseInput(offset, &ignored)) {
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:@"监视地址无效"
                             message:@"监视地址只能包含 0X、0-9 和 A-F。"
                      preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"好"
                                                  style:UIAlertActionStyleDefault
                                                handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    if (self.onDone) self.onDone();
    [self.navigationController popViewControllerAnimated:YES];
}

@end
