dependencies = [
    dep_dino,
    dep_gee,
    dep_gio,
    dep_glib,
    dep_gmodule,
    dep_crypto_vala,
    dependency('json-glib-1.0'),
    dep_libsoup,
    dep_qlite,
    dep_xmpp_vala,
    dep_libomemo_c,
    dep_libgcrypt,
    dep_gtk4,
    dep_libadwaita,
    dependency('gnutls'),
]

# Strip UI classes (Gtk/Adw) and register_plugin from omemo internal vapi
omemo_vapi_stripped = custom_target('omemo-vapi-stripped',
    input: vapi_omemo_internal,
    output: 'omemo-bot.vapi',
    command: [find_program('python3'),
        meson.project_source_root() / 'plugins/bot-features/strip_omemo_vapi.py',
        '@INPUT@'],
    capture: true,
)
dep_omemo_bot = declare_dependency(
    include_directories: [
        include_directories('../omemo'),
        include_directories('../omemo/src'),
    ],
    sources: [omemo_vapi_stripped],
)

sources = files(
    'src/plugin.vala',
    'src/register_plugin.vala',
    'src/bot_utils.vala',
    'src/bot_registry.vala',
    'src/token_manager.vala',
    'src/auth_middleware.vala',
    'src/rate_limiter.vala',
    'src/http_server.vala',
    'src/session_pool.vala',
    'src/message_router.vala',
    'src/webhook_dispatcher.vala',
    'src/ejabberd_api.vala',
    'src/bot_omemo.vala',
    'src/ai_integration.vala',
    'src/telegram_bridge.vala',
)
c_sources = files(
    'src/cert_gen.c',
)
vapi_sources = files(
    'vapi/cert_gen.vapi',
)
c_args = [
    '-DG_LOG_DOMAIN="bot-features"',
    '-DGETTEXT_PACKAGE="dino"',
]
vala_args = [
    '--pkg=dinox-native-streams', # Referenced by the imported internal OMEMO VAPI.
    '--vapidir', vala_source_root / 'plugins/omemo/vapi',
    '--vapidir', vala_source_root / 'plugins/bot-features/vapi',
]
# link_with would make Meson pass omemo.vapi to valac in addition to the
# deliberately stripped omemo-bot.vapi. Link the exact binary without Vala
# propagation, while link_depends still gives Meson the build-order edge.
omemo_bot_build_dir = vala_build_root / 'plugins/omemo'
omemo_bot_link_filename = host_machine.system() == 'windows' ? 'omemo.dll.a' : 'omemo.so'
omemo_bot_link_args = ['-L' + omemo_bot_build_dir, '-l:' + omemo_bot_link_filename]
omemo_bot_build_rpath = host_machine.system() == 'windows' ? '' : omemo_bot_build_dir
bot_features_install_rpath = host_machine.system() == 'windows' ? default_install_rpath : '$ORIGIN'
lib_bot_features = shared_library('bot-features', sources + c_sources + vapi_sources, name_prefix: '', c_args: c_args, vala_args: vala_args, include_directories: include_directories('src'), dependencies: dependencies + dep_omemo_bot, link_args: omemo_bot_link_args, link_depends: lib_omemo, install: true, install_dir: get_option('libdir') / get_option('plugindir'), build_rpath: omemo_bot_build_rpath, install_rpath: bot_features_install_rpath)
dep_bot_features = declare_dependency(link_with: lib_bot_features, include_directories: include_directories('.'))
summary('Botmother API and Bot Management (bot-features)', dep_bot_features, section: 'Plugins')

# Unit tests for bot-features (standalone, only rate_limiter.vala needs Gee)
bot_test_sources = files(
    'tests/common.vala',
    'tests/testcase.vala',
    'tests/bot_tests.vala',
    'tests/http_api_tests.vala',
    'tests/audit_tests.vala',
    'src/bot_utils.vala',
    'src/bot_registry.vala',
    'src/token_manager.vala',
    'src/auth_middleware.vala',
    'src/rate_limiter.vala',
    'src/http_server.vala',
    'src/webhook_dispatcher.vala',
    'src/ejabberd_api.vala',
    'src/ai_integration.vala',
    'src/telegram_bridge.vala',
    'src/cert_gen.c',
    'vapi/cert_gen.vapi',
)
exe_bot_test = executable('bot-features-test', bot_test_sources,
    c_args: ['-DG_LOG_DOMAIN="bot-features-test"', '-DGETTEXT_PACKAGE="dino"'],
    vala_args: vala_args,
    include_directories: include_directories('src'),
    dependencies: [dep_gee, dep_glib, dep_gio, dep_libsoup, dep_qlite, dep_crypto_vala, dependency('json-glib-1.0'), dependency('gnutls')],
    install: false)
test('bot-features-test', exe_bot_test)
test('bot-features-test-listing', exe_bot_test, args: ['-l'], timeout: 30)

# Use the real router/session/dispatcher; the API unit tests above deliberately
# replace router and session types with stubs. All storage is in memory and the
# only HTTP traffic is to an ephemeral loopback server.
bot_lifecycle_vala_args = vala_args
if dep_libsoup.version().version_compare('>= 3.2')
    bot_lifecycle_vala_args += ['--define=SOUP_SERVER_MESSAGE_PAUSE']
endif
exe_bot_lifecycle_test = executable('bot-features-lifecycle-test',
    'tests/message_router_lifecycle_tests.vala',
    c_args: ['-DG_LOG_DOMAIN="bot-features-lifecycle-test"', '-DGETTEXT_PACKAGE="dino"', '-include', 'libdino-internal.h'],
    vala_args: bot_lifecycle_vala_args,
    dependencies: [dep_bot_features, dep_dino_internal, dep_xmpp_vala,
        dep_gee, dep_glib, dep_gio, dep_qlite, dep_libsoup, dep_crypto_vala,
        dep_gtk4, dep_libadwaita, dep_omemo_bot, dep_libomemo_c, dep_libgcrypt,
        dependency('json-glib-1.0')],
    install: false)
test('bot-features-lifecycle-test', exe_bot_lifecycle_test)

# Exercise real Plugin settings, timers, API binding and backup orchestration.
# Dedicated XMPP establishment is replaced at its protected transport boundary;
# every test profile and loopback port belongs only to the disposable fixture.
exe_bot_plugin_lifecycle_test = executable('bot-features-plugin-lifecycle-test',
    'tests/plugin_lifecycle_tests.vala',
    c_args: ['-DG_LOG_DOMAIN="bot-features-plugin-lifecycle-test"', '-DGETTEXT_PACKAGE="dino"', '-include', 'libdino-internal.h'],
    vala_args: vala_args,
    dependencies: [dep_bot_features, dep_dino_internal, dep_xmpp_vala,
        dep_gee, dep_glib, dep_gio, dep_qlite, dep_libsoup, dep_crypto_vala,
        dep_gtk4, dep_libadwaita, dep_omemo_bot, dep_libomemo_c, dep_libgcrypt,
        dependency('json-glib-1.0')],
    install: false)
test('bot-features-plugin-lifecycle-test', exe_bot_plugin_lifecycle_test, timeout: 60)
