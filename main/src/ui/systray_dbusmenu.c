/*
 * Minimal DBusMenu exporter for the Linux StatusNotifierItem tray menu.
 */

#include "systray_dbusmenu.h"

#define DBUSMENU_IFACE "com.canonical.dbusmenu"

struct _SystrayDbusMenuServer {
    GDBusConnection *connection;
    gchar *object_path;
    guint registration_id;
    guint revision;
    gchar **labels;
    guint32 checked_mask;
    gboolean rtl;
    GHashTable *icon_data;
    SystrayDbusMenuActivateFunc activate_func;
    gpointer user_data;
};

static const gchar dbusmenu_xml[] =
"<node>"
"  <interface name='com.canonical.dbusmenu'>"
"    <property name='Version' type='u' access='read'/>"
"    <property name='TextDirection' type='s' access='read'/>"
"    <property name='Status' type='s' access='read'/>"
"    <property name='IconThemePath' type='as' access='read'/>"
"    <method name='GetLayout'>"
"      <arg name='parentId' type='i' direction='in'/>"
"      <arg name='recursionDepth' type='i' direction='in'/>"
"      <arg name='propertyNames' type='as' direction='in'/>"
"      <arg name='revision' type='u' direction='out'/>"
"      <arg name='layout' type='(ia{sv}av)' direction='out'/>"
"    </method>"
"    <method name='GetGroupProperties'>"
"      <arg name='ids' type='ai' direction='in'/>"
"      <arg name='propertyNames' type='as' direction='in'/>"
"      <arg name='properties' type='a(ia{sv})' direction='out'/>"
"    </method>"
"    <method name='GetProperty'>"
"      <arg name='id' type='i' direction='in'/>"
"      <arg name='name' type='s' direction='in'/>"
"      <arg name='value' type='v' direction='out'/>"
"    </method>"
"    <method name='Event'>"
"      <arg name='id' type='i' direction='in'/>"
"      <arg name='eventId' type='s' direction='in'/>"
"      <arg name='data' type='v' direction='in'/>"
"      <arg name='timestamp' type='u' direction='in'/>"
"    </method>"
"    <method name='EventGroup'>"
"      <arg name='events' type='a(isvu)' direction='in'/>"
"      <arg name='idErrors' type='ai' direction='out'/>"
"    </method>"
"    <method name='AboutToShow'>"
"      <arg name='id' type='i' direction='in'/>"
"      <arg name='needUpdate' type='b' direction='out'/>"
"    </method>"
"    <method name='AboutToShowGroup'>"
"      <arg name='ids' type='ai' direction='in'/>"
"      <arg name='updatesNeeded' type='ai' direction='out'/>"
"      <arg name='idErrors' type='ai' direction='out'/>"
"    </method>"
"    <signal name='ItemsPropertiesUpdated'>"
"      <arg name='updatedProps' type='a(ia{sv})'/>"
"      <arg name='removedProps' type='a(ias)'/>"
"    </signal>"
"    <signal name='LayoutUpdated'>"
"      <arg name='revision' type='u'/>"
"      <arg name='parent' type='i'/>"
"    </signal>"
"  </interface>"
"</node>";

static GDBusNodeInfo *node_info = NULL;

/* These are plain translated labels, including user-written status text.
 * DBusMenu interprets single underscores as accelerators; escape them only
 * at the wire boundary so literal names remain intact on the desktop. */
static GVariant *
label_variant (const gchar *label)
{
    GString *escaped = g_string_new (NULL);
    for (const gchar *p = label != NULL ? label : ""; *p; p++) {
        if (*p == '_') g_string_append_c (escaped, '_');
        g_string_append_c (escaped, *p);
    }
    return g_variant_new_take_string (g_string_free (escaped, FALSE));
}

static gboolean
is_valid_item_id (SystrayDbusMenuServer *server,
                  gint                   id)
{
    return server != NULL && server->labels != NULL && id >= 0 && id < (gint) g_strv_length (server->labels);
}

