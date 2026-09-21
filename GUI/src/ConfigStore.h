#import <Foundation/Foundation.h>

/* Trace 配置读写:与引擎 engine.m 同一路径、同一 JSON schema。
 * 顶层: { items: [ item... ] }
 *
 * 总开关 enabled 已搬到 settings.json(见 AppSettings),这里不再读写它 ——
 * 引擎要能只读 settings.json 就判断出该不该干活。旧 config.json 里残留的
 * enabled 字段被忽略,AppSettings 首次启动时会把它迁走。
 *
 * item:  { id, enabled, traceName(可选), bundleId, appName, module, start, end, count,
 *          moduleOnly, delaySecs, logMask, maxInstructions(可选,0=不限制),
 *          triggerConsume: repeat|once|custom, triggers: [ trigger... ],
 *          mutations: [ { enabled, offset, reg, width, value, apply } ],
 *          watches: [ watch... ] }
 * trigger: { triggerExpr, triggerAddress, triggerMatch, triggerValue,
 *            triggerWhere, triggerScan, triggerLimit }
 * watch: { module, offset, reg, expr, action, size, label } */
@interface ConfigStore : NSObject

+ (instancetype)shared;

@property (nonatomic, strong) NSMutableArray<NSMutableDictionary *> *items;

- (void)load;
- (BOOL)save;                                     /* 写 JSON,返回是否成功 */
- (NSString *)configPath;

/* 新建一个带默认值的 item(未加入 items,调用方负责 add) */
- (NSMutableDictionary *)newItem;

/* ---- 导出 / 导入 ---- */

/* Trace 的导出目录:<exportRoot>/trace(按需创建)。exportRoot 可在设置页改。
 * 开了 UIFileSharingEnabled 后 Finder/文件 App 可见。 */
- (NSString *)exportDir;

/* 把一条 item 导出成 JSON 文件。成功返回落地的完整路径,失败返回 nil。
 * 文件名 = trace_<appName净化><年月日时分>.json —— 前缀是为了文件被挪出目录后
 * 仍能一眼认出类型(导入时的类型判定另看文件内容,不依赖文件名)。 */
- (NSString *)exportItem:(NSDictionary *)item error:(NSError **)err;

/* 可导入的 .json 完整路径(按修改时间倒序)。除了新的 <exportRoot>/trace,
 * 还会扫旧版散落在 Documents 根下的文件,以免升级后"以前导出的都不见了"。 */
- (NSArray<NSString *> *)listImportableFiles;

/* 解析并校验一份导出 JSON(NSData 或字符串二选一),返回可导入的 item(已重生 id、
 * enabled=YES)。格式非法返回 nil 并置 error。不改动 items,调用方负责 add+save。 */
- (NSMutableDictionary *)importItemFromData:(NSData *)data error:(NSError **)err;
- (NSMutableDictionary *)importItemFromString:(NSString *)json error:(NSError **)err;

@end
