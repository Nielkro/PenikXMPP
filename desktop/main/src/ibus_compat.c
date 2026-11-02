/*
 * Copyright (C) 2026 DinoX contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

#if defined(__linux__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE
#endif

#include "ibus_compat.h"

#if defined(__linux__)
#include <dlfcn.h>
#include <gmodule.h>
#include <link.h>
#include <stdlib.h>
#include <string.h>

#define IBUS_SONAME "libibus-1.0.so.5"
#define IBUS_AFFECTED_FILE "libibus-1.0.so.5.0.529"
#define IBUS_FIXED_FILE "libibus-1.0.so.5.0.530"
#define IBUS_PROBE_SYMBOL "ibus_input_context_post_process_key_event"

static GMutex compat_mutex;
static gboolean private_client_selected;

static int
find_loaded_ibus (struct dl_phdr_info *info, size_t size, void *data)
{
    const gchar *name;

    (void) size;
    (void) data;
    name = strrchr (info->dlpi_name, '/');
    name = name != NULL ? name + 1 : info->dlpi_name;
    return g_str_has_prefix (name, "libibus-") ? 1 : 0;
}

static gboolean
ibus_is_loaded (void)
{
    void *handle;

    if (dl_iterate_phdr (find_loaded_ibus, NULL) != 0)
        return TRUE;

    /* Also recognize a renamed library through its normal ELF SONAME.
     * RTLD_NOLOAD never loads or initializes an absent library. */
    handle = dlopen (IBUS_SONAME, RTLD_NOLOAD | RTLD_LAZY | RTLD_LOCAL);
    if (handle == NULL)
        return FALSE;
    dlclose (handle);
    return TRUE;
}

static gchar *
symbol_library_path (GModule *module)
{
    gpointer symbol = NULL;
    Dl_info info;

    if (!g_module_symbol (module, IBUS_PROBE_SYMBOL, &symbol) ||
        symbol == NULL || dladdr (symbol, &info) == 0 || info.dli_fname == NULL)
        return NULL;

    return realpath (info.dli_fname, NULL);
}

static gboolean
path_has_basename (const gchar *path, const gchar *expected)
{
    const gchar *name;

    if (path == NULL)
        return FALSE;
    name = strrchr (path, '/');
    return strcmp (name != NULL ? name + 1 : path, expected) == 0;
}

gboolean
dinox_ibus_prepare_compat (const gchar *private_path)
{
    gchar *candidate = NULL;
    gchar *installed = NULL;
    gchar *selected = NULL;
    GModule *probe = NULL;
    GModule *private_module = NULL;
    gboolean result = FALSE;
    gboolean affected = FALSE;

    g_mutex_lock (&compat_mutex);
    if (private_client_selected) {
        result = TRUE;
        goto out;
    }

    if (private_path == NULL || !g_path_is_absolute (private_path) ||
        !g_module_supported () || ibus_is_loaded ())
        goto out;

    candidate = realpath (private_path, NULL);
    if (!path_has_basename (candidate, IBUS_FIXED_FILE) ||
        !g_file_test (candidate, G_FILE_TEST_IS_REGULAR))
        goto out;

    /* Looking up an address does not invoke IBus.  In particular, do not
     * call ibus_init(): GTK's IM module owns its type/resource registration. */
    probe = g_module_open (IBUS_SONAME, G_MODULE_BIND_LAZY | G_MODULE_BIND_LOCAL);
    if (probe == NULL)
        goto out;
    installed = symbol_library_path (probe);
    affected = path_has_basename (installed, IBUS_AFFECTED_FILE);
    if (!g_module_close (probe)) {
        probe = NULL;
        goto out;
    }
    probe = NULL;
    if (!affected || ibus_is_loaded ())
        goto out;

    /* The fixed library has the same ABI and SONAME as the affected client.
     * Loading it first lets the normal GTK IM module resolve that dependency.
     * Modern, unknown, and already loaded clients never reach this path. */
    private_module = g_module_open (candidate, G_MODULE_BIND_LAZY);
    if (private_module == NULL)
        goto out;
    selected = symbol_library_path (private_module);
    if (selected == NULL || strcmp (selected, candidate) != 0)
        goto out;

    g_module_make_resident (private_module);
    private_client_selected = TRUE;
    result = TRUE;

out:
    if (probe != NULL)
        g_module_close (probe);
    if (private_module != NULL)
        g_module_close (private_module);
    free (candidate);
    free (installed);
    free (selected);
    g_mutex_unlock (&compat_mutex);
    return result;
}

#else

gboolean
dinox_ibus_prepare_compat (const gchar *private_path)
{
    (void) private_path;
    return FALSE;
}

#endif
