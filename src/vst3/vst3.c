/* SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 Davidian. See LICENSE and README.md. */
/* Davidian Twinline as a VST3 plugin, written in C against Steinberg's VST3 C API
 * (vst3_c_api.h, BSD-style licence, see src/vst3/LICENSE.txt), so the build needs no VST3 SDK.
 *
 * One object is both the audio processor and the edit controller (a "single component
 * effect", as the SDK's SingleComponentEffect): the host finds IEditController on the
 * component itself. The parameters are the LV2 control ports, with the same indices as
 * their VST3 parameter IDs (ports.h, params.h). The GUI is the same panel as the LV2
version, in a child window of the host's (Win32 HWND or Cocoa NSView). On Linux the host
 * shows its own controls for the parameters.
 *
 * The main bus is mono or stereo. On stereo each side runs through its own copy of the
 * pedal with the same settings (a linked pair); a mono input feeding a stereo output
 * gives the same signal on both sides. */
#if defined(__APPLE__)
#    define PANEL_VIEW_CLASS DavidianTwinlineVST3View
#endif
#include "../ui/window.h" /* first: on macOS it imports Cocoa before anything else */

#include <ctype.h>
#include <math.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../engine.h"
#include "../params.h"
#include "../ports.h"
#include "vst3_c_api.h"

#define VENDOR      "Davidian"
#define PLUGIN_NAME DT_NAME
#define VERSION_STR "1.1.0"
#define SDK_VERSION "VST 3.8.1"
#define SUBCATS     "Fx|Delay"
#define STATE_MAGIC "TWL1"

/* Class ID of the plugin. Never change it, or saved projects won't find the plugin. */
static const Steinberg_TUID PLUGIN_CID =
    SMTG_INLINE_UID(0xD20DA02C, 0xE036495C, 0x89704C66, 0x1890239F);

#if defined(_WIN32)
#    define EXPORT __declspec(dllexport)
#else
#    define EXPORT __attribute__((visibility("default")))
#endif
#define API SMTG_STDMETHODCALLTYPE

typedef Steinberg_tresult tresult;
typedef Steinberg_uint32 uint32;

/* ---- Small helpers ---- */

static uint32 atomic_add(volatile long* v, long d)
{
#if defined(_WIN32)
    return (uint32)InterlockedExchangeAdd(v, d) + (uint32)d;
#else
    return (uint32)__atomic_add_fetch(v, d, __ATOMIC_ACQ_REL);
#endif
}

static double clampd(double v, double lo, double hi) { return v < lo ? lo : (v > hi ? hi : v); }

static int iid_eq(const void* a, const Steinberg_TUID b) { return a && memcmp(a, b, 16) == 0; }

static void str16(Steinberg_char16* dst, const char* src, int n)
{
    int i = 0;
    for (; src && src[i] && i < n - 1; ++i)
        dst[i] = (Steinberg_char16)(unsigned char)src[i];
    dst[i] = 0;
}

static void str8(char* dst, const char* src, size_t n)
{
    size_t i = 0;
    for (; src[i] && i < n - 1; ++i)
        dst[i] = src[i];
    dst[i] = 0;
}

/* ---- Parameters: VST3 parameter ID = LV2 port index ---- */

/* The host's bypass parameter is the LV2 version's "enabled" port, inverted (1 = bypassed).
 * It has no control on the panel: the host's own bypass button covers it. */
static const ParamInfo BYPASS_INFO = { "Bypass", "Bypass", "", 0, 1, 1, 2, 0 };
static const char* const BYPASS_OPTS[2] = { "Off", "On" };

static const ParamInfo* param(Steinberg_Vst_ParamID id)
{
    if (id == PORT_ENABLED)
        return &BYPASS_INFO;
    return id < PORT_COUNT ? param_info((int)id) : NULL;
}

static const char* opt_name(Steinberg_Vst_ParamID id, int i)
{
    return id == PORT_ENABLED ? BYPASS_OPTS[i] : param_info((int)id)->opts[i];
}

/* Engine value -> normalized 0..1. Switches are evenly spaced, as VST3 lists expect. */
static double to_norm(Steinberg_Vst_ParamID id, double v)
{
    const ParamInfo* p = param_info((int)id);
    if (id == PORT_ENABLED)
        return v > 0.5 ? 0.0 : 1.0;
    if (p->npos)
        v = floor(v + 0.5);
    return clampd((v - p->min) / (p->max - p->min), 0.0, 1.0);
}

/* Normalized 0..1 -> engine value. */
static double from_norm(Steinberg_Vst_ParamID id, double n)
{
    const ParamInfo* p = param_info((int)id);
    n = clampd(n, 0.0, 1.0);
    if (id == PORT_ENABLED)
        return n >= 0.5 ? 0.0 : 1.0;
    if (p->npos)
        return p->min + floor(n * (p->npos - 1) + 0.5);
    return p->min + n * (p->max - p->min);
}

