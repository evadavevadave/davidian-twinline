/* SPDX-License-Identifier: GPL-3.0-or-later AND ISC
 * Copyright (C) 2026 Davidian
 * The LV2 interface declarations in this file follow the ISC-licensed LV2 headers;
 * see LICENSE-LV2 for their copyright and permission notice. */
/* Offline checks for the built plugin DLL. Usage: test_host <dll> */
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <windows.h>

#define PI 3.14159265358979323846

typedef void *LV2_Handle;
typedef struct LV2_Descriptor {
    const char *URI;
    LV2_Handle (*instantiate)(const struct LV2_Descriptor *, double, const char *, const void *const *);
    void (*connect_port)(LV2_Handle, uint32_t, void *);
    void (*activate)(LV2_Handle);
    void (*run)(LV2_Handle, uint32_t);
    void (*deactivate)(LV2_Handle);
    void (*cleanup)(LV2_Handle);
    const void *(*extension_data)(const char *);
} LV2_Descriptor;

static const LV2_Descriptor *D;
static int failures;

static void check(const char *what, int ok)
{
    printf("  [%s] %s\n", ok ? "PASS" : "FAIL", what);
    if (!ok) ++failures;
}

/* Runs the plugin over in[] in blocks of `block`, writing out[]. */
static void render(double fs, float level, float blend, float delay,
                   const float *in, float *out, int n, int block)
{
    LV2_Handle h = D->instantiate(D, fs, "", NULL);
    int pos = 0;
    D->connect_port(h, 0, &level);
    D->connect_port(h, 1, &blend);
    D->connect_port(h, 2, &delay);
    D->activate(h);
    while (pos < n) {
        int m = n - pos < block ? n - pos : block;
        D->connect_port(h, 3, (void *)(in + pos));
        D->connect_port(h, 4, out + pos);
        D->run(h, (uint32_t)m);
        pos += m;
    }
    D->deactivate(h);
    D->cleanup(h);
}

static double tone_rms(const float *x, int start, int n)
{
    double s = 0;
    int i;
    for (i = start; i < start + n; ++i) s += (double)x[i] * x[i];
    return sqrt(s / n);
}

/* Amplitude of frequency f in x, Hann windowed. */
static double goertzel(const float *x, int n, double f, double fs)
{
    double re = 0, im = 0, wsum = 0;
    int i;
    for (i = 0; i < n; ++i) {
        double w = 0.5 - 0.5 * cos(2 * PI * i / (n - 1));
        re += w * x[i] * cos(2 * PI * f * i / fs);
        im += w * x[i] * sin(2 * PI * f * i / fs);
        wsum += w;
    }
    return 2 * sqrt(re * re + im * im) / wsum;
}

static double db(double x) { return 20 * log10(x > 1e-12 ? x : 1e-12); }

static int measure_delay_samples(double fs, float dly, float *in, float *out, int n)
{
    int i, b = (int)(fs * 0.005);
    double peak = 0;
    for (i = 0; i < n; ++i) in[i] = 0;
    for (i = 0; i < b; ++i)
        in[i] = (float)(0.1 * sin(PI * i / b) * sin(2 * PI * 1000 * i / fs));
    render(fs, 0, 1, dly, in, out, n, 512);
    for (i = 0; i < n; ++i) if (fabs(out[i]) > peak) peak = fabs(out[i]);
    for (i = 0; i < n; ++i) if (fabs(out[i]) > peak * 0.5) return i;
    return -1;
}

