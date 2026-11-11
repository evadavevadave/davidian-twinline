/* SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 Davidian. See LICENSE and README.md. */
/* Davidian Twinline as a macOS Audio Unit (version 2, type aufx), written in C
 * against Apple's AudioToolbox API, with no AU SDK classes. The parameters are the LV2
 * control ports, with the same indices as their AU parameter IDs (ports.h). The GUI is the
 * same panel as the LV2 and VST3 versions, in a Cocoa view the host gets through
 * kAudioUnitProperty_CocoaUI.
 *
 * The bus is 1 in / 1 out, 1 in / 2 out or 2 in / 2 out. On stereo each side runs
 * through its own copy of the pedal with the same settings; a mono input feeding a stereo
 * output gives the same signal on both sides.
 * Build as Objective-C without ARC (see the Makefile's au target). */
#import <Cocoa/Cocoa.h> /* first: AUCocoaUIView.h and panel.h both need it before them */
#import <AudioToolbox/AudioToolbox.h>
#import <AudioUnit/AUCocoaUIView.h>
#import <CoreAudio/CoreAudio.h>

#define PANEL_VIEW_CLASS DavidianTwinlineAUPanelView
#include "../ui/window.h" /* imports Cocoa, then the panel */

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../engine.h"
#include "../params.h"
#include "../ports.h"

#define BUNDLE_ID   "com.davidian.twinline.au" /* must match bundle/au/Info.plist */
#define VIEW_FACTORY_CLASS "DavidianTwinlineAUViewFactory"
#define AU_TYPE     'aufx'
#define AU_SUBTYPE  'Twln'
#define AU_MANU     'Dvdn'

#define MAX_LISTENERS 64
#define MAX_NOTIFIES  16

#define EXPORT __attribute__((visibility("default")))

/* ---- Parameters: AU parameter ID = LV2 port index, values as the engine uses them ---- */

typedef ParamInfo Param;

static const Param* param(AudioUnitParameterID id)
{
    return id < (AudioUnitParameterID)PORT_COUNT ? param_info((int)id) : NULL;
}

/* Delay is indexed (named positions); the footswitch and the host bypass are booleans;
 * Level is in dB; Blend is the knob position, 0 to 1. */
static AudioUnitParameterUnit param_unit(AudioUnitParameterID id)
{
    if (id == PORT_DELAY)
        return kAudioUnitParameterUnit_Indexed;
    if (id == PORT_ON || id == PORT_ENABLED)
        return kAudioUnitParameterUnit_Boolean;
    if (id == PORT_LEVEL)
        return kAudioUnitParameterUnit_Decibels;
    return kAudioUnitParameterUnit_Generic;
}

static float clamp_param(const Param* p, float v)
{
    if (!isfinite(v))
        return p->def;
    if (p->npos)
        v = floorf(v + 0.5f);
    return v < p->min ? p->min : (v > p->max ? p->max : v);
}

/* ---- The instance ---- */

typedef struct {
    AudioUnitPropertyID id;
    AudioUnitPropertyListenerProc proc;
    void* data;
} Listener;

typedef struct {
    AURenderCallback proc;
    void* data;
} Notify;

typedef struct {
    AudioComponentPlugInInterface iface; /* first: the host's pointer is the instance's */
    AudioComponentInstance self;

    Engine* engine;
    double rate;
    int initialized;
    UInt32 max_frames, in_ch, out_ch;
    float value[PORT_COUNT];
    float* in_buf[2];   /* the host's input lands here, max_frames each */
    float* out_buf[2];  /* used when the host gives no output buffers */

    AURenderCallbackStruct input_cb;
    AudioUnitConnection connection;
    int has_connection;
    OSStatus last_error;
    UInt32 should_allocate, offline;

    Listener listeners[MAX_LISTENERS];
    int n_listeners;
    Notify notifies[MAX_NOTIFIES];
    int n_notifies;

    SInt32 preset_number;
    CFStringRef preset_name;
} TwUnit;

static void notify_property(TwUnit* au, AudioUnitPropertyID id, AudioUnitScope scope, AudioUnitElement el)
{
    int i;
    for (i = 0; i < au->n_listeners; ++i)
        if (au->listeners[i].id == id)
            au->listeners[i].proc(au->listeners[i].data, au->self, id, scope, el);
}

static void notify_parameter(TwUnit* au, AudioUnitParameterID id)
{
    AudioUnitParameter p;
    p.mAudioUnit = au->self;
    p.mParameterID = id;
    p.mScope = kAudioUnitScope_Global;
    p.mElement = 0;
    AUParameterListenerNotify(NULL, NULL, &p);
}

static int latency_samples(const TwUnit* au)
{
    (void)au;
    return 0; /* the dry path has no latency */
}

static void free_buffers(TwUnit* au)
{
    int c;
    for (c = 0; c < 2; ++c) {
        free(au->in_buf[c]);
        free(au->out_buf[c]);
        au->in_buf[c] = au->out_buf[c] = NULL;
    }
}

static int alloc_buffers(TwUnit* au)
{
    const size_t n = au->max_frames ? au->max_frames : 1;
    int c;
    free_buffers(au);
    for (c = 0; c < 2; ++c) {
        au->in_buf[c] = (float*)calloc(n, sizeof(float));
        au->out_buf[c] = (float*)calloc(n, sizeof(float));
    }
    return au->in_buf[0] && au->in_buf[1] && au->out_buf[0] && au->out_buf[1];
}

