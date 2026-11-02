subdir('po')
dependencies = [
    dep_libadwaita,
    dep_crypto_vala,
    dep_dino,
    dep_gee,
    dep_glib,
    dep_gmodule,
    dep_gtk4,
    dep_libgcrypt,
    dep_libqrencode,
    dep_libomemo_c,
    dep_m,
    dep_qlite,
    dep_xmpp_vala,
]
sources = files(
    'src/dtls_srtp_verification_draft.vala',
    'src/file_transfer/file_decryptor.vala',
    'src/file_transfer/file_encryptor.vala',
    'src/jingle/jet_omemo.vala',
    'src/jingle/jingle_helper.vala',
    'src/logic/database.vala',
    'src/logic/decrypt.vala',
    'src/logic/decrypt_v2.vala',
    'src/logic/encrypt.vala',
    'src/logic/encrypt_v2.vala',
    'src/logic/manager.vala',
    'src/logic/legacy_registration_guard.vala',
    'src/logic/legacy_prekey_recovery.vala',
    'src/logic/pre_key_store.vala',
    'src/logic/session_store.vala',
    'src/logic/signed_pre_key_store.vala',
    'src/logic/trust_manager.vala',
    'src/plugin.vala',
    'src/protocol/bundle.vala',
    'src/protocol/bundle_v2.vala',
    'src/protocol/message_flag.vala',
    'src/protocol/stream_module.vala',
    'src/protocol/stream_module_v2.vala',
    'src/register_plugin.vala',
    'src/native/context.vala',
    'src/native/simple_iks.vala',
    'src/native/simple_pks.vala',
    'src/native/simple_spks.vala',
    'src/native/simple_ss.vala',
    'src/native/store.vala',
    'src/native/util.vala',
    'src/trust_level.vala',
    'src/ui/bad_messages_populator.vala',
    'src/ui/call_encryption_entry.vala',
    'src/ui/contact_details_provider.vala',
    'src/ui/device_notification_populator.vala',
    'src/ui/encryption_list_entry.vala',
    'src/ui/encryption_preferences_entry.vala',
    'src/ui/manage_key_dialog.vala',
    'src/ui/own_notifications.vala',
    'src/ui/util.vala',
)
sources += gnome.compile_resources(
    'resources',
    'data/gresource.xml',
    source_dir: 'data',
)
c_args = [
    '-DG_LOG_DOMAIN="OMEMO"',
    '-DGETTEXT_PACKAGE="dino-omemo"',
    '-DLOCALE_INSTALL_DIR="@0@"'.format(get_option('prefix') / get_option('localedir')),
]
omemo_native_link = []
if host_machine.system() == 'windows'
    # Keep handwritten crypto/provider C under the normal warning policy.
    # Linking this private archive whole preserves the helper exports used by
    # the plugin and its native tests without another runtime dependency.
    omemo_native_link += static_library('omemo-native-helper',
        'src/native/helper.c', c_args: c_args,
        dependencies: [dep_glib, dep_libgcrypt, dep_libomemo_c],
        pic: true, install: false)
    # valac emits unused closure-ref/async-finish helpers and cleanup labels.
    # Apply these two exceptions only to generated C, not the native helper.
    c_args += ['-Wno-unused-function', '-Wno-unused-label']
else
    sources += files('src/native/helper.c')
endif
vala_args = [
    '--pkg=dinox-native-streams',
    '--vapidir', vala_source_root / 'plugins/omemo/vapi',
    # This is to build internal vapi for tests
    '--header', vala_build_root / 'plugins/omemo' / 'omemo.h',
    '--internal-vapi', host_machine.system() == 'windows' ? '../omemo-internal.vapi' : meson.current_build_dir() / 'omemo-internal.vapi',
    '--internal-header', vala_build_root / 'plugins/omemo' / 'omemo-internal.h',
]
lib_omemo = shared_library('omemo', sources, name_prefix: '', c_args: c_args, vala_args: vala_args, include_directories: include_directories('src'), dependencies: dependencies, link_whole: omemo_native_link, install: true, install_dir: get_option('libdir') / get_option('plugindir'), build_rpath: local_libomemo_c_build_rpath, install_rpath: default_install_rpath)
dep_omemo = declare_dependency(link_with: lib_omemo, include_directories: include_directories('.'))
summary('End-to-end encryption using OMEMO (omemo)', dep_omemo.found(), bool_yn: true, section: 'Plugins')
# This is to use the internal vapi instead of the regular
vapi_omemo_internal = custom_target('omemo-internal-vapi', command: [find_program('touch'), meson.current_build_dir() / 'omemo-internal.vapi'], output: ['omemo-internal.vapi'], depends: lib_omemo)
omemo_internal_link = host_machine.system() == 'windows' ? fs.relative_to(lib_omemo, meson.project_build_root()) : lib_omemo.full_path()
dep_omemo_internal = declare_dependency(link_args: [omemo_internal_link], include_directories: include_directories('.', 'src'), sources: [vapi_omemo_internal])
http_files_header_dep = custom_target('http-files-header-dep', command: [find_program('touch'), '@OUTPUT@'], output: ['http-files-header-dep.h'], depends: lib_http_files)
dep_http_files_test_link = declare_dependency(link_args: [http_files_internal_link], include_directories: include_directories('../http-files'), sources: [http_files_header_dep])

