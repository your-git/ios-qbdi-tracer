# 设计思路

> 新会话维护本项目,先读这一篇。它解释**为什么**这么设计,读完再看代码就不会迷路。

## 1. 一句话

iOS 指令级 tracer:**运行期 JSON 配置 + 手机 UI 管理**,改配置不用重编译。引擎负责 Dobby hook + QBDI 逐指令 trace,配置层负责数据 + UI。

## 2. 两进程模型

成品是**一个 deb**,但里面装了**两个独立的东西**,运行在**不同进程**:

```
┌─ 控制 App(TracerGUI.app,主屏图标)──────────┐
│  UIKit 表格应用,管理 trace/hook 配置         │
│  bundleId = com.snk.qbditracer                │
│               │ 写 JSON                        │
└───────────────┼───────────────────────────────┘
                ▼
   /var/mobile/Documents/QBDITracer/{settings,config,hooks}.json
   (rootless: /var/jb/var/mobile/Documents/...)
                ▲
┌───────────────┼───────────────────────────────┐
│  引擎 tweak(TracerEngine.dylib)              │
│  全量注入(filter=com.apple.UIKit)           │
│  每个 app 启动 → 读 JSON → 匹配当前 bundleId  │
│  → 装 Dobby hook → QBDI trace → 写日志         │
└────────────────────────────────────────────────┘
```

**为什么两进程**:tweak 必须注入到**目标 app**(如 settings)里才能 hook 它的代码;而配置 UI 不能塞进 settings(会干扰、也不合理),必须是**独立 App**。两者只能通过磁盘上的共享文件通信。

**为什么用文件而不是进程间通信**:最简单可靠。控制 App 写,引擎读。不做实时同步 —— 改完配置**重开目标 app** 才生效(引擎只在启动时读一次)。

## 3. 全量注入 + 配置匹配

`Engine/TracerEngine.plist` 的过滤条件是 `com.apple.UIKit` —— 几乎所有前台 app 都链接 UIKit,所以**所有 app 启动都会载入这个 dylib**。

载入后 `engine_start()`(`Engine/src/engine.m`)第一时间判断:
1. 当前进程是控制 App 自己(`com.snk.qbditracer`)→ 直接返回(不自钩)
2. 读不到 JSON / 总开关 `enabled=false` / 没有匹配当前 bundleId 的启用条目 → 直接返回(**空转**)
3. 有匹配 → 装 hook 干活

**为什么不加"关掉就不注入"的开关**:要做到"关掉连 dylib 都不载入",得让控制 App 去改写 substrate 的过滤 plist(需要 root 写系统目录 + 重启目标),复杂且易错。而**空转开销是亚毫秒级**(一次 dylib 载入 + 几个 BOOL 判断),可忽略。所以总开关放在**执行层**(engine_start 里读 JSON 的 enabled),不放注入层。用户已确认接受这个取舍。

## 4. 引擎原理(经真机验证)

### 4.1 为什么要 Dobby + QBDI 两个

- **Dobby**:inline hook,负责"在某地址插一脚",是注入点。QBDI 本身不含注入方式。
- **QBDI**:动态二进制插桩,负责"逐条指令记录"。以基本块为单位把代码 JIT 到虚拟环境执行,每条指令给回调。

分工:Dobby 在 `模块基址+起始地址` hook 住,命中后把控制权交给 QBDI,QBDI 逐条 trace 到 `结束地址`。

### 4.2 trampoline 为什么是汇编

被 trace 的代码常在**函数中段**,依赖调用方保留寄存器(x19-x28)。普通 C 函数拿不到这些寄存器。所以 hook 的落点是一段 **naked arm64 汇编 trampoline**(`Engine/src/tramp.c`):

```
保存 x0-x28 / fp / lr / 真实sp / NZCV / FPCR / FPSR / q0-q31 到栈
  →  bl trace_ctx_entry(rf, slot)
  →  恢复全部应用状态(x17 除外)  →  x17 持有续跑地址  →  br x17
```

`x17` 是 Dobby 在 arm64 上声明的跳板临时寄存器，入口补丁本身就可能改写它；
trampoline 因而用 x17 承载 `trace_ctx_entry` 返回的 origin，并恢复 x16。源码有
`ARM64_TMP_REG_NDX_0 == 17` 的编译期检查，Dobby 契约变化时会直接拒绝构建。
曾经把返回值放进 x16、随后又用保存现场覆盖 x16，最终 `br x16` 跳回旧地址，表现为
同一个 hook 现场和寄存器值无限重复。

