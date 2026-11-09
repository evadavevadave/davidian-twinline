# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Davidian
# Linux / BSD / macOS / MinGW build of twinline.lv2 (plugin + GUI).
# Windows with Visual Studio: use build.bat instead.
#
#   make            build the bundle in build/twinline.lv2
#   make test       build and run the offline DSP test and the panel render
#   make install    copy the bundle to the per-user LV2 folder
#   make dist       zip the bundle with the docs into build/dist/

VERSION ?= dev
UNAME   := $(shell uname -s)
UNAME_M := $(shell uname -m)

CC      ?= cc
OPT     ?= -O2
WARN    ?= -Wall -Wextra
CSTD    := -std=c99 -D_DEFAULT_SOURCE
COMMON  := $(OPT) $(WARN) -fno-math-errno -fvisibility=hidden

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
else ifneq (,$(findstring MINGW,$(UNAME)))
  PLATFORM    := windows-x64
  LIB_EXT     := .dll
  SHARED      := -shared -static-libgcc
  UI_CLASS    := ui:WindowsUI
  UI_LANG     := $(CSTD)
  UI_LIBS     := -luser32 -lgdi32
  LV2DIR      ?= $(APPDATA)/LV2
  DL_LIBS     :=
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
endif

BUNDLE  := build/twinline.lv2
DISTDIR := build/dist
DISTNAME:= davidian-twinline-$(VERSION)-$(PLATFORM)

PLUGIN  := $(BUNDLE)/twinline$(LIB_EXT)
UI      := $(BUNDLE)/twinline_ui$(LIB_EXT)

all: $(PLUGIN) $(UI) $(BUNDLE)/manifest.ttl $(BUNDLE)/twinline.ttl

$(BUNDLE) build-test $(DISTDIR):
	mkdir -p $@

$(PLUGIN): src/twinline.c src/lv2_abi.h src/ports.h | $(BUNDLE)
	$(CC) $(COMMON) $(CSTD) $(CFLAGS) $< -o $@ $(SHARED) $(LDFLAGS) -lm

$(UI): src/ui/ui_lv2.c src/ui/*.h src/ports.h src/lv2_abi.h | $(BUNDLE)
	$(CC) $(COMMON) $(UI_LANG) $(CFLAGS) $< -o $@ $(SHARED) $(LDFLAGS) $(UI_LIBS) -lm

$(BUNDLE)/manifest.ttl: bundle/manifest.ttl.in | $(BUNDLE)
	sed -e 's/@LIB_EXT@/$(LIB_EXT)/g' -e 's/@UI_CLASS@/$(UI_CLASS)/g' $< > $@

$(BUNDLE)/twinline.ttl: bundle/twinline.ttl | $(BUNDLE)
	cp $< $@

# Offline tests (native architecture only, so they run on the build machine).
NATIVE := $(OPT) $(WARN) -fno-math-errno $(CSTD)

test: all build-test/test_host build-test/ui_render
	./build-test/test_host $(PLUGIN)
	./build-test/ui_render build-test/panel.bmp

build-test/test_host: tests/test_host.c | build-test
	$(CC) $(NATIVE) $< -o $@ $(DL_LIBS) -lm

build-test/ui_render: tests/ui_render.c src/ui/*.h | build-test
	$(CC) $(NATIVE) $< -o $@ -lm

install: all
	mkdir -p "$(LV2DIR)"
	rm -rf "$(LV2DIR)/twinline.lv2"
	cp -R $(BUNDLE) "$(LV2DIR)/"

dist: all | $(DISTDIR)
	rm -rf $(DISTDIR)/$(DISTNAME) $(DISTDIR)/$(DISTNAME).zip
	mkdir -p $(DISTDIR)/$(DISTNAME)
	cp -R $(BUNDLE) README.md LICENSE LICENSE-LV2 $(DISTDIR)/$(DISTNAME)/
	cd $(DISTDIR) && zip -qr $(DISTNAME).zip $(DISTNAME)
	@echo "Packaged $(DISTDIR)/$(DISTNAME).zip"

clean:
	rm -rf build build-test

.PHONY: all test install dist clean
