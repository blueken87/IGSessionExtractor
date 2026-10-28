export TARGET := iphone:clang:latest:15.0
export ARCHS := arm64 arm64e
export THEOS_PACKAGE_SCHEME := rootless

INSTALL_TARGET_PROCESSES := Instagram

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = IGSessionExtractor

IGSessionExtractor_FILES = Tweak.xm
IGSessionExtractor_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
IGSessionExtractor_FRAMEWORKS = Foundation UIKit

before-package::
	chmod 0755 layout/DEBIAN/* 2>/dev/null || true

include $(THEOS_MAKE_PATH)/tweak.mk
