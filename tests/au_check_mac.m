/* SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 Davidian */
/* Opens the installed Audio Unit the way a macOS host does: finds it by its component
 * description, renders audio through it, checks bypass, parameters and saved state, then
 * loads its Cocoa view through kAudioUnitProperty_CocoaUI, drives it with mouse events and
 * saves a screenshot. Apple's auval is run by the CI as well.
 * Install the component first (make install), then:
 * Build: clang -x objective-c -fno-objc-arc tests/au_check_mac.m -framework Cocoa \
 *        -framework AudioToolbox -framework AudioUnit -framework CoreAudio -o au_check_mac
 * Usage: au_check_mac [screenshot.png] */
#import <AudioToolbox/AudioToolbox.h>
#import <AudioUnit/AUCocoaUIView.h>
#import <Cocoa/Cocoa.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

#include "../src/params.h"
#include "../src/ports.h"

#define PANEL_W 560 /* must match src/ui/panel.h */
#define PANEL_H 430
#define RATE 48000.0
#define N 48000
#define BLOCK 512

static int failures;
static int last_port = -1, writes;
static float last_value;
static int begins, ends;
static AudioUnit unit;
static float snapshot[PORT_COUNT];

static void check(const char* what, int ok)
{
    printf("  [%s] %s\n", ok ? "PASS" : "FAIL", what);
    if (!ok)
        ++failures;
}

static float get_param(int id)
{
    AudioUnitParameterValue v = NAN;
    AudioUnitGetParameter(unit, (AudioUnitParameterID)id, kAudioUnitScope_Global, 0, &v);
    return v;
}

static void set_param(int id, float v)
{
    AudioUnitSetParameter(unit, (AudioUnitParameterID)id, kAudioUnitScope_Global, 0, v, 0);
}

/* The view sets parameters on the unit directly. After each mouse action, compare them
 * with the last snapshot to see what it sent. */
static void take_snapshot(void)
{
    int i;
    for (i = 0; i < N_PARAMS; ++i)
        snapshot[PARAM_PORTS[i]] = get_param(PARAM_PORTS[i]);
}

static void poll_params(void)
{
    int i;
    for (i = 0; i < N_PARAMS; ++i) {
        const int id = PARAM_PORTS[i];
        const float v = get_param(id);
        if (v != snapshot[id]) {
            last_port = id;
            last_value = v;
            ++writes;
            snapshot[id] = v;
        }
    }
}

/* ---- Audio ---- */

static float input[N];
static int in_pos;

static OSStatus feed(void* ref, AudioUnitRenderActionFlags* flags, const AudioTimeStamp* ts, UInt32 bus,
                     UInt32 frames, AudioBufferList* io)
{
    UInt32 c;
    (void)ref; (void)flags; (void)ts; (void)bus;
    for (c = 0; c < io->mNumberBuffers; ++c)
        memcpy(io->mBuffers[c].mData, input + in_pos, frames * sizeof(float));
    return noErr;
}

static int set_format(UInt32 in_ch, UInt32 out_ch)
{
    AudioStreamBasicDescription f;
    memset(&f, 0, sizeof f);
    f.mSampleRate = RATE;
    f.mFormatID = kAudioFormatLinearPCM;
    f.mFormatFlags = kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved;
    f.mBytesPerPacket = f.mBytesPerFrame = 4;
    f.mFramesPerPacket = 1;
    f.mBitsPerChannel = 32;
    f.mChannelsPerFrame = in_ch;
    if (AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &f, sizeof f))
        return 0;
    f.mChannelsPerFrame = out_ch;
    return AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &f, sizeof f) == noErr;
}

/* Renders the whole input through the unit into l (and r when stereo out). */
static int render(float* l, float* r, UInt32 out_ch)
{
    AudioTimeStamp ts;
    struct { AudioBufferList list; AudioBuffer extra; } out;
    memset(&ts, 0, sizeof ts);
    ts.mFlags = kAudioTimeStampSampleTimeValid;
    for (in_pos = 0; in_pos < N; in_pos += BLOCK) {
        /* N is not a multiple of BLOCK: the last block is shorter */
        const UInt32 n = N - in_pos < BLOCK ? (UInt32)(N - in_pos) : BLOCK;
        AudioUnitRenderActionFlags flags = 0;
        UInt32 c;
        out.list.mNumberBuffers = out_ch;
        for (c = 0; c < out_ch; ++c) {
            out.list.mBuffers[c].mNumberChannels = 1;
            out.list.mBuffers[c].mDataByteSize = n * sizeof(float);
            out.list.mBuffers[c].mData = NULL; /* let the unit supply the buffers */
        }
        ts.mSampleTime = in_pos;
        if (AudioUnitRender(unit, &flags, &ts, 0, n, &out.list) != noErr)
            return 0;
        memcpy(l + in_pos, out.list.mBuffers[0].mData, n * sizeof(float));
        if (r && out_ch > 1)
            memcpy(r + in_pos, out.list.mBuffers[1].mData, n * sizeof(float));
    }
    return 1;
}