**为什么要存这么多**:`DobbyHook` 是纯跳转 hook,不替我们保存任何 CPU 状态;而 hook 点落在
**函数中间**,不是函数调用边界 —— 这里没有任何 ABI 保护,原代码此刻持有的一切都得原样还回去。

- **NZCV(条件标志位)**:`trace_ctx_entry` 里的 C 代码(表达式求值、`memcmp`、字符串搜索)
  必然改写它。不恢复的话,原代码紧跟着的 `b.eq`/`cbz` 会基于被污染的标志位跳转 ——
  **如果那正好是循环的退出判断,程序就永远出不来**。真机上表现为:同一个函数被反复执行
  上百万次、寄存器和数据一直不变,看着像死锁,其实是控制流被带偏了。
- **q0-q31(向量寄存器)**:C 里的 `memcpy`/`memcmp`/字符串操作大量用 NEON。ABI 只保证
  v8-v15 的**低 64 位**由 callee 保护,而原代码在指令中间可能正拿着任意 v 寄存器存中间值。
- **FPCR/FPSR**:改动概率低,但既然要"原样还回去"就一起存。

栈布局(共 `0x320` 字节,`TraceRegFile` 仍在 `sp+0` 开头 `0x100` 字节,结构不变):

```
sp+0x000..0x0FF  x0..x28 / fp / lr / 真实sp   ← TraceRegFile
sp+0x100         NZCV
sp+0x108         FPCR
sp+0x110         FPSR
sp+0x120..0x31F  q0..q31
```

恢复顺序有讲究:`msr nzcv` 排在恢复通用寄存器**之前**(借 x9 当临时寄存器),因为之后的
`ldp`/`ldr`/`mov sp`/`br` 都不碰标志位,而 x9 随后会被还原成原值。

> 这段汇编改动前必须反汇编核对(`otool -tV`),32 个槽位都要逐个确认 —— 见 HANDOFF.md。

### 4.3 记录后原生续跑(关键设计)

QBDI 在**虚拟栈**上执行被 trace 的代码(用真实栈会让 QBDI 引擎 abort)。但虚拟栈执行完,app 的真实状态没更新,直接续跑会崩。

解法(`trace_ctx_entry` in `qbdi_trace.c`):
1. QBDI 在虚拟栈上**只做记录**,输出寄存器丢弃
2. 恢复 hook 点的**输入寄存器**
3. 跳回 Dobby origin,让区域代码**原生再执行一遍**

代价:被 trace 的区域执行两遍(QBDI 记录一遍 + 原生一遍)。对纯计算函数(签名计算)无害。

### 4.3.1 为什么 trace 区间必须 ≥ 0x10 字节

`qbdi_run(vm, entry, end)` 靠 **PC == end** 停,而 `end` 是**模块里的真实地址**。
Dobby 的补丁覆盖 `[start, start+QBDI_PATCH_SIZE)`(0x10 字节),这段的原指令被搬到
origin trampoline —— QBDI 执行的是那份副本,副本地址永远不等于模块里的 `end`。

所以 `end` 一旦落在补丁区内(`end - start < 0x10`):

1. 副本跑完,origin 末尾的跳回桩直接跳到 `start + 0x10`,**跨过了** `end`
2. stopAddr 永不命中
3. 兜底也常常失效(`run_trace` 里设了 `state->lr = end`,想让"提前 ret"跳回 end 停下,
   但区域里只要有一条 `BL`,LR 当场就被覆盖了)
4. 于是一路执行完整个函数、跑进所有被调函数,撞上 syscall / objc 快速路径 /
   C++ 异常这类 QBDI 不处理的东西 → SIGSEGV

这种配置**必然**跑飞,所以 `engine.m` 的 `load_watches` 之前和 `trace()` 入口都直接拒掉,
`TraceEditVC` 的「完成」也挡一道。想看某条指令附近的数据,应该用 watch,而不是缩小 trace 区间。

### 4.3.2 触发条件(按内存内容决定这次要不要 trace)

同一个 hook 点常常被调用很多次,只有少数几次携带你要的数据(其余可能是 `0x0`)。
`count` 是"前 N 次",挡不住这种情况 —— 第一次的垃圾数据就把次数消耗掉了。