static void wire_engine(TwUnit* au)
{
    int i;
    for (i = 0; i < PORT_COUNT; ++i)
        engine_connect(au->engine, (uint32_t)i, NULL);
    for (i = 0; i < N_PARAMS; ++i)
        engine_connect(au->engine, (uint32_t)PARAM_PORTS[i], &au->value[PARAM_PORTS[i]]);
}

/* ---- Saved state: the same "TWL1" blob as the VST3 version ---- */

static CFDataRef state_data(const TwUnit* au)
{
    unsigned char b[8 + 8 * N_PARAMS];
    int i;
    memcpy(b, "TWL1", 4);
    b[4] = N_PARAMS; b[5] = b[6] = b[7] = 0;
    for (i = 0; i < N_PARAMS; ++i) {
        const UInt32 id = (UInt32)PARAM_PORTS[i];
        UInt32 bits;
        int k;
        memcpy(&bits, &au->value[id], 4);
        for (k = 0; k < 4; ++k) {
            b[8 + 8 * i + k] = (unsigned char)(id >> (8 * k));
            b[12 + 8 * i + k] = (unsigned char)(bits >> (8 * k));
        }
    }
    return CFDataCreate(NULL, b, (CFIndex)sizeof b);
}

static UInt32 le32(const UInt8* b) { return (UInt32)b[0] | (UInt32)b[1] << 8 | (UInt32)b[2] << 16 | (UInt32)b[3] << 24; }

static int load_state_data(TwUnit* au, CFDataRef data)
{
    const UInt8* b;
    CFIndex len;
    UInt32 count, i;
    if (!data || CFGetTypeID(data) != CFDataGetTypeID())
        return 0;
    b = CFDataGetBytePtr(data);
    len = CFDataGetLength(data);
    if (len < 8 || memcmp(b, "TWL1", 4) != 0)
        return 0;
    count = le32(b + 4);
    for (i = 0; i < count && 8 + 8 * (CFIndex)i + 8 <= len; ++i) {
        const UInt32 id = le32(b + 8 + 8 * i), bits = le32(b + 12 + 8 * i);
        float f;
        memcpy(&f, &bits, 4);
        if (param(id))
            au->value[id] = clamp_param(param(id), f);
    }
    return 1;
}

static void dict_set_int(CFMutableDictionaryRef d, const char* key, SInt32 v)
{
    CFStringRef k = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
    CFNumberRef n = CFNumberCreate(NULL, kCFNumberSInt32Type, &v);
    CFDictionarySetValue(d, k, n);
    CFRelease(n);
    CFRelease(k);
}

static int dict_get_int(CFDictionaryRef d, const char* key, SInt32* v)
{
    CFStringRef k = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
    const void* n = CFDictionaryGetValue(d, k);
    CFRelease(k);
    return n && CFGetTypeID(n) == CFNumberGetTypeID() && CFNumberGetValue((CFNumberRef)n, kCFNumberSInt32Type, v);
}

static CFDictionaryRef class_info(const TwUnit* au)
{
    CFMutableDictionaryRef d = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
                                                         &kCFTypeDictionaryValueCallBacks);
    CFDataRef data = state_data(au);
    dict_set_int(d, kAUPresetVersionKey, 0);
    dict_set_int(d, kAUPresetTypeKey, (SInt32)AU_TYPE);
    dict_set_int(d, kAUPresetSubtypeKey, (SInt32)AU_SUBTYPE);
    dict_set_int(d, kAUPresetManufacturerKey, (SInt32)AU_MANU);
    CFDictionarySetValue(d, CFSTR(kAUPresetDataKey), data);
    CFDictionarySetValue(d, CFSTR(kAUPresetNameKey), au->preset_name ? au->preset_name : CFSTR("Untitled"));
    CFRelease(data);
    return d;
}

static OSStatus set_class_info(TwUnit* au, CFDictionaryRef d)
{
    SInt32 version, type, subtype, manu;
    const void* name;
    int i;
    if (!d || CFGetTypeID(d) != CFDictionaryGetTypeID())
        return kAudioUnitErr_InvalidPropertyValue;
    if (!dict_get_int(d, kAUPresetVersionKey, &version) || version != 0
        || !dict_get_int(d, kAUPresetTypeKey, &type) || (OSType)type != AU_TYPE
        || !dict_get_int(d, kAUPresetSubtypeKey, &subtype) || (OSType)subtype != AU_SUBTYPE
        || !dict_get_int(d, kAUPresetManufacturerKey, &manu) || (OSType)manu != AU_MANU)
        return kAudioUnitErr_InvalidPropertyValue;
    if (!load_state_data(au, (CFDataRef)CFDictionaryGetValue(d, CFSTR(kAUPresetDataKey))))
        return kAudioUnitErr_InvalidPropertyValue;
    name = CFDictionaryGetValue(d, CFSTR(kAUPresetNameKey));
    if (name && CFGetTypeID(name) == CFStringGetTypeID()) {
        if (au->preset_name)
            CFRelease(au->preset_name);
        au->preset_name = CFStringCreateCopy(NULL, (CFStringRef)name);
        au->preset_number = -1;
        notify_property(au, kAudioUnitProperty_PresentPreset, kAudioUnitScope_Global, 0);
    }
    for (i = 0; i < N_PARAMS; ++i)
        notify_parameter(au, (AudioUnitParameterID)PARAM_PORTS[i]);
    return noErr;
}

