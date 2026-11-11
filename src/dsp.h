/* SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 Davidian */
/*
 * Davidian Twinline DSP: a model of a BBD doubler, based on the circuit of a
 * classic 1970s double-tracking pedal. Shared by the LV2 build (twinline.c) and
 * the CLAP build (twinline_clap.c), which the VST3 and Audio Unit versions wrap.
 * No plugin API in here: the caller points the port pointers at its own floats.
 *
 * Signal path:
 *   in -> BS170 boost (Level) -+---------------------------------> Blend -> out
 *                              +-> pre LPF -> V3205 BBD -> post LPF -^
 *
 * Values taken from the layout:
 *   Clock:  CD4047 astable, f = 1/(4.4 R C), C = 100p, R = 100K, with
 *           47K + 6K8 switched in parallel by the delay switch.
 *           -> 22.7 kHz (90 ms) / 65.0 kHz (31.5 ms)
 *   BBD:    V3205, 4096 stages = 2048 clock periods of delay.
 *   Post:   Sallen-Key 33K/33K, 1n/470p -> 7 kHz, Q 0.73
 *           plus 33K/1n one-pole -> 4.8 kHz
 *   Pre:    4K7/4n7 -> 7.2 kHz (taken as a matching 7 kHz stage)
 *
 * Estimated, not derivable from a layout alone: boost range and clipping
 * headroom, the wet high-pass corner, and the Blend direction.
 */
#ifndef TWINLINE_DSP_H
#define TWINLINE_DSP_H

#include <math.h>
#include <stdint.h>
#include <stdlib.h>

#if defined(__SSE__) || defined(_M_X64) || defined(_M_IX86_FP) || defined(__x86_64__)
#    include <xmmintrin.h>
#    define FTZ_SSE 1
#endif

#include "ports.h"

#define PI 3.14159265358979323846

/* Flush denormals to zero during run(), so the filter tails can't slow the CPU down.
 * x86: MXCSR FTZ + DAZ. ARM64: FPCR.FZ. Elsewhere: no-op (the tail just decays normally). */
typedef uint64_t FpState;

static FpState fp_denormals_off(void)
{
#if defined(FTZ_SSE)
    const unsigned csr = _mm_getcsr();
    _mm_setcsr(csr | 0x8040);
    return csr;
#elif defined(__aarch64__) && (defined(__GNUC__) || defined(__clang__))
    uint64_t fpcr;
    __asm__ __volatile__("mrs %0, fpcr" : "=r"(fpcr));
    __asm__ __volatile__("msr fpcr, %0" : : "r"(fpcr | (1ull << 24)));
    return fpcr;
#else
    return 0;
#endif
}

static void fp_restore(FpState s)
{
#if defined(FTZ_SSE)
    _mm_setcsr((unsigned)s);
#elif defined(__aarch64__) && (defined(__GNUC__) || defined(__clang__))
    __asm__ __volatile__("msr fpcr, %0" : : "r"(s));
#else
    (void)s;
#endif
}

#define BBD_CLOCKS 2048              /* 4096 stages, two per clock period */
#define CLOCK_C 100e-12
#define CLOCK_R_LONG 100e3
#define CLOCK_R_SHORT (1.0 / (1.0 / 100e3 + 1.0 / (47e3 + 6.8e3)))

#define BOOST_HEADROOM 2.5           /* about +8 dBFS, assuming 0 dBFS = 1 V */
#define BOOST_ASYM 0.1
#define BBD_HEADROOM 1.2             /* BBD runs out of swing before the FET */
#define MAX_BOOST_DB 20.0

typedef struct { double b0, b1, b2, a1, a2, z1, z2; } Biquad;

static void bq_set(Biquad *f, double b0, double b1, double b2,
                   double a0, double a1, double a2)
{
    f->b0 = b0 / a0; f->b1 = b1 / a0; f->b2 = b2 / a0;
    f->a1 = a1 / a0; f->a2 = a2 / a0;
    f->z1 = f->z2 = 0.0;
}

static void bq_lowpass(Biquad *f, double fs, double fc, double q)
{
    double w = 2.0 * PI * fc / fs, c = cos(w), a = sin(w) / (2.0 * q);
    bq_set(f, (1.0 - c) / 2.0, 1.0 - c, (1.0 - c) / 2.0,
           1.0 + a, -2.0 * c, 1.0 - a);
}