所以 trace 条目可以带任意多条**触发条件**；多条之间是 OR，任意一条满足即可:

`triggerAddress` 缺失/留空/等于 `static_start` 时沿用原流程:

```
start hook 命中 → 求值 triggerExpr(用 start 的输入寄存器) → 匹配?
    不匹配 → 计数 +1,直接 return origin(不减 count、不启动 QBDI)
    匹配   → 照常 run_trace
```

自定义 `triggerAddress` 时另装一个 Dobby Hook:

```
trigger hook 命中并匹配 → 授权同一线程的下一次 start
start hook 命中且有授权 → 消费授权 → run_trace
```

授权用按条件数量懒分配的 TLS 状态隔离,防止 A 线程命中条件却让 B 线程开始 Trace。高于结束地址的
触发点因此可以授权程序之后跳回低地址的下一轮 Trace。所有判断都在
`g_remaining[idx]` 递减之前,不匹配不浪费 Trace 次数；Trace 未成功到达 end 时也会归还次数。
相同判断地址的条件共享一个 Dobby Hook，不同地址必须至少相差 `0x10`。

`triggerConsume=once` 时，每条条件只在成功 Trace 后消耗一次；`custom` 使用条件内的
`triggerLimit`（1..16，缺省 1）作为独立上限；`repeat` 不限制单条条件并作为旧配置默认值。
低 16 位成功次数 + 高 16 位进行中预占组成一个原子状态，避免多个线程同时突破上限；
失败会释放预占，不计条件次数，也会归还 Trace 总次数。

四种匹配方式(`TrigMatch`)× 两种位置(`TrigWhere`),都在 `config.h`:

| 方式 | 期望值 | 比较 |
|---|---|---|
| `notnull` | — | 地址可读且非 0。**光这一条就能滤掉所有 `(null)` 的调用** |
| `bytes` | `08a48c90` | 字节序列,按**内存顺序**(与 hexdump 所见一致),上限 32 字节 |
| `cstr` | `api` | C 字符串 |
| `u64` | `0x02100481908ca408` | 读 8 字节按小端当整数,相等 |

位置(只对 `bytes`/`cstr` 有意义,缺省 **cstr=包含、bytes=开头**):

| 位置 | 读多少 | 怎么比 |
|---|---|---|
| `prefix` | 只读期望值那么长 | 逐字节相等 |
| `contains` | 最多 `triggerScan` 字节(cstr 再按第一个 `\0` 截断) | 在里面搜子串 |

`bytes` 和 `u64` 对同一块内存的写法是**反的**(前者是内存顺序,后者是小端整数),
界面 footer 里有提示。表达式和期望值都在配置加载期编译/解析好,运行期只做比较。
比较逻辑单独拆成了 `trig_compare()`(不碰内存、不依赖 mach),所以能在 mac 上提取出来测。

`triggerScan` 默认 `0x100`、硬上限 `TRIG_MAX_SCAN = 0x1000`。窗口配得比期望值还短时
**加载期直接拒**(否则永远搜不到,却看不出为什么)。

**性能**:`contains` 几乎不比 `prefix` 慢 —— 成本在 **mach trap 次数**而不是读取字节数。
两者都是「1 次解引用 + 1 次读」共 2 次 trap;窗口一次读满(不像 `watch_read_string`
那样每 64 字节一趟),多出来的只是内存里的朴素搜索。这段代码在**每次 hook 命中**都跑,
所以 trap 次数是唯一要控的东西。

`vm_read_overwrite` 有个坑:读取范围末尾一旦跨到未映射页,**整块调用失败返回 0**。
所以 `trigger_read()` 在整块失败时退一步、只读到本页末尾 —— 否则窗口设大一点就什么都读不到。

**地址限制**:自定义判断地址不得落在 `(static_start, static_end)` 中。低于 start 时
与 start 至少差 `QBDI_PATCH_SIZE = 0x10`,避免两个 Dobby 补丁重叠。等于 end 或高于
end 可用。表达式的 `pc` 是实际判断 Hook 地址。数值上在区间外也不能完全证明安全:
QBDI 跟随的是动态控制流,如果 Trace 的调用路径又执行了外部 trigger Hook，Dobby 补丁仍可能影响
QBDI。引擎会阻止这种情况下的嵌套授权,但配置时仍应选不会在 Trace 动态路径里再次执行的点。

