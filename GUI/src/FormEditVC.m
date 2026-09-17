#import "FormEditVC.h"

@interface FormEditVC ()
@property (nonatomic, strong) NSMutableDictionary *target;
@property (nonatomic, strong) NSDictionary *snapshot;
@end

@implementation FormEditVC

- (void)beginEditingTarget:(NSMutableDictionary *)target {
    _target = target;
    NSMutableDictionary *snap = [target mutableCopy];
    for (NSString *k in [self snapshotExcludedKeys]) {
        [snap removeObjectForKey:k];
    }
    _snapshot = snap;
}

- (NSSet<NSString *> *)snapshotExcludedKeys {
    return [NSSet set];
}

- (BOOL)hasChanges {
    if (self.target == nil || self.snapshot == nil) {
        return NO;
    }
    NSMutableDictionary *cur = [self.target mutableCopy];
    for (NSString *k in [self snapshotExcludedKeys]) {
        [cur removeObjectForKey:k];
    }
    return ![cur isEqualToDictionary:self.snapshot];
}

/* 原地还原:调用方持有的是同一个字典引用,不能换对象。
 * snapshotExcludedKeys 里的子结构保持当前值(不回滚)。 */
- (void)restoreSnapshot {
    NSMutableDictionary *keep = [NSMutableDictionary dictionary];
    for (NSString *k in [self snapshotExcludedKeys]) {
        id v = self.target[k];
        if (v != nil) {
            keep[k] = v;
        }
    }
    [self.target removeAllObjects];
    [self.target addEntriesFromDictionary:self.snapshot];
    [self.target addEntriesFromDictionary:keep];
}

#pragma mark - 返回拦截

- (BOOL)navShouldPop {
    /* 先把正在编辑的输入框回写,让"改了但还没失焦"也算改动 */
    [self.view endEditing:YES];
    if (![self hasChanges]) {
        return YES;
    }
    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:@"放弃修改?"
                         message:@"当前修改还没保存,返回将丢弃这些改动。"
                  preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"继续编辑"
                                           style:UIAlertActionStyleCancel
                                         handler:nil]];
    [ac addAction:[UIAlertAction
                      actionWithTitle:@"放弃"
                                style:UIAlertActionStyleDestructive
                              handler:^(UIAlertAction *a) {
                                  [self restoreSnapshot];
                                  /* 代码 pop 不再走 navShouldPop,直接退 */
                                  [self.navigationController
                                      popViewControllerAnimated:YES];
                              }]];
    [self presentViewController:ac animated:YES completion:nil];
    return NO;
}

- (void)updatePopGesture {
    /* 右滑返回绕过 navShouldPop,有改动时只能整个关掉 */
    self.navigationController.interactivePopGestureRecognizer.enabled =
        ![self hasChanges];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self updatePopGesture];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    /* 必须恢复,否则会把手势禁用状态带给下一个页面 */
    self.navigationController.interactivePopGestureRecognizer.enabled = YES;
}

@end
