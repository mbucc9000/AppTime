TARGET = iphone:clang:6.1:6.0
ARCHS = armv7

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = AppTimePrefs
AppTimePrefs_FILES = ATRootListController.m
AppTimePrefs_INSTALL_PATH = /Library/PreferenceBundles
AppTimePrefs_FRAMEWORKS = UIKit Foundation CoreGraphics
AppTimePrefs_CFLAGS = -fobjc-arc

# Link Preferences if the SDK ships it; otherwise let dyld resolve PSListController/PSSpecifier
# at load time (Settings already has Preferences.framework loaded).
ifneq ($(wildcard $(THEOS)/sdks/iPhoneOS6.1.sdk/System/Library/PrivateFrameworks/Preferences.framework),)
AppTimePrefs_PRIVATE_FRAMEWORKS = Preferences
else
AppTimePrefs_LDFLAGS = -Wl,-undefined,dynamic_lookup
endif

include $(THEOS)/makefiles/bundle.mk

internal-stage::
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences$(ECHO_END)
	$(ECHO_NOTHING)cp entry.plist $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/AppTime.plist$(ECHO_END)
