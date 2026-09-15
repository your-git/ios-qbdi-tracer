#import "AppPickerVC.h"
#import <objc/runtime.h>
#import <dlfcn.h>

/* 私有 API 声明:LSApplicationWorkspace / LSApplicationProxy。
 * 越狱环境 App 可用;仅用于列出已装 app 图标+名字+bundleId。 */
@interface LSApplicationProxy : NSObject
@property (nonatomic, readonly) NSString *applicationIdentifier; /* bundleId */
@property (nonatomic, readonly) NSString *localizedName;
@property (nonatomic, readonly) NSString *applicationType; /* System/User */
@end

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (NSArray *)allApplications;
@end

@interface AppRow : NSObject
@property (nonatomic, copy) NSString *bundleId;
@property (nonatomic, copy) NSString *name;
@end
@implementation AppRow
@end

@interface AppPickerVC () <UISearchResultsUpdating>
@property (nonatomic, strong) NSArray<AppRow *> *all;
@property (nonatomic, strong) NSArray<AppRow *> *shown;
@property (nonatomic, strong) UISearchController *search;
@end

@implementation AppPickerVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"选择 App";
    self.search = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.search.searchResultsUpdater = self;
    self.search.obscuresBackgroundDuringPresentation = NO;
    self.navigationItem.searchController = self.search;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    [self loadApps];
}

- (void)loadApps {
    NSMutableArray *rows = [NSMutableArray array];
    Class ws = NSClassFromString(@"LSApplicationWorkspace");
    if (ws != nil) {
        LSApplicationWorkspace *w = [ws defaultWorkspace];
        for (LSApplicationProxy *p in [w allApplications]) {
            NSString *bid = p.applicationIdentifier;
            if (bid.length == 0) continue;
            AppRow *r = [AppRow new];
            r.bundleId = bid;
            r.name = p.localizedName.length ? p.localizedName : bid;
            [rows addObject:r];
        }
    }
    [rows sortUsingComparator:^NSComparisonResult(AppRow *a, AppRow *b) {
        return [a.name localizedCaseInsensitiveCompare:b.name];
    }];
    self.all = rows;
    self.shown = rows;
    [self.tableView reloadData];
}

/* 图标:通过私有 UIImage +_applicationIconImageForBundleIdentifier:format:scale: */
- (UIImage *)iconFor:(NSString *)bundleId {
    SEL sel = NSSelectorFromString(
        @"_applicationIconImageForBundleIdentifier:format:scale:");
    if (![UIImage respondsToSelector:sel]) {
        return nil;
    }
    NSMethodSignature *sig = [UIImage methodSignatureForSelector:sel];
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    inv.target = [UIImage class];
    inv.selector = sel;
    int format = 2; /* 小图标 */
    double scale = [UIScreen mainScreen].scale;
    [inv setArgument:&bundleId atIndex:2];
    [inv setArgument:&format atIndex:3];
    [inv setArgument:&scale atIndex:4];
    [inv invoke];
    UIImage *__unsafe_unretained img = nil;
    [inv getReturnValue:&img];
    return img;
}

#pragma mark - Search

- (void)updateSearchResultsForSearchController:(UISearchController *)sc {
    NSString *q = sc.searchBar.text;
    if (q.length == 0) {
        self.shown = self.all;
    } else {
        NSPredicate *p = [NSPredicate predicateWithBlock:^BOOL(AppRow *r, id _) {
            return [r.name localizedCaseInsensitiveContainsString:q] ||
                   [r.bundleId localizedCaseInsensitiveContainsString:q];
        }];
        self.shown = [self.all filteredArrayUsingPredicate:p];
    }
    [self.tableView reloadData];
}

#pragma mark - Table

- (NSInteger)tableView:(UITableView *)tableView
    numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.shown.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell =
        [tableView dequeueReusableCellWithIdentifier:@"app"];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:@"app"];
    }
    AppRow *r = self.shown[indexPath.row];
    cell.textLabel.text = r.name;
    cell.detailTextLabel.text = r.bundleId;
    cell.imageView.image = [self iconFor:r.bundleId];
    cell.imageView.layer.cornerRadius = 8;
    cell.imageView.clipsToBounds = YES;
    return cell;
}

- (void)tableView:(UITableView *)tableView
    didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    AppRow *r = self.shown[indexPath.row];
    UINavigationController *nav = self.navigationController;
    if (self.onPick) {
        self.onPick(r.bundleId, r.name); /* 回调里 push 编辑页 */
    }
    /* 编辑页已在栈顶;把 picker 从栈中间移除,取消编辑时直接回主列表 */
    NSMutableArray *vcs = [nav.viewControllers mutableCopy];
    [vcs removeObject:self];
    [nav setViewControllers:vcs animated:NO];
}

@end
