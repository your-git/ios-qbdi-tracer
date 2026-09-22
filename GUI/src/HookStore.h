#import <Foundation/Foundation.h>

/* Hook 配置读写:与引擎 engine.m 的 hooks.json 解析同一路径、同一 schema。
 * 与 Trace 完全独立(ConfigStore 管 config.json,这里管 hooks.json)。
 *
 * 顶层: { hooks: [ hook... ] }
 * hook:  { id, enabled, hookName(可选), bundleId, appName, module, target,
 *          delaySecs, maxHits(0=不限), mods: [ mod... ] }
 * mod:   { enabled, kind:"modify", type:"bytes|string|number",
 *          width(number 才有意义), expr, value }
 *
 * 总开关 enabled 在 settings.json(AppSettings),Hook 与 Trace 共用它。 */
@interface HookStore : NSObject

+ (instancetype)shared;

@property (nonatomic, strong) NSMutableArray<NSMutableDictionary *> *hooks;

- (void)load;
- (BOOL)save;
- (NSString *)configPath;

/* 新建一个带默认值的 hook(未加入 hooks,调用方负责 add) */
- (NSMutableDictionary *)newHook;
/* 新建一条默认的"修改数据"功能 */
- (NSMutableDictionary *)newMod;

/* ---- 导出 / 导入 ---- */

/* Hook 的导出目录:<exportRoot>/hook(按需创建)。 */
- (NSString *)exportDir;

/* 导出一条 hook。文件名 = hook_<appName净化><年月日时分>.json,
 * 内容 { version:1, type:"hook", hook:{...} }。成功返回完整路径,失败返回 nil。 */
- (NSString *)exportHook:(NSDictionary *)hook error:(NSError **)err;

/* 可导入的 .json 完整路径(hook 目录 + 旧版 Documents 根,按修改时间倒序) */
- (NSArray<NSString *> *)listImportableFiles;

/* 解析并校验一份 hook 导出(重生 id、enabled=YES);格式非法返回 nil+error。 */
- (NSMutableDictionary *)importHookFromData:(NSData *)data error:(NSError **)err;

/* 判定一份导出文件的真实类型:返回 @"trace" / @"hook" / nil(无法识别)。
 * 供导入页把"选错分页的文件"自动导到正确分页。 */
+ (NSString *)detectType:(NSData *)data;

@end
