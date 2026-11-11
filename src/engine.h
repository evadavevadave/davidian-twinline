/* SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 Davidian */
/* The engine the VST3 and AU wrappers drive: one or two copies of the mono pedal in
 * dsp.h with the same settings, so a stereo track gets the pedal on each side (a linked
 * pair, as with two pedals on one control set). The LV2 version uses dsp.h directly.
 *   engine_new(rate)                       NULL if out of memory
 *   engine_connect(e, port, &value)        point a control port at a float the caller owns
 *   engine_activate(e)                     clear the delay lines; call after connecting
 *   engine_process(e, in, out, nch, n)     nch = 1 or 2; a NULL input reads as silence
 *   engine_free(e) */
#ifndef ENGINE_H
#define ENGINE_H

#include "dsp.h"

#define MAX_CH 2
#define ENGINE_CHUNK 256

typedef struct {
    TwDsp* ch[MAX_CH];
    double rate;
} Engine;

static void engine_free(Engine* e)
{
    int c;
    if (!e)
        return;
    for (c = 0; c < MAX_CH; ++c)
        free(e->ch[c]);
    free(e);
}

static Engine* engine_new(double rate)
{
    Engine* e = (Engine*)calloc(1, sizeof(Engine));
    int c;
    if (!e)
        return NULL;
    e->rate = rate;
    for (c = 0; c < MAX_CH; ++c) {
        e->ch[c] = tw_new(rate);
        if (!e->ch[c]) {
            engine_free(e);
            return NULL;
        }
    }
    return e;
}

/* Control ports only; the audio buffers are passed to engine_process. */
static void engine_connect(Engine* e, uint32_t port, float* data)
{
    int c;
    if (port == PORT_IN || port == PORT_OUT)
        return;
    for (c = 0; c < MAX_CH; ++c)
        tw_connect(e->ch[c], port, data);
}

static void engine_activate(Engine* e)
{
    int c;
    for (c = 0; c < MAX_CH; ++c)
        tw_activate(e->ch[c]);
}

static void engine_process(Engine* e, const float* const* in, float* const* out, int nch, uint32_t n)
{
    static const float zeros[ENGINE_CHUNK] = { 0 };
    int c;
    if (nch > MAX_CH)
        nch = MAX_CH;
    for (c = 0; c < nch; ++c) {
        TwDsp* d = e->ch[c];
        if (!out[c])
            continue;
        if (in[c]) {
            /* In place is fine: the DSP reads each input sample before writing that output. */
            tw_connect(d, PORT_IN, (void*)in[c]);
            tw_connect(d, PORT_OUT, out[c]);
            tw_run(d, n);
        } else {
            uint32_t pos = 0;
            tw_connect(d, PORT_IN, (void*)zeros);
            while (pos < n) {
                const uint32_t k = n - pos < ENGINE_CHUNK ? n - pos : ENGINE_CHUNK;
                tw_connect(d, PORT_OUT, out[c] + pos);
                tw_run(d, k);
                pos += k;
            }
        }
    }
}

#endif
