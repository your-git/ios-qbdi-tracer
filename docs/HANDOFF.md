# 交接与维护文档

> 面向后续会话/维护者。读完 [DESIGN.md](DESIGN.md) 再读这篇。这里讲**每个文件干什么**、**常见修改怎么做**、**别踩什么坑**。

## 文件地图

### Engine/(引擎 tweak,注入到目标 app)

| 文件 | 行数 | 作用 | 改动频率 |
|---|---|---|---|
| `Tweak.x` | 小 | 入口。`__attribute__((constructor))` → `engine_start()`。**不用 Logos %ctor**(Apple clang 21+ 编不过其 `__unused` 参数) | 几乎不改 |
| `src/engine.m` | ~500 | **核心新代码**。先读 settings.json(总开关+日志根目录),再读 config.json 装 trace、hooks.json 装 hook。填 `g_traces`/`g_watches`/`g_hooks`,每条目 dispatch_after 延迟装 Dobby hook。含 `load_and_install_traces`/`load_and_install_hooks`/`load_hook`/`load_hook_mod` 和 `find_module` | 加字段/改匹配逻辑时 |
| `src/tramp.c` | ~230 | 固定 32 trace + 128 trigger + 32 hook 个 naked arm64 trampoline + `g_tramps[]`/`g_trigger_tramps[]`/`g_hook_tramps[]`。保存完整现场并恢复除 Dobby 临时寄存器 x17 外的状态；x17 专门承载 origin，最终 `br x17`(栈帧 `0x320`)。三种入口共用同一 TRAMP 宏,只差 C 入口函数名。少存任何一样或覆盖续跑地址都会破坏控制流 | **改完必须反汇编核对** |
| `src/qbdi_trace.c` | ~760 | QBDI 引擎:VM 记录、`trace_ctx_entry`(记录后原生续跑)、`watch_handle`、崩溃捕获。也含日志路径工具 `qbdi_trace_set_log_root`/`qbdi_log_timestamp`/`qbdi_log_build_path`(hook 日志复用) | 改 trace/watch/日志位置时 |
| `src/qbdi_trace.h` | 55 | LOG_* 位、`TRACE_MAX_TARGETS=32`/`TRACE_MAX_WATCHES=128`、`TraceRegFile`、函数声明 | 改上限时 |
| `src/watch_expr.{h,c}` | ~420 | **watch 取址表达式**(`x0-0x110`、`[[x0+8]+0x10]-4`)的编译与求值。递归下降 parser → 后缀式,加载期编译、命中时求值。纯 C,不依赖 QBDI(便于在 mac 上直接编译自测) | 改表达式语法时 |
| `src/hook.{h,c}` | ~500 | **Hook 运行期**(用 Dobby 真实改数据,非 QBDI)。`hook_ctx_entry`(改寄存器/内存后原生续跑)、`hook_encode_value`(字节/字符串/数值编码)、`hook_classify_target`(不对称写入语义)、`vm_protect` 提权写内存、连续失败自愈、hook 日志。纯逻辑部分可提取自测 | 改 hook 行为/语义时 |
| `src/config.h` | ~120 | `TraceSpec`/`TraceWatch`/`HookSpec`/`HookMod` 结构定义 + 表的 extern 声明。`HOOK_MAX_TARGETS=32`/`HOOK_MAX_MODS=16`/`HOOK_VAL_MAX=256` | 加字段时 |
| `src/engine.h` | 10 | `g_tramps[]` 和 `engine_start()` 声明 | 几乎不改 |
| `TracerEngine.plist` | 1 | 注入过滤:`{ Filter = { Bundles = ( "com.apple.UIKit" ); }; }` | 改注入范围时 |
| `Makefile` | 小 | tweak 子工程。include 路径用 `$(THEOS_PROJECT_DIR)/Engine/...` | 加源文件时 |

### GUI/(控制 App,主屏图标)

列表排序由 `ListSort.{h,m}`（拼音比较 / 加入时间 / 稳定排序）和
`SortedListVC.{h,m}`（右上角排序菜单 / 排序显示快照）共用。显示数组仍引用原条目对象，
不得按显示行号访问 ConfigStore / HookStore 的源数组，也不得排序源数组（会改变引擎加载顺序）。
新增 / 复制 / 导入使用 Unix 秒数 `addedAt`；编辑、命名、启停不改变它。导入不继承来源文件
的时间，而是使用本次加入时间。旧条目缺失 / 无效时间视为历史条目，并按原数组先后排序，
无法恢复真实历史时间。排序选择 `traceSortMode` / `hookSortMode` 保存在 settings.json，
缺省为旧到新，保存失败会恢复原选择。

文件导入页也使用 `QBDISortedFilePaths`，复用拼音 / 自然名称比较，时间取文件修改时间
（与列表显示时间一致，不是文件 JSON 中的加入时间）。`traceImportSortMode` / `hookImportSortMode`
单独保存于 settings.json，缺省文件新到旧，不影响主页排序。切换分页会重载各自的排序。
文件属性缺失时按无时间处理，不让比较器对 nil 日期崩溃；排序后点击仍使用完整文件路径。

`GUIFeatures.h` 的 `QBDI_SHOW_TRACE_MUTATIONS=0` 隐藏 Trace 寄存器修改区域和对应帮助入口，
`TraceFormSection` 把显示 section 4 映射到原 watch section 5，避免空白分组。
恢复时设为 1；MutationEditVC、配置读写 / 校验、引擎执行都保留，Hook 不受影响。
回归用 `./scripts/test_list_sort.sh`（实际排序和配置实现，ASan / UBSan，配置目录重定向到临时目录）
以及 `./scripts/test_watch_expr.sh`。

