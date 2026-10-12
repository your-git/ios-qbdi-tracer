# 编译文档

## 推荐：一条命令准备环境并打包

先安装**完整 Xcode**，打开它接受许可并完成首次启动（包括 iOS SDK / 组件）。
随后在工程根目录执行：

```sh
./scripts/setup_and_build.sh --release
```

统一入口依次检查 Xcode / iOS SDK、GitHub 网络、构建工具、Theos，以及项目依赖：

- 自动安装缺失的 Homebrew 工具：git、cmake、ninja、python（提供 python3）、ldid、xz。
- Homebrew 缺失时启动官方安装器，可能需要确认和管理员密码；不要 `sudo` 整个脚本。
- Theos 优先使用 `$THEOS`，未设置时使用 `~/theos`，缺失时从官方 GitHub 仓库递归克隆（包含子模块），使用已验证的 Xcode iOS SDK。
  已有完整安装直接复用；已有非空但不完整的目录会报错，需自行修复或指定新路径。
- 项目静态库 / 关键头文件齐备则复用；否则调用 `build_deps_ios.sh`，从
  `https://github.com/QBDI/QBDI`（dev-next）和 `https://github.com/jmpews/Dobby`（master）
  下载源码，在本地编译 iOS arm64 依赖，再调用 `build_debs.sh` 生成两种 deb。
- 任一步失败都会停止，不会继续打包。网络检查只代表 GitHub 首页可达，不能保证所有
  源码、子模块和依赖下载一定成功；实际下载失败时查看对应工具输出。
- 不自动安装 Xcode、不安装到手机。Xcode 未就绪时先给出指引；完成后重跑同一命令。

其它用法：

```sh
./scripts/setup_and_build.sh --check       # 只检测环境和网络；有缺失时返回非零
./scripts/setup_and_build.sh --setup-only  # 只准备工具和 Theos，不编译项目依赖
./scripts/setup_and_build.sh               # 默认双包；--release 开启发布模式
THEOS=/你的/theos ./scripts/setup_and_build.sh --release
```

脚本不会写入 shell 配置。默认 `~/theos` 每次都会自动找到；自定义路径请保留 `THEOS`
环境变量或每次显式传入。已有 Homebrew 但未加入 PATH 时，会查找 `/opt/homebrew` 和
`/usr/local`。Xcode 已安装在默认位置但 `xcode-select` 指向 CLT 时，只在本次运行中
设置 `DEVELOPER_DIR`，不修改系统设置；其它位置可显式指定：

```sh
DEVELOPER_DIR=/实际路径/Xcode.app/Contents/Developer ./scripts/setup_and_build.sh --release
```

`--check` 不安装、编译或修改文件；项目依赖尚未构建只显示提示，不算环境错误。
默认构建模式在网络不可用时，只有工具、Theos 和项目依赖全部齐备才能继续。

## 前置工具

下面是手动配置方式。底层 `build_deps_ios.sh` 仍只**检查**工具；自动安装请用上面的统一入口。

