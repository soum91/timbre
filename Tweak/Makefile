TARGET := iphone:clang:latest:16.0
ARCHS := arm64 arm64e
THEOS_PACKAGE_SCHEME := rootless
INSTALL_TARGET_PROCESSES := mediaserverd
include $(THEOS)/makefiles/common.mk
TWEAK_NAME = TimbreAudio
TimbreAudio_FILES = Tweak.mm ../NativeDSP/TimbreDSP.cpp
TimbreAudio_CFLAGS = -I../NativeDSP
TimbreAudio_CCFLAGS = -std=c++17 -fno-exceptions
TimbreAudio_FRAMEWORKS = AudioToolbox
TimbreAudio_LIBRARIES = substrate
include $(THEOS_MAKE_PATH)/tweak.mk