**条件配错时拒绝整条 trace**(而不是退化成无条件):过滤静默失效会给出一堆本该被滤掉的
日志,而用户以为条件在生效,比不 trace 更误导。

日志上不改动现有格式,只加行。不匹配时按**指数退避**打诊断 —— 第 1/10/100/1000/… 次
各打一次,内容是"表达式算出的地址 + 实际读到的数据 + 期望值":

```
[ExampleModule] trigger miss #1: [x2+0x10] = 0x280691000
    want: bytes prefix 08a48c90
    got : 0000000028043...  (read 0x4 bytes)
```

取址失败时改为打逐级 `deref#N` 链(复用 `wexpr_print_trace`)。这样"地址不对"和
"期望值写法不对"一眼能分清 —— 早期版本每 100 次只打一个计数,热点上写了 52 万行
却什么信息都没有,排查全靠猜。

命中时在 `==== trace#N enter ====` 之前写一行 `trigger matched (bytes prefix)
after N filtered calls`。

次数用完后**不再求值条件**(否则 trace 早结束了,过滤统计还会一直往日志里长)。

### 4.4 watch(监视点)

除了逐指令 trace,可在指定地址读一个**算出来的地址**指向的内存(`qbdi_trace.c` 的 `watch_handle`):
- 用 `vm_read_overwrite` **安全读**(野指针不崩,返回 `(not a pointer)`)
- action:`cstr`/`utf8`(size=0 读到 \0 不截断)、`u32`/`u64`、`hexdump`(上限 64KB)、`objc`(校验 isa 后当 ObjC 对象解析)

**取址方式**有两种,`expr` 优先于 `reg`:
- `reg`:直接取某个寄存器的值(`x0`..`x28`/`fp`/`lr`/`sp`)
- `expr`:取址表达式,支持 `寄存器 ± 十六进制常量` 与 `[]` 多级解引用,如 `x0-0x110`、`sp+0x40`、`[[x0+8]+0x10]-4`

表达式由 `watch_expr.c` 实现,设计上有两个关键点:

1. **在配置加载期编译,不在命中时解析**(`engine.m` 的 `load_watches` 调 `wexpr_compile`,结果存进 `TraceWatch.cexpr`)。编译产物是一段最多 24 步的后缀式,命中时只跑这几步。这样做的主要收益不是性能,而是**语法错误在 app 启动时就能写进日志** —— 否则配错了的表现和"没命中"一模一样,没法排查。
2. **表达式算出的是"地址",最后一次解引用交给 action**。于是 `expr="x0"` 与旧配置 `reg="x0"` 行为完全一致,老配置不需要迁移;而 `[x0+0x10]` 配 `cstr` 自然就是"读结构体里那个 `char*` 字段"。

多级指针失败时会把每一级的地址和读取结果都打进日志(`wexpr_print_trace`),否则三级解引用只报一句"读不出来"等于没有信息。

## 5. 运行期配置(核心设计)

所有 trace/watch 参数都放在 **JSON**,由 `engine.m` 在目标 app 启动时解析:

- **trace 配置** → JSON `items`,运行期解析,不用重编译
- **watch 配置** → JSON `items[].watches`
- **Trace 内寄存器修改** → JSON `items[].mutations`，仅改变 QBDI `GPRState`
- **延迟 / logMask** → 每条目独立字段 `delaySecs` / `logMask`
- **改配置** → 手机上改 → 重开目标 app 生效

**trampoline 为什么固定 32 槽位**:trampoline 的汇编里 `mov x1, #slot` 要求 slot 是**编译期字面量**,没法运行期动态生成。所以预生成 32 个一模一样(只差 slot 编号)的 trampoline,运行期 `engine.m` 决定 hook 哪几个槽位。上限 32 个 trace 条目(`TRACE_MAX_TARGETS`)、128 个 watch(`TRACE_MAX_WATCHES`)。

## 6. 配置文件 schema

配置目录 `/var/mobile/Documents/QBDITracer/`(rootless 加 `/var/jb` 前缀,引擎和 App 都会探测)下有**三份文件**,各管各的:

| 文件 | 内容 | 谁读 |
|---|---|---|
| `settings.json` | 总开关 `enabled` + 日志根目录 `logRoot` + 导入导出根目录 `exportRoot` | 引擎**最先读** + App |
| `config.json` | 顶层 `items`(trace 条目) | 引擎 + App(ConfigStore) |
| `hooks.json` | 顶层 `hooks`(hook 条目) | 引擎 + App(HookStore) |