/* ---- Stream formats ---- */

static void fill_format(const TwUnit* au, UInt32 channels, AudioStreamBasicDescription* f)
{
    memset(f, 0, sizeof *f);
    f->mSampleRate = au->rate;
    f->mFormatID = kAudioFormatLinearPCM;
    f->mFormatFlags = kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved;
    f->mBytesPerPacket = 4;
    f->mFramesPerPacket = 1;
    f->mBytesPerFrame = 4;
    f->mChannelsPerFrame = channels;
    f->mBitsPerChannel = 32;
}

static int format_ok(const AudioStreamBasicDescription* f)
{
    return f->mFormatID == kAudioFormatLinearPCM && (f->mFormatFlags & kAudioFormatFlagIsFloat)
        && (f->mFormatFlags & kAudioFormatFlagIsNonInterleaved) && f->mBitsPerChannel == 32
        && f->mChannelsPerFrame >= 1 && f->mChannelsPerFrame <= 2 && f->mSampleRate > 0.0;
}

static int channels_ok(UInt32 in, UInt32 out)
{
    return (in == 1 && out == 1) || (in == 1 && out == 2) || (in == 2 && out == 2);
}

/* ---- Property handling ---- */

static int is_global_only(AudioUnitPropertyID id)
{
    switch (id) {
    case kAudioUnitProperty_ClassInfo:
    case kAudioUnitProperty_ParameterInfo:
    case kAudioUnitProperty_Latency:
    case kAudioUnitProperty_SupportedNumChannels:
    case kAudioUnitProperty_MaximumFramesPerSlice:
    case kAudioUnitProperty_TailTime:
    case kAudioUnitProperty_BypassEffect:
    case kAudioUnitProperty_LastRenderError:
    case kAudioUnitProperty_CocoaUI:
    case kAudioUnitProperty_PresentPreset:
    case kAudioUnitProperty_OfflineRender:
    case kAudioUnitProperty_HostCallbacks:
    case kAudioUnitProperty_ContextName:
        return 1;
    default:
        return 0;
    }
}

/* Size and writability of a property, or an error if it isn't supported there. */
static OSStatus prop_info(TwUnit* au, AudioUnitPropertyID id, AudioUnitScope scope, AudioUnitElement el,
                          UInt32* size, Boolean* writable)
{
    UInt32 s = 0;
    Boolean w = false;
    if (is_global_only(id) && scope != kAudioUnitScope_Global)
        return kAudioUnitErr_InvalidScope;
    switch (id) {
    case kAudioUnitProperty_ClassInfo: s = sizeof(CFPropertyListRef); w = true; break;
    case kAudioUnitProperty_MakeConnection:
        if (scope != kAudioUnitScope_Input)
            return kAudioUnitErr_InvalidScope;
        if (el != 0)
            return kAudioUnitErr_InvalidElement;
        s = sizeof(AudioUnitConnection); w = true; break;
    case kAudioUnitProperty_SetRenderCallback:
        if (scope != kAudioUnitScope_Input)
            return kAudioUnitErr_InvalidScope;
        if (el != 0)
            return kAudioUnitErr_InvalidElement;
        s = sizeof(AURenderCallbackStruct); w = true; break;
    case kAudioUnitProperty_SampleRate:
        if (scope != kAudioUnitScope_Input && scope != kAudioUnitScope_Output)
            return kAudioUnitErr_InvalidScope;
        if (el != 0)
            return kAudioUnitErr_InvalidElement;
        s = sizeof(Float64); w = true; break;
    case kAudioUnitProperty_StreamFormat:
        if (scope != kAudioUnitScope_Input && scope != kAudioUnitScope_Output)
            return kAudioUnitErr_InvalidScope;
        if (el != 0)
            return kAudioUnitErr_InvalidElement;
        s = sizeof(AudioStreamBasicDescription); w = true; break;
    case kAudioUnitProperty_ParameterList:
        s = scope == kAudioUnitScope_Global ? (UInt32)(N_PARAMS * sizeof(AudioUnitParameterID)) : 0; break;
    case kAudioUnitProperty_ParameterInfo:
        if (!param(el))
            return kAudioUnitErr_InvalidParameter;
        s = sizeof(AudioUnitParameterInfo); break;
    case kAudioUnitProperty_ParameterValueStrings:
        if (scope != kAudioUnitScope_Global)
            return kAudioUnitErr_InvalidScope;
        if (!param(el) || param_unit(el) != kAudioUnitParameterUnit_Indexed)
            return kAudioUnitErr_InvalidProperty;
        s = sizeof(CFArrayRef); break;
    case kAudioUnitProperty_ElementCount: s = sizeof(UInt32); break;
    case kAudioUnitProperty_Latency:
    case kAudioUnitProperty_TailTime: s = sizeof(Float64); break;
    case kAudioUnitProperty_SupportedNumChannels: s = 3 * sizeof(AUChannelInfo); break;
    case kAudioUnitProperty_MaximumFramesPerSlice: s = sizeof(UInt32); w = true; break;
    case kAudioUnitProperty_BypassEffect: s = sizeof(UInt32); w = true; break;
    case kAudioUnitProperty_LastRenderError: s = sizeof(OSStatus); break;
    case kAudioUnitProperty_ShouldAllocateBuffer:
        if (scope != kAudioUnitScope_Input && scope != kAudioUnitScope_Output)
            return kAudioUnitErr_InvalidScope;
        s = sizeof(UInt32); w = true; break;
    case kAudioUnitProperty_OfflineRender: s = sizeof(UInt32); w = true; break;
    case kAudioUnitProperty_CocoaUI: s = sizeof(AudioUnitCocoaViewInfo); break;
    case kAudioUnitProperty_PresentPreset: s = sizeof(AUPreset); w = true; break;
    case kAudioUnitProperty_HostCallbacks: s = sizeof(HostCallbackInfo); w = true; break;
    case kAudioUnitProperty_ContextName: s = sizeof(CFStringRef); w = true; break;
    default:
        return kAudioUnitErr_InvalidProperty;
    }
    (void)au;
    if (size)
        *size = s;
    if (writable)
        *writable = w;
    return noErr;
}