static const gchar *
fallback_icon_name (SystrayDbusMenuServer *server,
                    gint                   id)
{
    if (g_hash_table_contains (server->icon_data, GINT_TO_POINTER (id))) return NULL;
    if (id == 5) return "document-edit-symbolic";
    if (id == 9) return "preferences-system-symbolic";
    if (id == 11) return "application-exit-symbolic";
    return NULL;
}

static void
add_item_properties (SystrayDbusMenuServer *server,
                     gint                   id,
                     GVariantBuilder       *props)
{
    if (id == 0) {
        g_variant_builder_add (props, "{sv}", "children-display", g_variant_new_string ("submenu"));
        return;
    }

    if (!is_valid_item_id (server, id)) {
        return;
    }

    const gchar *label = server->labels[id];
    gboolean is_separator = label == NULL || label[0] == '\0';

    g_variant_builder_add (props, "{sv}", "visible", g_variant_new_boolean (TRUE));
    g_variant_builder_add (props, "{sv}", "enabled", g_variant_new_boolean (!is_separator));

    if (is_separator) {
        g_variant_builder_add (props, "{sv}", "type", g_variant_new_string ("separator"));
        return;
    }

    g_variant_builder_add (props, "{sv}", "label", label_variant (label));

    GBytes *png = g_hash_table_lookup (server->icon_data, GINT_TO_POINTER (id));
    if (png != NULL) {
        g_variant_builder_add (props, "{sv}", "icon-data",
            g_variant_new_from_bytes (G_VARIANT_TYPE ("ay"), png, TRUE));
    }

    if (id >= 1 && id <= 4) {
        g_variant_builder_add (props, "{sv}", "toggle-type", g_variant_new_string ("radio"));
        g_variant_builder_add (props, "{sv}", "toggle-state",
            g_variant_new_int32 ((server->checked_mask & (1u << (id - 1))) != 0 ? 1 : 0));
    } else if (id == 6 || id == 7) {
        g_variant_builder_add (props, "{sv}", "toggle-type", g_variant_new_string ("checkmark"));
        g_variant_builder_add (props, "{sv}", "toggle-state",
            g_variant_new_int32 ((server->checked_mask & (1u << (id - 1))) != 0 ? 1 : 0));
    }
    const gchar *icon_name = fallback_icon_name (server, id);
    if (icon_name != NULL) {
        g_variant_builder_add (props, "{sv}", "icon-name",
            g_variant_new_string (icon_name));
    }
}

static GVariant *
build_node (SystrayDbusMenuServer *server,
            gint                   id)
{
    GVariantBuilder props;
    GVariantBuilder children;
    g_variant_builder_init (&props, G_VARIANT_TYPE ("a{sv}"));
    g_variant_builder_init (&children, G_VARIANT_TYPE ("av"));

    add_item_properties (server, id, &props);

    if (id == 0 && server->labels != NULL) {
        gsize count = g_strv_length (server->labels);
        for (gint i = 1; i < (gint) count; i++) {
            GVariant *child = build_node (server, i);
            g_variant_builder_add (&children, "v", child);
        }
    }

    return g_variant_new ("(i@a{sv}@av)", id, g_variant_builder_end (&props),
        g_variant_builder_end (&children));
}

static GVariant *
build_properties_for_id (SystrayDbusMenuServer *server,
                         gint                   id)
{
    GVariantBuilder props;
    g_variant_builder_init (&props, G_VARIANT_TYPE ("a{sv}"));
    add_item_properties (server, id, &props);
    return g_variant_new ("(i@a{sv})", id, g_variant_builder_end (&props));
}

