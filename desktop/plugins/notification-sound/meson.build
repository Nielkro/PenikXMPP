# Platform-specific: Linux uses libcanberra, Windows uses GStreamer playbin.
# The two plugin source files (plugin.vala / plugin_windows.vala) are
# completely independent — the Linux file is NEVER touched on Windows.
if host_machine.system() == 'windows'
    dependencies = [
        dep_dino,
        dep_gee,
        dep_gio,
        dep_glib,
        dep_gmodule,
        dep_gstreamer,
        dep_qlite,
        dep_xmpp_vala,
    ]
    sources = files(
        'src/plugin_windows.vala',
        'src/register_plugin.vala',
    )
else
    dependencies = [
        dep_dino,
        dep_gee,
        dep_gio,
        dep_glib,
        dep_gmodule,
        dep_libcanberra,
        dep_qlite,
        dep_xmpp_vala,
    ]
    sources = files(
        'src/plugin.vala',
        'src/register_plugin.vala',
    )
endif
lib_notification_sound = shared_library('notification-sound', sources, name_prefix: '', dependencies: dependencies, install: true, install_dir: get_option('libdir') / get_option('plugindir'), install_rpath: default_install_rpath)
dep_notification_sound = declare_dependency(link_with: lib_notification_sound, include_directories: include_directories('.'))
summary('Sound for chat notifications (notification-sound)', dep_notification_sound, section: 'Plugins')