| 工具 | 检查命令 | 安装(macOS) | 用途 |
|---|---|---|---|
| 完整 Xcode | `xcrun --sdk iphoneos --show-sdk-path` | App Store / Apple Developer，完成首次启动 | iOS SDK / clang（仅 CLT 不够） |
| git | `which git` | 随 Xcode 附带，或 `brew install git` | clone QBDI/Dobby |
| cmake | `which cmake` | `brew install cmake` | 配置 QBDI/Dobby 构建 |
| ninja | `which ninja` | `brew install ninja` | 编 QBDI(见下方说明) |
| python3 | `which python3` | 随 Xcode 附带，或 `brew install python` | Dobby 构建脚本 |
| ldid / xz | `which ldid xz` | `brew install ldid xz` | Theos 签名 / 打包 |
| Theos | `echo $THEOS` | [theos 安装文档](https://theos.dev/docs/installation) | 打包 deb |

安装 / 真机测试另需越狱设备。默认安装地址为 `localhost:2222`，使用 USB 时需事先
配置 SSH 转发（如 `iproxy 2222 22`）；仅插入 USB 不会自动建立转发。网络安装可通过
make 命令行参数覆盖 `THEOS_DEVICE_IP=设备IP THEOS_DEVICE_PORT=22`。

```sh
export THEOS=/path/to/theos   # 指向你的 Theos 安装目录
```

## 一、构建依赖(QBDI + Dobby,只做一次)

两种方式二选一:

**方式 A — 下载预编译(推荐,秒级)**

从项目 GitHub Release 下载 `deps-arm64-*.tar.gz`,解压到工程根目录,得到:
```
Engine/lib/arm64/{libQBDI.a, libdobby.a}
Engine/include/{QBDI.h, QBDI/, dobby.h, ...}
```

**方式 B — 自己编译(约 20-40 分钟)**

```sh
./scripts/build_deps_ios.sh
```

脚本做的事:
- 检查前置工具(缺失即报错)
- 在本工程 `third_party/` 里 clone 并编译 **QBDI**(arm64)和 **Dobby**(arm64)
- 把 `libQBDI.a` / `libdobby.a` 装进 `Engine/lib/arm64/`,头文件装进 `Engine/include/`

> **为什么 QBDI 必须用 ninja**:QBDI 自带静态 LLVM,LLVM 的 tablegen 有跨目录依赖,CMake 的 Makefiles 生成器处理不了,只有 Ninja 生成器能正确编译。所以 `cmake -G Ninja` + `ninja` 是硬要求。

> `Engine/lib/` 和 `Engine/include/` 已被 `.gitignore` 忽略(体积大,可重新生成/下载)。
> 若 `make package` 报"缺少 QBDI/Dobby 依赖",就是这步没做。

## 二、编译打包

**推荐:一键出 rootful + rootless 两个包**

```sh
export THEOS=/你的/theos/目录
./scripts/build_debs.sh            # debug 版
./scripts/build_debs.sh --release  # 发布版(去符号)
```

脚本会用同一个 `YYMMDDHHMM` 构建时间作为包版本，依次构建两种架构的 deb 各一个:
- `packages/com.snk.qbditracer_年月日时分_iphoneos-arm.deb`   —— **rootful**(传统越狱)
- `packages/com.snk.qbditracer_年月日时分_iphoneos-arm64.deb` —— **rootless**(Dopamine / palera1n)

打包暂存使用系统 `/tmp`，结束或失败后自动清理，最终 deb 仍在工程 `packages/`。
这可避免 exFAT 外置盘不支持 Unix 权限导致 `control directory has bad permissions 700`。
暂存文件还会清除 `._*` 并补齐读取 / 目录遍历权限；源文件不受影响。

例如 `2026-09-16 13:52` 会生成版本 `2609161352`。

> ⚠️ **rootful / rootless 装错会报架构不匹配**(`package architecture ... does not match system`)。
> 两种越狱怎么区分、装哪个包,见 [README 的"装哪个包"章节](../README.md#-装哪个包rootful--rootless-别装错)。

这是 Theos **aggregate 工程**(根 `Makefile` 的 `SUBPROJECTS = Engine GUI`),每个 deb 都含:
1. `Engine/` → `TracerEngine.dylib`(tweak)
2. `GUI/` → `TracerGUI.app`(控制 App)

---

**只想单独出某一种**(不用脚本时):

```sh
# rootful
make package

# rootless(切换 scheme 后务必 make clean,否则混用上次的中间产物)
make clean && THEOS_PACKAGE_SCHEME=rootless make package

# 发布版加 FINALPACKAGE=1(去 +debug 后缀、去符号)
make package FINALPACKAGE=1
```

## 三、安装

```sh
make install          # 设备 USB 连接,自动装
# 或
scp packages/*.deb root@设备IP:/tmp/
# 设备上:用 Sileo「安装本地 deb」,或 dpkg -i /tmp/xxx.deb
```

装完主屏出现 **QBDI Tracer** 图标。若没出现:设备上 `uicache -a` 或 respring。

> **⚠️ 重装不覆盖的坑**:dpkg/Sileo 在**包名相同**时经常不覆盖更新,导致"改了代码重编,设备上却没变化"。可靠做法是**先卸载再装**:
> ```sh
> dpkg -r com.snk.qbditracer                 # 先卸载
> dpkg -i /tmp/新包.deb && uicache -a        # 再装
> ```
> 或每次改动后升 `control` 里的 `Version`,让 dpkg 识别为更新。
> 排查"改了没生效"的完整套路见 [HANDOFF.md](HANDOFF.md#验证改动是否真的生效排查改了没变)。

## 四、验证是否装对

```sh
# deb 里应有这三样(macOS 上查看):
DEB=$(ls -t packages/*.deb | head -1)
TMP=$(mktemp -d); cp "$DEB" "$TMP/p.deb"; (cd "$TMP" && ar x p.deb && tar tf data.tar.* | grep -iE 'TracerGUI.app|TracerEngine')
# 期望:
#   Applications/TracerGUI.app/TracerGUI
#   Applications/TracerGUI.app/Info.plist
#   Library/MobileSubstrate/DynamicLibraries/TracerEngine.dylib
#   Library/MobileSubstrate/DynamicLibraries/TracerEngine.plist
```

## 五、单独语法检查(改代码后快速自检,不打包)

```sh
# 引擎 C/ObjC
INC=Engine/include; SDK=$(xcrun --sdk iphoneos --show-sdk-path)
clang -arch arm64 -std=c11 -fsyntax-only -I"$INC" -IEngine/src Engine/src/qbdi_trace.c
clang -arch arm64 -std=c11 -fsyntax-only -I"$INC" -IEngine/src Engine/src/tramp.c
clang -arch arm64 -fobjc-arc -fsyntax-only -isysroot "$SDK" -I"$INC" -IEngine/src Engine/src/engine.m

# GUI(会有 iOS 26 deprecation 警告,非错误,可忽略)
for f in GUI/entry.m GUI/src/*.m; do
  clang -arch arm64 -fobjc-arc -fsyntax-only -isysroot "$SDK" -IGUI/src "$f"
done
```

## 常见构建错误(本项目踩过的)

| 报错 | 原因 / 修法 |
|---|---|
| `._TracerEngine.plist: Property List error` | 外置磁盘上的 AppleDouble 元数据被误当成 plist；根 Makefile 的 `after-stage` 会在打包前清除暂存目录中的 `._*`，不改源文件 |
| `'engine.h' file not found` / `'AppDelegate.h' file not found` | 子工程 CFLAGS 的 include 路径写错。`$(THEOS_PROJECT_DIR)` 指**聚合根目录**,不是子目录 → 要写 `$(THEOS_PROJECT_DIR)/Engine/src`、`.../GUI/src` |
| 图标不出现 / app 装了但打不开 | Info.plist 没进 bundle。App 的 Info.plist 必须放 `GUI/Resources/Info.plist`(Theos 约定从 `Resources/` 拷),不能放 `GUI/Info.plist` |
| `'QBDI/Config.h' file not found` | QBDI 生成头没拷全。`build_deps_ios.sh` 会拷 `build-ios/include/` 和 `include-static/Config.h`;若手动搞依赖注意这几个是**构建时生成**的 |
| `缺少 QBDI/Dobby 依赖: Engine/lib/arm64/libQBDI.a 不存在` | 忘跑 `./scripts/build_deps_ios.sh` 或忘从 Release 下载预编译 deps。Makefile 主动检查依赖,缺失时直接报错 |
| `Building for iOS 9.0 ... can't produce arm64e` 警告 | 无害。只构建 arm64,arm64e 那条警告可忽略 |
| `ld: warning: -multiply_defined is obsolete` | Theos 固有警告,无害 |
| iOS 26 `mainScreen/initWithFrame/UIBarButtonItemStyleDone deprecated` | 只是 deprecation 警告。部署目标 15.0 这些 API 都在,能正常运行 |
| 改了代码/UI,设备上没变化 | 多半是**新包没装上**(dpkg 同包名不覆盖),不是代码问题。先 `dpkg -r com.snk.qbditracer` 再装,或升 Version。验证套路见 HANDOFF.md |
| 安装报 `package architecture (iphoneos-arm) does not match system (iphoneos-arm64)` | 装错架构了。rootless 越狱要装 `_iphoneos-arm64.deb`,rootful 装 `_iphoneos-arm.deb`。用 `./scripts/build_debs.sh` 一键出两个。详见 [README](../README.md#-装哪个包rootful--rootless-别装错) |
| 二进制里 UTF-8 搜不到中文字符串 | **误报**。含中文的 `@"..."` 被编成 UTF-16 存 `__ustring` 段,不是 UTF-8。用 `kw.encode('utf-16-le')` 搜才对 |
