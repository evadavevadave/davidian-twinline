# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Davidian
# Linux / BSD / macOS / MinGW build of build/lv2/twinline.lv2 (plugin + GUI) and
# build/vst3/twinline.vst3, and on macOS also the Audio Unit, build/au/twinline.component.
# Windows with Visual Studio: use build.bat instead.
#
#   make            build the bundles in build/
#   make test       build and run the offline DSP test, the panel render and the VST3 check
#   make install    copy the bundles to the per-user plugin folders
#   make dist       zip the bundles with the docs into build/dist/

VERSION ?= dev
UNAME   := $(shell uname -s)
UNAME_M := $(shell uname -m)

CC      ?= cc
OPT     ?= -O2
WARN    ?= -Wall -Wextra
CSTD    := -std=c99 -D_DEFAULT_SOURCE
# The VST3 C API header needs C11.
CSTD11  := -std=c11 -D_DEFAULT_SOURCE
COMMON  := $(OPT) $(WARN) -fno-math-errno -fvisibility=hidden

VST3_BUNDLE := build/vst3/twinline.vst3
AU_BUNDLE   := build/au/twinline.component

ifeq ($(UNAME),Darwin)
  PLATFORM    := macos-universal
  LIB_EXT     := .dylib
  MACOS_MIN   ?= 10.13
  ARCH_FLAGS  ?= -arch arm64 -arch x86_64
  COMMON      += $(ARCH_FLAGS) -mmacosx-version-min=$(MACOS_MIN)
  SHARED      := -dynamiclib
  UI_CLASS    := ui:CocoaUI
  UI_LANG     := -x objective-c -fno-objc-arc
  UI_LIBS     := -framework Cocoa
  LV2DIR      ?= $(HOME)/Library/Audio/Plug-Ins/LV2
  DL_LIBS     :=
  VST3_BIN    := $(VST3_BUNDLE)/Contents/MacOS/twinline
  VST3_LANG   := -x objective-c -fno-objc-arc
  VST3_LINK   := -bundle
  VST3_LIBS   := -framework Cocoa
  VST3DIR     ?= $(HOME)/Library/Audio/Plug-Ins/VST3
  AUDIR       ?= $(HOME)/Library/Audio/Plug-Ins/Components
  EXTRA       := vst3 au
else ifneq (,$(findstring MINGW,$(UNAME)))
  PLATFORM    := windows-x64
  LIB_EXT     := .dll
  SHARED      := -shared -static-libgcc
  UI_CLASS    := ui:WindowsUI
  UI_LANG     := $(CSTD)
  UI_LIBS     := -luser32 -lgdi32
  LV2DIR      ?= $(APPDATA)/LV2
  DL_LIBS     :=
  VST3_BIN    := $(VST3_BUNDLE)/Contents/x86_64-win/twinline.vst3
  VST3_LANG   := $(CSTD11)
  VST3_LINK   := $(SHARED)
  VST3_LIBS   := -luser32 -lgdi32
  VST3DIR     ?= $(COMMONPROGRAMFILES)/VST3
  EXTRA       := vst3
else
  PLATFORM    := linux-$(subst aarch64,arm64,$(subst x86_64,x64,$(UNAME_M)))
  LIB_EXT     := .so
  COMMON      += -fPIC
  SHARED      := -shared -Wl,--no-undefined
  UI_CLASS    := ui:X11UI
  UI_LANG     := $(CSTD)
  UI_LIBS     := -lX11
  LV2DIR      ?= $(HOME)/.lv2
  DL_LIBS     := -ldl
  VST3_BIN    := $(VST3_BUNDLE)/Contents/$(UNAME_M)-linux/twinline.so
  VST3_LANG   := $(CSTD11)
  VST3_LINK   := $(SHARED)
  VST3_LIBS   := -lX11
  VST3DIR     ?= $(HOME)/.vst3
  EXTRA       := vst3
endif

# One folder per format, so LV2 tools scanning build/lv2 see only the LV2 bundle.
BUNDLE  := build/lv2/twinline.lv2
DISTDIR := build/dist
DISTNAME:= davidian-twinline-$(VERSION)-$(PLATFORM)

PLUGIN  := $(BUNDLE)/twinline$(LIB_EXT)
UI      := $(BUNDLE)/twinline_ui$(LIB_EXT)
DSP_SRC := src/dsp.h src/engine.h src/ports.h src/params.h

all: $(PLUGIN) $(UI) $(BUNDLE)/manifest.ttl $(BUNDLE)/twinline.ttl $(EXTRA)

$(BUNDLE) build-test $(DISTDIR):
	mkdir -p $@

$(PLUGIN): src/twinline.c src/dsp.h src/lv2_abi.h src/ports.h | $(BUNDLE)
	$(CC) $(COMMON) $(CSTD) $(CFLAGS) $< -o $@ $(SHARED) $(LDFLAGS) -lm

