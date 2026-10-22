TARGET = iphone:clang:6.1:6.0
ARCHS = armv7

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AppTime
AppTime_FILES = Tweak.xm
AppTime_FRAMEWORKS = UIKit Foundation CoreGraphics
AppTime_CFLAGS = -fobjc-arc

include $(THEOS)/makefiles/tweak.mk

SUBPROJECTS += apptimeprefs
include $(THEOS)/makefiles/aggregate.mk

after-install::
	install.exec "killall -9 SpringBoard"
