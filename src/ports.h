/* SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 Davidian */
/* Port indices, shared by the plugin and its GUI. They must match bundle/twinline.ttl. */
#ifndef PORTS_H
#define PORTS_H

#define DT_URI    "urn:davidian:twinline"
#define DT_UI_URI "urn:davidian:twinline#ui"

enum {
    PORT_LEVEL, PORT_BLEND, PORT_DELAY, PORT_IN, PORT_OUT,
    PORT_ON,      /* the pedal's footswitch: off is true bypass */
    PORT_ENABLED, /* the host's bypass (lv2:enabled) */
    PORT_COUNT
};

#endif