static void bq_highpass(Biquad *f, double fs, double fc, double q)
{
    double w = 2.0 * PI * fc / fs, c = cos(w), a = sin(w) / (2.0 * q);
    bq_set(f, (1.0 + c) / 2.0, -(1.0 + c), (1.0 + c) / 2.0,
           1.0 + a, -2.0 * c, 1.0 - a);
}

static void bq_onepole_lp(Biquad *f, double fs, double fc)
{
    double k = tan(PI * fc / fs);
    bq_set(f, k, k, 0.0, 1.0 + k, k - 1.0, 0.0);
}

static double bq_run(Biquad *f, double x)
{
    double y = f->b0 * x + f->z1;
    f->z1 = f->b1 * x - f->a1 * y + f->z2;
    f->z2 = f->b2 * x - f->a2 * y;
    return y;
}

typedef struct {
    const float *port_level, *port_blend, *port_delay, *port_in;
    float *port_out;
    const float *port_on, *port_enabled;

    double fs;
    double fade;            /* 1 = effect in, 0 = bypassed */
    int os;                 /* oversampling factor for the BBD section */
    double fs_os;
    double smooth;          /* one-pole coefficient for the knobs */
    double level_gain, wet_mix;
    double boost_offset;

    Biquad dc_block, wet_hp, pre, post_sk, post_rc, dec1, dec2;

    double bbd[BBD_CLOCKS];
    int bbd_pos;
    double clock_phase;
    double hold;            /* current BBD output (zero-order hold) */
    double in_prev;         /* previous host-rate wet input */
    double pre_prev;        /* previous oversampled pre-filter output */
} TwDsp;

static double level_to_gain(double db)
{
    if (db < 0.0) db = 0.0;
    if (db > MAX_BOOST_DB) db = MAX_BOOST_DB;
    return pow(10.0, db / 20.0);
}

/* A10K: about 10% of the way through the track at noon. */
static double blend_to_wet(double p)
{
    if (p < 0.0) p = 0.0;
    if (p > 1.0) p = 1.0;
    return (pow(100.0, p) - 1.0) / 99.0;
}

/* On only when both the pedal's footswitch and the host's bypass say so. */
static double engaged(const TwDsp *p)
{
    const int on = !p->port_on || *p->port_on > 0.5f;
    const int enabled = !p->port_enabled || *p->port_enabled > 0.5f;
    return on && enabled ? 1.0 : 0.0;
}

static void reset_state(TwDsp *p)
{
    Biquad *f[7];
    int i;
    f[0] = &p->dc_block; f[1] = &p->wet_hp; f[2] = &p->pre;
    f[3] = &p->post_sk;  f[4] = &p->post_rc;
    f[5] = &p->dec1;     f[6] = &p->dec2;
    for (i = 0; i < 7; ++i) f[i]->z1 = f[i]->z2 = 0.0;
    for (i = 0; i < BBD_CLOCKS; ++i) p->bbd[i] = 0.0;
    p->bbd_pos = 0;
    p->clock_phase = 0.0;
    p->hold = p->in_prev = p->pre_prev = 0.0;
    /* Start at the knob values so the first block doesn't fade in. */
    p->level_gain = p->port_level ? level_to_gain(*p->port_level) : 1.0;
    p->wet_mix = p->port_blend ? blend_to_wet(*p->port_blend) : 0.0;
    p->fade = engaged(p);
}

static TwDsp *tw_new(double rate)
{
    TwDsp *p = (TwDsp *)calloc(1, sizeof(TwDsp));
    if (!p) return NULL;

    p->fs = rate;
    p->os = (int)ceil(170000.0 / rate);
    if (p->os < 1) p->os = 1;
    if (p->os > 8) p->os = 8;
    p->fs_os = rate * p->os;
    p->smooth = 1.0 - exp(-1.0 / (0.010 * rate));
    p->boost_offset = BOOST_HEADROOM * tanh(BOOST_ASYM / BOOST_HEADROOM);

    bq_highpass(&p->dc_block, rate, 5.0, 0.7071);
    bq_highpass(&p->wet_hp, rate, 100.0, 0.7071);
    bq_lowpass(&p->pre, p->fs_os, 7000.0, 0.73);
    bq_lowpass(&p->post_sk, p->fs_os, 7000.0, 0.73);
    bq_onepole_lp(&p->post_rc, p->fs_os, 4800.0);
    /* 4th-order Butterworth to come back down to the host rate. */
    bq_lowpass(&p->dec1, p->fs_os, 0.45 * rate, 0.5412);
    bq_lowpass(&p->dec2, p->fs_os, 0.45 * rate, 1.3066);
    return p;
}