static void format_value(Steinberg_Vst_ParamID id, double n, char* buf, size_t len)
{
    const ParamInfo* p = param(id);
    const double v = from_norm(id, n);
    if (!p)
        snprintf(buf, len, "?");
    else if (id == PORT_ENABLED)
        snprintf(buf, len, "%s", BYPASS_OPTS[n >= 0.5 ? 1 : 0]);
    else if (p->npos)
        snprintf(buf, len, "%s", p->opts[(int)v]);
    else if (id == PORT_BLEND)
        snprintf(buf, len, "%.0f", v * 100.0); /* knob position, in % (units "%") */
    else
        snprintf(buf, len, "%+.1f", v);
}

static int same_text(const char* a, const char* b)
{
    for (; *a && *b; ++a, ++b)
        if (tolower((unsigned char)*a) != tolower((unsigned char)*b))
            return 0;
    return *a == *b;
}

/* Accepts a position's name, or a value in the parameter's units (dB, or % for Blend). */
static int parse_value(Steinberg_Vst_ParamID id, const char* s, double* n)
{
    const ParamInfo* p = param(id);
    char* end;
    double v;
    int i;
    if (!p)
        return 0;
    for (i = 0; i < p->npos; ++i)
        if (same_text(s, opt_name(id, i))) {
            *n = (double)i / (p->npos - 1);
            return 1;
        }
    v = strtod(s, &end);
    if (end == s || !isfinite(v))
        return 0;
    if (id == PORT_ENABLED)
        *n = v >= 0.5 ? 1.0 : 0.0;
    else if (id == PORT_BLEND)
        *n = to_norm(id, v / 100.0);
    else
        *n = to_norm(id, v);
    return 1;
}

/* ---- The plugin object ---- */

typedef struct View View;

typedef struct {
    /* Each interface is a pointer to its vtable; the host's pointer is the field's address. */
    const Steinberg_Vst_IComponentVtbl* component;
    const Steinberg_Vst_IAudioProcessorVtbl* processor;
    const Steinberg_Vst_IEditControllerVtbl* controller;
    const Steinberg_Vst_IProcessContextRequirementsVtbl* requirements;
    volatile long refs;

    /* Processor side (audio thread) */
    Engine* engine;
    double rate;
    int active;
    Steinberg_Vst_SpeakerArrangement in_arr, out_arr;
    float value[PORT_COUNT]; /* engine values the engine reads */

    /* Controller side (UI thread) */
    double norm[PORT_COUNT];
    struct Steinberg_Vst_IComponentHandler* handler;
    View* view;
} Vst;

#define FROM(ptr, field) ((Vst*)((char*)(ptr) - offsetof(Vst, field)))

static void set_defaults(Vst* v)
{
    int i;
    for (i = 0; i < N_PARAMS; ++i) {
        const int id = PARAM_PORTS[i];
        v->value[id] = param_info(id)->def;
        v->norm[id] = to_norm((Steinberg_Vst_ParamID)id, v->value[id]);
    }
}

/* ---- Saved state: "S731", count, then (id, value) pairs, all little-endian 32-bit ---- */

static void put32(unsigned char* b, uint32 x)
{
    b[0] = (unsigned char)x; b[1] = (unsigned char)(x >> 8);
    b[2] = (unsigned char)(x >> 16); b[3] = (unsigned char)(x >> 24);
}

static uint32 get32(const unsigned char* b)
{
    return (uint32)b[0] | (uint32)b[1] << 8 | (uint32)b[2] << 16 | (uint32)b[3] << 24;
}

static int stream_read(struct Steinberg_IBStream* s, void* buf, int n)
{
    Steinberg_int32 got = 0;
    if (s->lpVtbl->read(s, buf, n, &got) != Steinberg_kResultOk)
        return 0;
    return got == n;
}

/* Reads a saved state into values[]; returns 0 if it isn't ours. */
static int read_state(struct Steinberg_IBStream* s, float* values)
{
    unsigned char b[8];
    uint32 count, i;
    if (!s || !stream_read(s, b, 8) || memcmp(b, STATE_MAGIC, 4) != 0)
        return 0;
    count = get32(b + 4);
    for (i = 0; i < count && i < 1000; ++i) {
        uint32 id, bits;
        float f;
        if (!stream_read(s, b, 8))
            return 0;
        id = get32(b);
        bits = get32(b + 4);
        memcpy(&f, &bits, 4);
        if (param(id) && isfinite(f))
            values[id] = f;
    }
    return 1;
}

static tresult write_state(struct Steinberg_IBStream* s, const float* values)
{
    unsigned char b[8 + 8 * N_PARAMS];
    Steinberg_int32 put = 0;
    int i;
    if (!s)
        return Steinberg_kInvalidArgument;
    memcpy(b, STATE_MAGIC, 4);
    put32(b + 4, N_PARAMS);
    for (i = 0; i < N_PARAMS; ++i) {
        uint32 bits;
        memcpy(&bits, &values[PARAM_PORTS[i]], 4);
        put32(b + 8 + 8 * i, (uint32)PARAM_PORTS[i]);
        put32(b + 12 + 8 * i, bits);
    }
    if (s->lpVtbl->write(s, b, (Steinberg_int32)sizeof b, &put) != Steinberg_kResultOk || put != (Steinberg_int32)sizeof b)
        return Steinberg_kResultFalse;
    return Steinberg_kResultOk;
}

