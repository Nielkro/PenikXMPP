plugin_name = 'tor-manager'
plugin_sources = files(
    'src/plugin.vala',
    'src/register_plugin.vala',
    'src/tor_manager.vala',
    'src/tor_controller.vala',
    'src/transport_command.vala',
    'src/owned_process.c',
    'src/owned_process.vapi',
    'src/moat_client.vala',
    'src/settings_page.vala',
    'src/ui_indicator.vala'
)

transport_command_test = executable('tor-transport-command-test',
    files('src/transport_command.vala', 'tests/transport_command_test.vala'),
    dependencies: [dep_glib, dep_gio],
    install: false)
test('Tor transport command', transport_command_test)

tor_owner_dependencies = [dep_glib, dep_gio]
if host_machine.system() != 'windows'
    tor_owner_dependencies += dependency('gio-unix-2.0')
    plugin_sources += files('src/local_runtime.vala')
    local_runtime_test = executable('tor-local-runtime-test',
        files('src/local_runtime.vala', 'tests/local_runtime_test.vala'),
        dependencies: [dep_glib, dep_gio],
        install: false)
    test('Tor local runtime lookup', local_runtime_test)
else
    # New GLib releases split Win32 stream headers into this pkg-config
    # package; older supported releases included them in gio-2.0 itself.
    tor_gio_windows = dependency('gio-windows-2.0', required: false)
    if tor_gio_windows.found()
        tor_owner_dependencies += tor_gio_windows
    endif
endif

shared_module(plugin_name,
    plugin_sources,
    c_args: [
        '-DG_LOG_DOMAIN="tor-manager"',
        '-DGETTEXT_PACKAGE="dino"',
        '-DLOCALE_INSTALL_DIR="@0@"'.format(get_option('prefix') / get_option('localedir')),
    ],
    include_directories: include_directories('src'),
    dependencies: tor_owner_dependencies + [
        dep_dino,
        dep_glib,
        dep_gio,
        dependency('gtk4'),
        dependency('libadwaita-1'),
        dep_libsoup,
        dep_gee,
        dep_xmpp_vala,
        dep_qlite
    ],
    install: true,
    install_dir: get_option('libdir') / get_option('plugindir')
)

# Exercise the real readiness gate/ConnectionManager using a fake Tor
# controller. These tests never spawn Tor or open any network socket.
tor_startup_sources = files(
    'src/tor_manager.vala', 'src/tor_controller.vala',
    'src/transport_command.vala', 'src/owned_process.c',
    'src/owned_process.vapi', 'tests/startup_readiness_test.vala')
if host_machine.system() != 'windows'
    tor_startup_sources += files('src/local_runtime.vala')
endif
tor_startup_test = executable('tor-startup-readiness-test', tor_startup_sources,
    include_directories: include_directories('src'),
    vala_args: ['-D', 'DINOX_TOR_TESTS'],
    c_args: ['-DG_LOG_DOMAIN="tor-manager"', '-DGETTEXT_PACKAGE="dino"',
        '-include', 'libdino-internal.h'],
    # dep_dino_internal uses a raw link path; declare libdino's crypto import
    # so Meson includes its DLL directory in the Windows test PATH.
    dependencies: tor_owner_dependencies + [dep_dino_internal, dep_crypto_vala,
        dep_gee, dep_gmodule, dep_gdk_pixbuf, dep_libsoup, dep_xmpp_vala, dep_qlite],
    build_rpath: '$ORIGIN:$ORIGIN/../../libdino', install: false)
test('Tor startup readiness', tor_startup_test, timeout: 30)

tor_owned_process_test = executable('tor-owned-process-test',
    files('src/owned_process.c', 'tests/owned_process_test.c'),
    include_directories: include_directories('src'),
    dependencies: tor_owner_dependencies, install: false)
test('Tor owned process lifecycle', tor_owned_process_test, timeout: 30)