| 文件 | 行数 | 作用 |
|---|---|---|
| `entry.m` | 10 | `UIApplicationMain` |
| `src/AppDelegate.m` | ~50 | 建 window + **底部 TabBar**(Trace=RootListVC / Hook=HookListVC,各自一个 NavController)。启动时先触发 AppSettings 加载与总开关迁移 |
| `src/AppSettings.{h,m}` | ~180 | **settings.json 读写 + 全部路径**:总开关 `enabled`、`logRoot`、`exportRoot`;四个落地子目录(trace-logs/hook-logs/trace/hook);总开关从旧 config.json 的迁移;`directoryUsable`(真写探针文件判断可写)。`QBDIConfigDir/QBDIDocumentsDir/QBDIDefault*` 也在这 |
| `src/ConfigStore.{h,m}` | ~280 | **config.json(trace)读写**。`load`/`save`/`newItem` + 导出/导入。不再管总开关(搬到 AppSettings)。导出走 `<exportRoot>/trace/`、文件名 `trace_` 前缀;导入列表兼容扫旧 Documents 根。**与引擎 schema 必须一致** |
| `src/HookStore.{h,m}` | ~230 | **hooks.json 读写**。`load`/`save`/`newHook`/`newMod` + 导出(`<exportRoot>/hook/`、`hook_` 前缀、体带 `type:"hook"`)/导入 + `+detectType:`(按内容判 trace/hook,供导入分流)。**与引擎 hook schema 必须一致** |
| `src/ExprInput.{h,m}` | ~320 | **取址表达式的输入与校验**,两个编辑页共用:`ExprSyntaxOK`/`ExprBaseReg`(轻量语法校验,**要与 `watch_expr.c` 的文法一致**)+ `ExprPrompt`(表达式快捷栏)+ `AttachHexKeyboard`(地址输入的 `0X 0-9 A-F` 快捷栏) |
| `src/HexValue.{h,m}` | ~50 | 「字节长度」类字段(watch 的 `size`、触发条件的 `triggerScan`)的进制处理:`HexValueFromJSON`(JSON 看前缀定进制)/ `HexParseInput`(输入框一律 hex)/ `HexDisplay`。**与引擎 `parse_size` 规则必须一致** |
| `src/NavController.{h,m}` | ~50 | `UINavigationController` 子类,override `navigationBar:shouldPopItem:` 来**拦住系统返回按钮**(UIKit 没有公开的"即将 pop"回调;这依赖 UINavigationController 私下就是自己 navigationBar 的 delegate)。含 `NavPopGuard` 协议 |
| `src/FormEditVC.{h,m}` | ~120 | 表单编辑页**基类**:快照 / 脏检查 / 「放弃修改?」确认；编辑页显示期间一律禁用右滑返回。TraceEditVC 和 WatchEditVC 都继承它 |
| `src/RootListVC.m` | ~450 | **Trace 列表页**。总开关(读写 AppSettings)+ 条目列表。点击=编辑,前缘滑=启停,尾缘滑=命名/导出/复制/删除。左上角走 `MoreMenuBarButton`;实现 `QBDIListPage`。所有提示改成手动点「好」的 `notify:` |
| `src/HookListVC.m` | ~320 | **Hook 列表页**。结构同 RootListVC,操作 HookStore;+ 菜单=创建/导入 Hook;实现 `QBDIListPage` |
| `src/HookEditVC.m` | ~300 | Hook 表单:目标 App、模块名、目标地址、延迟、执行次数上限、「添加功能」列表(修改数据/读取数据研发中);功能行左滑删除 |
| `src/HookModEditVC.m` | ~320 | 「修改数据」编辑页:表达式弹窗、类型(字节/字符串/数值)、位宽、修改内容。`classifyTarget` 镜像引擎 `hook_classify_target`,「完成」做即时校验;选字符串弹一次超长警告 |
| `src/SettingsVC.m` | ~180 | 设置页(继承 FormEditVC):日志根目录 / 导入导出根目录 + 每项「恢复默认」;保存前 `directoryUsable` 校验 |
| `src/MoreMenu.{h,m}` | ~330 | 左上角「更多」菜单(两个列表页共用):帮助(含 Hook 章节)、设置、新增副本、页面切换。`QBDIListPage` 协议在这 |
| `src/AppPickerVC.m` | 141 | 应用选择器。`LSApplicationWorkspace`(私有 API)列所有 app 图标+名字+bundleId,带搜索 |
| `src/TraceEditVC.m` | ~400 | trace 表单。恢复 1–16 次；触发条件为不限数量的子表，含 repeat/once/custom 消耗策略和地址间距校验 |
| `src/TriggerEditVC.m` | ~350 | 单条触发条件编辑页；custom 下显示 1–16 的触发次数上限，并负责表达式、地址、匹配与期望值校验 |
| `src/MutationEditVC.m` | ~300 | Trace 内寄存器修改编辑页：地址、寄存器、32/64 位、值、once/always；不提供内存写入 |
| `src/WatchEditVC.m` | ~217 | watch 表单。寄存器/action 用 action sheet;寄存器那栏顶部的「✎ 输入取址表达式…」走 `ExprInput` 的弹窗;size 走 `HexValue` |
| `src/ImportVC.m` | ~150 | **从文件导入**页:底部 Trace|Hook 分页(UISegmentedControl 放导航工具栏)。列各自导出目录 + 旧 Documents 根的 .json;点选按 `HookStore detectType` 的真实类型导入,与当前页不符时自动分流并提示。`initialHookPage` 决定默认页 |
| `Resources/Info.plist` | - | **必须在 Resources/**,否则图标不出现。bundleId=`com.snk.qbditracer`。含 `UIFileSharingEnabled`+`LSSupportsOpeningDocumentsInPlace`(导出文件供 Finder 文件共享取出) |
| `entitlements.plist` | - | platform-application + no-container + get-task-allow(私有 API + 写 /var/mobile) |
| `Makefile` | 小 | app 子工程。CFLAGS 含 `-I$(THEOS_PROJECT_DIR)/GUI/src` |

### 根

| 文件 | 作用 |
|---|---|
| `Makefile` | aggregate:`SUBPROJECTS = Engine GUI`；`after-stage` 只清除打包暂存目录里的 `._*`，防止外置磁盘的 AppleDouble 文件干扰发布打包 |
| `control` | 包名 `com.snk.qbditracer` |
| `scripts/setup_and_build.sh` | macOS 统一入口：完整 Xcode / SDK 和网络检测、Homebrew 安装缺失工具、Theos 官方源码安装、依赖构建、双包打包。`--check` 只检测，`--setup-only` 只准备工具，`--release` 发布模式。默认 Theos 为 `~/theos`，不写 shell 配置、不部署手机 |
| `scripts/build_deps_ios.sh` | 在本地 `third_party/` clone 并编译 QBDI+Dobby(arm64),装进 `Engine/lib`、`Engine/include`。只检查前置工具不自动装。可被 Release 预编译 deps 替代 |
| `scripts/build_debs.sh` | 一键出 rootful(`iphoneos-arm`)+ rootless(`iphoneos-arm64`)两个 deb。两包共用 `YYMMDDHHMM` 版本/文件名；首次 make 前修复 control 的 CRLF / CR；切 scheme 前自动 `make clean`,`--release` 出去符号版。使用 `/tmp` 暂存并自动清理，支持工程位于 exFAT 外置盘 |

## 常见修改任务

导出配置文件名使用 `trace_` / `hook_` + 净化的 App 名称 + `yyyyMMddHHmmss.json`，
例如 `trace_TikTok20261013123045.json`。日志文件仍使用两位年份、分钟精度；
帮助中的日志路径取当前设置，说明同名日志追加写入及查看 / 修改 / 排错方式。

### 环境入口维护

新用户优先使用 `./scripts/setup_and_build.sh --release`。保持兼容 macOS 自带 Bash 3.2，
特别注意 `set -u` 下空数组展开；Theos 复用检查还要覆盖 Logos / substrate 子模块。
Xcode 需要完整安装和首次启动，CLT 不含本项目所需 iOS SDK。安装失败立即停止，
不覆盖已有非空但不完整的 Theos 目录，也不自动更新用户已有工具。
环境入口修改后运行 `python3 tests/setup_and_build_test.py`（隔离模拟，不安装真实工具），
并用 `./scripts/setup_and_build.sh --check` 检查实际环境。

### A. 给 trace 条目加一个新字段(如 "maxInst")

**必须改 5 处**,漏一处就 schema 不一致:
1. `Engine/src/config.h` —— `TraceSpec` 加字段
2. `Engine/src/engine.m` —— 解析 JSON 填该字段(`t->maxInst = parse_int(it[@"maxInst"], ...)`)
3. `GUI/src/ConfigStore.m` —— `newItem` 加默认值
4. `GUI/src/ConfigStore.m` —— `importItemFromData` 的 key 白名单(漏了 → 导出再导入会丢掉它)
5. `GUI/src/TraceEditVC.m` —— 加一行 UI 让用户填

然后消费它的地方(如 `qbdi_trace.c`)按需读 `spec->maxInst`。

### A2. 给 watch 加一个新字段

**注意 watch 的默认值不在 `ConfigStore.m`**(`newItem` 里 `watches` 只是个空数组),
所以清单和 trace 字段不一样,是 **5 处**:
1. `Engine/src/config.h` —— `TraceWatch` 加字段
2. `Engine/src/engine.m` —— `load_watches` 解析
3. `Engine/src/qbdi_trace.c` —— `watch_handle` 消费它
4. `GUI/src/TraceEditVC.m` —— **两处**:新建 watch 的模板字典(`didSelectRowAtIndexPath` 里硬编码)+ watch 列表行的显示文本
5. `GUI/src/WatchEditVC.m` —— 表单里加一行

`ConfigStore.m` 导入时对 watches 只做整体深拷、不逐字段补齐,所以导入缺字段的旧 json 是安全的。

### A3. 改 watch 取址表达式的语法

语法有**两份实现**,必须同步改:
- `Engine/src/watch_expr.c` —— 权威实现(编译 + 求值)
- `GUI/src/ExprInput.m` 的 `ExprScan` —— 只做语法校验(为了在弹窗里即时标红/禁用「确定」),不求值

两边漂移的后果是"App 说语法没问题、装上却不生效"。改完务必跑一遍交叉测试(见下面「本机自测」),
它会拿同一批输入比对两边的接受/拒绝结论。

### A4. 改触发条件的匹配语义

四处要同步:
1. `Engine/src/config.h` —— `TrigMatch` / `TrigWhere` 枚举、`TRIG_MAX_*` 上限
2. `Engine/src/engine.m` 的 `load_trigger` —— 解析 + 加载期校验
3. `Engine/src/qbdi_trace.c` 的 `trig_compare` —— **纯比较逻辑**(不碰内存,便于提取自测)
   和 `trigger_hit`(负责读内存)、`trigger_log_miss`(诊断输出)
4. `GUI/src/TriggerEditVC.m` —— 单条条件表单和校验；`TraceEditVC.m` 负责条件列表与地址间距

新格式使用 item 级 `triggers` 数组和 `triggerConsume`；custom 策略读取每条条件的
`triggerLimit`（缺省 1）。旧版扁平 `trigger*` 字段仍会迁移/加载。
地址缺失/留空/等于 start 使用 start Hook；其余不同地址使用 `g_trigger_tramps`，相同地址共享 Hook。
命中后用按条件数量分配的线程局部状态授权同线程下一次 start，不要改成全局 bool。

改完跑 `./scripts/test_watch_expr.sh` 的第 4 组,它会验证解析结果和 `trig_compare` 的语义。

### A5. 改 Trace 内寄存器修改

配置位于 item 级 `mutations` 数组。修改时同步检查：

1. `Engine/src/config.h` 的 `TraceMutation`
2. `Engine/src/engine.m` 的 `load_mutations`（加载期严格校验）
3. `Engine/src/qbdi_trace.c` 的 `mutation_handle`（`QBDI_PREINST`，同地址按数组顺序）
4. `GUI/src/MutationEditVC.m` 和 `TraceEditVC.m`
5. `GUI/src/ConfigStore.m` 的加载、创建、导入深拷，以及 `RootListVC.m` 的复制

边界不可随意放宽：仅支持 `x0..x28`（排除 Dobby 使用的 `x17`）、`fp`、`lr`；
不支持 `sp/pc`，也不写真实内存。32 位写入按 AArch64 `wN` 语义清零高 32 位。
规则在目标指令执行前生效，所以覆盖 load 或 call 的结果必须选下一条指令。`once` 是
每次 Trace 首次命中，`always` 是每次命中。完整命中写文件，控制台只报每条规则首次，
避免热循环刷爆 Console。改完跑本机测试第 5 组。

### A6. 改 Hook(加字段 / 改写入语义)

Hook 与 Trace 完全独立,配置在 `hooks.json`。加 hook 条目字段或 mod 字段:
1. `Engine/src/config.h` —— `HookSpec` / `HookMod` 加字段
2. `Engine/src/engine.m` —— `load_hook` / `load_hook_mod` 解析(加载期严格校验,配错拒整条)
3. `Engine/src/hook.c` —— `hook_ctx_entry` 消费它(改寄存器/内存)
4. `GUI/src/HookStore.m` —— `newHook` / `newMod` 默认值 + `importHookFromData` 的 key 白名单(漏了导出再导入会丢)
5. `GUI/src/HookEditVC.m` / `HookModEditVC.m` —— 加 UI

**写入语义(不对称表)有两份实现,必须同步**(和 A3 同理):
- 引擎 `Engine/src/hook.c`:`hook_classify_target` / `outer_bracket` / `bare_register`(权威)
- GUI `GUI/src/HookModEditVC.m`:`classifyTarget` / `exprBracketed` / `exprBareRegister`(即时校验)

漂移后果是"App 说没问题、装上却被引擎拒(整条 Hook 不装)"。改完跑 `./scripts/test_watch_expr.sh` 第 6 组,它从两边**原样提取**函数交叉验证语义、值编码(字节内存序/字符串补 0/数值小端)与 256 字节边界。

边界不可随意放宽:数值 8/16 位只对**内存**开放,改**寄存器**只能 32/64;字节写内存必须用 `[]`,裸寄存器拒;字节容忍前导 `0x`(hex 辅助键盘有「0X」键,GUI/引擎两边都要剥,否则 App 放行、引擎拒)。连续 20 次求址失败自愈停用(`HOOK_FAIL_LIMIT`)。

### B. 改注入范围

改 `Engine/TracerEngine.plist` 的 Bundles。比如只注入特定 app 可写死 bundleId 列表;但当前"全量注入+配置匹配"更灵活(见 DESIGN.md §3)。

### C. 改 trace 记录内容 / watch 行为

改 `Engine/src/qbdi_trace.c` 的 `inst_cb`(逐指令输出格式)或 `watch_handle`(监视点)。

### D. 提高 trace 条目上限(超过 32)

1. `qbdi_trace.h` 改 `TRACE_MAX_TARGETS`
2. `tramp.c` 补更多 `TRAMP(n)` 和 `g_tramps[]` 条目(汇编槽位是硬生成的,必须手动加到新上限)

### E. 改日志路径

日志根目录 `logRoot` 来自 `settings.json`,用户可在设置页改。引擎读完 settings 后调 `qbdi_trace_set_log_root`;之后 trace 日志走 `<logRoot>/trace-logs/trace_<时间戳>.log`、hook 日志走 `<logRoot>/hook-logs/hook_<时间戳>.log`(`qbdi_trace.c` 的 `TRACE_LOG_SUBDIR`、`hook.c` 的 `HOOK_LOG_SUBDIR`)。文件名时间戳 `%y%m%d%H%M`(年份两位)由 `qbdi_log_timestamp` **全进程生成一次**、trace/hook 共享 —— 同一次运行两份日志后缀必须一致,别把它改成各自取时间。子目录名要和 `GUI/src/AppSettings.h` 的 `QBDI_*_LOG_SUBDIR` 保持一致。`qbdi_log_build_path` 负责拼路径 + `mkdir -p`。

运行状态与错误还会通过 `qbdi_console_logf` 写入 iPhone 系统控制台，统一前缀
`[ios-qbdi-tracer]`。`qbdi_trace_logf`(trace)/`qbdi_hook_logf`(hook)会同时写各自文件和控制台；逐指令/逐次命中内容直接写 `FILE *` 而不进控制台，避免刷屏。

## 别踩的坑(血泪)

1. **schema 三处同步**:引擎解析(engine.m)、App 写入(ConfigStore.m newItem)、App 表单(TraceEditVC.m)。字段名对不上 → 配了没效果,还不报错。
   - watch 字段是**另一套**清单(默认值在 `TraceEditVC.m` 不在 `ConfigStore.m`),见上面 §A2。
2. **子工程 include 路径**:`$(THEOS_PROJECT_DIR)` 在 aggregate 里指**根目录**,不是子目录。必须写全 `Engine/src`、`GUI/src`。
3. **Info.plist 位置**:App 的必须在 `GUI/Resources/Info.plist`。放错地方能编译成功但装上没图标。
4. **trampoline 必须保存完整 CPU 状态,不只是通用寄存器**。`DobbyHook` 是纯跳转,不替你存任何东西;hook 点又在函数中间,没有 ABI 保护。除通用寄存器/sp 外还必须存:
   - **NZCV** —— 漏了会让原代码的 `b.eq`/`cbz` 基于 C 代码留下的标志位跳转。**曾经踩过**:hook 点在循环里、退出判断被带偏 → 同一个函数被反复执行上百万次,现象酷似死锁(x21 和数据一直不变),实际是控制流出不来。C 代码越长(比如加了触发条件的表达式求值 + `memcmp`)越必然触发。
   - **q0-q31** —— `memcpy`/`memcmp`/字符串搜索都用 NEON;ABI 只保护 v8-v15 的低 64 位,而原代码可能正拿着任意 v 寄存器。
   - **FPCR/FPSR** —— 顺手存。

   `msr nzcv` 要排在恢复通用寄存器**之前**(借 x9,之后 x9 会被还原)。栈帧 `0x320`,`TraceRegFile` 仍在 `sp+0` 的前 `0x100` 字节 —— **这个结构别动**,`trace_ctx_entry` 按它取寄存器。

   **x17 是唯一例外**:Dobby 的 `ARM64_TMP_REG_NDX_0` 在 arm64 上是 17，入口跳板已经把它定义为临时寄存器。`trace_ctx_entry` 返回的 origin 必须一直放在 x17，恢复时只从 `sp+0x80` 取回 x16，最后 `br x17`。绝不能把 origin 放进 x16 后再执行 `ldp x16, x17` —— 那会覆盖续跑地址，并可能无限重复同一 hook 现场。`tramp.c` 已用预处理检查锁定这项 Dobby 契约。
   因为 x17 在到达本项目 trampoline 前就可能被 Dobby 改写，配置触发条件或 watch 时也不要把 x17 当作可靠的原程序寄存器值。

   **改完必须反汇编核对**,32 个槽位逐个确认:
   ```sh
   BIN=$(ls -t .theos/obj/*/TracerEngine.dylib | head -1)
   otool -tV "$BIN" | grep -A1 "sub.*sp, sp, #0x320" | grep -c "stp	x0, x1"  # 应为 32
   otool -tV "$BIN" | grep -c "msr.*NZCV"                                     # 应为 32
   otool -tV "$BIN" | grep -B1 "bl.*_trace_ctx_entry" | grep "mov.*x1, #"     # slot 应是 0x0..0x1f
   otool -tV "$BIN" | grep -c "mov.*x17, x0"                                  # 应为 32
   otool -tV "$BIN" | grep -c "ldr.*x16, \[sp, #0x80\]"                       # 应为 32
   otool -tV "$BIN" | grep -c "br.*x17"                                       # 至少 32；逐个槽位确认
   ```
5. **`trace_ctx_entry` 是每次 hook 命中都跑的热路径,别往里塞"看起来无害"的活**。踩过的坑:它原来每次命中都调 `find_module()` —— 而那个函数会遍历进程里**所有 dyld 镜像**、对每个路径做 `strstr`,还会获取 **dyld 内部锁**。一个大 app 有几百个镜像,hook 点每秒命中几十万次的话就是每秒上亿次字符串搜索 + 疯狂抢 dyld 锁,足以把**整个进程**拖到不可用(表现为"某个线程卡死在一处、数据反复相同",因为负责干活的线程被拖死了,新数据进不来)。
   - 模块基址装 hook 时就算好存进 `g_module_base[slot]`(进程生命周期内不变),命中时直接读数组。
   - 同理:别在这里做内存分配、ObjC 消息、加锁、syscall。目前每次命中只有 **1 次 `vm_read_overwrite`**(条件求值读内存),这已经是上限。
   - `trace_ctx_entry` **任何正常分支都不能返回 0**。拿不到 origin 时退回 `base + start + QBDI_PATCH_SIZE`；汇编层另以现场 LR 兜底，避免异常分支直接 `br 0`，但不能把 LR 兜底当成正常续跑方案。
6. **QBDI 用虚拟栈**:`trace_ctx_entry` 里 QBDI 跑虚拟栈只记录、原生再跑一遍。别改回"真实栈"(会让 QBDI 引擎 abort)。
7. **地址是偏移不是 VA**:配置里的 start/end/offset 都是相对模块基址,别加 slide。
8. **改了 UI 但设备上没变化 → 十有八九是没装上新包**,不是代码问题。`build_debs.sh` 会用构建时间更新包版本和文件名；手动 `make package` 仍要自行升 Version。验证套路见下面「验证改动是否真的生效」。
9. **watch 的 `expr` 优先于 `reg`,两者不能都留着**:引擎的规则是"`expr` 编译成功就用 `expr`,否则回落 `reg`"。所以 App 里选寄存器时**必须** `removeObjectForKey:@"expr"`,否则用户先配了表达式、后来改回选寄存器,会表现成"选了却没生效"。反过来,写 `expr` 时会把表达式里的基寄存器同步进 `reg` —— 这是给**旧版引擎**留的退路(它不认识 `expr`,而 `reg` 缺失会让整条 watch 被静默丢弃)。
10. **`size` 字段带不带 `0x` 语义不同**:`"0x110"` = 272,`"110"` = 110(十进制),NSNumber `272` = 272。旧配置是裸十进制,新 App 写出来一律带 `0x`,靠前缀区分、不用迁移。但**输入框里**一律按十六进制理解(敲 `10` 存成 `"0x10"` = 16)—— 因为框里显示的永远是带 `0x` 的规范形式,用户不会在 UI 里看到裸十进制。引擎侧千万别用 `parse_int`(它是 `strtol(s, NULL, 0)`,`"010"` 会被当八进制),用专门的 `parse_size`。
11. **trace 区间必须 ≥ 0x10 字节**:`end - start < 0x10` 时 end 落在 Dobby 补丁区内,QBDI 永远跑不到它 → 一路执行到 SIGSEGV(原因见 DESIGN.md §4.3.1)。三处都挡了:`engine.m` 加载、`qbdi_trace.c` 的 `trace()`、GUI 的「完成」。**改这个下限要同时改 4 个地方**:`qbdi_trace.h` 的 `QBDI_PATCH_SIZE`、上面两处校验、`TraceEditVC.m` 的 `TRACE_MIN_RANGE`。
12. **编辑页的快照必须在字段规范化之后拍**:`size` 会被规范成 `"0x..."`、`count`/`delaySecs` 会从字符串变 NSNumber、`logMask` 会被写成 17 —— 这些都不是用户的编辑动作。顺序反了的话,进表单什么都不动、一返回就误弹「放弃修改」。两个 VC 都在 `viewDidLoad` 里先规范化再 `beginEditingTarget:`。
13. **右滑返回绕过 `navShouldPop`**:它由 `interactivePopGestureRecognizer` 驱动,不经过 `navigationBar:shouldPopItem:`；字段未失焦时脏检查也看不到新值。所以 `FormEditVC` 在编辑页显示期间始终关闭手势，并且**必须在 `viewWillDisappear` 恢复**(不恢复会把禁用状态带给后面的页面)。
14. **触发条件配错会拒掉整条 trace**,不是退化成"无条件"。这是故意的:过滤静默失效会给一堆本该被滤掉的日志,而你以为条件在生效。日志里会写 `skip item (slot N): bad trigger: ...`。
15. **`bytes` 和 `u64` 的字节序是反的**:`bytes` 按内存顺序(和 hexdump 看到的一致),`u64` 是小端整数。同一块内存 `08 a4 8c 90 81 04 10 02`,前者写 `08a48c9081041002`,后者写 `0x02100481908ca408`。界面 footer 里有提示,改那段文案时别改错。
16. **触发条件的「字符串」不是 watch 的 `cstr`**:watch 的 `cstr` 是"读到 `\0` 然后打印出来";触发条件的「字符串」是拿期望值去比较。而且**用「字符串」填十六进制是常见误用** —— 填 `08a48c90` 会拿 ASCII 文本 `"08a48c90"`(`30 38 61 34…`)去比二进制 `08 a4 8c 90`,永远不匹配。二进制数据要用「字节」。
17. **`vm_read_overwrite` 跨到未映射页会整块失败**(返回 0,不是"读到一部分")。所以 `trigger_read()` 在整块失败时退到"只读本页末尾"。任何"读一个窗口"的新代码都要照这个处理,否则窗口一调大就什么都读不到。
18. **在每次 hook 命中都跑的代码里,成本是 mach trap 次数,不是字节数**。`trigger_hit` 一次读满窗口(而不是像 `watch_read_string` 那样每 64 字节一趟),所以 `contains` 和 `prefix` 速度基本一样。新增这类逻辑时别退化成分块读。
19. **同一个 hook 点会被多个线程同时命中**,所以 `g_remaining`、每条条件的 `consume_state`、`filtered`、`next_log` 都必须原子访问。`consume_state` 低 16 位是成功次数、高 16 位是进行中预占；once/custom 先预占，成功转成计数，失败释放。日志整段仍需一次加锁。
20. **不要再恢复固定 1000 万条静默截断**:`qbdi_run` 的返回值只表示至少执行了一个 block，`ok=1` 不代表已到 end。旧逻辑在 `inst=10000001 ok=1` 时已经是被上限强制停止。现在 `maxInstructions` 缺省/0 不再按指令数截断，非 0 才启用保护；不限制时每 1000 万条向系统控制台报告当前 PC/end，但继续跑。退出日志必须保留 `reason=end|instruction-limit|qbdi-failed|unexpected-stop` 和最终 PC，只有 `state->pc == end` 才可标记 `reason=end`。被上限截断时还要打印 next PC 并写入系统控制台。
21. **`ConfigStore.m` 的导入白名单**:`importItemFromData` 里那个 key 数组是写死的,**加了 item 级字段就得加进去**,否则"导出→导入"会把新字段静默丢掉。
22. **别用 UTF-8 在二进制里搜中文字符串来验证**:含非 ASCII 的 `@"中文"` NSString 字面量,clang 会编成 **UTF-16** 存进 `__ustring` 段(不是 UTF-8 的 `__cstring`)。用 UTF-8 搜会全部 "missing" —— 这是**误报**,不代表字符串没编进去。要搜就搜 UTF-16LE(`kw.encode('utf-16-le')`)。ASCII 字符串才在 `__cstring` 里。
23. **启停只能在写入 JSON 成功后更新界面**:保存失败时要恢复内存中的 `enabled`，否则会出现“界面已停用，目标 App 重启后仍启用”。UI 和引擎对旧 JSON 缺失 `enabled` 的默认值都必须是 `true`，否则会显示为停用但引擎仍执行。引擎只在目标 App 启动时读一次配置，所以成功切换后仍必须重启目标 App。
24. **`traceName` 是可选展示字段**:旧 JSON 没有时必须保持原来的两行展示；导入白名单必须保留它，复制/导出也必须带上。空白名称要删除 key，不要显示空的第一行。
25. **每个不同的自定义触发地址会多一个 Dobby Hook**:同一 trace 内相同地址共享 Hook；不同地址彼此及与 start 至少相差 `0x10`，且不能在 `(start,end)` 内。数值在区间外不代表动态路径不会经过它；帮助里的 QBDI/Dobby 冲突提示不能删。
26. **总开关搬到了 settings.json,迁移必须两头做**:App(`AppSettings load`)在 settings.json 缺失时读旧 config.json 的 enabled 再写出;引擎(`engine_start`)在 settings.json 缺失时同样回落读旧值。少任何一头,老用户升级后关掉的插件会自己变开。引擎**先读 settings.json**,总开关关着立即返回,别把这个顺序改了(否则丢了"关掉就不读另外两份"的省事)。
27. **Hook 写入语义有两份实现**(引擎 `hook.c` 的 `hook_classify_target` 与 GUI `HookModEditVC.m` 的 `classifyTarget`),漂移后果同触发条件/watch:App 放行、引擎拒。见 §A6,改完跑第 6 组。
28. **Hook 是真的改数据,不是 QBDI 虚拟修改**:寄存器修改靠 hook trampoline 恢复时把改过的槽位写回真实寄存器而持久生效(别改成"跑完丢弃");内存写用 `vm_protect` 提权 —— 只读段也会被真的改。改错地址会让目标 App 崩,不像 trace 那样安全。
29. **Hook 日志时间戳与 trace 共享一次生成**(`qbdi_log_timestamp`,`%y%m%d%H%M` 两位年份)。别让 hook 各自取时间,否则同一次运行的两份日志对不上号。
30. **字节值容忍前导 `0x`**:hex 辅助键盘有「0X」键,GUI(`bytesValid`)和引擎(`hook_encode_value` 的 BYTES 分支)都要剥掉它,否则用户敲了 0X → App 放行、引擎拒。

## 本机自测(不用设备、不用 theos)

```sh
./scripts/test_watch_expr.sh
```

跑**六组**:①引擎表达式 parser 本身(编译/求值/多级解引用/失败诊断)、②GUI 校验与引擎 parser
的判断是否一致、③size 进制规则两侧是否一致、④触发条件期望值(bytes/cstr/u64)的解析与拒绝、
⑤Trace 内寄存器修改配置解析、⑥**Hook 修改数据的不对称写入语义表 + 值编码 + 256 边界**。
带 ASan/UBSan。

第 2..6 组不复制被测代码,而是用 awk 从 `GUI/src/ExprInput.m`、`GUI/src/HexValue.m`、
`Engine/src/engine.m`、`Engine/src/qbdi_trace.c`、`Engine/src/hook.c` 里**原样提取**函数段落再编译。好处是测试永远跟着真实源码走;代价是
**改动那几处的段落标记(`#pragma mark`、`static uint64_t parse_size`、`static bool
load_trigger`、`static bool trig_compare`、`static int hex_digit`、`bool hook_classify_target`、
`static bool load_hook_mod` 这些)会让提取失败** —— 脚本会直接报"提取失败",按提示把 awk 的匹配模式
跟着改一下就行。

改了 `watch_expr.c`、`ExprInput.m` 的 `ExprScan`、`engine.m` 的 `load_trigger`/`parse_size`/`load_hook_mod`、
`qbdi_trace.c` 的 `trig_compare`、或 `hook.c` 的 `hook_encode_value`/`hook_classify_target`,务必跑一遍。

提取用的是 awk 的 `index($0, sig) == 1` 字面量前缀匹配,**不是正则** —— 因为函数签名里的
`*`(如 `static const char *dup_str`)当正则会被当成量词,而 awk 的 `-v` 还会吃掉转义反斜杠。

## 验证改动是否真的生效(排查"改了没变")

遇到"我改了代码/重编了,设备上却没变"时,按这个顺序查,别怀疑代码先:

```sh
# 1. 确认源码是对的
grep -n '你改的字符串' GUI/src/RootListVC.m