static GVariant *
build_property_value (SystrayDbusMenuServer *server,
                      gint                   id,
                      const gchar           *name)
{
    if (id == 0 && g_strcmp0 (name, "children-display") == 0) {
        return g_variant_new_variant (g_variant_new_string ("submenu"));
    }

    if (!is_valid_item_id (server, id)) {
        return g_variant_new_variant (g_variant_new_string (""));
    }

    const gchar *label = server->labels[id];
    gboolean is_separator = label == NULL || label[0] == '\0';

    if (g_strcmp0 (name, "visible") == 0) {
        return g_variant_new_variant (g_variant_new_boolean (TRUE));
    } else if (g_strcmp0 (name, "enabled") == 0) {
        return g_variant_new_variant (g_variant_new_boolean (!is_separator));
    } else if (g_strcmp0 (name, "type") == 0 && is_separator) {
        return g_variant_new_variant (g_variant_new_string ("separator"));
    } else if (g_strcmp0 (name, "label") == 0) {
        return g_variant_new_variant (label_variant (label));
    } else if (g_strcmp0 (name, "icon-data") == 0) {
        GBytes *png = g_hash_table_lookup (server->icon_data, GINT_TO_POINTER (id));
        return g_variant_new_variant (png != NULL
            ? g_variant_new_from_bytes (G_VARIANT_TYPE ("ay"), png, TRUE)
            : g_variant_new_array (G_VARIANT_TYPE_BYTE, NULL, 0));
    } else if (g_strcmp0 (name, "toggle-type") == 0 && id >= 1 && id <= 4) {
        return g_variant_new_variant (g_variant_new_string ("radio"));
    } else if (g_strcmp0 (name, "toggle-state") == 0 && id >= 1 && id <= 4) {
        return g_variant_new_variant (g_variant_new_int32 (
            (server->checked_mask & (1u << (id - 1))) != 0 ? 1 : 0));
    } else if (g_strcmp0 (name, "toggle-type") == 0 && (id == 6 || id == 7)) {
        return g_variant_new_variant (g_variant_new_string ("checkmark"));
    } else if (g_strcmp0 (name, "toggle-state") == 0 && (id == 6 || id == 7)) {
        return g_variant_new_variant (g_variant_new_int32 (
            (server->checked_mask & (1u << (id - 1))) != 0 ? 1 : 0));
    } else if (g_strcmp0 (name, "icon-name") == 0) {
        const gchar *icon_name = fallback_icon_name (server, id);
        return g_variant_new_variant (g_variant_new_string (icon_name != NULL ? icon_name : ""));
    }

    return g_variant_new_variant (g_variant_new_string (""));
}

static GVariant *
handle_get_property (GDBusConnection  *connection,
                     const gchar      *sender,
                     const gchar      *object_path,
                     const gchar      *interface_name,
                     const gchar      *property_name,
                     GError          **error,
                     gpointer          user_data)
{
    (void) connection;
    (void) sender;
    (void) object_path;
    (void) interface_name;
    (void) error;
    SystrayDbusMenuServer *server = user_data;

    if (g_strcmp0 (property_name, "Version") == 0)
        return g_variant_new_uint32 (3);
    if (g_strcmp0 (property_name, "TextDirection") == 0)
        return g_variant_new_string (server->rtl ? "rtl" : "ltr");
    if (g_strcmp0 (property_name, "Status") == 0)
        return g_variant_new_string ("normal");
    if (g_strcmp0 (property_name, "IconThemePath") == 0)
        return g_variant_new_strv (NULL, 0);
    return NULL;
}

static void
handle_event (SystrayDbusMenuServer *server,
              gint                   id,
              const gchar           *event_id)
{
    if (id <= 0 || server == NULL || server->activate_func == NULL) return;
    if (g_strcmp0 (event_id, "clicked") == 0 ||
        g_strcmp0 (event_id, "activated") == 0 ||
        g_strcmp0 (event_id, "activate") == 0) {
        server->activate_func (id, server->user_data);
    }
}

