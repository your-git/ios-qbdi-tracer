# qbdi-tracer-gui —— 聚合工程:一个 deb 同时装
#   /Applications/TracerGUI.app   (控制 App)
#   DynamicLibraries/TracerEngine (引擎 tweak,全量注入)
#
# 前置:先跑一次 ./scripts/build_deps_ios.sh(装 QBDI/Dobby 到 Engine/lib、Engine/include)
# 常用:
#   make package        # 出单 deb
#   make install        # 装到设备
# rootless:export THEOS_PACKAGE_SCHEME=rootless

THEOS_DEVICE_IP = localhost
THEOS_DEVICE_PORT = 2222
DEBUG = 0
ARCHS = arm64
include $(THEOS)/makefiles/common.mk

SUBPROJECTS = Engine GUI

include $(THEOS)/makefiles/aggregate.mk
