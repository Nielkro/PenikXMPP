/*
 * VAPI for the minimal DBusMenu exporter used by the Linux SNI tray.
 */

[CCode (cheader_filename = "systray_dbusmenu.h")]
namespace SystrayDbusMenu {
    [CCode (cname = "SystrayDbusMenuActivateFunc", has_target = false)]
    public delegate void ActivateFunc (int item_id, void* user_data);

    [Compact]
    [CCode (cname = "SystrayDbusMenuServer", free_function = "systray_dbusmenu_server_free")]
    public class Server {
        [CCode (cname = "systray_dbusmenu_server_new")]
        public Server (GLib.DBusConnection connection,
                       string object_path,
                       ActivateFunc activate_func,
                       void* user_data) throws GLib.Error;

        [CCode (cname = "systray_dbusmenu_server_set_menu")]
        public void set_menu ([CCode (array_length = false, array_null_terminated = true)] string?[] labels,
                              uint32 checked_mask);

        [CCode (cname = "systray_dbusmenu_server_set_rtl")]
        public void set_rtl (bool rtl);

        [CCode (cname = "systray_dbusmenu_server_set_icon_data")]
        public void set_icon_data (int item_id, GLib.Bytes? png);
    }
}
