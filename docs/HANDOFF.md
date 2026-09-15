# 交接与维护文档

> 面向后续会话/维护者。读完 [DESIGN.md](DESIGN.md) 再读这篇。这里讲**每个文件干什么**、**常见修改怎么做**、**别踩什么坑**。

## 文件地图

### Engine/(引擎 tweak,注入到目标 app)

| 文件 | 行数 | 作用 | 改动频率 |
|---|---|---|---|
| `Tweak.x` | 小 | 入口。`__attribute__((constructor))` → `engine_start()`。**不用 Logos %ctor**(Apple clang 21+ 编不过其 `__unused` 参数) | 几乎不改 |
| `src/engine.m` | 236 | **核心新代码**。读 JSON、匹配 bundleId、填 `g_traces`/`g_watches`、每条目 dispatch_after 延迟装 Dobby hook。也定义了 `g_traces/g_watches/g_trace_count/g_watch_count` 和 `find_module` | 加字段/改匹配逻辑时 |
| `src/tramp.c` | 77 | 固定 32 个 naked arm64 trampoline + `g_tramps[]` 指针表。汇编序列经真机验证 | **别乱改汇编** |
| `src/qbdi_trace.c` | 648 | QBDI 引擎:VM 记录、`trace_ctx_entry`(记录后原生续跑)、`watch_handle`、崩溃捕获 | 改 trace/watch 行为时 |
| `src/qbdi_trace.h` | 55 | LOG_* 位、`TRACE_MAX_TARGETS=32`/`TRACE_MAX_WATCHES=128`、`TraceRegFile`、函数声明 | 改上限时 |
| `src/config.h` | 37 | `TraceSpec`/`TraceWatch` 结构定义 + 表的 extern 声明 | 加字段时 |
| `src/engine.h` | 10 | `g_tramps[]` 和 `engine_start()` 声明 | 几乎不改 |
| `TracerEngine.plist` | 1 | 注入过滤:`{ Filter = { Bundles = ( "com.apple.UIKit" ); }; }` | 改注入范围时 |
| `Makefile` | 小 | tweak 子工程。include 路径用 `$(THEOS_PROJECT_DIR)/Engine/...` | 加源文件时 |

### GUI/(控制 App,主屏图标)

| 文件 | 行数 | 作用 |
|---|---|---|
| `entry.m` | 10 | `UIApplicationMain` |
| `src/AppDelegate.m` | 17 | 建 window + 导航栈,root = RootListVC |
| `src/ConfigStore.{h,m}` | ~290 | **JSON 读写**。`load`/`save`/`newItem` + **导出/导入**(`exportItem`/`listImportableFiles`/`importItemFromData`/`importItemFromString`/`exportDir`)。路径探测(rootless /var/jb)。**与引擎 schema 必须一致** |
| `src/RootListVC.m` | 221 | 主界面。总开关 + 条目列表。点击=编辑,前缘滑=启停,尾缘滑=复制/删除(删除弹确认框),+ 按钮=加trace(先进 AppPicker) |
| `src/AppPickerVC.m` | 141 | 应用选择器。`LSApplicationWorkspace`(私有 API)列所有 app 图标+名字+bundleId,带搜索 |
| `src/TraceEditVC.m` | 297 | trace 表单。5 段:App信息/模块地址/选项/logMask多选/watches子表 |
| `src/WatchEditVC.m` | 134 | watch 表单。寄存器和 action 用 action sheet 选择器 |
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
| `scripts/build_debs.sh` | 一键出 rootful(`iphoneos-arm`)+ rootless(`iphoneos-arm64`)两个 deb。切 scheme 前自动 `make clean`,`--release` 出去符号版 |

## 常见修改任务

### A. 给 trace 条目加一个新字段(如 "maxInst")

**必须改 4 处**,漏一处就 schema 不一致:
1. `Engine/src/config.h` —— `TraceSpec` 加字段
2. `Engine/src/engine.m` —— 解析 JSON 填该字段(`t->maxInst = parse_int(it[@"maxInst"], ...)`)
3. `GUI/src/ConfigStore.m` —— `newItem` 加默认值
4. `GUI/src/TraceEditVC.m` —— 加一行 UI 让用户填

然后消费它的地方(如 `qbdi_trace.c`)按需读 `spec->maxInst`。

### B. 改注入范围

改 `Engine/TracerEngine.plist` 的 Bundles。比如只注入特定 app 可写死 bundleId 列表;但当前"全量注入+配置匹配"更灵活(见 DESIGN.md §3)。

### C. 改 trace 记录内容 / watch 行为

改 `Engine/src/qbdi_trace.c` 的 `inst_cb`(逐指令输出格式)或 `watch_handle`(监视点)。

### D. 提高 trace 条目上限(超过 32)

1. `qbdi_trace.h` 改 `TRACE_MAX_TARGETS`
2. `tramp.c` 补更多 `TRAMP(n)` 和 `g_tramps[]` 条目(汇编槽位是硬生成的,必须手动加到新上限)

### E. 改日志路径

`qbdi_trace.c` 顶部的 `TRACE_LOG_DIR` / `TRACE_LOG_PREFIX`(当前 `/tmp/qbdi_trace_<年月日时分>.log`)。文件名在 `trace_log_open` 里按进程首次写日志的时间用 `strftime("%Y%m%d%H%M")` 生成一次。若想改成"固定文件名"或"每条 trace 一个文件",改这个函数。

## 别踩的坑(血泪)

1. **schema 三处同步**:引擎解析(engine.m)、App 写入(ConfigStore.m newItem)、App 表单(TraceEditVC.m)。字段名对不上 → 配了没效果,还不报错。
2. **子工程 include 路径**:`$(THEOS_PROJECT_DIR)` 在 aggregate 里指**根目录**,不是子目录。必须写全 `Engine/src`、`GUI/src`。
3. **Info.plist 位置**:App 的必须在 `GUI/Resources/Info.plist`。放错地方能编译成功但装上没图标。
4. **trampoline 汇编别动**:`tramp.c` 的寄存器保存/恢复顺序、偏移(0x00..0xf8)、`mov sp,x9` 用真实 sp —— 都是真机调出来的。改错直接崩。
5. **QBDI 用虚拟栈**:`trace_ctx_entry` 里 QBDI 跑虚拟栈只记录、原生再跑一遍。别改回"真实栈"(会让 QBDI 引擎 abort)。
6. **地址是偏移不是 VA**:配置里的 start/end/offset 都是相对模块基址,别加 slide。
7. **改了 UI 但设备上没变化 → 十有八九是没装上新包**,不是代码问题。dpkg/Sileo 在包名相同时经常**不覆盖更新**。验证套路见下面「验证改动是否真的生效」。重装前先 `dpkg -r com.snk.qbditracer` 再装,或升 `control` 里的 Version。
8. **别用 UTF-8 在二进制里搜中文字符串来验证**:含非 ASCII 的 `@"中文"` NSString 字面量,clang 会编成 **UTF-16** 存进 `__ustring` 段(不是 UTF-8 的 `__cstring`)。用 UTF-8 搜会全部 "missing" —— 这是**误报**,不代表字符串没编进去。要搜就搜 UTF-16LE(`kw.encode('utf-16-le')`)。ASCII 字符串才在 `__cstring` 里。

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
