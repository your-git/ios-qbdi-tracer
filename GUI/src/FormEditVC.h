#import <UIKit/UIKit.h>

#import "NavController.h"

/* 表单编辑页基类:管快照、脏检查、返回确认、右滑手势。
 *
 * 背景:编辑页拿到的可变字典**就是**配置里的那一个(不是副本),所以每次输入回写都
 * 已经原地改了内存里的配置,只有点「完成/确定」才落盘。为了让"没确定就返回"真的
 * 不算保存,这里在进入时拍一份快照,返回时比对,确认放弃就原地还原。
 *
 * 子类要做的:
 *   1. 先把字段规范化好(比如 size 转成 "0x..."、logMask 写成默认值),再调
 *      beginEditingTarget: —— 顺序反了会把自动规范化当成"用户改了东西"而误弹确认框
 *   2. 有不参与回滚的子结构时覆盖 snapshotExcludedKeys
 *   3. 编辑页显示期间由基类统一禁用右滑返回
 */
@interface FormEditVC : UITableViewController <NavPopGuard>

/* 正在编辑的字典(配置里的那一个,不是副本) */
@property (nonatomic, strong, readonly) NSMutableDictionary *target;

/* 拍快照开始编辑。务必在字段规范化**之后**调。 */
- (void)beginEditingTarget:(NSMutableDictionary *)target;

/* 不参与快照/回滚的 key(默认空集)。放在这里的子结构改了也不会被还原。 */
- (NSSet<NSString *> *)snapshotExcludedKeys;

/* 当前内容与快照是否不同(不含 snapshotExcludedKeys) */
- (BOOL)hasChanges;

/* 编辑页显示期间关闭右滑返回(它会绕过 navShouldPop) */
- (void)updatePopGesture;

@end