/* ---- The editor view (IPlugView) ---- */

struct View {
    const Steinberg_IPlugViewVtbl* vtbl;
    volatile long refs;
    Vst* vst;
    int open;
    PanelWindow win;
};

static void view_sync(View* w)
{
    int i;
    for (i = 0; i < N_PARAMS; ++i) {
        const int id = PARAM_PORTS[i];
        panel_set(&w->win.panel, id, (float)from_norm((Steinberg_Vst_ParamID)id, w->vst->norm[id]));
    }
    pw_redraw(&w->win);
}

static void view_write(void* host, int port, float value)
{
    View* w = (View*)host;
    Vst* v = w->vst;
    const double n = to_norm((Steinberg_Vst_ParamID)port, value);
    if (!param((Steinberg_Vst_ParamID)port))
        return;
    v->norm[port] = n;
    if (v->handler)
        v->handler->lpVtbl->performEdit(v->handler, (Steinberg_Vst_ParamID)port, n);
}

static void view_gesture(void* host, int port, int begin)
{
    View* w = (View*)host;
    Vst* v = w->vst;
    if (!v->handler || !param((Steinberg_Vst_ParamID)port))
        return;
    if (begin)
        v->handler->lpVtbl->beginEdit(v->handler, (Steinberg_Vst_ParamID)port);
    else
        v->handler->lpVtbl->endEdit(v->handler, (Steinberg_Vst_ParamID)port);
}

static uint32 vst_add_ref(Vst* v);
static uint32 vst_release(Vst* v);

static tresult API view_query(void* self, const Steinberg_TUID iid, void** obj)
{
    View* w = (View*)self;
    if (iid_eq(iid, Steinberg_FUnknown_iid) || iid_eq(iid, Steinberg_IPlugView_iid)) {
        atomic_add(&w->refs, 1);
        *obj = w;
        return Steinberg_kResultOk;
    }
    *obj = NULL;
    return Steinberg_kNoInterface;
}

static uint32 API view_add_ref(void* self) { return atomic_add(&((View*)self)->refs, 1); }

static void view_close(View* w)
{
    if (!w->open)
        return;
    window_close(&w->win);
    panel_free(&w->win.panel);
    w->open = 0;
}

static uint32 API view_release(void* self)
{
    View* w = (View*)self;
    const uint32 n = atomic_add(&w->refs, -1);
    if (n == 0) {
        view_close(w);
        if (w->vst->view == w)
            w->vst->view = NULL;
        vst_release(w->vst);
        free(w);
    }
    return n;
}

static const char* const PLATFORM =
#if defined(_WIN32)
    "HWND";
#elif defined(__APPLE__)
    "NSView";
#else
    "X11EmbedWindowID";
#endif

static tresult API view_supported(void* self, Steinberg_FIDString type)
{
    (void)self;
    return type && !strcmp(type, PLATFORM) ? Steinberg_kResultTrue : Steinberg_kResultFalse;
}

static tresult API view_attached(void* self, void* parent, Steinberg_FIDString type)
{
    View* w = (View*)self;
    if (!parent || view_supported(self, type) != Steinberg_kResultTrue)
        return Steinberg_kResultFalse;
    view_close(w);
    if (!panel_init(&w->win.panel, view_write, w))
        return Steinberg_kResultFalse;
    w->win.panel.gesture = view_gesture;
    if (!window_open(&w->win, parent)) {
        panel_free(&w->win.panel);
        return Steinberg_kResultFalse;
    }
    w->open = 1;
    view_sync(w);
    return Steinberg_kResultOk;
}

static tresult API view_removed(void* self)
{
    view_close((View*)self);
    return Steinberg_kResultOk;
}

static tresult API view_on_wheel(void* self, float d) { (void)self; (void)d; return Steinberg_kResultFalse; }

static tresult API view_on_key(void* self, Steinberg_char16 key, Steinberg_int16 code, Steinberg_int16 mods)
{
    (void)self; (void)key; (void)code; (void)mods;
    return Steinberg_kResultFalse;
}

static tresult API view_get_size(void* self, struct Steinberg_ViewRect* r)
{
    (void)self;
    if (!r)
        return Steinberg_kInvalidArgument;
    r->left = r->top = 0;
    r->right = PANEL_W;
    r->bottom = PANEL_H;
    return Steinberg_kResultOk;
}

static tresult API view_on_size(void* self, struct Steinberg_ViewRect* r) { (void)self; (void)r; return Steinberg_kResultOk; }
static tresult API view_on_focus(void* self, Steinberg_TBool f) { (void)self; (void)f; return Steinberg_kResultOk; }
static tresult API view_set_frame(void* self, struct Steinberg_IPlugFrame* f) { (void)self; (void)f; return Steinberg_kResultOk; }
static tresult API view_can_resize(void* self) { (void)self; return Steinberg_kResultFalse; }

