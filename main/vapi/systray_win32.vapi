/*
 * VAPI for Win32 Shell_NotifyIcon systray helper.
 */

[CCode (cheader_filename = "systray_win32.h")]
namespace SystrayWin32 {

    [CCode (cname = "SystrayWin32Callback", has_target = false)]
    public delegate void Callback (int menu_id, void* user_data);

    [CCode (cname = "SystrayWin32BalloonCallback", has_target = false)]
    public delegate void BalloonCallback (void* user_data);

    [CCode (cname = "GDestroyNotify", has_target = false)]
    public delegate void DestroyCallback(void* user_data);

    [CCode (cname = "systray_win32_check_single_instance")]
    public static bool check_single_instance ();

    [CCode (cname = "systray_win32_activate_existing_instance")]
    public static bool activate_existing_instance ();

    [CCode (cname = "systray_win32_init")]
    public static bool init (string tooltip,
                             int icon_resource_id,
                             Callback callback,
                             void* user_data);

    [CCode (cname = "systray_win32_set_menu")]
    public static void set_menu ([CCode (array_null_terminated = true, array_length = false)]
                                 string?[] labels,
                                 [CCode (array_length = false)] int[] icons,
                                 uint32 checked_mask);

    [CCode (cname = "systray_win32_set_menu_theme")]
    public static void set_menu_theme(bool dark, bool website);

    [CCode (cname = "systray_win32_set_tooltip")]
    public static void set_tooltip (string tooltip);

    [CCode (cname = "systray_win32_show_balloon")]
    public static void show_balloon (string title,
                                     string body,
                                     int icon_type,
                                     BalloonCallback? callback,
                                     void* user_data,
                                     DestroyCallback? destroy,
                                     string? key);

    [CCode (cname = "systray_win32_hide_balloon")]
    public static void hide_balloon (string? key = null, bool prefix = false);

    [CCode (cname = "systray_win32_cleanup")]
    public static void cleanup ();

    [CCode (cname = "systray_win32_attach_parent_console")]
    public static void attach_parent_console ();

    [CCode (cname = "systray_win32_get_system_directory")]
    public static string? get_system_directory ();

    [CCode (cname = "systray_win32_set_app_id")]
    public static void set_app_id (string app_id);

    [CCode (cname = "systray_win32_register_xmpp_protocol_handler")]
    public static bool register_xmpp_protocol_handler (string exe_path);

    [CCode (cname = "systray_win32_open_file")]
    public static bool open_file (string path);

    [CCode (cname = "systray_win32_foreground_window_is_external")]
    public static bool foreground_window_is_external ();

    [CCode (cname = "systray_win32_suppress_crt_assertions")]
    public static void suppress_crt_assertions ();
}