static double rms(const float* x, int n)
{
    double s = 0;
    int i;
    for (i = 0; i < n; ++i)
        s += (double)x[i] * x[i];
    return sqrt(s / n);
}

static double max_err(const float* a, const float* b, int from, int to)
{
    double e = 0;
    int i;
    for (i = from; i < to; ++i)
        e = fmax(e, fabs(a[i] - b[i]));
    return e;
}

/* ---- GUI helpers ---- */

static NSEvent* mouse(NSEventType type, NSView* v, float x, float y, int clicks)
{
    NSPoint p = [v convertPoint:NSMakePoint(x, y) toView:nil];
    return [NSEvent mouseEventWithType:type location:p modifierFlags:0 timestamp:0
                          windowNumber:[[v window] windowNumber] context:nil eventNumber:0
                            clickCount:clicks pressure:1.0f];
}

static void click(NSView* v, float x, float y)
{
    [v mouseDown:mouse(NSEventTypeLeftMouseDown, v, x, y, 1)];
    [v mouseUp:mouse(NSEventTypeLeftMouseUp, v, x, y, 1)];
    poll_params();
}

static void drag(NSView* v, float x, float y, float dy)
{
    int i;
    [v mouseDown:mouse(NSEventTypeLeftMouseDown, v, x, y, 1)];
    for (i = 1; i <= 6; ++i)
        [v mouseDragged:mouse(NSEventTypeLeftMouseDragged, v, x, y + dy * i / 6, 1)];
    [v mouseUp:mouse(NSEventTypeLeftMouseUp, v, x, y + dy, 1)];
    poll_params();
}

static void on_event(void* data, void* object, const AudioUnitEvent* e, UInt64 time, AudioUnitParameterValue v)
{
    (void)data; (void)object; (void)time; (void)v;
    if (e->mEventType == kAudioUnitEvent_BeginParameterChangeGesture)
        ++begins;
    else if (e->mEventType == kAudioUnitEvent_EndParameterChangeGesture)
        ++ends;
}

static void spin(double secs) { CFRunLoopRunInMode(kCFRunLoopDefaultMode, secs, false); }

