dependencies = [
    dep_crypto_vala,
    dep_dino,
    dep_gee,
    dep_gio,
    dep_glib,
    dep_gmodule,
    dep_gnutls,
    dep_nice,
    dep_qlite,
    dep_xmpp_vala,
]
sources = files(
    'src/dtls_srtp.vala',
    'src/jingle_s5b_policy.vala',
    'src/module.vala',
    'src/plugin.vala',
    'src/transport_parameters.vala',
    'src/util.vala',
    'src/register_plugin.vala',
)
c_args = [
    '-DG_LOG_DOMAIN="ice"',
]
vala_args = [
    '--vapidir', vala_source_root / 'plugins/ice/vapi',
    '--header', vala_build_root / 'plugins/ice' / 'ice.h',
    '--internal-vapi', host_machine.system() == 'windows' ? '../ice-internal.vapi' : meson.current_build_dir() / 'ice-internal.vapi',
    '--internal-header', vala_build_root / 'plugins/ice' / 'ice-internal.h',
]
lib_ice = shared_library('ice', sources, name_prefix: '', c_args: c_args, vala_args: vala_args, dependencies: dependencies, install: true, install_dir: get_option('libdir') / get_option('plugindir'), install_rpath: default_install_rpath)
dep_ice = declare_dependency(link_with: lib_ice, include_directories: include_directories('.'))
summary('Peer-to-peer communication (ice)', dep_ice.found(), bool_yn: true, section: 'Plugins')

vapi_ice_internal = custom_target('ice-internal-vapi', command: [find_program('touch'), meson.current_build_dir() / 'ice-internal.vapi'], output: ['ice-internal.vapi'], depends: lib_ice)
ice_internal_link = host_machine.system() == 'windows' ? fs.relative_to(lib_ice, meson.project_build_root()) : lib_ice.full_path()
dep_ice_internal = declare_dependency(link_args: [ice_internal_link], include_directories: include_directories('.', 'src'), sources: [vapi_ice_internal])

test_sources = files(
    'tests/ice_test.vala',
)
test_c_args = ['-DG_LOG_DOMAIN="ice-test"', '-include', 'ice-internal.h', '-include', 'libdino-internal.h']
test_dependencies = [
    dep_crypto_vala,
    dep_dino_internal,
    dep_gdk_pixbuf,
    dep_gee,
    dep_gio,
    dep_glib,
    dep_gmodule,
    dep_gnutls,
    dep_nice,
    dep_qlite,
    dep_xmpp_vala,
]

exe_ice_test = executable('ice-test', test_sources, c_args: test_c_args, vala_args: ['--vapidir', vala_source_root / 'plugins/ice/vapi'], dependencies: test_dependencies + dep_ice_internal, build_rpath: '$ORIGIN:$ORIGIN/../../libdino', install: false)
test('Tests for ice', exe_ice_test)
