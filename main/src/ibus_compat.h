/*
 * Copyright (C) 2026 DinoX contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

#ifndef DINOX_IBUS_COMPAT_H
#define DINOX_IBUS_COMPAT_H

#include <glib.h>

G_BEGIN_DECLS

/* Call before GTK creates any input contexts.  Never initializes IBus or
 * changes the process environment.  TRUE means the private client library
 * has been selected; FALSE leaves the installed client library in use. */
gboolean dinox_ibus_prepare_compat (const gchar *private_path);

G_END_DECLS

#endif