static tresult API view_check_size(void* self, struct Steinberg_ViewRect* r)
{
    return view_get_size(self, r);
}

static const Steinberg_IPlugViewVtbl VIEW_VTBL = {
    view_query, view_add_ref, view_release, view_supported, view_attached, view_removed,
    view_on_wheel, view_on_key, view_on_key, view_get_size, view_on_size, view_on_focus,
    view_set_frame, view_can_resize, view_check_size
};

/* ---- FUnknown for the plugin object, shared by all its interfaces ---- */

static uint32 vst_add_ref(Vst* v) { return atomic_add(&v->refs, 1); }

static uint32 vst_release(Vst* v)
{
    const uint32 n = atomic_add(&v->refs, -1);
    if (n == 0) {
        if (v->handler)
            v->handler->lpVtbl->release(v->handler);
        if (v->engine)
            engine_free(v->engine);
        free(v);
    }
    return n;
}

static tresult vst_query(Vst* v, const Steinberg_TUID iid, void** obj)
{
    void* p = NULL;
    if (iid_eq(iid, Steinberg_FUnknown_iid) || iid_eq(iid, Steinberg_IPluginBase_iid)
        || iid_eq(iid, Steinberg_Vst_IComponent_iid))
        p = &v->component;
    else if (iid_eq(iid, Steinberg_Vst_IAudioProcessor_iid))
        p = &v->processor;
    else if (iid_eq(iid, Steinberg_Vst_IEditController_iid))
        p = &v->controller;
    else if (iid_eq(iid, Steinberg_Vst_IProcessContextRequirements_iid))
        p = &v->requirements;
    *obj = p;
    if (!p)
        return Steinberg_kNoInterface;
    vst_add_ref(v);
    return Steinberg_kResultOk;
}

#define UNKNOWN_FOR(field)                                                                      \
    static tresult API field##_query(void* s, const Steinberg_TUID iid, void** obj)             \
    {                                                                                           \
        return vst_query(FROM(s, field), iid, obj);                                             \
    }                                                                                           \
    static uint32 API field##_add_ref(void* s) { return vst_add_ref(FROM(s, field)); }          \
    static uint32 API field##_release(void* s) { return vst_release(FROM(s, field)); }

UNKNOWN_FOR(component)
UNKNOWN_FOR(processor)
UNKNOWN_FOR(controller)
UNKNOWN_FOR(requirements)

/* ---- IPluginBase (the component and the controller share it) ---- */

static tresult API base_initialize(void* s, struct Steinberg_FUnknown* context)
{
    (void)s;
    (void)context;
    return Steinberg_kResultOk;
}

static tresult API base_terminate(void* s)
{
    (void)s;
    return Steinberg_kResultOk;
}

/* ---- IComponent ---- */

static tresult API comp_controller_cid(void* s, Steinberg_TUID cid)
{
    (void)s;
    (void)cid;
    return Steinberg_kNotImplemented; /* the controller is this object */
}

static tresult API comp_set_io_mode(void* s, Steinberg_Vst_IoMode mode)
{
    (void)s;
    (void)mode;
    return Steinberg_kNotImplemented;
}

static Steinberg_int32 API comp_bus_count(void* s, Steinberg_Vst_MediaType type, Steinberg_Vst_BusDirection dir)
{
    (void)s;
    (void)dir;
    return type == Steinberg_Vst_MediaTypes_kAudio ? 1 : 0;
}

static int arr_channels(Steinberg_Vst_SpeakerArrangement a) { return a == Steinberg_Vst_SpeakerArr_kStereo ? 2 : 1; }

static tresult API comp_bus_info(void* s, Steinberg_Vst_MediaType type, Steinberg_Vst_BusDirection dir,
                                 Steinberg_int32 index, struct Steinberg_Vst_BusInfo* bus)
{
    Vst* v = FROM(s, component);
    const int in = dir == Steinberg_Vst_BusDirections_kInput;
    if (type != Steinberg_Vst_MediaTypes_kAudio || index != 0 || !bus)
        return Steinberg_kInvalidArgument;
    memset(bus, 0, sizeof *bus);
    bus->mediaType = type;
    bus->direction = dir;
    bus->channelCount = arr_channels(in ? v->in_arr : v->out_arr);
    str16(bus->name, in ? "Input" : "Output", 128);
    bus->busType = Steinberg_Vst_BusTypes_kMain;
    bus->flags = Steinberg_Vst_BusInfo_BusFlags_kDefaultActive;
    return Steinberg_kResultOk;
}

static tresult API comp_routing(void* s, struct Steinberg_Vst_RoutingInfo* a, struct Steinberg_Vst_RoutingInfo* b)
{
    (void)s; (void)a; (void)b;
    return Steinberg_kNotImplemented;
}

