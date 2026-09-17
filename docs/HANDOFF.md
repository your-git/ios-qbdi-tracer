# 交接与维护文档

> 面向后续会话/维护者。读完 [DESIGN.md](DESIGN.md) 再读这篇。这里讲**每个文件干什么**、**常见修改怎么做**、**别踩什么坑**。

## 文件地图

### Engine/(引擎 tweak,注入到目标 app)

| 文件 | 行数 | 作用 | 改动频率 |
|---|---|---|---|
| `Tweak.x` | 小 | 入口。`__attribute__((constructor))` → `engine_start()`。**不用 Logos %ctor**(Apple clang 21+ 编不过其 `__unused` 参数) | 几乎不改 |
| `src/engine.m` | 236 | **核心新代码**。读 JSON、匹配 bundleId、填 `g_traces`/`g_watches`、每条目 dispatch_after 延迟装 Dobby hook。也定义了 `g_traces/g_watches/g_trace_count/g_watch_count` 和 `find_module` | 加字段/改匹配逻辑时 |
| `src/tramp.c` | ~150 | 固定 32 个 naked arm64 trampoline + `g_tramps[]` 指针表。保存/恢复 **x0-x30 + 真实sp + NZCV + FPCR/FPSR + q0-q31**(栈帧 `0x320`)。少存任何一样都会破坏原代码状态 —— NZCV 尤其致命 | **改完必须反汇编核对** |
| `src/qbdi_trace.c` | 680 | QBDI 引擎:VM 记录、`trace_ctx_entry`(记录后原生续跑)、`watch_handle`、崩溃捕获 | 改 trace/watch 行为时 |
| `src/qbdi_trace.h` | 55 | LOG_* 位、`TRACE_MAX_TARGETS=32`/`TRACE_MAX_WATCHES=128`、`TraceRegFile`、函数声明 | 改上限时 |
| `src/watch_expr.{h,c}` | ~420 | **watch 取址表达式**(`x0-0x110`、`[[x0+8]+0x10]-4`)的编译与求值。递归下降 parser → 后缀式,加载期编译、命中时求值。纯 C,不依赖 QBDI(便于在 mac 上直接编译自测) | 改表达式语法时 |
| `src/config.h` | 40 | `TraceSpec`/`TraceWatch` 结构定义 + 表的 extern 声明 | 加字段时 |
| `src/engine.h` | 10 | `g_tramps[]` 和 `engine_start()` 声明 | 几乎不改 |
| `TracerEngine.plist` | 1 | 注入过滤:`{ Filter = { Bundles = ( "com.apple.UIKit" ); }; }` | 改注入范围时 |
| `Makefile` | 小 | tweak 子工程。include 路径用 `$(THEOS_PROJECT_DIR)/Engine/...` | 加源文件时 |

### GUI/(控制 App,主屏图标)

