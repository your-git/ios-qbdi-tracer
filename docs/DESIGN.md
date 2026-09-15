# 设计思路

> 新会话维护本项目,先读这一篇。它解释**为什么**这么设计,读完再看代码就不会迷路。

## 1. 一句话

iOS 指令级 tracer:**运行期 JSON 配置 + 手机 UI 管理**,改配置不用重编译。引擎负责 Dobby hook + QBDI 逐指令 trace,配置层负责数据 + UI。

## 2. 两进程模型

成品是**一个 deb**,但里面装了**两个独立的东西**,运行在**不同进程**:

```
┌─ 控制 App(TracerGUI.app,主屏图标)──────────┐
│  UIKit 表格应用,管理 trace 配置              │
│  bundleId = com.snk.qbditracer                │
│               │ 写 JSON                        │
└───────────────┼───────────────────────────────┘
                ▼
   /var/mobile/Documents/QBDITracer/config.json
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
保存 x0-x28 / fp / lr / 真实sp 到栈  →  bl trace_ctx_entry(rf, slot)
→ 恢复全部寄存器(sp 用真实sp)  →  br 续跑地址
```

这段汇编序列经过**真机验证**,一字未改。

### 4.3 记录后原生续跑(关键设计)

QBDI 在**虚拟栈**上执行被 trace 的代码(用真实栈会让 QBDI 引擎 abort)。但虚拟栈执行完,app 的真实状态没更新,直接续跑会崩。

解法(`trace_ctx_entry` in `qbdi_trace.c`):
1. QBDI 在虚拟栈上**只做记录**,输出寄存器丢弃
2. 恢复 hook 点的**输入寄存器**
3. 跳回 Dobby origin,让区域代码**原生再执行一遍**

代价:被 trace 的区域执行两遍(QBDI 记录一遍 + 原生一遍)。对纯计算函数(签名计算)无害。

### 4.4 watch(监视点)

除了逐指令 trace,可在指定地址读某个寄存器指向的内存(`qbdi_trace.c` 的 `watch_handle`):
- 用 `vm_read_overwrite` **安全读**(野指针不崩,返回 `(not a pointer)`)
- action:`cstr`/`utf8`(size=0 读到 \0 不截断)、`u32`/`u64`、`hexdump`、`objc`(校验 isa 后当 ObjC 对象解析)

## 5. 运行期配置(核心设计)

所有 trace/watch 参数都放在 **JSON**,由 `engine.m` 在目标 app 启动时解析:

- **trace 配置** → JSON `items`,运行期解析,不用重编译
- **watch 配置** → JSON `items[].watches`
- **延迟 / logMask** → 每条目独立字段 `delaySecs` / `logMask`
- **改配置** → 手机上改 → 重开目标 app 生效

**trampoline 为什么固定 32 槽位**:trampoline 的汇编里 `mov x1, #slot` 要求 slot 是**编译期字面量**,没法运行期动态生成。所以预生成 32 个一模一样(只差 slot 编号)的 trampoline,运行期 `engine.m` 决定 hook 哪几个槽位。上限 32 个 trace 条目(`TRACE_MAX_TARGETS`)、128 个 watch(`TRACE_MAX_WATCHES`)。

## 6. 配置文件 schema

路径:`/var/mobile/Documents/QBDITracer/config.json`(rootless 加 `/var/jb` 前缀,引擎和 App 都会探测)。

```json
{
  "enabled": true,                    // 总开关
  "items": [
    {
      "id": "uuid",                   // 条目唯一 id
      "enabled": true,                // 该条目勾选状态
      "bundleId": "com.zhiliaoapp.musically",
      "appName": "settings",            // 仅 UI 展示
      "module": "MainModule",      // dyld 镜像名子串
      "start": "0x27A1F4E0",          // 相对模块基址偏移(hex 字符串)
      "end": "0x27A1F4F0",            // 同上,执行到此即停(不含)
      "count": 1,                     // trace 次数,之后透传
      "moduleOnly": true,             // 1=只记录模块内指令
      "delaySecs": 10,                // 本条目延迟多少秒装 hook
      "logMask": 1,                   // LOG_INST=1 MEM=2 REGS=4 BRANCH=8 VREG=16 位或
      "watches": [
        { "module": "ModuleName", "offset": "0x27A1F4E8",
          "reg": "x0", "action": "cstr", "size": 0, "label": "url" }
      ]
    }
  ]
}
```

**地址是相对模块基址的偏移**,和 Frida `module_base.add(x)` 一致 —— 不是绝对 VA,不要加 slide。引擎用 `_dyld_get_image_header` 取运行时基址(已含 slide)。

## 6.5 导出 / 导入

- **导出**(trace 条目左滑「导出」):把该 item(含 watches)包成 `{"version":1,"item":{...}}` 写到 **App 沙盒 Documents**(`ConfigStore exportDir`,运行时探测)。文件名 `<appName净化><年月日时分>.json`(如 `Demo202608191647.json`)。成功弹框显示**实际落地完整路径**。
- **取出**:App 的 Info.plist 开了 `UIFileSharingEnabled`+`LSSupportsOpeningDocumentsInPlace`,用户用 Finder 连手机 → 文件共享 → QBDI Tracer 拖出,不依赖越狱工具。
- **导入**(左上角 + → 导入 Tracer):两种 —— 「从文件导入」(`ImportVC` 列 exportDir 里的 .json 点选)、「粘贴 JSON」(输入框)。都做校验:**解析失败或缺 module/start/end → 弹"配置格式无效"并中止**;通过则**重生 id、enabled=YES** 再加入 items,避免与现有条目冲突。
- **兼容**:导入既接受 `{version,item}` 包装,也接受裸 item。
- **系统级 app 沙盒风险**:控制 App 装在 `/Applications`(系统级),`NSHomeDirectory()`/Documents 是否是标准可共享沙盒**待真机确认**;`exportDir` 有回退逻辑,且落地路径始终显示给用户(不猜)。

## 7. schema 一致性(维护重点)

控制 App(`GUI/src/ConfigStore.m` 的 `newItem`)和引擎(`Engine/src/engine.m` 的解析)**必须用同一套字段名**。改任何字段,两边都要改。这是本项目最容易出 bug 的地方 —— 详见 [HANDOFF.md](HANDOFF.md)。