static void
handle_method_call (GDBusConnection       *connection,
                    const gchar           *sender,
                    const gchar           *object_path,
                    const gchar           *interface_name,
                    const gchar           *method_name,
                    GVariant              *parameters,
                    GDBusMethodInvocation *invocation,
                    gpointer               user_data)
{
    (void) connection;
    (void) sender;
    (void) object_path;
    (void) interface_name;

    SystrayDbusMenuServer *server = user_data;

    if (g_strcmp0 (method_name, "GetLayout") == 0) {
        gint parent_id;
        gint recursion_depth;
        const gchar **property_names;
        g_variant_get (parameters, "(ii^a&s)", &parent_id, &recursion_depth, &property_names);
        g_free (property_names);
        (void) recursion_depth;

        GVariant *layout = build_node (server, parent_id == 0 ? 0 : parent_id);
        g_dbus_method_invocation_return_value (invocation, g_variant_new ("(u@(ia{sv}av))",
            server->revision, layout));
    } else if (g_strcmp0 (method_name, "GetGroupProperties") == 0) {
        GVariantIter *ids;
        const gchar **property_names;
        gint id;
        GVariantBuilder builder;
        g_variant_get (parameters, "(ai^a&s)", &ids, &property_names);
        g_free (property_names);

        g_variant_builder_init (&builder, G_VARIANT_TYPE ("a(ia{sv})"));
        while (g_variant_iter_next (ids, "i", &id)) {
            g_variant_builder_add_value (&builder, build_properties_for_id (server, id));
        }
        g_variant_iter_free (ids);
        g_dbus_method_invocation_return_value (invocation,
            g_variant_new ("(@a(ia{sv}))", g_variant_builder_end (&builder)));
    } else if (g_strcmp0 (method_name, "GetProperty") == 0) {
        gint id;
        const gchar *name;
        g_variant_get (parameters, "(i&s)", &id, &name);
        g_dbus_method_invocation_return_value (invocation,
            g_variant_new ("(@v)", build_property_value (server, id, name)));
    } else if (g_strcmp0 (method_name, "Event") == 0) {
        gint id;
        const gchar *event_id;
        GVariant *data;
        guint32 timestamp;
        g_variant_get (parameters, "(i&svu)", &id, &event_id, &data, &timestamp);
        g_variant_unref (data);
        (void) timestamp;
        handle_event (server, id, event_id);
        g_dbus_method_invocation_return_value (invocation, NULL);
    } else if (g_strcmp0 (method_name, "EventGroup") == 0) {
        GVariantIter *events;
        gint id;
        const gchar *event_id;
        GVariant *data;
        guint32 timestamp;
        GVariantBuilder errors;
        g_variant_get (parameters, "(a(isvu))", &events);
        while (g_variant_iter_next (events, "(i&svu)", &id, &event_id, &data, &timestamp)) {
            g_variant_unref (data);
            (void) timestamp;
            handle_event (server, id, event_id);
        }
        g_variant_iter_free (events);

        g_variant_builder_init (&errors, G_VARIANT_TYPE ("ai"));
        g_dbus_method_invocation_return_value (invocation,
            g_variant_new ("(@ai)", g_variant_builder_end (&errors)));
    } else if (g_strcmp0 (method_name, "AboutToShow") == 0) {
        g_dbus_method_invocation_return_value (invocation, g_variant_new ("(b)", FALSE));
    } else if (g_strcmp0 (method_name, "AboutToShowGroup") == 0) {
        GVariantBuilder updates;
        GVariantBuilder errors;
        g_variant_builder_init (&updates, G_VARIANT_TYPE ("ai"));
        g_variant_builder_init (&errors, G_VARIANT_TYPE ("ai"));
        g_dbus_method_invocation_return_value (invocation,
            g_variant_new ("(@ai@ai)", g_variant_builder_end (&updates),
                g_variant_builder_end (&errors)));
    } else {
        g_dbus_method_invocation_return_dbus_error (invocation,
            "org.freedesktop.DBus.Error.UnknownMethod", method_name);
    }
}

