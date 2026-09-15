TARGET := iphone:clang:latest:15.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

# 依赖检查:QBDI/Dobby 静态库必须先由 scripts/build_deps_ios.sh 生成(或从 Release 解压)。
# 缺失时立即报错,避免编译到链接阶段才失败、报错难懂。
ifeq ($(wildcard $(THEOS_PROJECT_DIR)/Engine/lib/arm64/libQBDI.a),)
$(error 缺少 QBDI/Dobby 依赖: Engine/lib/arm64/libQBDI.a 不存在。请先运行 ./scripts/build_deps_ios.sh, 或从 GitHub Release 下载预编译 deps 解压到 Engine/lib 与 Engine/include)
endif

TWEAK_NAME = TracerEngine

TracerEngine_FILES = Tweak.x src/engine.m src/tramp.c src/qbdi_trace.c
TracerEngine_CFLAGS = -fobjc-arc -Wno-unused-function -Wno-unused-parameter \
                      -I$(THEOS_PROJECT_DIR)/Engine/include \
                      -I$(THEOS_PROJECT_DIR)/Engine/src
# 项目内本地静态库(build_deps_ios.sh 生成);QBDI 是 C++,需要 -lc++
TracerEngine_LDFLAGS = -L$(THEOS_PROJECT_DIR)/Engine/lib/arm64 -ldobby -lQBDI -lc++
TracerEngine_FRAMEWORKS = Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
