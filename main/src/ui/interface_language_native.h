#pragma once
#include <glib.h>

/* GLib owns a const string vector. Give Vala an independent, owned GStrv
 * instead of treating that borrowed const vector as mutable gchar **. */
static inline gchar **dinox_dup_language_names(void)
{
    const gchar * const *names = g_get_language_names();
    gsize count = 0;
    while (names[count] != NULL)
        count++;
    gchar **copy = g_new0(gchar *, count + 1);
    for (gsize i = 0; i < count; i++)
        copy[i] = g_strdup(names[i]);
    return copy;
}