static void tw_connect(TwDsp *p, uint32_t port, void *data)
{
    switch (port) {
    case PORT_LEVEL: p->port_level = (const float *)data; break;
    case PORT_BLEND: p->port_blend = (const float *)data; break;
    case PORT_DELAY: p->port_delay = (const float *)data; break;
    case PORT_IN:    p->port_in = (const float *)data; break;
    case PORT_OUT:   p->port_out = (float *)data; break;
    case PORT_ON:    p->port_on = (const float *)data; break;
    case PORT_ENABLED: p->port_enabled = (const float *)data; break;
    }
}

/* Clears the delay line and filters, and jumps the smoothed controls to the port values. */
static void tw_activate(TwDsp *p) { reset_state(p); }

static void tw_run(TwDsp *p, uint32_t n)
{
    const FpState fp = fp_denormals_off();
    const double target_gain = level_to_gain(*p->port_level);
    const double target_wet = blend_to_wet(*p->port_blend);
    const double target_fade = engaged(p);
    /* Changing the clock mid-note bends the pitch, as on the real pedal. */
    const double r = (*p->port_delay >= 0.5f) ? CLOCK_R_LONG : CLOCK_R_SHORT;
    const double phase_inc = (1.0 / (4.4 * r * CLOCK_C)) / p->fs_os;
    const int os = p->os;
    uint32_t i;

    for (i = 0; i < n; ++i) {
        double x, wet_in, wet = 0.0;
        int k;

        p->level_gain += p->smooth * (target_gain - p->level_gain);
        p->wet_mix += p->smooth * (target_wet - p->wet_mix);

        /* BS170 boost: soft, slightly asymmetric limit. */
        x = (double)p->port_in[i] * p->level_gain;
        x = BOOST_HEADROOM * tanh((x + BOOST_ASYM) / BOOST_HEADROOM)
            - p->boost_offset;
        x = bq_run(&p->dc_block, x);

        wet_in = bq_run(&p->wet_hp, x);

        for (k = 1; k <= os; ++k) {
            const double up = p->in_prev
                + (wet_in - p->in_prev) * (double)k / (double)os;
            double in_f = bq_run(&p->pre, up);
            double y = p->hold;

            in_f = BBD_HEADROOM * tanh(in_f / BBD_HEADROOM);

            p->clock_phase += phase_inc;
            if (p->clock_phase >= 1.0) {
                /* Fraction of this tick after the clock edge. */
                const double frac = (p->clock_phase - 1.0) / phase_inc;
                const double sampled = in_f + (p->pre_prev - in_f) * frac;
                const double out = p->bbd[p->bbd_pos];

                p->clock_phase -= 1.0;
                p->bbd[p->bbd_pos] = sampled;
                if (++p->bbd_pos == BBD_CLOCKS) p->bbd_pos = 0;

                /* Blend the edge across the tick to reduce timing jitter. */
                y = p->hold + (out - p->hold) * frac;
                p->hold = out;
            }
            p->pre_prev = in_f;

            y = bq_run(&p->post_sk, y);
            y = bq_run(&p->post_rc, y);
            if (os > 1) {
                y = bq_run(&p->dec1, y);
                y = bq_run(&p->dec2, y);
            }
            wet = y;
        }
        p->in_prev = wet_in;

        /* The circuit keeps running while bypassed, so switching back in is seamless. */
        p->fade += p->smooth * (target_fade - p->fade);
        p->port_out[i] = (float)((double)p->port_in[i] * (1.0 - p->fade)
            + (x * (1.0 - p->wet_mix) + wet * p->wet_mix) * p->fade);
    }

    fp_restore(fp);
}

#endif /* TWINLINE_DSP_H */
