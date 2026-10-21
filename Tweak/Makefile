TARGET := iphone:clang:latest:16.0
ARCHS := arm64
THEOS_PACKAGE_SCHEME := rootless
INSTALL_TARGET_PROCESSES := mediaserverd audiomxd
include $(THEOS)/makefiles/common.mk
TWEAK_NAME = TimbreAudio
TimbreAudio_FILES = Tweak.mm ../NativeDSP/TimbreDSP.cpp
TimbreAudio_CCFLAGS = -std=c++17 -fexceptions
TimbreAudio_FRAMEWORKS = AudioToolbox Foundation
TimbreAudio_LIBRARIES = substrate
include $(THEOS_MAKE_PATH)/tweak.mk

APPLICATION_NAME = TimbreControl
TimbreControl_FILES = TimbreControl/main.m
TimbreControl_FRAMEWORKS = UIKit Foundation
TimbreControl_CFLAGS = -fobjc-arc
include $(THEOS_MAKE_PATH)/application.mk
