#import "SortedListVC.h"
#import "AppSettings.h"
#import "ListSort.h"

@implementation SortedListVC
- (NSArray<NSMutableDictionary *> *)sourceEntries { return @[]; }
- (BOOL)isHookList { return NO; }
- (QBDIListSortMode)sortMode {
    AppSettings *settings = [AppSettings shared];
    return self.isHookList ? settings.hookSortMode : settings.traceSortMode;
}
- (void)installSortButton {
    UIBarButtonItem *sort = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"arrow.up.arrow.down"]
        style:UIBarButtonItemStylePlain target:self action:@selector(showSortMenu:)];
    sort.accessibilityLabel = @"排序";
    self.navigationItem.rightBarButtonItems = @[ self.navigationItem.rightBarButtonItem, sort ];
    [self reloadEntries];
}
- (void)reloadEntries {
    self.displayedEntries = QBDISortedEntries([self sourceEntries],
        self.isHookList ? @"hookName" : @"traceName", [self sortMode]);
    [self.tableView reloadData];
}
- (void)showSortMenu:(UIBarButtonItem *)sender {
    QBDIListSortMode current = [self sortMode];
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:@"排序"
        message:@"按自定义名称排序，未命名时使用 App 名称；中文按拼音排序。"
        preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSInteger i = QBDIListSortNameAscending; i <= QBDIListSortOldestFirst; i++) {
        NSString *title = QBDIListSortTitle(i);
        if (i == current) title = [@"✓ " stringByAppendingString:title];
        [menu addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *action) {
                AppSettings *settings = [AppSettings shared];
                QBDIListSortMode old = [self sortMode];
                if (self.isHookList) settings.hookSortMode = i;
                else settings.traceSortMode = i;
                if (![settings save]) {
                    if (self.isHookList) settings.hookSortMode = old;
                    else settings.traceSortMode = old;
                    UIAlertController *error = [UIAlertController alertControllerWithTitle:@"保存失败"
                        message:@"未能保存排序选择，已恢复原排序。请检查配置目录权限。"
                        preferredStyle:UIAlertControllerStyleAlert];
                    [error addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
                    [self presentViewController:error animated:YES completion:nil];
                    return;
                }
                [self reloadEntries];
            }]];
    }
    [menu addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    menu.popoverPresentationController.barButtonItem = sender;
    [self presentViewController:menu animated:YES completion:nil];
}
@end
