dependencies = [
    dep_dino,
    dep_gee,
    dep_glib,
    dep_gmodule,
    dep_libsoup,
    dep_qlite,
    dep_xmpp_vala,
    dep_crypto_vala,
]
sources = files(
    'src/url_validation.vala',
    'src/file_provider.vala',
    'src/file_sender.vala',
    'src/plugin.vala',
    'src/register_plugin.vala',
)

vala_args = [
    '-D', 'SOUP_3_0',
    '--header', vala_build_root / 'plugins/http-files' / 'http-files.h',
    '--internal-vapi', host_machine.system() == 'windows' ? '../http-files-internal.vapi' : meson.current_build_dir() / 'http-files-internal.vapi',
    '--internal-header', vala_build_root / 'plugins/http-files' / 'http-files-internal.h',
]
lib_http_files = shared_library('http-files', sources, name_prefix: '', vala_args: vala_args, dependencies: dependencies, install: true, install_dir: get_option('libdir') / get_option('plugindir'), install_rpath: default_install_rpath)
dep_http_files = declare_dependency(link_with: lib_http_files, include_directories: include_directories('.'))
summary('HTTP file upload (http-files)', dep_http_files.found(), bool_yn: true, section: 'Plugins')

vapi_http_files_internal = custom_target('http-files-internal-vapi', command: [find_program('touch'), meson.current_build_dir() / 'http-files-internal.vapi'], output: ['http-files-internal.vapi'], depends: lib_http_files)
http_files_internal_link = host_machine.system() == 'windows' ? fs.relative_to(lib_http_files, meson.project_build_root()) : lib_http_files.full_path()
dep_http_files_internal = declare_dependency(link_args: [http_files_internal_link], include_directories: include_directories('.', 'src'), sources: [vapi_http_files_internal])

test_sources = [
    'tests/common.vala',
    'tests/testcase.vala',
    'tests/http_files_test.vala',
    'tests/outgoing_file_link.vala',
    'tests/remote_private_muc_http_smoke.vala',
    'tests/remote_foreign_http_upload_smoke.vala',
]
test_vala_args = [
    '--pkg=dinox-native-streams',
    '--pkg=dinox-test-mutex',
    '-D', 'SOUP_3_0',
]
test_c_args = ['-DG_LOG_DOMAIN="http-files-test"', '-include', 'http-files-internal.h', '-include', 'libdino-internal.h']
test_dependencies = [
    dep_dino_internal,
    dep_gdk_pixbuf,
    dep_gee,
    dep_gio,
    dep_glib,
    dep_gmodule,
    dep_libsoup,
    dep_qlite,
    dep_xmpp_vala,
    dep_crypto_vala,
]

exe_http_files_test = executable('http-files-test', test_sources, c_args: test_c_args, vala_args: test_vala_args, dependencies: test_dependencies + dep_http_files_internal, build_rpath: '$ORIGIN:$ORIGIN/../../libdino', install: false)
http_files_test_env = environment()
http_files_test_env.set('XDG_DATA_HOME', meson.current_build_dir() / 'test-xdg-data')
http_files_test_env.set('XDG_CACHE_HOME', meson.current_build_dir() / 'test-xdg-cache')
test('Tests for http-files', exe_http_files_test, env: http_files_test_env)
