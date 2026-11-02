/*
 * Win32 Shell_NotifyIcon systray helper for DinoX.
 * Provides a notification-area icon with left-click toggle and right-click popup menu.
 */

#ifndef SYSTRAY_WIN32_H
#define SYSTRAY_WIN32_H

#include <glib.h>

/* Callback: user clicked a menu item (menu_id = 0..N-1 items, or -1 for left-click,
 * -2 for "always show window" from second instance activation) */
typedef void (*SystrayWin32Callback)(int menu_id, gpointer user_data);

/* Callback: user clicked a balloon notification */
typedef void (*SystrayWin32BalloonCallback)(gpointer user_data);

/* Check if another DinoX instance is already running (named mutex).
 * If yes, returns FALSE (caller should pass any startup payload, activate the
 * existing instance, then exit).
 * If no, acquires the mutex and returns TRUE (caller is the primary instance). */
gboolean systray_win32_check_single_instance (void);

/* Ask the existing DinoX tray message window to show itself. */
gboolean systray_win32_activate_existing_instance (void);

/* Initialise the tray icon.  tooltip_utf8 is shown on hover.
 * icon_resource_id: resource index in the .exe (1 = IDI_ICON1 from dinox.rc)
 * Returns TRUE on success. */
gboolean systray_win32_init   (const gchar          *tooltip_utf8,
                                int                   icon_resource_id,
                                SystrayWin32Callback  callback,
                                gpointer              user_data);

/* Replace the entire popup menu.  labels is a NULL-terminated array of
 * UTF-8 strings.  An empty string ("") inserts a separator.
 * icons: one icon kind per label (1 window, 2..5 presence, 6 message,
 * 7 sound, 8 notification, 9 preferences, 10 quit).
 * checked_mask: native radio state for presence, checkbox state for toggles. */
void     systray_win32_set_menu (gchar **labels, const gint *icons, guint32 checked_mask);
void     systray_win32_set_menu_theme (gboolean dark, gboolean website);

/* Update the hover tooltip. */
void     systray_win32_set_tooltip (const gchar *tooltip_utf8);

/* Show a balloon notification (title + body).
 * icon_type: 0 = none, 1 = info, 2 = warning, 3 = error.
 * Serialized with other balloons. Each item owns user data through destroy,
 * including rejected, cancelled and replaced queued notifications. */
void     systray_win32_show_balloon (const gchar                  *title_utf8,
                                     const gchar                  *body_utf8,
                                     int                           icon_type,
                                     SystrayWin32BalloonCallback   callback,
                                     gpointer                      balloon_user_data,
                                     GDestroyNotify                destroy,
                                     const gchar                  *key);

/* Remove matching queued/active balloons; NULL matches all.
 * prefix selects a namespace such as "conv:". */
void     systray_win32_hide_balloon (const gchar *key, gboolean prefix);

/* Remove tray icon and clean up. */
void     systray_win32_cleanup (void);

/* Attach to parent console (if launched from CMD/MSYS2).
 * With -mwindows the EXE has no console by default; this re-attaches
 * stdout/stderr to an existing parent console so log output is visible
 * when the user runs dinox.exe from a terminal.  Explorer launches allocate
 * and immediately hide a private console inherited by console helpers. */
void     systray_win32_attach_parent_console (void);

/* Return the native Windows system directory as newly allocated UTF-8. */
gchar   *systray_win32_get_system_directory (void);

/* Set the process-level AppUserModelID (must be called BEFORE any windows
 * are created).  This controls how Windows groups the app in the taskbar
 * and is required for jump list suppression to work correctly. */
void     systray_win32_set_app_id (const gchar *app_id_utf8);

/* Register DinoX as the current user's xmpp: URL protocol handler.
 * Uses HKCU only, so no administrator rights or installer are required. */
gboolean systray_win32_register_xmpp_protocol_handler (const gchar *exe_path_utf8);

/* Open a local file through the Windows shell/default application. */
gboolean systray_win32_open_file (const gchar *path_utf8);

/* Return TRUE only when the current foreground window belongs to another
 * process. A NULL/transitioning foreground window is treated as internal so
 * callers do not close GTK native popovers during Win32 focus hand-off. */
gboolean systray_win32_foreground_window_is_external (void);

/* Suppress Windows CRT invalid-parameter-handler assertions.
 * GStreamer's MediaFoundation plugin scanning triggers CRT invalid parameter
 * calls in worker threads, which corrupts GLib's handler stack and causes
 * GLib-CRITICAL (recursed) g_win32_pop_invalid_parameter_handler crashes.
 * Call this BEFORE Gst.init(). */
void     systray_win32_suppress_crt_assertions (void);

#endif /* SYSTRAY_WIN32_H */
