/* SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 Davidian */
/* The parameter table shared by the VST3 and AU wrappers: names, ranges, defaults and the
 * names of each switch position. Indexed by port. The ranges and defaults must match
 * bundle/twinline.ttl and the panel's WIDGETS (src/ui/panel.h). */
#ifndef PARAMS_H
#define PARAMS_H

#include "ports.h"

typedef struct {
    const char* name;
    const char* short_name;
    const char* unit; /* "dB", "%" or "" */
    float min, max, def;
    int npos;                 /* switch positions, or 0 for a continuous control */
    const char* const* opts;  /* npos names */
} ParamInfo;

/* The host-visible parameters, in the order hosts list them. The audio ports sit in the
 * middle of the LV2 port list, so the parameters are listed rather than a range. */
static const int PARAM_PORTS[] = { PORT_LEVEL, PORT_BLEND, PORT_DELAY, PORT_ON, PORT_ENABLED };
#define N_PARAMS ((int)(sizeof PARAM_PORTS / sizeof PARAM_PORTS[0]))

static const char* const DELAY_OPTS[2] = { "Double", "Slap" };
static const char* const ON_OPTS[2] = { "Bypass", "On" };

/* NULL for the audio ports. Blend is the knob position (the audio taper is in the DSP). */
static const ParamInfo PARAM_INFO[PORT_COUNT] = {
    { "Level", "Level", "dB", 0, 20, 0, 0, 0 },
    { "Blend", "Blend", "%", 0, 1, 0.75f, 0, 0 },
    { "Delay", "Delay", "", 0, 1, 0, 2, DELAY_OPTS },
    { 0, 0, 0, 0, 0, 0, 0, 0 },
    { 0, 0, 0, 0, 0, 0, 0, 0 },
    { "Footswitch", "Footsw", "", 0, 1, 1, 2, ON_OPTS },
    { "Enabled", "Enabled", "", 0, 1, 1, 2, ON_OPTS },
};

static const ParamInfo* param_info(int port)
{
    return port >= 0 && port < PORT_COUNT && PARAM_INFO[port].name ? &PARAM_INFO[port] : 0;
}

#endif
