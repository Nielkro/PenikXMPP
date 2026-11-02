/*
 * Minimal DBusMenu exporter for the Linux StatusNotifierItem tray menu.
 *
 * This implements the small com.canonical.dbusmenu surface DinoX needs for
 * status selection and quit, avoiding the external libdbusmenu dependency.
 */

#ifndef SYSTRAY_DBUSMENU_H
#define SYSTRAY_DBUSMENU_H

#include <gio/gio.h>

typedef struct _SystrayDbusMenuServer SystrayDbusMenuServer;

typedef void (*SystrayDbusMenuActivateFunc) (gint     item_id,
                                             gpointer user_data);

SystrayDbusMenuServer *systray_dbusmenu_server_new      (GDBusConnection              *connection,
                                                         const gchar                  *object_path,
                                                         SystrayDbusMenuActivateFunc   activate_func,
                                                         gpointer                      user_data,
                                                         GError                      **error);

void                   systray_dbusmenu_server_set_menu (SystrayDbusMenuServer        *server,
                                                         const gchar * const          *labels,
                                                         guint32                       checked_mask);

void                   systray_dbusmenu_server_set_rtl  (SystrayDbusMenuServer *server,
                                                        gboolean               rtl);

/* Cache an item's PNG; publish the completed update with set_menu(). */
void                   systray_dbusmenu_server_set_icon_data (SystrayDbusMenuServer *server,
                                                             gint                   item_id,
                                                             GBytes                *png);

void                   systray_dbusmenu_server_free     (SystrayDbusMenuServer        *server);

#endif
