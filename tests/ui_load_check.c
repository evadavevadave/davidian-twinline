/* SPDX-License-Identifier: GPL-3.0-or-later AND ISC
 * Copyright (C) 2026 Davidian
 * The LV2 interface declarations in this file follow the ISC-licensed LV2 headers;
 * see LICENSE-LV2 for their copyright and permission notice. */
/* Loads the built GUI library with dlopen, the way a Linux host does, opens it as a
 * top-level window, feeds it port values and runs its idle loop. Run it under a virtual
 * display (xvfb-run) on a machine without a screen.
 * Usage: ui_load_check <bundle folder> */
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

#include "../src/lv2_abi.h"
#include "../src/ports.h"

typedef void (*WriteFn)(void*, uint32_t, uint32_t, uint32_t, const void*);
typedef struct {
    const char* URI;
    void* (*instantiate)(const void*, const char*, const char*, WriteFn, void*, void**, const LV2_Feature* const*);
    void (*cleanup)(void*);
    void (*port_event)(void*, uint32_t, uint32_t, uint32_t, const void*);
    const void* (*extension_data)(const char*);
} UiDesc;
typedef struct { int (*idle)(void* ui); } IdleIface;

static int failures;

static void check(const char* what, int ok)
{
    printf("  [%s] %s\n", ok ? "PASS" : "FAIL", what);
    if (!ok)
        ++failures;
}

static void on_write(void* c, uint32_t p, uint32_t s, uint32_t f, const void* b)
{
    (void)c; (void)p; (void)s; (void)f; (void)b;
}

int main(int argc, char** argv)
{
    char path[1024];
    void* lib;
    const UiDesc* (*get)(uint32_t);
    const UiDesc* d;
    const IdleIface* idle;
    void* ui;
    void* widget = NULL;
    int i;
    static const float vals[PORT_COUNT] = { 6.0f, 0.75f, 1, 0, 0, 1, 1 };

    if (argc < 2) {
        printf("usage: ui_load_check <bundle folder>\n");
        return 2;
    }
    snprintf(path, sizeof path, "%s/twinline_ui.so", argv[1]);
    lib = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    check("GUI library loads", lib != NULL);
    if (!lib) {
        printf("  %s\n", dlerror());
        return 1;
    }
    *(void**)&get = dlsym(lib, "lv2ui_descriptor");
    check("exports lv2ui_descriptor", get != NULL);
    if (!get)
        return 1;
    d = get(0);
    check("descriptor has the GUI's URI", d && strcmp(d->URI, DT_UI_URI) == 0);
    check("refuses another plugin's URI",
          d->instantiate(d, "urn:other", argv[1], on_write, NULL, &widget, NULL) == NULL);
    ui = d->instantiate(d, DT_URI, argv[1], on_write, NULL, &widget, NULL);
    check("opens a top-level X11 window (no parent given)", ui != NULL && widget != NULL);
    if (!ui)
        return 1;
    for (i = 0; i < PORT_COUNT; ++i)
        if (i != PORT_IN && i != PORT_OUT)
            d->port_event(ui, (uint32_t)i, sizeof(float), 0, &vals[i]);
    idle = (const IdleIface*)d->extension_data("http://lv2plug.in/ns/extensions/ui#idleInterface");
    check("offers the idle interface", idle != NULL);
    if (idle) {
        int ok = 1;
        for (i = 0; i < 20; ++i)
            ok &= idle->idle(ui) == 0;
        check("idle runs and keeps the window open", ok);
    }
    d->cleanup(ui);
    check("cleanup returns", 1);
    dlclose(lib);
    printf(failures ? "\n%d FAILED\n" : "\nAll passed\n", failures);
    return failures ? 1 : 0;
}