static OSStatus ho_get_property_info(void* self, AudioUnitPropertyID id, AudioUnitScope scope, AudioUnitElement el,
                                  UInt32* size, Boolean* writable)
{
    return prop_info((TwUnit*)self, id, scope, el, size, writable);
}

static OSStatus ho_get_property(void* self, AudioUnitPropertyID id, AudioUnitScope scope, AudioUnitElement el,
                              void* out, UInt32* io_size)
{
    TwUnit* au = (TwUnit*)self;
    UInt32 size = 0;
    OSStatus err = prop_info(au, id, scope, el, &size, NULL);
    if (err)
        return err;
    if (!io_size)
        return kAudio_ParamError;
    if (!out) { /* some hosts ask for the size this way */
        *io_size = size;
        return noErr;
    }
    if (*io_size < size)
        return kAudioUnitErr_InvalidPropertyValue;
    switch (id) {
    case kAudioUnitProperty_ClassInfo:
        *(CFPropertyListRef*)out = class_info(au); /* the caller releases it */
        break;
    case kAudioUnitProperty_MakeConnection:
        *(AudioUnitConnection*)out = au->connection;
        break;
    case kAudioUnitProperty_SetRenderCallback:
        *(AURenderCallbackStruct*)out = au->input_cb;
        break;
    case kAudioUnitProperty_SampleRate:
        *(Float64*)out = au->rate;
        break;
    case kAudioUnitProperty_StreamFormat:
        fill_format(au, scope == kAudioUnitScope_Input ? au->in_ch : au->out_ch, (AudioStreamBasicDescription*)out);
        break;
    case kAudioUnitProperty_ParameterList: {
        AudioUnitParameterID* ids = (AudioUnitParameterID*)out;
        int i;
        if (scope == kAudioUnitScope_Global)
            for (i = 0; i < N_PARAMS; ++i)
                ids[i] = (AudioUnitParameterID)PARAM_PORTS[i];
        break;
    }
    case kAudioUnitProperty_ParameterInfo: {
        const Param* p = param(el);
        AudioUnitParameterInfo* info = (AudioUnitParameterInfo*)out;
        memset(info, 0, sizeof *info);
        strlcpy(info->name, p->name, sizeof info->name);
        info->cfNameString = CFStringCreateWithCString(NULL, p->name, kCFStringEncodingUTF8);
        info->unit = param_unit(el);
        info->minValue = p->min;
        info->maxValue = p->max;
        info->defaultValue = p->def;
        info->flags = kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_IsWritable
                    | kAudioUnitParameterFlag_HasCFNameString | kAudioUnitParameterFlag_CFNameRelease;
        break;
    }
    case kAudioUnitProperty_ParameterValueStrings: {
        const Param* p = param(el);
        CFStringRef names[20];
        int i;
        for (i = 0; i < p->npos && i < 20; ++i)
            names[i] = CFStringCreateWithCString(NULL, p->opts[i], kCFStringEncodingUTF8);
        *(CFArrayRef*)out = CFArrayCreate(NULL, (const void**)names, i, &kCFTypeArrayCallBacks);
        while (i-- > 0)
            CFRelease(names[i]);
        break;
    }
    case kAudioUnitProperty_ElementCount:
        *(UInt32*)out = scope == kAudioUnitScope_Global || scope == kAudioUnitScope_Input
                                || scope == kAudioUnitScope_Output ? 1 : 0;
        break;
    case kAudioUnitProperty_Latency:
        *(Float64*)out = latency_samples(au) / au->rate;
        break;
    case kAudioUnitProperty_TailTime:
        *(Float64*)out = 0.25; /* the echo arrives up to 91 ms late (Slap), then the filters ring */
        break;
    case kAudioUnitProperty_SupportedNumChannels: {
        AUChannelInfo* c = (AUChannelInfo*)out;
        c[0].inChannels = 1; c[0].outChannels = 1;
        c[1].inChannels = 1; c[1].outChannels = 2;
        c[2].inChannels = 2; c[2].outChannels = 2;
        break;
    }
    case kAudioUnitProperty_MaximumFramesPerSlice:
        *(UInt32*)out = au->max_frames;
        break;
    case kAudioUnitProperty_BypassEffect:
        *(UInt32*)out = au->value[PORT_ENABLED] > 0.5f ? 0 : 1;
        break;
    case kAudioUnitProperty_LastRenderError:
        *(OSStatus*)out = au->last_error;
        au->last_error = noErr;
        break;
    case kAudioUnitProperty_ShouldAllocateBuffer:
        *(UInt32*)out = au->should_allocate;
        break;
    case kAudioUnitProperty_OfflineRender:
        *(UInt32*)out = au->offline;
        break;
    case kAudioUnitProperty_CocoaUI: {
        AudioUnitCocoaViewInfo* info = (AudioUnitCocoaViewInfo*)out;
        CFBundleRef b = CFBundleGetBundleWithIdentifier(CFSTR(BUNDLE_ID));
        if (!b)
            return kAudioUnitErr_InvalidProperty;
        info->mCocoaAUViewBundleLocation = CFBundleCopyBundleURL(b); /* the caller releases both */
        info->mCocoaAUViewClass[0] = CFStringCreateWithCString(NULL, VIEW_FACTORY_CLASS, kCFStringEncodingUTF8);
        break;
    }
    case kAudioUnitProperty_PresentPreset: {
        AUPreset* p = (AUPreset*)out;
        p->presetNumber = au->preset_number;
        p->presetName = au->preset_name ? (CFStringRef)CFRetain(au->preset_name) : CFSTR("Untitled");
        break;
    }
    default:
        return kAudioUnitErr_InvalidProperty; /* write-only, such as the host callbacks */
    }
    *io_size = size;
    return noErr;
}