| 文件 | 行数 | 作用 |
|---|---|---|
| `entry.m` | 10 | `UIApplicationMain` |
| `src/AppDelegate.m` | 17 | 建 window + 导航栈,root = RootListVC |
| `src/ConfigStore.{h,m}` | ~290 | **JSON 读写**。`load`/`save`/`newItem` + **导出/导入**(`exportItem`/`listImportableFiles`/`importItemFromData`/`importItemFromString`/`exportDir`)。路径探测(rootless /var/jb)。**与引擎 schema 必须一致** |
| `src/ExprInput.{h,m}` | ~250 | **取址表达式的输入与校验**,两个编辑页共用:`ExprSyntaxOK`/`ExprBaseReg`(轻量语法校验,**要与 `watch_expr.c` 的文法一致**)+ `ExprPrompt`(带寄存器/`[]`/`0x` 快捷栏、即时标红的输入弹窗) |
| `src/HexValue.{h,m}` | ~50 | 「字节长度」类字段(watch 的 `size`、触发条件的 `triggerScan`)的进制处理:`HexValueFromJSON`(JSON 看前缀定进制)/ `HexParseInput`(输入框一律 hex)/ `HexDisplay`。**与引擎 `parse_size` 规则必须一致** |
| `src/NavController.{h,m}` | ~50 | `UINavigationController` 子类,override `navigationBar:shouldPopItem:` 来**拦住系统返回按钮**(UIKit 没有公开的"即将 pop"回调;这依赖 UINavigationController 私下就是自己 navigationBar 的 delegate)。含 `NavPopGuard` 协议 |
| `src/FormEditVC.{h,m}` | ~120 | 表单编辑页**基类**:快照 / 脏检查 / 「放弃修改?」确认；编辑页显示期间一律禁用右滑返回。TraceEditVC 和 WatchEditVC 都继承它 |
| `src/RootListVC.m` | 221 | 主界面。总开关 + 条目列表。点击=编辑,前缘滑=启停,尾缘滑=复制/删除(删除弹确认框),+ 按钮=加trace(先进 AppPicker) |
| `src/AppPickerVC.m` | 141 | 应用选择器。`LSApplicationWorkspace`(私有 API)列所有 app 图标+名字+bundleId,带搜索 |
| `src/TraceEditVC.m` | ~680 | trace 表单。**5 段**:App信息/模块地址/选项/触发条件/watches子表(trace 次数和原来的 logMask 均已隐藏)。触发条件那段按匹配方式伸缩，并在启用时显示「改为无条件」按钮。「完成」里带 end-start ≥ 0x10、表达式语法、期望值格式、搜索窗口的校验 |
| `src/WatchEditVC.m` | ~217 | watch 表单。寄存器/action 用 action sheet;寄存器那栏顶部的「✎ 输入取址表达式…」走 `ExprInput` 的弹窗;size 走 `HexValue` |
| `src/ImportVC.m` | ~110 | **从文件导入**列表页。列 exportDir 里的 .json,点选 → 校验 → 加入 items |
| `Resources/Info.plist` | - | **必须在 Resources/**,否则图标不出现。bundleId=`com.snk.qbditracer`。含 `UIFileSharingEnabled`+`LSSupportsOpeningDocumentsInPlace`(导出文件供 Finder 文件共享取出) |
| `entitlements.plist` | - | platform-application + no-container + get-task-allow(私有 API + 写 /var/mobile) |
| `Makefile` | 小 | app 子工程。CFLAGS 含 `-I$(THEOS_PROJECT_DIR)/GUI/src` |

### 根

| 文件 | 作用 |
|---|---|
| `Makefile` | aggregate:`SUBPROJECTS = Engine GUI` |
| `control` | 包名 `com.snk.qbditracer` |
| `scripts/build_deps_ios.sh` | 在本地 `third_party/` clone 并编译 QBDI+Dobby(arm64),装进 `Engine/lib`、`Engine/include`。只检查前置工具不自动装。可被 Release 预编译 deps 替代 |
| `scripts/build_debs.sh` | 一键出 rootful(`iphoneos-arm`)+ rootless(`iphoneos-arm64`)两个 deb。两包共用 `YYMMDDHHMM` 版本/文件名；切 scheme 前自动 `make clean`,`--release` 出去符号版 |

## 常见修改任务

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
4. `GUI/src/TraceEditVC.m` —— `TrigMatchKind`/`TrigWhereKind` 枚举、`triggerRows` 行映射、
   footer 文案、「完成」校验

改完跑 `./scripts/test_watch_expr.sh` 的第 4 组,它会验证解析结果和 `trig_compare` 的语义。

### B. 改注入范围

改 `Engine/TracerEngine.plist` 的 Bundles。比如只注入特定 app 可写死 bundleId 列表;但当前"全量注入+配置匹配"更灵活(见 DESIGN.md §3)。

### C. 改 trace 记录内容 / watch 行为

改 `Engine/src/qbdi_trace.c` 的 `inst_cb`(逐指令输出格式)或 `watch_handle`(监视点)。

### D. 提高 trace 条目上限(超过 32)

1. `qbdi_trace.h` 改 `TRACE_MAX_TARGETS`
2. `tramp.c` 补更多 `TRAMP(n)` 和 `g_tramps[]` 条目(汇编槽位是硬生成的,必须手动加到新上限)

### E. 改日志路径

`qbdi_trace.c` 顶部的 `TRACE_LOG_DIR` / `TRACE_LOG_PREFIX`(当前 `/tmp/qbdi_trace_<年月日时分>.log`)。文件名在 `trace_log_open` 里按进程首次写日志的时间用 `strftime("%Y%m%d%H%M")` 生成一次。若想改成"固定文件名"或"每条 trace 一个文件",改这个函数。

运行状态与错误还会通过 `qbdi_console_logf` 写入 iPhone 系统控制台，统一前缀
`[ios-qbdi-tracer]`。`qbdi_trace_logf` 会同时写文件和控制台；逐指令内容直接写 `FILE *`
而不进控制台，避免刷屏。新增 hook 生命周期或失败分支时优先走这两个入口。

## 别踩的坑(血泪)

1. **schema 三处同步**:引擎解析(engine.m)、App 写入(ConfigStore.m newItem)、App 表单(TraceEditVC.m)。字段名对不上 → 配了没效果,还不报错。
   - watch 字段是**另一套**清单(默认值在 `TraceEditVC.m` 不在 `ConfigStore.m`),见上面 §A2。
2. **子工程 include 路径**:`$(THEOS_PROJECT_DIR)` 在 aggregate 里指**根目录**,不是子目录。必须写全 `Engine/src`、`GUI/src`。
3. **Info.plist 位置**:App 的必须在 `GUI/Resources/Info.plist`。放错地方能编译成功但装上没图标。
4. **trampoline 必须保存完整 CPU 状态,不只是通用寄存器**。`DobbyHook` 是纯跳转,不替你存任何东西;hook 点又在函数中间,没有 ABI 保护。除 x0-x30/sp 外还必须存:
   - **NZCV** —— 漏了会让原代码的 `b.eq`/`cbz` 基于 C 代码留下的标志位跳转。**曾经踩过**:hook 点在循环里、退出判断被带偏 → 同一个函数被反复执行上百万次,现象酷似死锁(x21 和数据一直不变),实际是控制流出不来。C 代码越长(比如加了触发条件的表达式求值 + `memcmp`)越必然触发。
   - **q0-q31** —— `memcpy`/`memcmp`/字符串搜索都用 NEON;ABI 只保护 v8-v15 的低 64 位,而原代码可能正拿着任意 v 寄存器。
   - **FPCR/FPSR** —— 顺手存。

   `msr nzcv` 要排在恢复通用寄存器**之前**(借 x9,之后 x9 会被还原)。栈帧 `0x320`,`TraceRegFile` 仍在 `sp+0` 的前 `0x100` 字节 —— **这个结构别动**,`trace_ctx_entry` 按它取寄存器。

   **改完必须反汇编核对**,32 个槽位逐个确认:
   ```sh
   BIN=$(ls -t .theos/obj/*/TracerEngine.dylib | head -1)
   otool -tV "$BIN" | grep -A1 "sub.*sp, sp, #0x320" | grep -c "stp	x0, x1"  # 应为 32
   otool -tV "$BIN" | grep -c "msr.*NZCV"                                     # 应为 32
   otool -tV "$BIN" | grep -B1 "bl.*_trace_ctx_entry" | grep "mov.*x1, #"     # slot 应是 0x0..0x1f
   ```
5. **`trace_ctx_entry` 是每次 hook 命中都跑的热路径,别往里塞"看起来无害"的活**。踩过的坑:它原来每次命中都调 `find_module()` —— 而那个函数会遍历进程里**所有 dyld 镜像**、对每个路径做 `strstr`,还会获取 **dyld 内部锁**。一个大 app 有几百个镜像,hook 点每秒命中几十万次的话就是每秒上亿次字符串搜索 + 疯狂抢 dyld 锁,足以把**整个进程**拖到不可用(表现为"某个线程卡死在一处、数据反复相同",因为负责干活的线程被拖死了,新数据进不来)。
   - 模块基址装 hook 时就算好存进 `g_module_base[slot]`(进程生命周期内不变),命中时直接读数组。
   - 同理:别在这里做内存分配、ObjC 消息、加锁、syscall。目前每次命中只有 **1 次 `vm_read_overwrite`**(条件求值读内存),这已经是上限。
   - `trace_ctx_entry` **任何分支都不能返回 0** —— trampoline 会 `br` 到这个返回值,0 就是跳 NULL 直接崩。拿不到 origin 时退回 `base + start + QBDI_PATCH_SIZE`。
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
19. **同一个 hook 点会被多个线程同时命中**,所以 `trace_ctx_entry` 里的共享状态都得是原子的:`g_remaining`(非原子的话两个线程能把 `count=1` 用成两次)、`g_filtered`、`g_trig_next_log`(用 CAS 决定"这次该谁打诊断")。日志也一样 —— `trigger_log_miss` 整段在一次加锁里写完,否则 `want:`/`got:` 几行会被别的线程插进来。
20. **`ConfigStore.m` 的导入白名单**:`importItemFromData` 里那个 key 数组是写死的,**加了 item 级字段就得加进去**,否则"导出→导入"会把新字段静默丢掉。
21. **别用 UTF-8 在二进制里搜中文字符串来验证**:含非 ASCII 的 `@"中文"` NSString 字面量,clang 会编成 **UTF-16** 存进 `__ustring` 段(不是 UTF-8 的 `__cstring`)。用 UTF-8 搜会全部 "missing" —— 这是**误报**,不代表字符串没编进去。要搜就搜 UTF-16LE(`kw.encode('utf-16-le')`)。ASCII 字符串才在 `__cstring` 里。

## 本机自测(不用设备、不用 theos)

```sh
./scripts/test_watch_expr.sh
```

跑四组:引擎表达式 parser 本身(编译/求值/多级解引用/失败诊断)、GUI 校验与引擎 parser
的判断是否一致、size 进制规则两侧是否一致、触发条件期望值(bytes/cstr/u64)的解析与拒绝。
带 ASan/UBSan。

第 2/3/4 组不复制被测代码,而是用 awk 从 `GUI/src/ExprInput.m`、`GUI/src/HexValue.m`、
`Engine/src/engine.m`、`Engine/src/qbdi_trace.c` 里**原样提取**函数段落再编译。好处是测试永远跟着真实源码走;代价是
**改动那几处的段落标记(`#pragma mark`、`static uint64_t parse_size`、`static bool
load_trigger`、`static bool trig_compare` 这些)会让提取失败** —— 脚本会直接报"提取失败",按提示把 awk 的匹配模式
跟着改一下就行。

改了 `watch_expr.c`、`ExprInput.m` 的 `ExprScan`、`engine.m` 的 `load_trigger`/`parse_size`、
或 `qbdi_trace.c` 的 `trig_compare`,务必跑一遍。

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

- trace 条目 ≤ 32,watch ≤ 128(硬上限)
- 被 trace 区域会执行两遍(记录 + 原生),有副作用的函数需留意
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

22. 「触发条件」段留空时只有一行、显示"无条件",行为与以前完全一致
23. 配 `triggerExpr` + 匹配方式「非空」→ 那些 `[x2+0x10]=0x0 (null)` 的调用不产生逐指令/watch 内容；
    第 1/10/100/1000… 次只输出一条 `trigger miss` 诊断到文件和系统控制台
24. 配「字节」+ `08a48c90` → 只有内存以这 4 个字节开头的那次被 trace,
    命中前一行 `trigger matched after N filtered calls`
25. **count 不被浪费**:`count=1` + 条件,连续调用几百次后仍能抓到第一次真正匹配的那次
26. 点触发条件段底部红色「改为无条件」→ 回到无条件；左滑「取址表达式」的旧入口也保留
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

### trampoline 完整状态保存(本次新增,**最高优先级**)

34. **条件一直不匹配时,程序仍能正常往下跑** —— 表达式算出的地址/内容每次调用都在变,
    不再出现"同一个值重复几十万次"。这是 NZCV 修复是否生效的判据。
35. 目标 app 在挂着条件(且长时间不匹配)的情况下,界面不卡、功能正常
36. 条件命中后 trace 正常输出,且 trace 结束后 app 继续正常运行(不崩、不卡)
37. 多线程同时命中时:`count=1` 只产生**一份** trace 日志;`trigger miss #N` 的编号不重复
38. **热路径开销**:条件长期不匹配时,目标 app 仍然流畅(`find_module` 已从每次命中的路径上
    移除)。判据是 `trigger miss` 的 `at : lr=... sp=...` 两次之间**有变化** —— 如果 lr/sp
    完全不动,说明还是卡在同一次调用的同一个循环里,得继续查
39. hook 点选得太热时(每秒命中几十万次)即便只剩 1 次 `vm_read_overwrite` 也会拖慢;
    这种情况应该换一个"每次请求只过一遍"的位置,而不是靠优化引擎