static tresult API comp_activate_bus(void* s, Steinberg_Vst_MediaType type, Steinberg_Vst_BusDirection dir,
                                     Steinberg_int32 index, Steinberg_TBool state)
{
    (void)s; (void)dir; (void)state;
    return type == Steinberg_Vst_MediaTypes_kAudio && index == 0 ? Steinberg_kResultOk : Steinberg_kInvalidArgument;
}

static void engine_wire(Vst* v)
{
    int i;
    for (i = 0; i < PORT_COUNT; ++i)
        engine_connect(v->engine, (uint32_t)i, NULL);
    for (i = 0; i < N_PARAMS; ++i)
        engine_connect(v->engine, (uint32_t)PARAM_PORTS[i], &v->value[PARAM_PORTS[i]]);
}

static tresult API comp_set_active(void* s, Steinberg_TBool state)
{
    Vst* v = FROM(s, component);
    if (state) {
        if (!v->engine || v->engine->rate != v->rate) {
            if (v->engine)
                engine_free(v->engine);
            v->engine = engine_new(v->rate);
            if (!v->engine)
                return Steinberg_kResultFalse;
            engine_wire(v);
        }
        engine_activate(v->engine);
    }
    v->active = state != 0;
    return Steinberg_kResultOk;
}

static void controller_load(Vst* v, const float* values)
{
    int i;
    for (i = 0; i < N_PARAMS; ++i)
        v->norm[PARAM_PORTS[i]] = to_norm((Steinberg_Vst_ParamID)PARAM_PORTS[i], values[PARAM_PORTS[i]]);
    if (v->view && v->view->open)
        view_sync(v->view);
}

static tresult API comp_set_state(void* s, struct Steinberg_IBStream* state)
{
    Vst* v = FROM(s, component);
    float values[PORT_COUNT];
    memcpy(values, v->value, sizeof values);
    if (!read_state(state, values))
        return Steinberg_kResultFalse;
    memcpy(v->value, values, sizeof values);
    controller_load(v, values); /* same object, so the controller follows at once */
    return Steinberg_kResultOk;
}

static tresult API comp_get_state(void* s, struct Steinberg_IBStream* state)
{
    return write_state(state, FROM(s, component)->value);
}

static const Steinberg_Vst_IComponentVtbl COMPONENT_VTBL = {
    component_query, component_add_ref, component_release, base_initialize, base_terminate,
    comp_controller_cid, comp_set_io_mode, comp_bus_count, comp_bus_info, comp_routing,
    comp_activate_bus, comp_set_active, comp_set_state, comp_get_state
};

/* ---- IAudioProcessor ---- */

static int arr_ok(Steinberg_Vst_SpeakerArrangement a)
{
    return a == Steinberg_Vst_SpeakerArr_kMono || a == Steinberg_Vst_SpeakerArr_kStereo;
}

static tresult API proc_set_arrangements(void* s, Steinberg_Vst_SpeakerArrangement* ins, Steinberg_int32 n_in,
                                         Steinberg_Vst_SpeakerArrangement* outs, Steinberg_int32 n_out)
{
    Vst* v = FROM(s, processor);
    if (n_in != 1 || n_out != 1 || !ins || !outs || !arr_ok(ins[0]) || !arr_ok(outs[0])
        || (ins[0] == Steinberg_Vst_SpeakerArr_kStereo && outs[0] == Steinberg_Vst_SpeakerArr_kMono))
        return Steinberg_kResultFalse;
    v->in_arr = ins[0];
    v->out_arr = outs[0];
    return Steinberg_kResultTrue;
}

static tresult API proc_get_arrangement(void* s, Steinberg_Vst_BusDirection dir, Steinberg_int32 index,
                                        Steinberg_Vst_SpeakerArrangement* arr)
{
    Vst* v = FROM(s, processor);
    if (index != 0 || !arr)
        return Steinberg_kInvalidArgument;
    *arr = dir == Steinberg_Vst_BusDirections_kInput ? v->in_arr : v->out_arr;
    return Steinberg_kResultOk;
}

static tresult API proc_can_sample_size(void* s, Steinberg_int32 size)
{
    (void)s;
    return size == Steinberg_Vst_SymbolicSampleSizes_kSample32 ? Steinberg_kResultTrue : Steinberg_kResultFalse;
}

static uint32 API proc_latency(void* s)
{
    Vst* v = FROM(s, processor);
    (void)v;
    return 0; /* the dry path has no latency */
}

static tresult API proc_setup(void* s, struct Steinberg_Vst_ProcessSetup* setup)
{
    Vst* v = FROM(s, processor);
    if (!setup || setup->symbolicSampleSize != Steinberg_Vst_SymbolicSampleSizes_kSample32
        || !(setup->sampleRate > 0.0))
        return Steinberg_kResultFalse;
    v->rate = setup->sampleRate;
    return Steinberg_kResultOk;
}

static tresult API proc_set_processing(void* s, Steinberg_TBool state)
{
    (void)s;
    (void)state;
    return Steinberg_kResultOk;
}

