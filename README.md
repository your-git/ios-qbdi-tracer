# ios-qbdi-tracer

> ✅ **实测可用**:Mac M4(编译) · iPhone 8 / iOS 16.7.10(运行)

带图形界面的 iOS 指令级 tracer:主屏一个**控制 App** 管理 trace 配置,一个**全量注入的引擎 tweak** 在目标进程里用 Dobby + QBDI 执行 trace。二者打包成**一个 deb**(Sileo 可装)。

## 能做什么

主界面底部分 **Trace / Hook** 两页,左上角「更多」里有帮助、设置和页面切换。

**Trace(只读记录)**

- 在手机上直接:选目标 App → 填模块名/起始地址/结束地址/延迟 → 加监视点(读字符串/整数/ObjC 对象/hexdump,取址支持 `x0-0x110`、`[[x0+8]+0x10]-4` 这类多级指针表达式)→ 保存
- 从 `模块基址+起始地址` 开始逐条指令 trace,直到 `模块基址+结束地址`,落盘到 `<日志根目录>/trace-logs/trace_<年月日时分>.log`
- trace 条目列表:右滑启停、左滑命名/导出/复制/删除、点击编辑
- 一个总开关控制整个插件是否工作(Trace 和 Hook 共用)

**Hook(真实改数据)**

- 用 Dobby 在目标地址真实改写目标进程的寄存器/内存(区别于 Trace 的只读),续跑后一直有效
- 选目标 App → 填模块名/目标地址 → 添加「修改数据」功能:寄存器或取址表达式 + 修改类型(字节/字符串/数值,数值选 8/16/32/64 位)+ 修改内容
- 只读内存自动 `vm_protect` 提权再写;命中日志落盘到 `<日志根目录>/hook-logs/hook_<年月日时分>.log`

**其它**

- 日志根目录、导入导出根目录都可在「更多 → 设置」里配置
- 导入页底部 Trace / Hook 分页,选错分页会按文件真实类型自动分流

## 文档索引

| 文档 | 用途 |
|---|---|
| [docs/DESIGN.md](docs/DESIGN.md) | **设计思路** —— 架构、两进程模型、引擎原理、为什么这么设计。**新会话先读这个** |
| [docs/BUILD.md](docs/BUILD.md) | **编译文档** —— 依赖构建、make package、安装、常见构建错误 |
| [docs/HANDOFF.md](docs/HANDOFF.md) | **交接维护** —— 每个文件干什么、常见修改任务怎么做、已知限制、未验证项 |

## 前提

- macOS + **完整 Xcode（含 iOS SDK）**，打开 Xcode 完成首次启动；仅 Command Line Tools 不够
- 其余工具（git / cmake / ninja / python3 / ldid / xz / Theos）可由统一脚本检查并安装
- 安装运行需要越狱设备(arm64,A7~A11 / iOS 15+)，编译打包无需连接手机
- 完整前置工具表见 [docs/BUILD.md](docs/BUILD.md#前置工具)

## 快速开始

```sh
# 1. 在工程根目录执行：安装缺失工具 + 下载编译官方依赖 + 生成两个 deb
./scripts/setup_and_build.sh --release

# 2. 安装:按你的越狱类型选对应的 deb(见下方"装哪个包")
#    scp packages/对应架构.deb 到设备,用 Sileo / dpkg -i 安装
```

Homebrew 首次安装可能提示输入管理员密码；不要用 `sudo` 运行整个脚本。
Theos 优先复用 `$THEOS`，未设置时使用 `~/theos`。依赖齐备后重复运行会复用，不重复下载编译。
QBDI / Dobby 从各自官方 GitHub 仓库获取，与本项目的 GitHub Release 无关。

```sh
./scripts/setup_and_build.sh --check       # 只检测，不安装、不编译
./scripts/setup_and_build.sh --setup-only  # 只安装工具和 Theos
./scripts/setup_and_build.sh               # 准备环境并生成默认双包
```

装完主屏出现 **QBDI Tracer** 图标。详见 [docs/BUILD.md](docs/BUILD.md)。

## ⚠️ 装哪个包(rootful / rootless 别装错)

**这是最容易踩的坑**:iOS 越狱分两种,dpkg 架构不同,装错会直接报错:

```
dpkg: error processing archive ... (--install):
 package architecture (iphoneos-arm) does not match system (iphoneos-arm64)
```

按你的越狱类型选对应的包:

| 越狱类型 | 代表工具 | dpkg 架构 | 装这个 deb |
|---|---|---|---|
| **rootful**(传统) | unc0ver / checkra1n / Taurine | `iphoneos-arm` | `*_iphoneos-arm.deb` |
| **rootless** | Dopamine / palera1n rootless | `iphoneos-arm64` | `*_iphoneos-arm64.deb` |

> 💡 **怎么判断自己是哪种**:设备上看有没有 `/var/jb` 目录——有就是 rootless,装 `arm64` 那个;没有就是 rootful,装 `arm` 那个。
> (注意:`arch` 命令显示的 `arm64` 是 **CPU 架构**,rootful/rootless 都是 arm64 CPU,**不能**用它来区分。)

`build_debs.sh` 会一次产出两个包,发布时两个都放上去,让用户各取所需。若只想单独出某一种:

```sh
# 只出 rootful
make package
# 只出 rootless(切换后务必 make clean,否则混用中间产物)
make clean && THEOS_PACKAGE_SCHEME=rootless make package
```

## 现状

- ✅ 聚合工程编译链路打通,deb 结构正确(App + dylib + Info.plist)
- ✅ **已真机验证**:Mac M4 编译打包,iPhone 8 / iOS 16.7.10 上运行
- ℹ️ 其它设备/iOS 版本未逐一验证,arm64e(A12+)仍未支持 —— 见 [docs/HANDOFF.md](docs/HANDOFF.md) 的"已知限制"

## 依赖与许可

本项目集成 [QBDI](https://github.com/QBDI/QBDI)(Apache-2.0)和 [Dobby](https://github.com/jmpews/Dobby)(Apache-2.0)。
