#import "WatchEditVC.h"
#import <objc/runtime.h>

static NSArray *RegNames(void) {
    NSMutableArray *a = [NSMutableArray array];
    for (int i = 0; i <= 28; i++) [a addObject:[NSString stringWithFormat:@"x%d", i]];
    [a addObjectsFromArray:@[ @"fp", @"lr", @"sp" ]];
    return a;
}
static NSArray *ActionNames(void) {
    return @[ @"cstr", @"utf8", @"u32", @"u64", @"hexdump", @"objc" ];
}

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
}

/* 行:0 module / 1 offset / 2 reg / 3 action / 4 size / 5 label */
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s { return 6; }

- (UITableViewCell *)tableView:(UITableView *)tv
         cellForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.row == 2 || ip.row == 3) {
        UITableViewCell *c = [[UITableViewCell alloc]
            initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
        c.textLabel.text = (ip.row == 2) ? @"寄存器" : @"输出形式";
        c.detailTextLabel.text = (ip.row == 2) ? self.watch[@"reg"]
                                               : self.watch[@"action"];
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return c;
    }
    NSArray *keys = @[ @"module", @"offset", @"", @"", @"size", @"label" ];
    NSArray *labels = @[ @"模块名", @"监视地址", @"", @"", @"读取上限(0=不截断)", @"标签" ];
    NSArray *ph = @[ @"ModuleName", @"0x...", @"", @"", @"0", @"url" ];
    NSString *key = keys[ip.row];
    WEFieldCell *c = [[WEFieldCell alloc] initWithReuseIdentifier:nil];
    c.textLabel.text = labels[ip.row];
    c.field.placeholder = ph[ip.row];
    c.field.delegate = self;
    BOOL numeric = [key isEqualToString:@"size"];
    c.field.keyboardType = numeric ? UIKeyboardTypeNumberPad
                                   : UIKeyboardTypeASCIICapable;
    id v = self.watch[key];
    c.field.text = [v isKindOfClass:[NSString class]]
                       ? v : ([v respondsToSelector:@selector(stringValue)]
                                  ? [v stringValue] : @"");
    objc_setAssociatedObject(c.field, "k", key, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(c.field, "n", @(numeric), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return c;
}

- (void)textFieldDidEndEditing:(UITextField *)tf {
    NSString *k = objc_getAssociatedObject(tf, "k");
    if (k.length == 0) return;
    if ([objc_getAssociatedObject(tf, "n") boolValue]) {
        self.watch[k] = @([tf.text integerValue]);
    } else {
        self.watch[k] = tf.text ?: @"";
    }
}
- (BOOL)textFieldShouldReturn:(UITextField *)tf { [tf resignFirstResponder]; return YES; }

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.row != 2 && ip.row != 3) return;
    BOOL isReg = (ip.row == 2);
    NSArray *opts = isReg ? RegNames() : ActionNames();
    NSString *key = isReg ? @"reg" : @"action";
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:(isReg ? @"选择寄存器" : @"选择输出形式")
                         message:nil
                  preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSString *o in opts) {
        [sheet addAction:[UIAlertAction actionWithTitle:o
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *a) {
                  self.watch[key] = o;
                  [self.tableView reloadData];
              }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    sheet.popoverPresentationController.sourceView =
        [tv cellForRowAtIndexPath:ip];
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)commit {
    [self.view endEditing:YES];
    if (self.onDone) self.onDone();
    [self.navigationController popViewControllerAnimated:YES];
}

@end