static OSStatus ho_set_property(void* self, AudioUnitPropertyID id, AudioUnitScope scope, AudioUnitElement el,
                              const void* in, UInt32 size)
{
    TwUnit* au = (TwUnit*)self;
    UInt32 need = 0;
    Boolean writable = false;
    OSStatus err = prop_info(au, id, scope, el, &need, &writable);
    if (err)
        return err;
    if (!writable)
        return kAudioUnitErr_PropertyNotWritable;
    if (!in || size < need)
        return kAudioUnitErr_InvalidPropertyValue;
    switch (id) {
    case kAudioUnitProperty_ClassInfo:
        return set_class_info(au, *(const CFDictionaryRef*)in);
    case kAudioUnitProperty_MakeConnection:
        au->connection = *(const AudioUnitConnection*)in;
        au->has_connection = au->connection.sourceAudioUnit != NULL;
        if (au->has_connection)
            memset(&au->input_cb, 0, sizeof au->input_cb);
        break;
    case kAudioUnitProperty_SetRenderCallback:
        au->input_cb = *(const AURenderCallbackStruct*)in;
        if (au->input_cb.inputProc)
            au->has_connection = 0;
        break;
    case kAudioUnitProperty_SampleRate:
    case kAudioUnitProperty_StreamFormat: {
        AudioStreamBasicDescription f;
        if (id == kAudioUnitProperty_SampleRate) {
            const Float64 r = *(const Float64*)in;
            fill_format(au, scope == kAudioUnitScope_Input ? au->in_ch : au->out_ch, &f);
            f.mSampleRate = r;
        } else {
            f = *(const AudioStreamBasicDescription*)in;
        }
        if (!format_ok(&f))
            return kAudioUnitErr_FormatNotSupported;
        if (au->initialized) {
            AudioStreamBasicDescription cur;
            fill_format(au, scope == kAudioUnitScope_Input ? au->in_ch : au->out_ch, &cur);
            if (f.mSampleRate != cur.mSampleRate || f.mChannelsPerFrame != cur.mChannelsPerFrame)
                return kAudioUnitErr_Initialized;
            break;
        }
        if (scope == kAudioUnitScope_Input)
            au->in_ch = f.mChannelsPerFrame;
        else
            au->out_ch = f.mChannelsPerFrame;
        if (f.mSampleRate != au->rate) {
            /* One rate for both sides: tell listeners of the other side and the latency. */
            au->rate = f.mSampleRate;
            notify_property(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0);
            notify_property(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0);
            notify_property(au, kAudioUnitProperty_SampleRate, kAudioUnitScope_Input, 0);
            notify_property(au, kAudioUnitProperty_SampleRate, kAudioUnitScope_Output, 0);
            notify_property(au, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0);
            return noErr;
        }
        break;
    }
    case kAudioUnitProperty_MaximumFramesPerSlice: {
        const UInt32 n = *(const UInt32*)in;
        if (n == 0 || n > 65536)
            return kAudioUnitErr_InvalidPropertyValue;
        if (n != au->max_frames) {
            au->max_frames = n;
            if (au->initialized && !alloc_buffers(au))
                return kAudio_MemFullError;
            if (au->initialized)
                wire_engine(au);
        }
        break;
    }
    case kAudioUnitProperty_BypassEffect: {
        const float enabled = *(const UInt32*)in ? 0.0f : 1.0f;
        if (au->value[PORT_ENABLED] != enabled) {
            au->value[PORT_ENABLED] = enabled;
            notify_parameter(au, PORT_ENABLED);
        }
        break;
    }
    case kAudioUnitProperty_ShouldAllocateBuffer:
        au->should_allocate = *(const UInt32*)in;
        break;
    case kAudioUnitProperty_OfflineRender:
        au->offline = *(const UInt32*)in;
        break;
    case kAudioUnitProperty_PresentPreset: {
        const AUPreset* p = (const AUPreset*)in;
        if (au->preset_name)
            CFRelease(au->preset_name);
        au->preset_name = p->presetName ? CFStringCreateCopy(NULL, p->presetName) : NULL;
        au->preset_number = p->presetNumber;
        break;
    }
    case kAudioUnitProperty_HostCallbacks:
    case kAudioUnitProperty_ContextName:
        break; /* not needed: the pedal uses no tempo or transport */
    default:
        return kAudioUnitErr_InvalidProperty;
    }
    notify_property(au, id, scope, el);
    return noErr;
}

