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
TimbreControl_RESOURCE_FILES = TimbreControl/Info.plist $(wildcard TimbreControl/Icons/*.png)
TimbreControl_CODESIGN_FLAGS = -STimbreControl/entitlements.plist
TimbreControl_FRAMEWORKS = UIKit Foundation
TimbreControl_CFLAGS = -fobjc-arc
include $(THEOS_MAKE_PATH)/application.mk

TOOL_NAME = timbrectl
timbrectl_FILES = Helper/main.c
timbrectl_INSTALL_PATH = /usr/libexec
timbrectl_CODESIGN_FLAGS = -SHelper/entitlements.plist
include $(THEOS_MAKE_PATH)/tool.mk