static void read_param_changes(Vst* v, struct Steinberg_Vst_IParameterChanges* changes)
{
    Steinberg_int32 i, n;
    if (!changes)
        return;
    n = changes->lpVtbl->getParameterCount(changes);
    for (i = 0; i < n; ++i) {
        struct Steinberg_Vst_IParamValueQueue* q = changes->lpVtbl->getParameterData(changes, i);
        Steinberg_Vst_ParamID id;
        Steinberg_int32 points, offset;
        Steinberg_Vst_ParamValue value;
        if (!q)
            continue;
        id = q->lpVtbl->getParameterId(q);
        points = q->lpVtbl->getPointCount(q);
        /* The engine smooths every control, so the last point of the block is enough. */
        if (param(id) && points > 0
            && q->lpVtbl->getPoint(q, points - 1, &offset, &value) == Steinberg_kResultOk)
            v->value[id] = (float)from_norm(id, value);
    }
}

static tresult API proc_process(void* s, struct Steinberg_Vst_ProcessData* data)
{
    Vst* v = FROM(s, processor);
    Steinberg_int32 total, c;
    float **in = NULL, **out = NULL;
    const float* ins[MAX_CH] = { NULL, NULL };
    float* outs[MAX_CH] = { NULL, NULL };
    int n_in = 0, n_out = 0, nch;
    if (!data)
        return Steinberg_kInvalidArgument;
    read_param_changes(v, data->inputParameterChanges);
    total = data->numSamples;
    if (total <= 0 || data->numOutputs < 1 || !data->outputs)
        return Steinberg_kResultOk; /* a parameter flush */
    if (data->symbolicSampleSize != Steinberg_Vst_SymbolicSampleSizes_kSample32 || !v->engine)
        return Steinberg_kResultFalse;
    out = data->outputs[0].Steinberg_Vst_AudioBusBuffers_channelBuffers32;
    n_out = data->outputs[0].numChannels;
    if (data->numInputs > 0 && data->inputs) {
        in = data->inputs[0].Steinberg_Vst_AudioBusBuffers_channelBuffers32;
        n_in = data->inputs[0].numChannels;
    }
    if (!out || n_out < 1)
        return Steinberg_kResultOk;
    /* Stereo in and out: two channels. Otherwise one, copied to every output. */
    nch = n_in >= 2 && n_out >= 2 ? 2 : 1;
    for (c = 0; c < nch; ++c) {
        ins[c] = in && c < n_in ? in[c] : NULL; /* missing input reads as silence */
        outs[c] = out[c];
    }
    engine_process(v->engine, ins, outs, nch, (uint32_t)total);
    for (c = nch; c < n_out; ++c)
        if (out[c] && out[0])
            memcpy(out[c], out[0], sizeof(float) * (size_t)total);
    data->outputs[0].silenceFlags = 0;
    return Steinberg_kResultOk;
}

static uint32 API proc_tail(void* s)
{
    Vst* v = FROM(s, processor);
    /* The echo arrives up to 91 ms after the input stops (Slap), then the filters ring. */
    return (uint32)(0.25 * v->rate);
}

static const Steinberg_Vst_IAudioProcessorVtbl PROCESSOR_VTBL = {
    processor_query, processor_add_ref, processor_release, proc_set_arrangements,
    proc_get_arrangement, proc_can_sample_size, proc_latency, proc_setup, proc_set_processing,
    proc_process, proc_tail
};

/* ---- IProcessContextRequirements: the pedal needs no tempo or transport ---- */

static uint32 API req_get(void* s)
{
    (void)s;
    return 0;
}

static const Steinberg_Vst_IProcessContextRequirementsVtbl REQUIREMENTS_VTBL = {
    requirements_query, requirements_add_ref, requirements_release, req_get
};

/* ---- IEditController ---- */

static tresult API ctl_set_component_state(void* s, struct Steinberg_IBStream* state)
{
    Vst* v = FROM(s, controller);
    float values[PORT_COUNT];
    int id;
    for (id = 0; id < PORT_COUNT; ++id)
        values[id] = param((Steinberg_Vst_ParamID)id) ? (float)from_norm((Steinberg_Vst_ParamID)id, v->norm[id]) : 0.0f;
    if (!read_state(state, values))
        return Steinberg_kResultFalse;
    controller_load(v, values);
    return Steinberg_kResultOk;
}

/* The controller has no state of its own: everything is in the component state. */
static tresult API ctl_set_state(void* s, struct Steinberg_IBStream* state)
{
    (void)s;
    (void)state;
    return Steinberg_kResultOk;
}

static tresult API ctl_get_state(void* s, struct Steinberg_IBStream* state)
{
    (void)s;
    (void)state;
    return Steinberg_kResultOk;
}

static Steinberg_int32 API ctl_param_count(void* s)
{
    (void)s;
    return N_PARAMS;
}