**为什么拆三份**:总开关和路径属于"设置",和具体条目是两个关注点;Trace 与 Hook 相互独立,混在一个文件里导出单条时容易互相带出、schema 也更易错。引擎先读 `settings.json`,总开关关着就立即返回,另外两份根本不用读(比原来还省)。

**总开关迁移**:`enabled` 原来在 `config.json`,现已搬到 `settings.json`。迁移做两头 —— App 首次启动(AppSettings load)若 `settings.json` 不存在,就读旧 `config.json` 的 `enabled` 再写出 `settings.json`;引擎在 `settings.json` 缺失时同样回落读旧值。少任何一头,老用户升级后"原本关掉的插件"都会自己变成开启。

### settings.json

GUI 还保存独立的 `traceSortMode` / `hookSortMode`：0=名称 A–Z，1=名称 Z–A，
2=加入时间新到旧，3=旧到新（缺省）。引擎忽略这些展示字段。
条目的可选 `addedAt` 是加入本机软件的 Unix 时间秒数，用于 GUI 排序，编辑不更新；
复制和导入产生新时间。历史条目没有时间时以原数组顺序兜底，且排在有时间的新条目前。
排序只生成显示视图，不重排配置数组。
文件导入页的 `traceImportSortMode` / `hookImportSortMode` 使用相同枚举，缺省 2；
名称取文件名，时间取文件修改时间，各分页独立记住选择，与主页排序互不影响。

```json
{
  "enabled": true,                              // 总开关(Trace/Hook 共用)
  "logRoot": "/tmp/ios-qbdi-tracer",            // 日志根目录;引擎按它定日志位置
  "exportRoot": "/var/mobile/.../ios-qbdi-tracer-config-json"  // 仅 App 用
}
```

`logRoot` 下自动建 `trace-logs/`、`hook-logs/`;`exportRoot` 下自动建 `trace/`、`hook/`。这些子目录名是固定的(引擎 `qbdi_trace.c` 的 `TRACE_LOG_SUBDIR` 与 App `AppSettings.h` 的 `QBDI_*_SUBDIR` 必须一致)。

### config.json(trace)

```json
{
  "items": [
    {
      "id": "uuid",                   // 条目唯一 id
      "enabled": true,                // 该条目勾选状态
      "traceName": "登录签名计算",     // 可选的用户自定义名称;缺省/空=旧版展示
      "bundleId": "com.example.exampleapp",
      "appName": "settings",            // 仅 UI 展示
      "module": "MainModule",      // dyld 镜像名子串
      "start": "0x27A1F4E0",          // 相对模块基址偏移(hex 字符串)
      "end": "0x27A1F4F0",            // 同上,执行到此即停(不含)
      "count": 1,                     // 成功 trace 次数,范围 1..16
      "moduleOnly": true,             // 1=只记录模块内指令
      "delaySecs": 10,                // 本条目延迟多少秒装 hook
      "logMask": 17,                  // LOG_INST=1 MEM=2 REGS=4 BRANCH=8 VREG=16 位或
                                      // 界面已不再暴露这一栏,新建/编辑后统一写 17
                                      // (INST|VREG);引擎照旧按字段值跑,旧配置不受影响
      "maxInstructions": 0,           // 可选;0/缺省=跑到 end,非 0=达上限时截断
      "triggerConsume": "repeat",     // repeat | once | custom
      "triggers": [                    // 空数组=无条件;数量不设 UI/配置上限
        { "triggerExpr": "[x2+0x10]", "triggerAddress": "0x27A1F400",
          "triggerMatch": "bytes", "triggerValue": "08a48c90",
          "triggerWhere": "prefix", "triggerScan": "0x100",
          "triggerLimit": 1 }          // custom 下生效，范围 1..16
      ],
      "mutations": [                   // 缺失/空数组=不修改，兼容旧 JSON
        { "enabled": true,
          "offset": "0x27A1F4E8",      // 当前 trace 模块的静态偏移
          "reg": "x8",                 // x0..x28(不含 x17)、fp、lr
          "width": 32,                  // 32=wN 且高位清零；64=xN
          "value": "0x2",
          "apply": "once" }            // once=每轮首次；always=每次命中
      ],
      "watches": [
        { "module": "ModuleName", "offset": "0x27A1F4E8",
          "reg": "x0", "action": "cstr", "size": "0x0", "label": "url" },
        { "module": "ModuleName", "offset": "0x27A1F4E8",
          "reg": "x0",                    // 基寄存器,给旧版引擎留的退路
          "expr": "[[x0+8]+0x10]-4",      // 取址表达式,存在时优先于 reg
          "action": "hexdump", "size": "0x110", "label": "hdr" }
      ]
    }
  ]
}
```

