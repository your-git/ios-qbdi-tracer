#import <Foundation/Foundation.h>

/* 全局设置与路径中心。
 *
 * 配置目录下现在有三份文件,各管各的:
 *   settings.json —— 本类负责。总开关 + 日志根目录 + 导入导出根目录。
 *                    引擎**最先读这一份**,总开关关着就立即空转返回,
 *                    另外两份根本不用读。
 *   config.json   —— ConfigStore 负责,只剩顶层 items(trace 条目)。
 *   hooks.json    —— Hook 条目(阶段③引入)。
 *
 * 总开关原来在 config.json 里,现在搬到 settings.json。搬迁做两头:
 *   - App 这边:load 时若 settings.json 不存在,就去读旧 config.json 的 enabled,
 *     随后立刻写出 settings.json(见 -load)。
 *   - 引擎那边:settings.json 缺失时同样回落去读旧 config.json 的 enabled。
 * 少了任何一头,老用户升级后"原本关掉的插件"都会自己变成开启。 */

/* 配置目录:rootless 优先 /var/jb,否则经典路径。引擎 config_path() 与此一致。 */
NSString *QBDIConfigDir(void);

/* App 沙盒 Documents(探测失败时有回退)。也是旧版导出文件散落的地方。 */
NSString *QBDIDocumentsDir(void);

/* 两个根目录的出厂默认值 */
NSString *QBDIDefaultLogRoot(void);    /* /tmp/ios-qbdi-tracer */
NSString *QBDIDefaultExportRoot(void); /* <Documents>/ios-qbdi-tracer-config-json */

/* 根目录下的固定子目录名。**引擎侧 qbdi_trace.c 有同名常量,改这里要一起改**。 */
#define QBDI_TRACE_LOG_SUBDIR    @"trace-logs"
#define QBDI_HOOK_LOG_SUBDIR     @"hook-logs"
#define QBDI_TRACE_EXPORT_SUBDIR @"trace"
#define QBDI_HOOK_EXPORT_SUBDIR  @"hook"

@interface AppSettings : NSObject

+ (instancetype)shared;

/* 插件总开关(Trace 和 Hook 共用)。主页列表第一行那个开关。 */
@property (nonatomic, assign) BOOL enabled;
/* 日志根目录。引擎要读它决定日志往哪写。 */
@property (nonatomic, copy) NSString *logRoot;
/* 导入导出根目录。只有控制 App 用,引擎不关心。 */
@property (nonatomic, copy) NSString *exportRoot;

- (void)load;
- (BOOL)save;
- (NSString *)settingsPath;

/* 四个实际落地目录(按需创建;创建失败仍返回路径,由调用方处理写入失败) */
- (NSString *)traceLogDir;
- (NSString *)hookLogDir;
- (NSString *)traceExportDir;
- (NSString *)hookExportDir;

/* 目录是否可用(能创建且可写)。设置页保存前用它校验用户填的路径。 */
+ (BOOL)directoryUsable:(NSString *)path;

@end