static tresult API ctl_param_info(void* s, Steinberg_int32 index, struct Steinberg_Vst_ParameterInfo* info)
{
    const Steinberg_Vst_ParamID id = index >= 0 && index < N_PARAMS ? (Steinberg_Vst_ParamID)PARAM_PORTS[index] : 0xFFFFFFFFu;
    const ParamInfo* p = param(id);
    (void)s;
    if (index < 0 || index >= N_PARAMS || !p || !info)
        return Steinberg_kInvalidArgument;
    memset(info, 0, sizeof *info);
    info->id = id;
    str16(info->title, p->name, 128);
    str16(info->shortTitle, p->short_name, 128);
    str16(info->units, p->unit, 128);
    info->stepCount = p->npos ? p->npos - 1 : 0;
    info->defaultNormalizedValue = to_norm(id, param_info((int)id)->def);
    info->unitId = Steinberg_Vst_kRootUnitId;
    info->flags = Steinberg_Vst_ParameterInfo_ParameterFlags_kCanAutomate;
    if (id == PORT_ENABLED)
        info->flags |= Steinberg_Vst_ParameterInfo_ParameterFlags_kIsBypass;
    else if (p->npos)
        info->flags |= Steinberg_Vst_ParameterInfo_ParameterFlags_kIsList;
    return Steinberg_kResultOk;
}

static tresult API ctl_string_by_value(void* s, Steinberg_Vst_ParamID id, Steinberg_Vst_ParamValue n,
                                       Steinberg_Vst_String128 str)
{
    char buf[64];
    (void)s;
    if (!param(id) || !str)
        return Steinberg_kInvalidArgument;
    format_value(id, n, buf, sizeof buf);
    str16(str, buf, 128);
    return Steinberg_kResultOk;
}

static tresult API ctl_value_by_string(void* s, Steinberg_Vst_ParamID id, Steinberg_Vst_TChar* str,
                                       Steinberg_Vst_ParamValue* n)
{
    char buf[64];
    int i;
    (void)s;
    if (!param(id) || !str || !n)
        return Steinberg_kInvalidArgument;
    for (i = 0; i < 63 && str[i]; ++i)
        buf[i] = str[i] < 128 ? (char)str[i] : '?';
    buf[i] = 0;
    return parse_value(id, buf, n) ? Steinberg_kResultOk : Steinberg_kResultFalse;
}

static Steinberg_Vst_ParamValue API ctl_to_plain(void* s, Steinberg_Vst_ParamID id, Steinberg_Vst_ParamValue n)
{
    (void)s;
    return param(id) ? from_norm(id, n) : n;
}

static Steinberg_Vst_ParamValue API ctl_to_norm(void* s, Steinberg_Vst_ParamID id, Steinberg_Vst_ParamValue v)
{
    (void)s;
    return param(id) ? to_norm(id, v) : v;
}

static Steinberg_Vst_ParamValue API ctl_get_norm(void* s, Steinberg_Vst_ParamID id)
{
    Vst* v = FROM(s, controller);
    return param(id) ? v->norm[id] : 0.0;
}

static tresult API ctl_set_norm(void* s, Steinberg_Vst_ParamID id, Steinberg_Vst_ParamValue n)
{
    Vst* v = FROM(s, controller);
    if (!param(id))
        return Steinberg_kInvalidArgument;
    v->norm[id] = clampd(n, 0.0, 1.0);
    if (v->view && v->view->open) {
        panel_set(&v->view->win.panel, (int)id, (float)from_norm(id, v->norm[id]));
        pw_redraw(&v->view->win);
    }
    return Steinberg_kResultOk;
}

static tresult API ctl_set_handler(void* s, struct Steinberg_Vst_IComponentHandler* handler)
{
    Vst* v = FROM(s, controller);
    if (handler == v->handler)
        return Steinberg_kResultOk;
    if (handler)
        handler->lpVtbl->addRef(handler);
    if (v->handler)
        v->handler->lpVtbl->release(v->handler);
    v->handler = handler;
    return Steinberg_kResultOk;
}

static struct Steinberg_IPlugView* API ctl_create_view(void* s, Steinberg_FIDString name)
{
    Vst* v = FROM(s, controller);
    View* w;
#if !defined(_WIN32) && !defined(__APPLE__)
    (void)v; (void)w; (void)name;
    return NULL; /* X11 embedding needs the host's run loop; not done yet */
#else
    if (!name || strcmp(name, "editor") != 0)
        return NULL;
    w = (View*)calloc(1, sizeof(View));
    if (!w)
        return NULL;
    w->vtbl = &VIEW_VTBL;
    w->refs = 1;
    w->vst = v;
    vst_add_ref(v); /* the view keeps the controller alive */
    v->view = w;
    return (struct Steinberg_IPlugView*)w;
#endif
}

static const Steinberg_Vst_IEditControllerVtbl CONTROLLER_VTBL = {
    controller_query, controller_add_ref, controller_release, base_initialize, base_terminate,
    ctl_set_component_state, ctl_set_state, ctl_get_state, ctl_param_count, ctl_param_info,
    ctl_string_by_value, ctl_value_by_string, ctl_to_plain, ctl_to_norm, ctl_get_norm,
    ctl_set_norm, ctl_set_handler, ctl_create_view
};

