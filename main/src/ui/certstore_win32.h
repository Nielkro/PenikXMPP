/*
 * certstore_win32.h — Export Windows Root CA certificates to PEM file
 *
 * On MinGW/MSYS2, GnuTLS (used by glib-networking) does not read
 * the Windows system certificate store. This helper exports all
 * trusted root certificates from the Windows "ROOT" store into a
 * PEM file that can be used via GTLS_SYSTEM_CA_FILE.
 */

#ifndef CERTSTORE_WIN32_H
#define CERTSTORE_WIN32_H

#include <glib.h>

#ifdef _WIN32

/**
 * Export all certificates from the Windows "ROOT" certificate store
 * to a PEM file at the given path.
 *
 * Returns: TRUE on success (at least one cert exported), FALSE on error.
 */
gboolean certstore_win32_export_pem(const gchar *output_path);

/**
 * Return the active Windows ANSI code page for this process.
 *
 * The DinoX application manifest sets it to CP_UTF8 on supported Windows
 * versions so UTF-8 GLib paths also work in legacy narrow-path libraries.
 */
guint certstore_win32_get_active_code_page(void);

#else

static inline gboolean
certstore_win32_export_pem(const gchar *output_path) {
    (void)output_path;
    return FALSE;
}

static inline guint
certstore_win32_get_active_code_page(void) {
    return 0;
}

#endif

#endif /* CERTSTORE_WIN32_H */