static OSStatus ho_add_property_listener(void* self, AudioUnitPropertyID id, AudioUnitPropertyListenerProc proc, void* data)
{
    TwUnit* au = (TwUnit*)self;
    if (!proc)
        return kAudio_ParamError;
    if (au->n_listeners >= MAX_LISTENERS)
        return kAudio_MemFullError;
    au->listeners[au->n_listeners].id = id;
    au->listeners[au->n_listeners].proc = proc;
    au->listeners[au->n_listeners].data = data;
    ++au->n_listeners;
    return noErr;
}

static void remove_listeners(TwUnit* au, AudioUnitPropertyID id, AudioUnitPropertyListenerProc proc, int match_data, void* data)
{
    int i = 0;
    while (i < au->n_listeners) {
        const Listener* l = &au->listeners[i];
        if (l->id == id && l->proc == proc && (!match_data || l->data == data))
            au->listeners[i] = au->listeners[--au->n_listeners];
        else
            ++i;
    }
}

static OSStatus ho_remove_property_listener(void* self, AudioUnitPropertyID id, AudioUnitPropertyListenerProc proc)
{
    remove_listeners((TwUnit*)self, id, proc, 0, NULL);
    return noErr;
}

static OSStatus ho_remove_property_listener_with_user_data(void* self, AudioUnitPropertyID id,
                                                     AudioUnitPropertyListenerProc proc, void* data)
{
    remove_listeners((TwUnit*)self, id, proc, 1, data);
    return noErr;
}

static OSStatus ho_add_render_notify(void* self, AURenderCallback proc, void* data)
{
    TwUnit* au = (TwUnit*)self;
    if (!proc)
        return kAudio_ParamError;
    if (au->n_notifies >= MAX_NOTIFIES)
        return kAudio_MemFullError;
    au->notifies[au->n_notifies].proc = proc;
    au->notifies[au->n_notifies].data = data;
    ++au->n_notifies;
    return noErr;
}

static OSStatus ho_remove_render_notify(void* self, AURenderCallback proc, void* data)
{
    TwUnit* au = (TwUnit*)self;
    int i = 0;
    while (i < au->n_notifies) {
        if (au->notifies[i].proc == proc && au->notifies[i].data == data)
            au->notifies[i] = au->notifies[--au->n_notifies];
        else
            ++i;
    }
    return noErr;
}

/* ---- Parameters ---- */

static OSStatus ho_get_parameter(void* self, AudioUnitParameterID id, AudioUnitScope scope, AudioUnitElement el,
                               AudioUnitParameterValue* value)
{
    TwUnit* au = (TwUnit*)self;
    (void)el;
    if (scope != kAudioUnitScope_Global)
        return kAudioUnitErr_InvalidScope;
    if (!param(id))
        return kAudioUnitErr_InvalidParameter;
    if (!value)
        return kAudio_ParamError;
    *value = au->value[id];
    return noErr;
}

static OSStatus ho_set_parameter(void* self, AudioUnitParameterID id, AudioUnitScope scope, AudioUnitElement el,
                               AudioUnitParameterValue value, UInt32 offset)
{
    TwUnit* au = (TwUnit*)self;
    (void)el;
    (void)offset; /* the engine smooths every control, so per-block is enough */
    if (scope != kAudioUnitScope_Global)
        return kAudioUnitErr_InvalidScope;
    if (!param(id))
        return kAudioUnitErr_InvalidParameter;
    au->value[id] = clamp_param(param(id), value);
    return noErr;
}

static OSStatus ho_schedule_parameters(void* self, const AudioUnitParameterEvent* events, UInt32 n)
{
    UInt32 i;
    for (i = 0; i < n; ++i) {
        const AudioUnitParameterEvent* e = &events[i];
        const AudioUnitParameterValue v = e->eventType == kParameterEvent_Ramped
                                              ? e->eventValues.ramp.endValue
                                              : e->eventValues.immediate.value;
        const OSStatus err = ho_set_parameter(self, e->parameter, e->scope, e->element, v, 0);
        if (err)
            return err;
    }
    return noErr;
}

/* ---- Life cycle and rendering ---- */

static OSStatus ho_initialize(void* self)
{
    TwUnit* au = (TwUnit*)self;
    if (au->initialized)
        return noErr;
    if (!channels_ok(au->in_ch, au->out_ch))
        return kAudioUnitErr_FormatNotSupported;
    if (!au->engine || au->engine->rate != au->rate) {
        if (au->engine)
            engine_free(au->engine);
        au->engine = engine_new(au->rate);
        if (!au->engine)
            return kAudioUnitErr_FailedInitialization;
    }
    if (!alloc_buffers(au))
        return kAudioUnitErr_FailedInitialization;
    wire_engine(au);
    engine_activate(au->engine);
    au->initialized = 1;
    notify_property(au, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0);
    return noErr;
}

static OSStatus ho_uninitialize(void* self)
{
    ((TwUnit*)self)->initialized = 0;
    return noErr;
}

static OSStatus ho_reset(void* self, AudioUnitScope scope, AudioUnitElement el)
{
    TwUnit* au = (TwUnit*)self;
    (void)scope;
    (void)el;
    if (au->initialized && au->engine)
        engine_activate(au->engine);
    return noErr;
}

