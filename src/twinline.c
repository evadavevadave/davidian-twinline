/* SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 Davidian */
/* Davidian Twinline, LV2 build: the LV2 entry points around the shared DSP in dsp.h. */
#include "lv2_abi.h"
#include "dsp.h"

static LV2_Handle instantiate(const LV2_Descriptor *d, double rate,
                              const char *path, const LV2_Feature *const *feat)
{
    (void)d; (void)path; (void)feat;
    return tw_new(rate);
}

static void connect_port(LV2_Handle h, uint32_t port, void *data)
{
    tw_connect((TwDsp *)h, port, data);
}

static void activate(LV2_Handle h) { tw_activate((TwDsp *)h); }
static void run(LV2_Handle h, uint32_t n) { tw_run((TwDsp *)h, n); }
static void deactivate(LV2_Handle h) { (void)h; }
static void cleanup(LV2_Handle h) { free(h); }
static const void *extension_data(const char *uri) { (void)uri; return NULL; }

static const LV2_Descriptor descriptor = {
    DT_URI, instantiate, connect_port, activate, run,
    deactivate, cleanup, extension_data
};

LV2_EXPORT const LV2_Descriptor *lv2_descriptor(uint32_t index)
{
    return index == 0 ? &descriptor : NULL;
}
