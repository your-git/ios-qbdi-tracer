TARGET := iphone:clang:latest:15.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = TracerGUI

TracerGUI_FILES = entry.m src/AppDelegate.m src/ConfigStore.m \
                  src/RootListVC.m src/AppPickerVC.m \
                  src/TraceEditVC.m src/WatchEditVC.m src/ImportVC.m
TracerGUI_FRAMEWORKS = UIKit Foundation
TracerGUI_CFLAGS = -fobjc-arc -I$(THEOS_PROJECT_DIR)/GUI/src
# LSApplicationWorkspace 等私有 API:越狱 App 直接用,无需额外链接
TracerGUI_CODESIGN_FLAGS = -Sentitlements.plist

include $(THEOS_MAKE_PATH)/application.mk