static void call_notifies(TwUnit* au, AudioUnitRenderActionFlags flag, AudioUnitRenderActionFlags* flags,
                          const AudioTimeStamp* ts, UInt32 bus, UInt32 frames, AudioBufferList* io)
{
    int i;
    for (i = 0; i < au->n_notifies; ++i) {
        AudioUnitRenderActionFlags f = (flags ? *flags : 0) | flag;
        au->notifies[i].proc(au->notifies[i].data, &f, ts, bus, frames, io);
    }
}

static OSStatus pull_input(TwUnit* au, const AudioTimeStamp* ts, UInt32 frames, AudioBufferList* abl)
{
    AudioUnitRenderActionFlags flags = 0;
    UInt32 c;
    abl->mNumberBuffers = au->in_ch;
    for (c = 0; c < au->in_ch; ++c) {
        abl->mBuffers[c].mNumberChannels = 1;
        abl->mBuffers[c].mDataByteSize = frames * sizeof(float);
        abl->mBuffers[c].mData = au->in_buf[c];
    }
    if (au->input_cb.inputProc)
        return au->input_cb.inputProc(au->input_cb.inputProcRefCon, &flags, ts, 0, frames, abl);
    if (au->has_connection)
        return AudioUnitRender(au->connection.sourceAudioUnit, &flags, ts, au->connection.sourceOutputNumber,
                               frames, abl);
    return kAudioUnitErr_NoConnection;
}

static OSStatus ho_render(void* self, AudioUnitRenderActionFlags* flags, const AudioTimeStamp* ts,
                         UInt32 bus, UInt32 frames, AudioBufferList* io)
{
    TwUnit* au = (TwUnit*)self;
    struct {
        AudioBufferList list;
        AudioBuffer extra; /* room for a second channel */
    } in;
    OSStatus err;
    UInt32 c;
    if (!au->initialized)
        return kAudioUnitErr_Uninitialized;
    if (bus != 0)
        return kAudioUnitErr_InvalidElement;
    if (frames > au->max_frames)
        return kAudioUnitErr_TooManyFramesToProcess;
    if (!io || io->mNumberBuffers != au->out_ch)
        return kAudio_ParamError;
    call_notifies(au, kAudioUnitRenderAction_PreRender, flags, ts, bus, frames, io);
    err = pull_input(au, ts, frames, &in.list);
    if (err) {
        au->last_error = err;
        return err;
    }
    for (c = 0; c < io->mNumberBuffers; ++c) {
        if (!io->mBuffers[c].mData)
            io->mBuffers[c].mData = au->out_buf[c];
        io->mBuffers[c].mDataByteSize = frames * sizeof(float);
    }
    {
        /* Stereo in and out: two channels. Otherwise one, copied to the second output. */
        const int nch = in.list.mNumberBuffers >= 2 && io->mNumberBuffers >= 2 ? 2 : 1;
        const float* ins[2] = { NULL, NULL };
        float* outs[2] = { NULL, NULL };
        for (c = 0; c < (UInt32)nch; ++c) {
            ins[c] = (const float*)in.list.mBuffers[c].mData; /* NULL reads as silence */
            outs[c] = (float*)io->mBuffers[c].mData;
        }
        engine_process(au->engine, ins, outs, nch, frames);
        for (c = (UInt32)nch; c < io->mNumberBuffers; ++c)
            memcpy(io->mBuffers[c].mData, io->mBuffers[0].mData, frames * sizeof(float));
    }
    if (flags)
        *flags &= ~kAudioUnitRenderAction_OutputIsSilence;
    call_notifies(au, kAudioUnitRenderAction_PostRender, flags, ts, bus, frames, io);
    return noErr;
}

/* ---- The component plug-in interface ---- */

static OSStatus ho_open(void* self, AudioComponentInstance instance)
{
    ((TwUnit*)self)->self = instance;
    return noErr;
}

static OSStatus ho_close(void* self)
{
    TwUnit* au = (TwUnit*)self;
    if (au->engine)
        engine_free(au->engine);
    free_buffers(au);
    if (au->preset_name)
        CFRelease(au->preset_name);
    free(au);
    return noErr;
}

static AudioComponentMethod ho_lookup(SInt16 selector)
{
    switch (selector) {
    case kAudioUnitInitializeSelect: return (AudioComponentMethod)ho_initialize;
    case kAudioUnitUninitializeSelect: return (AudioComponentMethod)ho_uninitialize;
    case kAudioUnitGetPropertyInfoSelect: return (AudioComponentMethod)ho_get_property_info;
    case kAudioUnitGetPropertySelect: return (AudioComponentMethod)ho_get_property;
    case kAudioUnitSetPropertySelect: return (AudioComponentMethod)ho_set_property;
    case kAudioUnitAddPropertyListenerSelect: return (AudioComponentMethod)ho_add_property_listener;
    case kAudioUnitRemovePropertyListenerSelect: return (AudioComponentMethod)ho_remove_property_listener;
    case kAudioUnitRemovePropertyListenerWithUserDataSelect:
        return (AudioComponentMethod)ho_remove_property_listener_with_user_data;
    case kAudioUnitAddRenderNotifySelect: return (AudioComponentMethod)ho_add_render_notify;
    case kAudioUnitRemoveRenderNotifySelect: return (AudioComponentMethod)ho_remove_render_notify;
    case kAudioUnitGetParameterSelect: return (AudioComponentMethod)ho_get_parameter;
    case kAudioUnitSetParameterSelect: return (AudioComponentMethod)ho_set_parameter;
    case kAudioUnitScheduleParametersSelect: return (AudioComponentMethod)ho_schedule_parameters;
    case kAudioUnitRenderSelect: return (AudioComponentMethod)ho_render;
    case kAudioUnitResetSelect: return (AudioComponentMethod)ho_reset;
    default: return NULL;
    }
}