int main(int argc, char **argv)
{
    static const double rates[] = { 44100, 48000, 88200, 96000, 192000 };
    static const double freqs[] = { 100, 500, 1000, 3000, 5000, 7000, 10000, 15000 };
    HMODULE lib;
    const LV2_Descriptor *(*get)(uint32_t);
    const int n = 192000 * 2;
    float *in = malloc(sizeof(float) * n), *out = malloc(sizeof(float) * n),
          *out2 = malloc(sizeof(float) * n);
    int i, r;

    if (argc < 2 || !(lib = LoadLibraryA(argv[1]))) {
        printf("cannot load DLL (error %lu)\n", GetLastError());
        return 2;
    }
    get = (const LV2_Descriptor *(*)(uint32_t))GetProcAddress(lib, "lv2_descriptor");
    if (!get || !(D = get(0))) { printf("no lv2_descriptor export\n"); return 2; }
    printf("URI: %s\n", D->URI);
    check("descriptor index 1 is NULL", get(1) == NULL);

    printf("Delay time, wet only (-6 dB onset of a 5 ms burst):\n");
    for (r = 0; r < 5; ++r) {
        double fs = rates[r];
        int sn = (int)(fs * 0.3);
        double a = measure_delay_samples(fs, 0, in, out, sn) * 1000.0 / fs;
        double b = measure_delay_samples(fs, 1, in, out, sn) * 1000.0 / fs;
        printf("  %6.0f Hz: double %.2f ms, slap %.2f ms\n", fs, a, b);
        if (a < 31.5 || a > 36 || b < 90 || b > 95) check("delay in expected range", 0);
    }
    check("delay checks done", 1);

    printf("Wet response at 48 kHz, -26 dBFS tone, relative to 1 kHz (dB):\n");
    for (r = 0; r < 2; ++r) {
        double ref = 0;
        int sn = 48000;
        printf("  %s:", r ? "slap  " : "double");
        for (i = 0; i < 8; ++i) {
            int j;
            double g;
            for (j = 0; j < sn; ++j) in[j] = (float)(0.05 * sin(2 * PI * freqs[i] * j / 48000));
            render(48000, 0, 1, (float)r, in, out, sn, 512);
            g = tone_rms(out, sn / 2, sn / 2) / tone_rms(in, sn / 2, sn / 2);
            if (i == 2) ref = g;
            out2[i] = (float)g;
        }
        for (i = 0; i < 8; ++i) printf(" %.0fHz %+.1f", freqs[i], db(out2[i] / ref));
        printf("  (1 kHz abs %+.2f dB)\n", db(ref));
        check("wet near unity at 1 kHz", fabs(db(ref)) < 1.0);
        check("wet rolled off at 15 kHz", db(out2[7] / ref) < -20);
    }

    printf("BBD clock images, 5 kHz at -14 dBFS, 96 kHz host:\n");
    {
        int sn = 96000, j;
        for (j = 0; j < sn; ++j) in[j] = (float)(0.2 * sin(2 * PI * 5000 * j / 96000.0));
        render(96000, 0, 1, 1, in, out, sn, 512);
        printf("  slap: tone %.1f dB, image at clock-5k %.1f dB\n",
               db(goertzel(out + sn / 2, sn / 2, 5000, 96000)),
               db(goertzel(out + sn / 2, sn / 2, 22727.3 - 5000, 96000)));
    }

    printf("Blend and Level at 48 kHz:\n");
    {
        int sn = 48000, j;
        double e = 0, p = 0;
        for (j = 0; j < sn; ++j) in[j] = (float)(0.02 * sin(2 * PI * 440 * j / 48000));
        render(48000, 0, 0, 0, in, out, sn, 512);
        for (j = sn / 2; j < sn; ++j) { e += pow(out[j] - in[j], 2); p += in[j] * in[j]; }
        printf("  blend 0 vs input: %.1f dB residual\n", 10 * log10(e / p + 1e-20));
        check("blend 0 is essentially the dry signal", 10 * log10(e / p + 1e-20) < -30);

        render(48000, 20, 0, 0, in, out, sn, 512);
        printf("  level +20 dB: gain %.2f dB\n", db(tone_rms(out, sn / 2, sn / 2) / tone_rms(in, sn / 2, sn / 2)));
        check("level 20 gives about +20 dB on a small signal",
              fabs(db(tone_rms(out, sn / 2, sn / 2) / tone_rms(in, sn / 2, sn / 2)) - 20) < 1.0);
    }

    printf("Robustness:\n");
    {
        int sn = 96000, j, bad = 0;
        double peak = 0, tail = 0;
        /* Block-size independence. */
        for (j = 0; j < sn; ++j) in[j] = (float)(0.5 * sin(2 * PI * 330 * j / 48000.0) * ((j / 4800) % 2));
        render(48000, 6, 0.75f, 1, in, out, sn, 64);
        render(48000, 6, 0.75f, 1, in, out2, sn, 4096);
        for (j = 0; j < sn; ++j) if (out[j] != out2[j]) ++bad;
        check("output identical for block sizes 64 and 4096", bad == 0);
        /* Full-scale noise at max boost, then silence. */
        srand(1);
        for (j = 0; j < sn; ++j) in[j] = j < sn / 2 ? (float)(2.0 * rand() / RAND_MAX - 1.0) : 0.0f;
        render(48000, 20, 1, 1, in, out, sn, 256);
        bad = 0;
        for (j = 0; j < sn; ++j) {
            if (!(out[j] == out[j]) || fabs(out[j]) > 1e6f) ++bad;
            if (fabs(out[j]) > peak) peak = fabs(out[j]);
        }
        for (j = sn - 4800; j < sn; ++j) tail = fmax(tail, fabs(out[j]));
        printf("  max-boost noise: peak %.2f, tail 400 ms after input stops %.1f dB\n", peak, db(tail));
        check("no NaN or runaway", bad == 0);
        check("output bounded under max boost", peak < 8);
        check("tail decays after input stops", db(tail) < -80);
        /* A knob sweep shouldn't blow up either. */
        {
            LARGE_INTEGER t0, t1, fq;
            int sn2 = 48000 * 8;
            float *big = malloc(sizeof(float) * sn2), *bigo = malloc(sizeof(float) * sn2);
            for (j = 0; j < sn2; ++j) big[j] = (float)(0.3 * sin(2 * PI * 220 * j / 48000.0));
            QueryPerformanceFrequency(&fq);
            QueryPerformanceCounter(&t0);
            render(48000, 6, 0.75f, 0, big, bigo, sn2, 256);
            QueryPerformanceCounter(&t1);
            printf("  CPU: %.2f%% of one core at 48 kHz\n",
                   100.0 * (double)(t1.QuadPart - t0.QuadPart) / fq.QuadPart / 8.0);
            free(big); free(bigo);
        }
    }

    printf("%s (%d failures)\n", failures ? "FAILED" : "ALL PASSED", failures);
    return failures ? 1 : 0;
}