# 2. 确认最新 deb 里真的含新内容(注意中文用 UTF-16LE 搜!)
DEB=$(ls -t packages/*.deb | head -1); echo "$DEB"
TMP=$(mktemp -d); cp "$DEB" "$TMP/p.deb"; (cd "$TMP" && ar x p.deb && mkdir ex && tar xf data.tar.* -C ex)
BIN=$(find "$TMP/ex" -name TracerGUI -type f)
python3 - "$BIN" <<'PY'
import sys; d=open(sys.argv[1],'rb').read()
for kw in ['关闭','你改的中文串']:
    print(kw, 'utf16le=', kw.encode('utf-16-le') in d)  # 中文查 UTF-16
for kw in ['ascii_string']:
    print(kw, 'utf8=', kw.encode() in d)                # ASCII 查 UTF-8
PY

# 3. deb 里对了 → 问题在安装。设备上先卸载再装:
#    dpkg -r com.snk.qbditracer && dpkg -i /tmp/新包.deb && uicache -a
```

## 已知限制

- trace 条目 ≤ 32,watch ≤ 128,hook 条目 ≤ 32、单条 hook ≤ 16 条修改、单条修改载荷 ≤ 256 字节(均硬上限)
- 被 trace 区域会执行两遍(记录 + 原生),有副作用的函数需留意
- Hook 是真实改数据:改错地址会让目标 App 崩,内存写会 `vm_protect` 提权改到只读段,请先用 trace/watch 确认地址
- QBDI 不处理 syscall/信号/C++ 异常;目标含 `svc`/大量 `objc_msgSend` 可能崩
- 只 arm64(没做 arm64e);arm64e 设备需 arm64e 切片的 QBDI/Dobby
- 改配置不实时生效,需重开目标 app
- 控制 App 用私有 API(LSApplicationWorkspace、app 图标),仅越狱环境可用

## 未验证项(重要)

**整个工程编译通过、deb 结构正确,但尚未真机验证运行。** 首次上真机需确认:
1. 主屏图标出现、App 能打开
2. AppPicker 能列出已装 app(私有 API 在你的越狱类型/iOS 版本上可用)
3. 能加 trace、JSON 正确落盘(`cat /var/mobile/Documents/QBDITracer/config.json` 核对)
4. entitlements 是否够(写 /var/mobile、私有 API)—— 若 App 闪退,先查 `GUI/entitlements.plist`
5. 配一条 settings trace → 重开 settings → `/tmp/qbdi_trace_<年月日时分>.log` 出现 trace(引擎联动)
6. 空配置/关总开关时,其它 app 启动无异常、不崩(全量注入的空转路径)
7. **导出**:trace 条目左滑「导出」→ 成功弹框的路径,能否用 Finder 文件共享真的取到该文件(系统级 app 的 Documents 是否进文件共享列表 = 本功能成败关键)
8. **导入**:把导出的 .json 放回 exportDir →「从文件导入」能列出并成功导入;「粘贴 JSON」能导入;格式错弹"配置格式无效"

### watch 取址表达式 / size 十六进制(本次新增,同样只过了本机自测)

表达式的编译与求值逻辑已在 mac 上验证(`./scripts/test_watch_expr.sh`,含 ASan/UBSan),
GUI 校验与引擎 parser 的判断、size 两侧的进制解析都交叉比对过。**但界面交互和真机取值没验证**:

9. 表达式弹窗:键盘上方那条快捷栏在真机上能正常出现(`UIAlertController` 的 textField 挂
   `inputAccessoryView`),小屏/横屏下 alert 不被键盘顶掉;`[ ]` 按钮插入后光标停在中间
10. 语法错误时输入框变红、「确定」变灰;改对后恢复可点
11. 选寄存器 → 再打开弹窗,里面显示的是刚选的寄存器(说明 `expr` 被清掉了)
12. 真机取值:配 `[x0+0x10]` + `cstr` 能读出结构体里的字符串字段;配 `x0-0x110` + `hexdump`
    + 长度 `110`,日志里 hexdump 的**绝对地址列**与预期一致
13. 故意配一个读不出来的多级表达式(如 `[[x0+0x1000]]`),日志出现 `<unreadable>` 且把
    每一级 `deref#N` 都列了出来
14. 故意在 json 里写个语法错的 `expr`,app 启动后日志出现 `[watch] bad expr ...`,且该条
    watch 回落到 `reg` 而不是整条消失
15. size:旧配置(裸十进制 `272`)打开表单显示 `0x110`,保存后 json 里变成 `"0x110"`,
    **实际截断长度没变**(仍是 272 字节)

### 区间校验 / 选项隐藏 / 返回确认

16. 配一条 `end - start < 0x10` 的规则 →「完成」被挡下并提示;手工写进 json 的话,
    目标 app 启动后日志出现 `[engine] skip item ... range too short`,且**不会**再跑飞到 SIGSEGV
17. logMask 那一段在界面上没了;打开一条旧规则(json 里 `logMask: 1`)点「完成」,
    json 里变成 `17`,重开目标 app 后日志里出现 `V{...}` 向量寄存器行
    - trace 次数也不再显示；新规则仍默认 `count=1`，旧 JSON 的值继续兼容
18. **返回拦截**(三个入口都要试):
    - 编辑 Trace 改一个字段 → 点左上角 `< QBDI Tracer` → 弹「放弃修改?」;选「放弃」字段回到原值,选「继续编辑」留在原页
    - 编辑监视改一个字段 → 点左上角 `< 编辑 Trace` → 同上
    - 不论是否已有改动，两个编辑页右滑返回都应**无反应**
19. `shouldPopItem:` 返回 NO 之后,左上角返回按钮**没有卡在半透明状态**(NavController 里手动淡回来了)
20. 在监视页点「确定」→ 回到 Trace 页 → 点「放弃」→ watch 的改动**仍然保留**(这是刻意的)
21. 新建 trace 填了一半点返回 → 弹确认 → 放弃后回到 AppPicker,列表里没有多出条目

### 触发条件(本次新增)

22. 「触发条件」列表为空时行为与以前的无条件 Trace 完全一致；可以连续添加多条且没有数量限制
23. 配 `triggerExpr` + 匹配方式「非空」→ 那些 `[x2+0x10]=0x0 (null)` 的调用不产生逐指令/watch 内容；
    第 1/10/100/1000… 次只输出一条 `trigger miss` 诊断到文件和系统控制台
24. 配「字节」+ `08a48c90` → 只有内存以这 4 个字节开头的那次被 trace，日志带条件编号
25. **count 不被浪费**:`count=1` + 条件,连续调用几百次后仍能抓到第一次真正匹配的那次
26. 左滑逐条删除触发条件；删完最后一条后恢复为无条件 Trace
27. 期望值写坏(奇数个 hex、非 hex 字符、超 32 字节)→「完成」被挡下并提示;
    手工写进 json 的话,日志出现 `bad trigger:` 且该条 trace **不装 hook**
28. 「字节」和「u64」对同一块内存分别按内存顺序/小端写,都能命中同一次调用
29. **匹配位置**:同一块内存 `08 a4 8c 90 81 04`,「字节 + 开头 + `a48c90`」不命中、
    「字节 + 包含 + `a48c90`」命中
30. **字符串包含**:watch 里能看到完整字符串(如 `https://x.com/api/v2`),
    配「字符串 + 包含 + `api`」能命中;换成「开头」不命中
31. **诊断输出**:条件配错时日志出现 `trigger miss #1: ... want/got`,
    且只在第 1/10/100/1000/… 次出现(不再是每 100 次一行计数)
32. 「最长读取」填得比期望值短 →「完成」被挡下;手工写进 json 则日志 `bad trigger:` 且不装 hook
33. 窗口设 `0x1000` 时仍能正常读到数据(验证跨页退避那段:`trigger_read` 整块失败后
    退到本页末尾)
34. 两条条件任意一条命中都可 Trace；相同地址只安装一个 Hook，不同地址相差不足 `0x10` 时保存被挡下
35. `once` 下成功到 end 后只消耗本次贡献的条件；QBDI 失败/提前停止时条件和 Trace 次数都会恢复
36. `custom` 下分别设置 1、2 次的两条条件，各自只能成功对应次数；并发命中不能突破单条上限
37. `repeat` 下同一条件可以反复触发，直到完成 1–16 次；第 2 条以后默认继承第 1 条地址和表达式，但次数上限固定默认 1

### trampoline 完整状态保存(本次新增,**最高优先级**)

38. **条件一直不匹配时,程序仍能正常往下跑** —— 表达式算出的地址/内容每次调用都在变,
    不再出现"同一个值重复几十万次"。这是 NZCV 修复是否生效的判据。
39. 目标 app 在挂着条件(且长时间不匹配)的情况下,界面不卡、功能正常
40. 条件命中后 trace 正常输出,且 trace 结束后 app 继续正常运行(不崩、不卡)
41. 多线程同时命中时:`count=1` 只产生**一份** trace 日志;`trigger miss #N` 的编号不重复
42. **热路径开销**:条件长期不匹配时,目标 app 仍然流畅(`find_module` 已从每次命中的路径上
    移除)。判据是 `trigger miss` 的 `at : lr=... sp=...` 两次之间**有变化** —— 如果 lr/sp
    完全不动,说明还是卡在同一次调用的同一个循环里,得继续查
43. hook 点选得太热时(每秒命中几十万次)即便只剩 1 次 `vm_read_overwrite` 也会拖慢;
    这种情况应该换一个"每次请求只过一遍"的位置,而不是靠优化引擎
44. **续跑寄存器回归测试**:同一 hook 点让 `x21` 先后指向 `this is a string` 和
    `this is a key`，触发条件设 `x21` + 字符串包含 `key`；第一次应 miss、第二次应命中，
    诊断里的地址/内容必须随调用变化。若始终停在第一次，立即反汇编确认结尾是
    `mov x17, x0` → 恢复 x16 → `br x17`，且中间没有恢复覆盖 x17。
45. **启停两种入口**:右滑到底自动执行、只露出按钮再点击，两者都应更新勾选并提示“重启目标 App 后生效”；重启后核对 JSON 与引擎行为一致。
46. **自定义触发地址**:留空/等于 start 保持原行为；低于 start 且间隔≥0x10 可命中；等于/高于 end 命中后，同一线程下一次跳回 start 才 Trace。
47. 判断地址在 `(start,end)` 内或低地址距 start <0x10 → GUI/引擎都拒绝；与另一条目 Hook 补丁重叠 → 引擎加载时拒绝。系统控制台应有 `[ios-qbdi-tracer]` 诊断。
48. 用两个线程验证自定义触发:线程 A 命中 trigger 后，线程 B 先到 start 不能 Trace；只有 A 到 start 才能消费授权。
49. 起始/结束/判断/监视地址输入框都有 `0X 0-9 A-F` 快捷键；非法字符即时标红，「完成」时再做权威校验。
50. **启停保存失败**:在测试环境临时使配置目录不可写，操作后必须提示失败并恢复原勾选，不得出现假启用/假停用。
51. **自定义名称**:左滑「命名」后显示三行；再次命名为空后恢复旧两行。名称同时出现在 hook 安装日志中。
52. **名称兼容性**:旧 JSON 打开无空白行；命名后复制、导出再导入，`traceName` 都不丢失。

### Hook 修改数据 / 三份配置拆分 / 主页重构(本次新增,只过了本机自测第 6 组)

引擎 hook 写入通路 + 32 个 hook 跳板已过反汇编核对(`hook_ctx_entry` 32、`msr NZCV`/`mov x17,x0`
各 192 = 32 trace+128 trigger+32 hook);不对称写入语义、值编码、256 边界过第 6 组。**但真机改数据没验证**:

53. **三份配置**:全新安装后,设置里改路径 → `settings.json` 落 `logRoot`/`exportRoot`/`enabled`;
    加 trace 落 `config.json`(不再含 enabled);加 hook 落 `hooks.json`。三份都 `cat` 核对。
54. **总开关迁移**:用旧版 `config.json`(含 `enabled:false`)升级、还没打开控制 App 就重开目标 app →
    引擎应回落读到 false 不干活;打开控制 App 后 `settings.json` 出现且 `enabled:false`,主页开关是关的。
55. **数值改寄存器**:hook 一个点、`x8` + 数值 + 64 位,重开目标 app → 该点之后 x8 变成配置值且**持久**
    (不是只在 hook 那一刻)。32 位模式高 32 位清零。
56. **字节/字符串改内存**:`[x0]` + 字节写一段、`x0`(char\*)+ 字符串写一段 → 目标内存真的变了;
    字符串底层带 `00` 结尾。日志 `hook-logs/hook_*.log` 有 old/new 对照。
57. **只读段提权**:往一个只读数据段地址写 → 成功(vm_protect 生效);故意写未映射地址 → 安全跳过、
    不崩,日志 `写入失败(不可写/跨区/未映射)`。
58. **自愈**:配一个永远读不出的多级表达式 `[[x0+0x99999999]]` → 连续 20 次后日志出现"已自动停用",
    之后不再尝试;目标 app 继续正常跑。
59. **执行次数上限**:maxHits=1 → 只有第一次命中改,之后透传。
60. **不对称语义拒绝**:字节 + 裸寄存器 `x0`、数值改寄存器选 8/16 位 → GUI「完成」当场拦;
    手工写进 hooks.json 则引擎加载期拒该条并写日志,不装 hook。
61. **共享时间戳**:同一次运行既有 trace 又有 hook → 两个日志文件名的 `<年月日时分>` 完全一致。
62. **导入分流**:导入页切到 Hook 分页却选了一份 trace 导出文件 → 自动作为 Tracer 导入并提示;反之亦然。
63. **主页/汉堡菜单**:底部 TabBar 切 Trace/Hook;左上角「更多」有帮助(含 Hook 章节)、设置、
    新增副本(创建/导入 Tracer/Hook)、页面切换;右上角 + 跟随当前页。
64. **弹窗改造**:启停/保存/导入等原来 1.2 秒自动消失的提示,现在都要手动点「好」才关。
65. **Hook 编辑页返回拦截**:改一半点返回或右滑 → 与 trace 编辑页一致(弹「放弃修改?」/右滑无反应)。
