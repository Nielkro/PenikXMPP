subdir('po')
dependencies = [
    dep_libadwaita,
    dep_dino,
    dep_gee,
    dep_glib,
    dep_gmodule,
    dep_gpgme,
    dep_gtk4,
    dep_qlite,
    dep_xmpp_vala,
]
sources = files(
    'src/contact_details_provider.vala',
    'src/database.vala',
    'src/encryption_list_entry.vala',
    'src/encryption_preferences_entry.vala',
    'src/file_transfer/file_decryptor.vala',
    'src/file_transfer/file_encryptor.vala',
    'src/file_transfer/temp_file_input_stream.vala',
    'src/gpgme_fix.c',
    'src/gpg_cli_helper.vala',
    'src/key_management_dialog.vala',
    'src/manager.vala',
    'src/plugin.vala',
    'src/register_plugin.vala',
    'src/stream_flag.vala',
    'src/stream_module.vala',
    'src/util.vala',
    'src/xep0373_key_manager.vala',
    'vapi/gpg-error.vapi',
)
sources += gnome.compile_resources(
    'resources',
    'data/gresource.xml',
    source_dir: 'data',
)
c_args = [
    '-DG_LOG_DOMAIN="OpenPGP"',
    '-DGETTEXT_PACKAGE="dino-openpgp"',
    '-DLOCALE_INSTALL_DIR="@0@"'.format(get_option('prefix') / get_option('localedir')),
]
vala_args = [
    '--pkg=dinox-native-streams',
    '--vapidir', vala_source_root / 'plugins/openpgp/vapi',
    # This is to build internal vapi for tests
    '--header', vala_build_root / 'plugins/openpgp' / 'openpgp.h',
    '--internal-vapi', host_machine.system() == 'windows' ? '../openpgp-internal.vapi' : meson.current_build_dir() / 'openpgp-internal.vapi',
    '--internal-header', vala_build_root / 'plugins/openpgp' / 'openpgp-internal.h',
]
if dep_libadwaita.version() == 'unknown' or dep_libadwaita.version().version_compare('>=1.4')
    vala_args += ['-D', 'Adw_1_4']
endif
lib_openpgp = shared_library('openpgp', sources, name_prefix: '', c_args: c_args, vala_args: vala_args, include_directories: include_directories('src'), dependencies: dependencies, install: true, install_dir: get_option('libdir') / get_option('plugindir'), install_rpath: default_install_rpath)
dep_openpgp = declare_dependency(link_with: lib_openpgp, include_directories: include_directories('.'))
summary('End-to-end encryption using PGP (openpgp)', dep_openpgp.found(), bool_yn: true, section: 'Plugins')
# This is to use the internal vapi instead of the regular
vapi_openpgp_internal = custom_target('openpgp-internal-vapi', command: [find_program('touch'), meson.current_build_dir() / 'openpgp-internal.vapi'], output: ['openpgp-internal.vapi'], depends: lib_openpgp)
openpgp_internal_link = host_machine.system() == 'windows' ? fs.relative_to(lib_openpgp, meson.project_build_root()) : lib_openpgp.full_path()
dep_openpgp_internal = declare_dependency(link_args: [openpgp_internal_link], include_directories: include_directories('.', 'src'), sources: [vapi_openpgp_internal])
# The small test VAPI deliberately avoids importing the complete HTTP plugin
# VAPI. Still order compilation after its generated header and library, as in
# the OMEMO tests; a link argument alone does not create that build dependency.
openpgp_http_files_header_dep = custom_target('openpgp-http-files-header-dep',
    command: [find_program('touch'), '@OUTPUT@'],
    output: ['openpgp-http-files-header-dep.h'], depends: lib_http_files)
dep_http_files_test_link = declare_dependency(link_args: [http_files_internal_link],
    include_directories: include_directories('../http-files'), sources: [openpgp_http_files_header_dep])

test_sources = [
    'tests/common.vala',
    'tests/testcase.vala',
    'tests/stream_module_logic.vala',
    'tests/gpg_keylist_parser.vala',
    'tests/secret_key_backup.vala',
    'tests/key_publication_lifecycle.vala',
    'tests/armor_parser.vala',
    'tests/live_gpg_helper.vala',
    'tests/remote_private_muc_http_smoke.vala',
    'tests/file_decryptor.vala',
    'tests/http_files_test_api.vapi',
    'vapi/gpg-error.vapi',
]
test_vala_args = [
    '--pkg=dinox-native-streams',
    '--pkg=dinox-test-mutex',
    '-D', 'SOUP_3_0',
    '--vapidir', vala_source_root / 'plugins/openpgp/vapi',
]
test_c_args = c_args + ['-include', 'openpgp-internal.h', '-include', 'libdino-internal.h']
test_dependencies = [
    dep_gio,
    dep_libadwaita,
    dep_dino_internal,
    dep_gee,
    dep_glib,
    dep_gmodule,
    dep_gpgme,
    dep_gtk4,
    dep_json_glib,
    dep_libsoup,
    dep_qlite,
    dep_xmpp_vala,
    dep_http_files_test_link,
]

exe_openpgp_test = executable('openpgp-test', test_sources, c_args: test_c_args, vala_args: test_vala_args, dependencies: test_dependencies + dep_openpgp_internal, build_rpath: '$ORIGIN:$ORIGIN/../http-files:$ORIGIN/../../libdino', install: false)
openpgp_test_env = environment()
openpgp_test_env.set('XDG_DATA_HOME', meson.current_build_dir() / 'test-xdg-data')
openpgp_test_env.set('XDG_CACHE_HOME', meson.current_build_dir() / 'test-xdg-cache')
if host_machine.system() == 'windows'
    openpgp_test_env.prepend('PATH', [
        meson.current_build_dir(),
        meson.current_build_dir() / '../http-files',
        meson.current_build_dir() / '../../libdino',
        meson.current_build_dir() / '../../qlite',
        meson.current_build_dir() / '../../xmpp-vala',
        meson.current_build_dir() / '../../crypto-vala',
    ], separator: ';')
endif
test('Tests for openpgp', exe_openpgp_test, env: openpgp_test_env, timeout: 120)

# Real account-scoped GTK import and legacy-presence regressions. The fixture
# owns its XDG directories and GnuPG homes; it never opens a user profile.
exe_openpgp_account_ui_test = executable('openpgp-account-ui-test',
    ['tests/key_management_account_scope.vala', 'vapi/gpg-error.vapi'],
    c_args: test_c_args, vala_args: test_vala_args,
    dependencies: test_dependencies + dep_openpgp_internal,
    build_rpath: '$ORIGIN:$ORIGIN/../http-files:$ORIGIN/../../libdino',
    install: false)
openpgp_xvfb = find_program('xvfb-run', required: false)
openpgp_dbus_session = find_program('dbus-run-session', required: false)
if openpgp_xvfb.found() and openpgp_dbus_session.found()
    test('Tests for OpenPGP account UI runtime', openpgp_dbus_session,
        args: ['--', openpgp_xvfb.full_path(), '--auto-servernum',
            '--server-args=-screen 0 1024x768x24', exe_openpgp_account_ui_test],
        env: {'GTK_A11Y': 'none'}, timeout: 90)
endif