static Vst* vst_new(void)
{
    Vst* v = (Vst*)calloc(1, sizeof(Vst));
    if (!v)
        return NULL;
    v->component = &COMPONENT_VTBL;
    v->processor = &PROCESSOR_VTBL;
    v->controller = &CONTROLLER_VTBL;
    v->requirements = &REQUIREMENTS_VTBL;
    v->refs = 1;
    v->rate = 48000.0;
    v->in_arr = Steinberg_Vst_SpeakerArr_kStereo;
    v->out_arr = Steinberg_Vst_SpeakerArr_kStereo;
    set_defaults(v);
    return v;
}

/* ---- The factory ---- */

typedef struct {
    const Steinberg_IPluginFactory2Vtbl* vtbl;
} Factory;

static tresult API fac_query(void* s, const Steinberg_TUID iid, void** obj)
{
    if (iid_eq(iid, Steinberg_FUnknown_iid) || iid_eq(iid, Steinberg_IPluginFactory_iid)
        || iid_eq(iid, Steinberg_IPluginFactory2_iid)) {
        *obj = s;
        return Steinberg_kResultOk;
    }
    *obj = NULL;
    return Steinberg_kNoInterface;
}

/* The factory is static: counting references would only matter if it were freed. */
static uint32 API fac_add_ref(void* s) { (void)s; return 1; }
static uint32 API fac_release(void* s) { (void)s; return 1; }

static tresult API fac_info(void* s, struct Steinberg_PFactoryInfo* info)
{
    (void)s;
    if (!info)
        return Steinberg_kInvalidArgument;
    memset(info, 0, sizeof *info);
    str8(info->vendor, VENDOR, sizeof info->vendor);
    str8(info->url, "https://github.com/evadavevadave/davidian-twinline", sizeof info->url);
    info->flags = Steinberg_PFactoryInfo_FactoryFlags_kUnicode;
    return Steinberg_kResultOk;
}

static Steinberg_int32 API fac_count(void* s)
{
    (void)s;
    return 1;
}

static void class_basics(Steinberg_TUID cid, Steinberg_int32* card, char* cat, char* name)
{
    memcpy(cid, PLUGIN_CID, 16);
    *card = Steinberg_PClassInfo_ClassCardinality_kManyInstances;
    str8(cat, "Audio Module Class", 32);
    str8(name, PLUGIN_NAME, 64);
}

static tresult API fac_class_info(void* s, Steinberg_int32 index, struct Steinberg_PClassInfo* info)
{
    (void)s;
    if (index != 0 || !info)
        return Steinberg_kInvalidArgument;
    memset(info, 0, sizeof *info);
    class_basics(info->cid, &info->cardinality, info->category, info->name);
    return Steinberg_kResultOk;
}

static tresult API fac_class_info2(void* s, Steinberg_int32 index, struct Steinberg_PClassInfo2* info)
{
    (void)s;
    if (index != 0 || !info)
        return Steinberg_kInvalidArgument;
    memset(info, 0, sizeof *info);
    class_basics(info->cid, &info->cardinality, info->category, info->name);
    info->classFlags = 0; /* the processor and controller can't be split across machines */
    str8(info->subCategories, SUBCATS, sizeof info->subCategories);
    str8(info->vendor, VENDOR, sizeof info->vendor);
    str8(info->version, VERSION_STR, sizeof info->version);
    str8(info->sdkVersion, SDK_VERSION, sizeof info->sdkVersion);
    return Steinberg_kResultOk;
}

static tresult API fac_create(void* s, Steinberg_FIDString cid, Steinberg_FIDString iid, void** obj)
{
    Vst* v;
    tresult r;
    (void)s;
    if (!obj)
        return Steinberg_kInvalidArgument;
    *obj = NULL;
    if (!iid_eq(cid, PLUGIN_CID))
        return Steinberg_kNoInterface;
    v = vst_new();
    if (!v)
        return Steinberg_kResultFalse;
    r = vst_query(v, (const char*)iid, obj);
    vst_release(v); /* the query holds the only reference now (or none, and v is freed) */
    return r;
}

static const Steinberg_IPluginFactory2Vtbl FACTORY_VTBL = {
    fac_query, fac_add_ref, fac_release, fac_info, fac_count, fac_class_info, fac_create,
    fac_class_info2
};

static Factory factory = { &FACTORY_VTBL };

/* ---- Module entry points ---- */

EXPORT struct Steinberg_IPluginFactory* API GetPluginFactory(void)
{
    return (struct Steinberg_IPluginFactory*)&factory;
}

#if defined(_WIN32)
EXPORT int InitDll(void) { return 1; }
EXPORT int ExitDll(void) { return 1; }
#elif defined(__APPLE__)
EXPORT int bundleEntry(void* ref) { (void)ref; return 1; }
EXPORT int bundleExit(void) { return 1; }
#else
EXPORT int ModuleEntry(void* lib) { (void)lib; return 1; }
EXPORT int ModuleExit(void) { return 1; }
#endif
