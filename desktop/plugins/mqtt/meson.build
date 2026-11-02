# MQTT Plugin for DinoX
#
# Optional plugin — requires libmosquitto (client library).
# If libmosquitto is not available, the plugin is skipped.
#
# Platform notes:
#   Linux:   apt install libmosquitto-dev
#   MSYS2:   pacman -S mingw-w64-x86_64-mosquitto
#   Flatpak: Built from source (see im.dinox.dinox.json)

plugin_mqtt_opt = get_option('plugin-mqtt')

# Step 1: Detect libmosquitto via pkg-config
dep_mosquitto_check = dependency('libmosquitto',
    required: plugin_mqtt_opt.enabled(),
)

if dep_mosquitto_check.found() and plugin_mqtt_opt.allowed()

    # Step 2: Link via C compiler (not valac --pkg) because there is
    #         no system Vala VAPI. Our custom vapi/mosquitto.vapi is
    #         added to sources instead. Use the pkg-config paths explicitly so
    #         private release prefixes work just like distro/MSYS2 prefixes.
    cc = meson.get_compiler('c')
    mosquitto_libdir = dep_mosquitto_check.get_variable(pkgconfig: 'libdir')
    mosquitto_includedir = dep_mosquitto_check.get_variable(pkgconfig: 'includedir')
    if mosquitto_libdir == '' or mosquitto_includedir == ''
        error('libmosquitto pkg-config metadata must define libdir and includedir')
    endif
    lib_mosquitto_link = cc.find_library('mosquitto',
        dirs: [mosquitto_libdir],
        required: true,
    )

    dependencies = [
        dep_dino,
        dep_gee,
        dep_gio,
        dep_glib,
        dep_gmodule,
        dep_gstreamer,
        dep_gtk4,
        dep_json_glib,
        dep_libadwaita,
        dep_qlite,
        dep_xmpp_vala,
    ]

    sources = files(
        'src/plugin.vala',
        'src/register_plugin.vala',
        'src/mqtt_client.vala',
        'src/connection_config.vala',
        'src/dns_security_group.vala',
        'src/database.vala',
        'src/server_detector.vala',
        'src/settings_page.vala',
        'src/bot_conversation.vala',
        'src/command_handler.vala',
        'src/alert_manager.vala',
        'src/bridge_manager.vala',
        'src/discovery_manager.vala',
        'src/topic_manager_dialog.vala',
        'src/mqtt_bot_manager_dialog.vala',
        'src/mqtt_utils.vala',
    )

    vapi_sources = files(
        'vapi/mosquitto.vapi',
    )

    vala_args = [
        '--vapidir', vala_source_root / 'plugins/mqtt/vapi',
    ]

    c_args = [
        '-DG_LOG_DOMAIN="mqtt"',
        '-DGETTEXT_PACKAGE="dino"',
        '-DLOCALE_INSTALL_DIR="@0@"'.format(get_option('prefix') / get_option('localedir')),
        '-I' + mosquitto_includedir,
    ]

    if dep_unbound.found()
        dependencies += dep_dns_security
        vala_args += ['--define=HAVE_DNSSEC']
    endif

    lib_mqtt = shared_library('mqtt', sources + vapi_sources,
        name_prefix: '',
        c_args: c_args,
        vala_args: vala_args,
        dependencies: dependencies + [lib_mosquitto_link],
        install: true,
        install_dir: get_option('libdir') / get_option('plugindir'),
        install_rpath: default_install_rpath,
    )

    dep_mqtt = declare_dependency(
        link_with: lib_mqtt,
        include_directories: include_directories('.'),
    )

    summary('MQTT IoT/Event Plugin (mqtt)', true, bool_yn: true, section: 'Plugins')

    # Unit tests for MQTT plugin (standalone — no broker, no DB, no UI)
    # Only includes source files with minimal dependencies.
    # AlertRule/MqttPriority live in alert_manager.vala which depends on
    # the full Plugin class; those are tested via integration tests instead.
    mqtt_test_sources = files(
        'tests/common.vala',
        'tests/testcase.vala',
        'tests/mqtt_tests.vala',
        'src/mqtt_utils.vala',
        'src/connection_config.vala',
    )
    exe_mqtt_test = executable('mqtt-test', mqtt_test_sources,
        c_args: ['-DG_LOG_DOMAIN="mqtt-test"'],
        dependencies: [dep_gee, dep_glib, dep_gio, dep_json_glib],
        install: false)
    test('mqtt-test', exe_mqtt_test)

    mqtt_locale_test = executable('mqtt-locale-test',
        files('tests/locale_boundaries.vala'), c_args: c_args,
        dependencies: dependencies + [dep_mqtt], install: false)
    test('MQTT locale boundaries', mqtt_locale_test)

    if dep_unbound.found()
        mqtt_client_dns_test = executable('mqtt-client-dns-test',
            files('tests/client_dns_policy.vala', 'src/mqtt_client.vala') + vapi_sources,
            c_args: c_args, vala_args: vala_args,
            dependencies: [dep_gee, dep_glib, dep_gio, dep_xmpp_vala,
                dep_dns_security, lib_mosquitto_link], install: false)
        if dns_python.found()
            test('MQTT client DNS policy and cancellation', dns_python,
                args: [files('tests/run-client-dns-fixture.py'), mqtt_client_dns_test], timeout: 25)
        endif
    endif

else
    if plugin_mqtt_opt.enabled()
        error('MQTT plugin was explicitly enabled but libmosquitto was not found.\n' + \
              'Install: apt install libmosquitto-dev (Linux) or pacman -S mingw-w64-x86_64-mosquitto (MSYS2)')
    endif
    summary('MQTT IoT/Event Plugin (mqtt)', false, bool_yn: true, section: 'Plugins')
endif