static const GDBusInterfaceVTable dbusmenu_vtable = {
    .method_call = handle_method_call,
    .get_property = handle_get_property,
    .set_property = NULL,
    .padding = { NULL }
};

SystrayDbusMenuServer *
systray_dbusmenu_server_new (GDBusConnection              *connection,
                             const gchar                  *object_path,
                             SystrayDbusMenuActivateFunc   activate_func,
                             gpointer                      user_data,
                             GError                      **error)
{
    if (node_info == NULL) {
        node_info = g_dbus_node_info_new_for_xml (dbusmenu_xml, error);
        if (node_info == NULL)
            return NULL;
    }

    SystrayDbusMenuServer *server = g_new0 (SystrayDbusMenuServer, 1);
    server->connection = g_object_ref (connection);
    server->object_path = g_strdup (object_path);
    server->revision = 1;
    server->icon_data = g_hash_table_new_full (g_direct_hash, g_direct_equal,
        NULL, (GDestroyNotify) g_bytes_unref);
    server->activate_func = activate_func;
    server->user_data = user_data;

    server->registration_id = g_dbus_connection_register_object (connection,
        object_path, node_info->interfaces[0], &dbusmenu_vtable, server, NULL, error);

    if (server->registration_id == 0) {
        systray_dbusmenu_server_free (server);
        return NULL;
    }

    return server;
}

void
systray_dbusmenu_server_set_icon_data (SystrayDbusMenuServer *server,
                                      gint                   item_id,
                                      GBytes                *png)
{
    /* This exporter's fixed menu reserves 0 for the root and 8/10 for separators. */
    if (server == NULL || !((item_id >= 1 && item_id <= 7) || item_id == 9 || item_id == 11)) return;
    if (png == NULL) {
        g_hash_table_remove (server->icon_data, GINT_TO_POINTER (item_id));
    } else {
        g_hash_table_replace (server->icon_data, GINT_TO_POINTER (item_id),
            g_bytes_ref (png));
    }
}

void
systray_dbusmenu_server_set_rtl (SystrayDbusMenuServer *server,
                                gboolean               rtl)
{
    g_return_if_fail (server != NULL);
    if (server->rtl == rtl) return;
    server->rtl = rtl;
    GVariantBuilder changed;
    g_variant_builder_init (&changed, G_VARIANT_TYPE ("a{sv}"));
    g_variant_builder_add (&changed, "{sv}", "TextDirection",
        g_variant_new_string (rtl ? "rtl" : "ltr"));
    g_dbus_connection_emit_signal (server->connection, NULL, server->object_path,
        "org.freedesktop.DBus.Properties", "PropertiesChanged",
        g_variant_new ("(sa{sv}as)", DBUSMENU_IFACE, &changed, NULL), NULL);
}

void
systray_dbusmenu_server_set_menu (SystrayDbusMenuServer *server,
                                  const gchar * const   *labels,
                                  guint32                checked_mask)
{
    if (server == NULL) return;

    g_strfreev (server->labels);
    server->labels = g_strdupv ((gchar **) labels);
    server->checked_mask = checked_mask;
    server->revision++;

    if (server->connection != NULL && !g_dbus_connection_is_closed (server->connection)) {
        g_dbus_connection_emit_signal (server->connection, NULL, server->object_path,
            DBUSMENU_IFACE, "LayoutUpdated",
            g_variant_new ("(ui)", server->revision, 0), NULL);
    }
}

void
systray_dbusmenu_server_free (SystrayDbusMenuServer *server)
{
    if (server == NULL) return;

    if (server->connection != NULL && server->registration_id != 0) {
        g_dbus_connection_unregister_object (server->connection, server->registration_id);
    }

    g_clear_object (&server->connection);
    g_clear_pointer (&server->object_path, g_free);
    g_clear_pointer (&server->labels, g_strfreev);
    g_clear_pointer (&server->icon_data, g_hash_table_unref);
    g_free (server);
}