**地址是相对模块基址的偏移**,和 Frida `module_base.add(x)` 一致 —— 不是绝对 VA,不要加 slide。引擎用 `_dyld_get_image_header` 取运行时基址(已含 slide)。

`mutations` 在全局 `QBDI_PREINST` 回调中、目标指令执行前按数组顺序应用。地址不做
`start/end` 数值区间限制：控制流可以跳到区间数值外，只有 QBDI 动态路径实际执行到该地址
才会生效；修改点不额外安装 Dobby Hook。自动 Hook 路径在 QBDI 返回后恢复入口现场，
因此寄存器覆盖不会写回真实 App；
但 Trace 内走到的系统调用、文件、网络等外部副作用不会回滚。要覆盖 load/函数调用的结果，
规则应设在它的下一条指令。禁止 `sp`、`pc` 和 Dobby 跳板占用的 `x17`。

**`size` 的进制看前缀**:`"0x110"` = 272,`"110"` = 110(十进制),裸数字 `272` = 272。旧配置里 size 是十进制数字,新 App 写出来一律是 `"0x..."` 字符串,靠前缀区分,不需要迁移。`start`/`end`/`offset` 则一律按十六进制解(带不带 `0x` 都一样)。

### hooks.json(hook)

```json
{
  "hooks": [
    {
      "id": "uuid",
      "enabled": true,                 // 该条目勾选状态
      "hookName": "登录返回值改写",     // 可选自定义名称
      "bundleId": "com.example.exampleapp",
      "appName": "settings",             // 仅 UI 展示
      "module": "MainModule",         // dyld 镜像名子串
      "target": "0x27A1F4E0",          // 目标地址:相对模块基址偏移(Dobby hook 落点)
      "delaySecs": 0,                  // 延迟多少秒装 hook
      "maxHits": 0,                    // 应用修改的次数上限;0=每次命中都改
      "mods": [                        // 修改数据功能列表(最多 16 条)
        { "enabled": true,
          "kind": "modify",            // 目前只有 modify;read(读取数据)研发中
          "type": "number",           // bytes | string | number
          "width": 32,                 // number 才有意义:8/16/32/64
          "expr": "[x0+0x10]",         // 寄存器/取址表达式(不对称语义见 §Hook)
          "value": "0x1" }             // bytes:hex 串;string:UTF-8;number:hex
      ]
    }
  ]
}
```

## 6.4 Hook(用 Dobby 真实改数据)

**与 Trace 的本质区别**:Trace 用 QBDI 在虚拟栈上**只读记录**、跑完恢复现场,`items[].mutations` 也只改 QBDI 虚拟寄存器、不写回真实 App。**Hook 是真的改**:在 `模块基址+target` 装 Dobby hook,命中后直接改写目标进程的寄存器或内存,续跑后一直有效。

**执行路径**(`Engine/src/hook.c` 的 `hook_ctx_entry`):Dobby 命中 → hook trampoline(`tramp.c`,与 trace 同一套 `0x320` 完整现场保存)→ `hook_ctx_entry` 改写栈上保存的寄存器槽 / 调 `vm_write` 改内存 → trampoline 恢复现场(**含被改过的寄存器**)→ `br origin` 原生续跑。寄存器修改因此能持久生效,而不是像 trace 那样跑完就丢 —— 这正是复用 trace trampoline 的关键收益。

**不对称写入语义**(最容易写错、写错就往错地址写内存 → 崩;`hook_classify_target` 实现):

| 修改类型 | 裸寄存器 `x0` | `[x0]` / `[x0+0x10]` |
|---|---|---|
| 数值 | 改**寄存器本身**(仅 32/64 位,32 位按 wN 清高位) | 改**内存**,8/16/32/64 位 |
| 字节 | ❌ 报错(裸寄存器写不了字节序列) | 改**内存** |
| 字符串 | x0 的值当 **char\* 首地址**,写到那里 | 改**内存** |