test_sources = [
    'tests/native/common.vala',
    'tests/native/testcase.vala',

    'tests/native/curve25519.vala',
    'tests/native/file_decryptor.vala',
    'tests/native/decrypt_logic.vala',
    'tests/native/bundle_parser.vala',
    'tests/native/legacy_bundle_pubsub.vala',
    'tests/native/legacy_registration_guard.vala',
    'tests/native/legacy_registration_pubsub.vala',
    'tests/native/legacy_prekey_recovery.vala',
    'tests/native/legacy_prekey_high_watermark.vala',
    'tests/native/legacy_own_bundle_maintenance.vala',
    'tests/native/muc_historical_receive.vala',
    'tests/native/sce_context.vala',
    'tests/native/own_bundle_v2_maintenance.vala',
    'tests/native/trust_lifecycle.vala',
    'tests/native/signal_failure_diagnostics.vala',
    'tests/native/jet_omemo.vala',
    'tests/native/jingle_s5b_jet_omemo_file_manager.vala',
    'tests/native/omemo2_crypto.vala',
    'tests/native/hkdf.vala',
    'tests/native/session_builder.vala',
    'tests/native/session_version_guard.vala',
    'tests/native/security_logic.vala',
    'tests/native/multi_account_message_state.vala',
    'tests/native/proactive_muc_discovery_queue.vala',
    'tests/native/file_send_session_proof.vala',
    'tests/native/outgoing_current_device.vala',
    'tests/native/call_fingerprint.vala',
    'tests/native/remote_private_muc_http_smoke.vala',
    'tests/native/remote_jingle_s5b_jet_omemo_smoke.vala',
    'tests/native/http_files_test_api.vapi',
]
test_vala_args = [
    '--pkg=dinox-native-streams',
    '--pkg=dinox-test-mutex',
    '--vapidir', vala_source_root / 'plugins/omemo/vapi',
]
test_c_args = c_args + ['-include', 'omemo-internal.h', '-include', 'libdino-internal.h']
test_dependencies = [
    dep_libadwaita,
    dep_crypto_vala,
    dep_dino_internal,
    dep_gee,
    dep_glib,
    dep_gmodule,
    dep_gtk4,
    dep_http_files_test_link,
    dep_libgcrypt,
    dep_libqrencode,
    dep_libomemo_c,
    dep_libsoup,
    dep_m,
    dep_qlite,
    dep_xmpp_vala,
]

omemo_test_build_rpath = '$ORIGIN:$ORIGIN/../http-files:$ORIGIN/../../libdino'
if local_libomemo_c_build_rpath != ''
    omemo_test_build_rpath += ':' + local_libomemo_c_build_rpath
endif
exe_omemo_test = executable('omemo-test', test_sources, c_args: test_c_args, vala_args: test_vala_args, dependencies: test_dependencies + dep_omemo_internal, build_rpath: omemo_test_build_rpath, install: false)
omemo_test_env = environment()
omemo_test_env.set('XDG_DATA_HOME', meson.current_build_dir() / 'test-xdg-data')
omemo_test_env.set('XDG_CACHE_HOME', meson.current_build_dir() / 'test-xdg-cache')
# Persistent SQLCipher fixtures and native PubSub integration exceed one
# minute together. Individual IQ and held-response deadlines remain bounded.
# Persistent lifecycle regressions add real encrypted databases and native
# sessions; retain their short per-operation deadlines on slower Windows disks.
test('Tests for omemo', exe_omemo_test, env: omemo_test_env, timeout: 300)

exe_legacy_session_persistence_test = executable(
    'legacy-omemo-session-persistence-test',
    'tests/native/legacy_session_persistence.vala',
    c_args: test_c_args,
    vala_args: test_vala_args,
    dependencies: test_dependencies + dep_omemo_internal,
    build_rpath: omemo_test_build_rpath,
    install: false,
)
legacy_session_persistence_test_env = environment()
legacy_session_persistence_test_env.set(
    'XDG_DATA_HOME',
    meson.current_build_dir() / 'test-persistence-xdg-data',
)
legacy_session_persistence_test_env.set(
    'XDG_CACHE_HOME',
    meson.current_build_dir() / 'test-persistence-xdg-cache',
)
test(
    'Legacy OMEMO session persistence',
    exe_legacy_session_persistence_test,
    env: legacy_session_persistence_test_env,
    timeout: 60,
)
