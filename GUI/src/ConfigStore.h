#import <Foundation/Foundation.h>

/* 配置读写:与引擎 engine.m 同一路径、同一 JSON schema。
 * 顶层: { enabled: bool, items: [ item... ] }
 * item:  { id, enabled, traceName(可选), bundleId, appName, module, start, end, count,
 *          moduleOnly, delaySecs, logMask, maxInstructions(可选,0=不限制),
 *          triggerConsume: repeat|once, triggers: [ trigger... ],
 *          watches: [ watch... ] }
 * trigger: { triggerExpr, triggerAddress, triggerMatch, triggerValue,
 *            triggerWhere, triggerScan }
 * watch: { module, offset, reg, expr, action, size, label } */
@interface ConfigStore : NSObject

+ (instancetype)shared;

@property (nonatomic, assign) BOOL enabled;      /* 总开关 */
@property (nonatomic, strong) NSMutableArray<NSMutableDictionary *> *items;

- (void)load;
- (BOOL)save;                                     /* 写 JSON,返回是否成功 */
- (NSString *)configPath;

/* 新建一个带默认值的 item(未加入 items,调用方负责 add) */
- (NSMutableDictionary *)newItem;

/* ---- 导出 / 导入 ---- */

/* 导出用目录(App 沙盒 Documents,开了 UIFileSharingEnabled 后 Finder/文件 App 可见)。
 * 探测真实路径;必要时创建。 */
- (NSString *)exportDir;

/* 把一条 item 导出成 JSON 文件。成功返回落地的完整路径,失败返回 nil。
 * 文件名 = <appName净化><年月日时分>.json */
- (NSString *)exportItem:(NSDictionary *)item error:(NSError **)err;

/* 列出 exportDir 下所有 .json 文件的完整路径(按修改时间倒序) */
- (NSArray<NSString *> *)listImportableFiles;

/* 解析并校验一份导出 JSON(NSData 或字符串二选一),返回可导入的 item(已重生 id、
 * enabled=YES)。格式非法返回 nil 并置 error。不改动 items,调用方负责 add+save。 */
- (NSMutableDictionary *)importItemFromData:(NSData *)data error:(NSError **)err;
- (NSMutableDictionary *)importItemFromString:(NSString *)json error:(NSError **)err;

@end
