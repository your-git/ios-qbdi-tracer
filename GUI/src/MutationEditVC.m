#import "MutationEditVC.h"
#import "ExprInput.h"
#import "HexValue.h"
#import <objc/runtime.h>
#include <stdint.h>

static NSArray<NSString *> *MutationRegisters(void) {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (int i = 0; i <= 28; i++) {
        if (i == 17) continue;
        [names addObject:[NSString stringWithFormat:@"x%d", i]];
    }
    [names addObjectsFromArray:@[ @"fp", @"lr" ]];
    return names;
}

static BOOL MutationRegisterValid(NSString *name) {
    return [MutationRegisters() containsObject:name];
}

@interface MutationFieldCell : UITableViewCell
@property(nonatomic, strong) UITextField *field;
@end

@implementation MutationFieldCell
- (instancetype)init {
    self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
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

@interface MutationEditVC () <UITextFieldDelegate>
@property(nonatomic, strong) NSMutableDictionary *mutation;
@end

@implementation MutationEditVC

- (instancetype)initWithMutation:(NSMutableDictionary *)mutation {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) _mutation = mutation;
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Trace 内寄存器修改";
    self.tableView.rowHeight = 52;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:@"确定" style:UIBarButtonItemStyleDone
               target:self action:@selector(commit)];

    if (self.mutation[@"enabled"] == nil) self.mutation[@"enabled"] = @YES;
    if (!MutationRegisterValid(self.mutation[@"reg"])) self.mutation[@"reg"] = @"x0";
    NSInteger width = [self.mutation[@"width"] integerValue];
    self.mutation[@"width"] = @(width == 32 ? 32 : 64);
    if ([self isFixed64Register]) self.mutation[@"width"] = @64;
    if (![self.mutation[@"apply"] isEqual:@"always"]) self.mutation[@"apply"] = @"once";
    self.mutation[@"offset"] = HexDisplay(self.mutation[@"offset"] ?: @"0x0");
    self.mutation[@"value"] = HexDisplay(self.mutation[@"value"] ?: @"0x0");
    [self beginEditingTarget:self.mutation];
}

- (BOOL)isFixed64Register {
    NSString *reg = self.mutation[@"reg"];
    return [reg isEqual:@"fp"] || [reg isEqual:@"lr"];
}

- (NSString *)registerDisplay {
    NSString *reg = self.mutation[@"reg"] ?: @"x0";
    if ([self.mutation[@"width"] integerValue] == 32 && [reg hasPrefix:@"x"]) {
        return [@"w" stringByAppendingString:[reg substringFromIndex:1]];
    }
    return reg;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return 6;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return @"在目标指令执行前覆盖 QBDI 寄存器，只影响本次 Trace，不写回真实 App。"
            @"若要改写 load 或函数调用的结果，请选择它的下一条指令。"
            @"不支持 sp、pc、x17；wN 写入会把高 32 位清零。";
}