$(UI): src/ui/ui_lv2.c src/ui/*.h src/ports.h src/lv2_abi.h | $(BUNDLE)
	$(CC) $(COMMON) $(UI_LANG) $(CFLAGS) $< -o $@ $(SHARED) $(LDFLAGS) $(UI_LIBS) -lm

$(BUNDLE)/manifest.ttl: bundle/manifest.ttl.in | $(BUNDLE)
	sed -e 's/@LIB_EXT@/$(LIB_EXT)/g' -e 's/@UI_CLASS@/$(UI_CLASS)/g' $< > $@

$(BUNDLE)/twinline.ttl: bundle/twinline.ttl | $(BUNDLE)
	cp $< $@

# The VST3: one module with the engine, the parameters and (Windows, macOS) the same GUI.
vst3: $(VST3_BIN) $(VST3_BUNDLE)/Contents/Resources/LICENSE $(VST3_BUNDLE)/Contents/Resources/LICENSE-VST3.txt \
      $(if $(filter Darwin,$(UNAME)),$(VST3_BUNDLE)/Contents/Info.plist)

$(VST3_BIN): src/vst3/vst3.c src/vst3/vst3_c_api.h src/ui/*.h $(DSP_SRC)
	mkdir -p $(dir $@)
	$(CC) $(COMMON) $(VST3_LANG) $(CFLAGS) $< -o $@ $(VST3_LINK) $(LDFLAGS) $(VST3_LIBS) -lm

$(VST3_BUNDLE)/Contents/Info.plist: bundle/vst3/Info.plist
	mkdir -p $(dir $@)
	cp $< $@

$(VST3_BUNDLE)/Contents/Resources/LICENSE: LICENSE
	mkdir -p $(dir $@)
	cp $< $@

$(VST3_BUNDLE)/Contents/Resources/LICENSE-VST3.txt: src/vst3/LICENSE.txt
	mkdir -p $(dir $@)
	cp $< $@

# The Audio Unit (macOS): one bundle with the engine, the parameters and the same GUI.
AU_BIN  := $(AU_BUNDLE)/Contents/MacOS/twinline
AU_LIBS := -framework AudioToolbox -framework AudioUnit -framework CoreAudio -framework CoreFoundation -framework Cocoa

au: $(AU_BIN) $(AU_BUNDLE)/Contents/Info.plist $(AU_BUNDLE)/Contents/Resources/LICENSE

$(AU_BIN): src/au/au.m src/ui/*.h $(DSP_SRC)
	mkdir -p $(dir $@)
	$(CC) $(COMMON) -x objective-c -fno-objc-arc $(CFLAGS) $< -o $@ -bundle $(LDFLAGS) $(AU_LIBS) -lm

$(AU_BUNDLE)/Contents/Info.plist: bundle/au/Info.plist
	mkdir -p $(dir $@)
	cp $< $@

$(AU_BUNDLE)/Contents/Resources/LICENSE: LICENSE
	mkdir -p $(dir $@)
	cp $< $@

# Offline tests (native architecture only, so they run on the build machine).
NATIVE := $(OPT) $(WARN) -fno-math-errno $(CSTD)

test: all build-test/test_host build-test/ui_render build-test/vst3_check
	./build-test/test_host $(PLUGIN)
	./build-test/ui_render build-test/panel.bmp
	./build-test/vst3_check $(VST3_BUNDLE)

build-test/test_host: tests/test_host.c | build-test
	$(CC) $(NATIVE) $< -o $@ $(DL_LIBS) -lm

build-test/ui_render: tests/ui_render.c src/ui/*.h | build-test
	$(CC) $(NATIVE) $< -o $@ -lm

build-test/vst3_check: tests/vst3_check.c src/vst3/vst3_c_api.h src/params.h | build-test
	$(CC) $(OPT) $(WARN) $(CSTD11) $< -o $@ $(DL_LIBS) -lm

install: all
	mkdir -p "$(LV2DIR)" "$(VST3DIR)"
	rm -rf "$(LV2DIR)/twinline.lv2" "$(VST3DIR)/twinline.vst3"
	cp -R $(BUNDLE) "$(LV2DIR)/"
	cp -R $(VST3_BUNDLE) "$(VST3DIR)/"
ifeq ($(UNAME),Darwin)
	mkdir -p "$(AUDIR)"
	rm -rf "$(AUDIR)/twinline.component"
	cp -R $(AU_BUNDLE) "$(AUDIR)/"
endif

dist: all | $(DISTDIR)
	rm -rf $(DISTDIR)/$(DISTNAME) $(DISTDIR)/$(DISTNAME).zip
	mkdir -p $(DISTDIR)/$(DISTNAME)
	cp -R $(BUNDLE) $(VST3_BUNDLE) $(if $(filter Darwin,$(UNAME)),$(AU_BUNDLE)) \
	      README.md LICENSE LICENSE-LV2 $(DISTDIR)/$(DISTNAME)/
	cp src/vst3/LICENSE.txt $(DISTDIR)/$(DISTNAME)/LICENSE-VST3.txt
	cd $(DISTDIR) && zip -qry $(DISTNAME).zip $(DISTNAME)
	@echo "Packaged $(DISTDIR)/$(DISTNAME).zip"

clean:
	rm -rf build build-test

.PHONY: all vst3 au test install dist clean