判定规则:整串被一对最外层 `[]` 包住 → 内存写,地址 = 方括号内部求值(复用 `watch_expr`);否则是单个裸寄存器 → 按上表分流;其余(如 `x0+0x10` 无括号)一律拒。

**只读内存**:写前若目标页不可写,先 `vm_protect` 加写权限(带 `VM_PROT_COPY`,copy-on-write 不影响其它进程)、写完恢复原保护位。地址未映射/跨内存区/提权失败都安全跳过,不崩。

**自愈**:取址表达式连续 `HOOK_FAIL_LIMIT`(20)次求不出地址就自动停用该 Hook(成功一次即清零),避免野配置一直白跑。

**日志**:`<logRoot>/hook-logs/hook_<年月日时分>.log`,按第 1/10/100/1000… 次指数退避记地址/旧值/新值;**旧值只在要写日志的那几次才读**(省热路径 mach 调用)。时间戳与 trace 日志共享一次生成(`qbdi_log_timestamp`),同一次运行两份日志后缀一致。

**上限**:32 条 Hook(`HOOK_MAX_TARGETS`,对应 `tramp.c` 的 32 个 hook 跳板)、单条 16 条修改(`HOOK_MAX_MODS`)、单条修改载荷 256 字节(`HOOK_VAL_MAX`)。Hook 的 target 与 Trace 的 start/trigger 补丁共用同一张已装地址表做 `0x10` 间距冲突检测(同进程两个 Dobby 补丁靠太近会互相踩坏,与类型无关)。

## 6.5 导出 / 导入

- **导出**:trace 条目左滑「导出」→ `{"version":1,"item":{...}}` 写到 `<exportRoot>/trace/`,文件名 `trace_<appName净化><年月日时分秒>.json`（`yyyyMMddHHmmss`）;hook 条目左滑「导出」→ `{"version":1,"type":"hook","hook":{...}}` 写到 `<exportRoot>/hook/`,文件名 `hook_<appName净化><年月日时分秒>.json`。成功弹框显示实际落地完整路径。`exportRoot` 默认 `<Documents>/ios-qbdi-tracer-config-json`,可在设置页改。
- **取出**:App 的 Info.plist 开了 `UIFileSharingEnabled`+`LSSupportsOpeningDocumentsInPlace`,用 Finder 连手机 → 文件共享 → QBDI Tracer 拖出。
- **导入**(+ → 导入,或「更多 → 新增」):`ImportVC` 底部 **Trace|Hook 分页**,列各自导出目录 +**旧版 Documents 根**下的 .json(升级后不会"看起来全丢了")。点选文件时按**内容真实类型**(`HookStore detectType`:看 `type` 字段/包装 key/特征字段)导入 —— 选中的文件若与当前分页不符,自动导到正确的一类并提示。都会重生 id、enabled=YES。
- **兼容**:trace 接受 `{version,item}` 或裸 item;hook 接受 `{version,type,hook}` 或裸 hook。
- **系统级 app 沙盒风险**:控制 App 装在 `/Applications`(系统级),`NSHomeDirectory()`/Documents 是否是标准可共享沙盒**待真机确认**;`exportDir` 有回退逻辑,落地路径始终显示给用户。

## 7. schema 一致性(维护重点)

- **Trace**:控制 App(`GUI/src/ConfigStore.m` 的 `newItem`)和引擎(`Engine/src/engine.m` 的解析)**必须用同一套字段名**。
- **Hook**:控制 App(`GUI/src/HookStore.m` + `HookEditVC`/`HookModEditVC`)和引擎(`engine.m` 的 `load_hook`/`load_hook_mod` + `hook.c`)也必须同步。特别是**不对称写入语义有两份实现**:GUI `HookModEditVC.m` 的 `classifyTarget`/`exprBracketed`/`exprBareRegister` 和引擎 `hook.c` 的 `hook_classify_target`/`outer_bracket`/`bare_register` 必须给出一致结论,否则"App 说没问题、装上却被拒"。

改任何字段两边都要改。这是本项目最容易出 bug 的地方 —— 详见 [HANDOFF.md](HANDOFF.md)。改完跑 `./scripts/test_watch_expr.sh`(第 6 组交叉验证 hook 纯逻辑)。
