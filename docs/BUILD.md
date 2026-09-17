# 编译文档

## 前置工具

`build_deps_ios.sh` 只**检查**这些工具,缺少时报错并给出安装命令(不自动安装):

| 工具 | 检查命令 | 安装(macOS) | 用途 |
|---|---|---|---|
| Xcode CLT | `xcode-select -p` | `xcode-select --install` | iOS SDK / clang |
| git | `which git` | 随 CLT 附带 | clone QBDI/Dobby |
| cmake | `which cmake` | `brew install cmake` | 配置 QBDI/Dobby 构建 |
| ninja | `which ninja` | `brew install ninja` | 编 QBDI(见下方说明) |
| python3 | `which python3` | 随 CLT 附带 | Dobby 构建脚本 |
| Theos | `echo $THEOS` | [theos 安装文档](https://theos.dev/docs/installation) | 打包 deb |

另需:越狱设备,USB 连接,usbmuxd 转发到 `localhost:2222`(装/测试用)。

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
export THEOS=/Users/tk/Documents/tools/theos
./scripts/build_debs.sh            # debug 版
./scripts/build_debs.sh --release  # 发布版(去符号)
```

脚本会用同一个 `YYMMDDHHMM` 构建时间作为包版本，依次构建两种架构的 deb 各一个:
- `packages/com.snk.qbditracer_年月日时分_iphoneos-arm.deb`   —— **rootful**(传统越狱)
- `packages/com.snk.qbditracer_年月日时分_iphoneos-arm64.deb` —— **rootless**(Dopamine / palera1n)

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
