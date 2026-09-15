#import "TraceEditVC.h"
#import "ConfigStore.h"
#import "WatchEditVC.h"
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

@interface TraceEditVC () <UITextFieldDelegate>
@property (nonatomic, strong) NSMutableDictionary *item;
@property (nonatomic, assign) BOOL isNew;
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
    /* 统一行高:所有 cell(输入框行 / 开关行 / 多选行)一样高,舒展一点 */
    self.tableView.rowHeight = 52.0;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:@"完成"
                style:UIBarButtonItemStyleDone
               target:self
               action:@selector(done)];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}

#pragma mark - 字段布局

/* section: 0=App 信息(只读) 1=地址 2=选项 3=logMask 4=watches */
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 5;
}

- (NSString *)tableView:(UITableView *)tableView
    titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case 0: return @"目标 App";
        case 1: return @"模块与地址(十六进制)";
        case 2: return @"选项";
        case 3: return @"记录内容(logMask)";
        case 4: return @"监视(watch)";
    }
    return nil;
}

- (NSInteger)tableView:(UITableView *)tableView
    numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case 0: return 1;                 /* app 名 */
        case 1: return 3;                 /* module / start / end */
        case 2: return 3;                 /* count / delaySecs / moduleOnly */
        case 3: return 5;                 /* INST/MEM/REGS/BRANCH/VREG */
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
            return [self fieldCellKey:@"count" label:@"Trace 次数"
                          placeholder:@"1" numeric:YES];
        }
        if (ip.row == 1) {
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
        NSArray *names = @[ @"指令(INST)", @"内存(MEM)", @"寄存器(REGS)",
                            @"仅分支(BRANCH)", @"向量寄存器(VREG)" ];
        int bit = 1 << ip.row;
        UITableViewCell *c = [[UITableViewCell alloc]
            initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        c.textLabel.text = names[ip.row];
        int mask = [self.item[@"logMask"] intValue];
        c.accessoryType = (mask & bit) ? UITableViewCellAccessoryCheckmark
                                       : UITableViewCellAccessoryNone;
        return c;
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
    c.textLabel.text = [NSString stringWithFormat:@"%@ %@ %@",
                        w[@"reg"] ?: @"?", w[@"action"] ?: @"",
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
    return c;
}

#pragma mark - 输入回写

- (void)textFieldDidEndEditing:(UITextField *)tf {
    NSString *key = objc_getAssociatedObject(tf, "cfgKey");
    if (key == nil) return;
    BOOL numeric = [objc_getAssociatedObject(tf, "numeric") boolValue];
    if (numeric) {
        self.item[key] = @([tf.text integerValue]);
    } else {
        self.item[key] = tf.text ?: @"";
    }
}

- (BOOL)textFieldShouldReturn:(UITextField *)tf {
    [tf resignFirstResponder];
    return YES;
}

- (void)moduleOnlyChanged:(UISwitch *)sw {
    self.item[@"moduleOnly"] = @(sw.on);
}

#pragma mark - 选择

- (void)tableView:(UITableView *)tableView
    didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tableView deselectRowAtIndexPath:ip animated:YES];

    if (ip.section == 3) {
        /* 切 logMask 位 */
        int bit = 1 << ip.row;
        int mask = [self.item[@"logMask"] intValue] ^ bit;
        self.item[@"logMask"] = @(mask);
        [tableView reloadRowsAtIndexPaths:@[ ip ]
                         withRowAnimation:UITableViewRowAnimationNone];
        return;
    }

    if (ip.section == 4) {
        NSMutableArray *watches = self.item[@"watches"];
        NSMutableDictionary *w;
        BOOL isNewWatch = (ip.row == (NSInteger)watches.count);
        if (isNewWatch) {
            w = [@{ @"module": self.item[@"module"] ?: @"",
                    @"offset": @"0x0", @"reg": @"x0",
                    @"action": @"cstr", @"size": @0, @"label": @"" } mutableCopy];
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

/* watch 行左滑删除 */
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
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

- (void)done {
    [self.view endEditing:YES]; /* 触发所有 textFieldDidEndEditing 回写 */

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