- (MutationFieldCell *)hexField:(NSString *)key label:(NSString *)label {
    MutationFieldCell *cell = [MutationFieldCell new];
    cell.textLabel.text = label;
    cell.field.text = HexDisplay(self.mutation[key]);
    cell.field.placeholder = @"0x...";
    cell.field.delegate = self;
    cell.field.keyboardType = UIKeyboardTypeASCIICapable;
    cell.field.autocorrectionType = UITextAutocorrectionTypeNo;
    cell.field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    objc_setAssociatedObject(cell.field, "mutationKey", key,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    AttachHexKeyboard(cell.field);
    [cell.field addTarget:self action:@selector(hexChanged:)
         forControlEvents:UIControlEventEditingChanged];
    return cell;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.row == 0) {
        UITableViewCell *cell = [[UITableViewCell alloc]
            initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        cell.textLabel.text = @"启用";
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        UISwitch *toggle = [UISwitch new];
        toggle.on = [self.mutation[@"enabled"] boolValue];
        [toggle addTarget:self action:@selector(enabledChanged:)
         forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
        return cell;
    }
    if (ip.row == 1) return [self hexField:@"offset" label:@"静态地址"];
    if (ip.row == 4) return [self hexField:@"value" label:@"写入值"];

    UITableViewCell *cell = [[UITableViewCell alloc]
        initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    if (ip.row == 2) {
        cell.textLabel.text = @"寄存器";
        cell.detailTextLabel.text = [self registerDisplay];
    } else if (ip.row == 3) {
        cell.textLabel.text = @"位宽";
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%ld 位",
                                     (long)[self.mutation[@"width"] integerValue]];
    } else {
        cell.textLabel.text = @"应用方式";
        cell.detailTextLabel.text = [self.mutation[@"apply"] isEqual:@"always"]
                                        ? @"每次命中" : @"每次 Trace 仅一次";
    }
    return cell;
}

- (void)enabledChanged:(UISwitch *)toggle {
    self.mutation[@"enabled"] = @(toggle.on);
    [self updatePopGesture];
}

- (void)hexChanged:(UITextField *)field {
    NSString *key = objc_getAssociatedObject(field, "mutationKey");
    NSString *text = [field.text stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    unsigned long long ignored = 0;
    BOOL valid = text.length > 0 && HexParseInput(text, &ignored);
    self.mutation[key] = text ?: @"";
    field.textColor = valid ? [UIColor labelColor] : [UIColor systemRedColor];
    [self updatePopGesture];
}

- (void)textFieldDidEndEditing:(UITextField *)field {
    NSString *key = objc_getAssociatedObject(field, "mutationKey");
    if (key.length == 0) return;
    unsigned long long value = 0;
    if (HexParseInput(field.text, &value)) {
        NSString *normalized = [NSString stringWithFormat:@"0x%llx", value];
        self.mutation[key] = normalized;
        field.text = normalized;
    }
    [self hexChanged:field];
}

- (BOOL)textFieldShouldReturn:(UITextField *)field {
    [field resignFirstResponder];
    return YES;
}

- (void)showOptions:(NSArray<NSString *> *)labels
                keys:(NSArray *)keys
               title:(NSString *)title
              source:(UITableViewCell *)source
             handler:(void (^)(id key))handler {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:title
        message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSUInteger i = 0; i < labels.count; i++) {
        id key = keys[i];
        [sheet addAction:[UIAlertAction actionWithTitle:labels[i]
            style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                handler(key);
                [self.tableView reloadData];
                [self updatePopGesture];
            }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消"
        style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = source;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *source = [tableView cellForRowAtIndexPath:ip];
    [tableView deselectRowAtIndexPath:ip animated:YES];
    if (ip.row == 2) {
        NSArray *regs = MutationRegisters();
        [self showOptions:regs keys:regs title:@"选择寄存器" source:source
                  handler:^(id selected) {
            NSString *reg = selected;
            self.mutation[@"reg"] = reg;
            if ([self isFixed64Register]) self.mutation[@"width"] = @64;
        }];
    } else if (ip.row == 3) {
        if ([self isFixed64Register]) {
            [self alert:@"位宽固定" message:@"fp 和 lr 只支持 64 位写入。"];
            return;
        }
        [self showOptions:@[ @"64 位（xN）", @"32 位（wN）" ] keys:@[ @64, @32 ]
                     title:@"选择位宽" source:source handler:^(id selected) {
            NSNumber *width = selected;
            self.mutation[@"width"] = width;
        }];
    } else if (ip.row == 5) {
        [self showOptions:@[ @"每次 Trace 仅一次", @"每次命中" ]
                     keys:@[ @"once", @"always" ] title:@"选择应用方式"
                   source:source handler:^(id selected) {
            NSString *apply = selected;
            self.mutation[@"apply"] = apply;
        }];
    }
}

- (void)alert:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好"
        style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)commit {
    [self.view endEditing:YES];
    unsigned long long offset = 0, value = 0;
    if (!HexParseInput([self.mutation[@"offset"] description], &offset)) {
        [self alert:@"静态地址无效" message:@"静态地址只能包含 0X、0-9 和 A-F。"];
        return;
    }
    if (!HexParseInput([self.mutation[@"value"] description], &value)) {
        [self alert:@"写入值无效" message:@"写入值只能包含 0X、0-9 和 A-F。"];
        return;
    }
    NSString *reg = self.mutation[@"reg"];
    NSInteger width = [self.mutation[@"width"] integerValue];
    if (!MutationRegisterValid(reg) || (width != 32 && width != 64) ||
        ([self isFixed64Register] && width != 64)) {
        [self alert:@"寄存器配置无效" message:@"请重新选择寄存器和位宽。"];
        return;
    }
    if (width == 32 && value > UINT32_MAX) {
        [self alert:@"写入值过大" message:@"32 位寄存器的写入值不能超过 0xFFFFFFFF。"];
        return;
    }
    self.mutation[@"offset"] = [NSString stringWithFormat:@"0x%llx", offset];
    self.mutation[@"value"] = [NSString stringWithFormat:@"0x%llx", value];
    if (self.onDone) self.onDone();
    [self.navigationController popViewControllerAnimated:YES];
}

@end