int main(int argc, char** argv)
{
    @autoreleasepool {
        static float l[N], r[N];
        AudioComponentDescription desc = { kAudioUnitType_Effect, 'Twln', 'Dvdn', 0, 0 };
        AudioComponent comp;
        CFStringRef name = NULL;
        char label[200], text[128];
        AURenderCallbackStruct cb = { feed, NULL };
        Float64 latency = -1, tail = -1;
        UInt32 size, bypass, n_params;
        CFPropertyListRef state = NULL;
        AudioUnitCocoaViewInfo vi;
        double wet, err;
        int i, ok;

        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

        comp = AudioComponentFindNext(NULL, &desc);
        check("the system finds the Audio Unit (aufx Twln Dvdn)", comp != NULL);
        if (!comp)
            return 1;
        AudioComponentCopyName(comp, &name);
        text[0] = 0;
        if (name)
            CFStringGetCString(name, text, sizeof text, kCFStringEncodingUTF8);
        snprintf(label, sizeof label, "its name is \"%s\"", text);
        check(label, !strcmp(text, "Davidian: Twinline"));
        check("opens an instance", AudioComponentInstanceNew(comp, &unit) == noErr && unit);
        if (!unit)
            return 1;

        size = 0;
        AudioUnitGetPropertyInfo(unit, kAudioUnitProperty_ParameterList, kAudioUnitScope_Global, 0, &size, NULL);
        n_params = size / sizeof(AudioUnitParameterID);
        snprintf(label, sizeof label, "%u parameters", n_params);
        check(label, n_params == (UInt32)N_PARAMS);
        check("parameters start at their defaults (Blend 0.75, footswitch on, not bypassed)",
              get_param(PORT_BLEND) == 0.75f && get_param(PORT_ON) == 1.0f && get_param(PORT_ENABLED) == 1.0f);
        check("refuses 2 in / 1 out", set_format(2, 1) && AudioUnitInitialize(unit) != noErr);

        ok = set_format(1, 1)
            && AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, sizeof cb) == noErr
            && AudioUnitInitialize(unit) == noErr;
        check("initializes at 48 kHz, mono", ok);
        if (!ok)
            return 1;
        size = sizeof latency;
        AudioUnitGetProperty(unit, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0, &latency, &size);
        size = sizeof tail;
        AudioUnitGetProperty(unit, kAudioUnitProperty_TailTime, kAudioUnitScope_Global, 0, &tail, &size);
        snprintf(label, sizeof label, "no latency, and a tail long enough for the echo (%.2f s)", tail);
        check(label, latency == 0.0 && tail >= 0.1);

        for (i = 0; i < N; ++i)
            input[i] = (float)(0.2 * sin(2.0 * M_PI * 220.0 * i / RATE));
        set_param(PORT_BLEND, 0.0f);
        ok = render(l, NULL, 1);
        err = max_err(l, input, N / 2, N);
        snprintf(label, sizeof label, "Blend fully dry gives the input back (error %.1e)", err);
        check(label, ok && err < 0.02);
        set_param(PORT_BLEND, 1.0f);
        ok = render(l, NULL, 1);
        wet = rms(l + N / 2, N / 2);
        err = max_err(l, input, N / 2, N);
        snprintf(label, sizeof label, "Blend fully wet gives the delayed signal: rms %.3f", wet);
        check(label, ok && isfinite(wet) && wet > 0.1 && err > 0.05);
        bypass = 1;
        AudioUnitSetProperty(unit, kAudioUnitProperty_BypassEffect, kAudioUnitScope_Global, 0, &bypass, sizeof bypass);
        check("the host's bypass sets the Enabled parameter off", get_param(PORT_ENABLED) == 0.0f);
        ok = render(l, NULL, 1);
        err = max_err(l, input, N / 2, N);
        snprintf(label, sizeof label, "bypass passes the input through untouched (error %.1e)", err);
        check(label, ok && err < 1e-6);
        bypass = 0;
        AudioUnitSetProperty(unit, kAudioUnitProperty_BypassEffect, kAudioUnitScope_Global, 0, &bypass, sizeof bypass);

        AudioUnitUninitialize(unit);
        {
            const int fmt = set_format(1, 2);
            const OSStatus init = fmt ? AudioUnitInitialize(unit) : -1;
            const int rendered = init == noErr && render(l, r, 2);
            ok = rendered && !memcmp(l, r, sizeof l) && rms(l + N / 2, N / 2) > 1e-3;
            snprintf(label, sizeof label, "1 in / 2 out carries the same signal on both sides (format %d, init %d, render %d)",
                     fmt, (int)init, rendered);
            check(label, ok);
        }

        /* Saved state */
        {
            OSStatus get, set = -1;
            set_param(PORT_LEVEL, 12.0f);
            set_param(PORT_DELAY, 1.0f);
            size = sizeof state;
            get = AudioUnitGetProperty(unit, kAudioUnitProperty_ClassInfo, kAudioUnitScope_Global, 0, &state, &size);
            snprintf(label, sizeof label, "saves its state (ClassInfo, status %d)", (int)get);
            check(label, get == noErr && state);
            set_param(PORT_LEVEL, 3.0f);
            set_param(PORT_DELAY, 0.0f);
            if (state)
                set = AudioUnitSetProperty(unit, kAudioUnitProperty_ClassInfo, kAudioUnitScope_Global, 0, &state, sizeof state);
            snprintf(label, sizeof label, "restores it (status %d, Level %+.1f dB, Delay %.0f)", (int)set,
                     get_param(PORT_LEVEL), get_param(PORT_DELAY));
            check(label, set == noErr && fabsf(get_param(PORT_LEVEL) - 12.0f) < 1e-6f && get_param(PORT_DELAY) == 1.0f);
        }
        if (state)
            CFRelease(state);
        set_param(PORT_LEVEL, 0.0f);
        set_param(PORT_DELAY, 0.0f);
        set_param(PORT_BLEND, 0.75f);

        /* The Cocoa view */
        {
            OSStatus st;
            size = sizeof vi;
            memset(&vi, 0, sizeof vi);
            st = AudioUnitGetProperty(unit, kAudioUnitProperty_CocoaUI, kAudioUnitScope_Global, 0, &vi, &size);
            ok = st == noErr && vi.mCocoaAUViewBundleLocation && vi.mCocoaAUViewClass[0];
            snprintf(label, sizeof label, "offers a Cocoa view (status %d)", (int)st);
            check(label, ok);
        }
        if (ok) {
            NSBundle* bundle = [NSBundle bundleWithURL:(NSURL*)vi.mCocoaAUViewBundleLocation];
            Class cls = [bundle classNamed:(NSString*)vi.mCocoaAUViewClass[0]];
            id<AUCocoaUIBase> factory = cls ? [[cls alloc] init] : nil;
            NSView* view = factory ? [factory uiViewForAudioUnit:unit withSize:NSMakeSize(PANEL_W, PANEL_H)] : nil;
            NSWindow* win;
            NSView* panel;
            AUEventListenerRef listener = NULL;
            check("the view factory class loads and conforms to AUCocoaUIBase",
                  cls && [cls conformsToProtocol:@protocol(AUCocoaUIBase)]);
            snprintf(label, sizeof label, "the factory makes a %.0fx%.0f view",
                     view ? [view frame].size.width : 0.0, view ? [view frame].size.height : 0.0);
            check(label, view && [view frame].size.width == PANEL_W && [view frame].size.height == PANEL_H);
            if (!view)
                return 1;
            [view retain];
            win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, PANEL_W, PANEL_H)
                                              styleMask:NSWindowStyleMaskBorderless
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
            [win setFrameOrigin:NSMakePoint(0, 0)];
            [[win contentView] addSubview:view];
            panel = [[view subviews] count] ? [[view subviews] objectAtIndex:0] : nil;
            check("the panel is inside it", panel != nil);
            if (!panel)
                return 1;

            AUEventListenerCreate(on_event, NULL, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode, 0, 0, &listener);
            for (i = 0; i < N_PARAMS; ++i) {
                AudioUnitEvent e;
                memset(&e, 0, sizeof e);
                e.mArgument.mParameter.mAudioUnit = unit;
                e.mArgument.mParameter.mParameterID = (AudioUnitParameterID)PARAM_PORTS[i];
                e.mArgument.mParameter.mScope = kAudioUnitScope_Global;
                e.mEventType = kAudioUnitEvent_BeginParameterChangeGesture;
                AUEventListenerAddEventType(listener, NULL, &e);
                e.mEventType = kAudioUnitEvent_EndParameterChangeGesture;
                AUEventListenerAddEventType(listener, NULL, &e);
            }
            take_snapshot();
            spin(0.1);

            drag(panel, 96, 166, -90);
            snprintf(label, sizeof label, "dragging Level up 90 pt sets port %d = %.3f", last_port, last_value);
            check(label, last_port == PORT_LEVEL && fabsf(last_value - 10.0f) < 0.05f);
            click(panel, 430, 166 + 18);
            check("clicking the bottom of the Delay switch selects Slap", last_port == PORT_DELAY && last_value == 1.0f);
            click(panel, 280, 352);
            check("footswitch turns the pedal off", last_port == PORT_ON && last_value == 0.0f);
            click(panel, 280, 352);
            check("footswitch turns it back on", last_port == PORT_ON && last_value == 1.0f);

            spin(0.3);
            snprintf(label, sizeof label, "edits are reported as gestures (%d begin, %d end)", begins, ends);
            check(label, begins > 0 && begins == ends);

            /* Automation from the host reaches the panel. */
            {
                AudioUnitParameter p = { unit, PORT_BLEND, kAudioUnitScope_Global, 0 };
                AUParameterSet(NULL, NULL, &p, 0.2f, 0);
                spin(0.2);
            }
            {
                NSBitmapImageRep* rep = [panel bitmapImageRepForCachingDisplayInRect:[panel bounds]];
                [panel cacheDisplayInRect:[panel bounds] toBitmapImageRep:rep];
                if (argc > 1) {
                    NSData* png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
                    check("screenshot written", [png writeToFile:[NSString stringWithUTF8String:argv[1]] atomically:YES]);
                    printf("         %s\n", argv[1]);
                }
            }
            if (listener)
                AUListenerDispose(listener);
            [view removeFromSuperview];
            [view release];
            [win release];
            [(id)factory release];
            CFRelease(vi.mCocoaAUViewBundleLocation);
            CFRelease(vi.mCocoaAUViewClass[0]);
            spin(0.1);
            check("closing the view leaves the unit working", render(l, r, 2));
        }

        AudioUnitUninitialize(unit);
        AudioComponentInstanceDispose(unit);
        if (name)
            CFRelease(name);
        printf(failures ? "\n%d FAILED\n" : "\nAll passed\n", failures);
    }
    return failures ? 1 : 0;
}