/* Named in bundle/au/Info.plist. */
EXPORT void* DavidianTwinlineAUFactory(const AudioComponentDescription* desc)
{
    TwUnit* au = (TwUnit*)calloc(1, sizeof(TwUnit));
    int i;
    (void)desc;
    if (!au)
        return NULL;
    au->iface.Open = ho_open;
    au->iface.Close = ho_close;
    au->iface.Lookup = ho_lookup;
    au->iface.reserved = NULL;
    au->rate = 44100.0;
    au->max_frames = 1156; /* the usual AU default */
    au->in_ch = au->out_ch = 2;
    au->should_allocate = 1;
    au->preset_number = -1;
    for (i = 0; i < N_PARAMS; ++i)
        au->value[PARAM_PORTS[i]] = param_info(PARAM_PORTS[i])->def;
    return au;
}

/* ---- The Cocoa view: the panel in a container the host owns ---- */

typedef struct {
    PanelWindow win;
    AudioUnit au;
    AUEventListenerRef listener;
} ViewState;

static AudioUnitParameter au_param(ViewState* st, int port)
{
    AudioUnitParameter p;
    p.mAudioUnit = st->au;
    p.mParameterID = (AudioUnitParameterID)port;
    p.mScope = kAudioUnitScope_Global;
    p.mElement = 0;
    return p;
}

static void view_write(void* host, int port, float value)
{
    ViewState* st = (ViewState*)host;
    AudioUnitParameter p = au_param(st, port);
    if (param((AudioUnitParameterID)port))
        AUParameterSet(st->listener, st, &p, value, 0); /* sets it and tells the host */
}

static void view_gesture(void* host, int port, int begin)
{
    ViewState* st = (ViewState*)host;
    AudioUnitEvent e;
    if (!param((AudioUnitParameterID)port))
        return;
    memset(&e, 0, sizeof e);
    e.mEventType = begin ? kAudioUnitEvent_BeginParameterChangeGesture : kAudioUnitEvent_EndParameterChangeGesture;
    e.mArgument.mParameter = au_param(st, port);
    AUEventListenerNotify(st->listener, st, &e);
}

/* Parameter changes from the host (automation, presets), on the main run loop. */
static void view_event(void* data, void* object, const AudioUnitEvent* e, UInt64 time, AudioUnitParameterValue v)
{
    ViewState* st = (ViewState*)data;
    (void)object;
    (void)time;
    if (e->mEventType != kAudioUnitEvent_ParameterValueChange)
        return;
    panel_set(&st->win.panel, (int)e->mArgument.mParameter.mParameterID, v);
    pw_redraw(&st->win);
}

@interface DavidianTwinlineAUView : NSView {
    ViewState* st;
}
- (id)initWithAudioUnit:(AudioUnit)au;
@end

@implementation DavidianTwinlineAUView

- (id)initWithAudioUnit:(AudioUnit)au
{
    int k;
    self = [super initWithFrame:NSMakeRect(0, 0, PANEL_W, PANEL_H)];
    if (!self)
        return nil;
    st = (ViewState*)calloc(1, sizeof(ViewState));
    if (!st || !panel_init(&st->win.panel, view_write, st)) {
        free(st);
        st = NULL;
        [self release];
        return nil;
    }
    st->au = au;
    st->win.panel.gesture = view_gesture;
    if (!window_open(&st->win, self)) {
        panel_free(&st->win.panel);
        free(st);
        st = NULL;
        [self release];
        return nil;
    }
    if (AUEventListenerCreate(view_event, st, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode, 0.02f, 0.02f,
                              &st->listener) != noErr)
        st->listener = NULL;
    for (k = 0; k < N_PARAMS; ++k) {
        const int i = PARAM_PORTS[k];
        AudioUnitParameterValue v;
        AudioUnitEvent e;
        if (AudioUnitGetParameter(au, (AudioUnitParameterID)i, kAudioUnitScope_Global, 0, &v) == noErr)
            panel_set(&st->win.panel, i, v);
        if (st->listener) {
            memset(&e, 0, sizeof e);
            e.mEventType = kAudioUnitEvent_ParameterValueChange;
            e.mArgument.mParameter = au_param(st, i);
            AUEventListenerAddEventType(st->listener, st, &e);
        }
    }
    pw_redraw(&st->win);
    return self;
}

- (BOOL)isFlipped { return YES; }

- (void)dealloc
{
    if (st) {
        if (st->listener)
            AUListenerDispose(st->listener);
        window_close(&st->win);
        panel_free(&st->win.panel);
        free(st);
        st = NULL;
    }
    [super dealloc];
}

@end

/* The class the host finds through kAudioUnitProperty_CocoaUI. */
@interface DavidianTwinlineAUViewFactory : NSObject <AUCocoaUIBase>
@end

@implementation DavidianTwinlineAUViewFactory

- (unsigned)interfaceVersion { return 0; }

- (NSString*)description { return @"Davidian Twinline"; }

- (NSView*)uiViewForAudioUnit:(AudioUnit)au withSize:(NSSize)size
{
    (void)size; /* the panel has one size */
    return [[[DavidianTwinlineAUView alloc] initWithAudioUnit:au] autorelease];
}

@end
