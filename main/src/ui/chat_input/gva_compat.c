/*
 * Compatibility wrapper for deprecated GValueArray access.
 * GStreamer's level element still uses GValueArray (deprecated since GLib 2.32).
 * This wrapper avoids deprecation warnings in Vala code.
 */

#define GLIB_DISABLE_DEPRECATION_WARNINGS
#include <glib-object.h>

GValue* dino_gva_get_nth(void* value_array, guint index) {
    if (value_array == NULL) return NULL;
    G_GNUC_BEGIN_IGNORE_DEPRECATIONS
    return g_value_array_get_nth((GValueArray*) value_array, index);
    G_GNUC_END_IGNORE_DEPRECATIONS
}
