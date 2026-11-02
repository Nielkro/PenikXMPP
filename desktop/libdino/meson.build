# version_vala
version_py = files('version.py')[0]
if meson.version().version_compare('>=1.4.0')
    version_py_path = version_py.full_path()
else
    version_py_path = meson.current_source_dir() / 'version.py'
endif
command = [prog_python, version_py_path, version_file_path, '--git-repo', meson.current_source_dir()]
if prog_git.found()
    command += ['--git', prog_git]
endif
# We add those dummy args to ensure meson sees the dependency
command += [version_py, version_file]
version_vala = vcs_tag(command: command, input: 'src/version.vala.in', output: 'version.vala', replace_string: '%VERSION%')

# libdino
dependencies = [
    dep_gdk_pixbuf,
    dep_gee,
    dep_gio,
    dep_glib,
    # Reuse GTK's existing text runtime for Unicode grapheme boundaries.
    dependency('pango'),
    dep_gmodule,
    dep_libsoup,
    dep_qlite,
    dep_xmpp_vala,
    dep_crypto_vala,
    dep_libsecret
]
sources = files(
    'src/application.vala',
    'src/security/file_encryption.vala',
    'src/security/key_manager.vala',
    'src/security/profile_lock.vala',
    'src/security/profile_lock.c',
    'src/security/profile_restore.vala',
    'src/security/profile_restore_sync.c',
    'src/security/profile_snapshot.vala',
    'src/security/profile_maintenance.vala',
    'src/security/profile_deletion.vala',
    'src/dbus/login1.vala',
    'src/dbus/notifications.vala',
    'src/dbus/upower.vala',
    'src/entity/account.vala',
    'src/entity/call.vala',
    'src/entity/conversation.vala',
    'src/entity/encryption.vala',
    'src/entity/file_transfer.vala',
    'src/entity/message.vala',
    'src/entity/settings.vala',
    'src/plugin/interfaces.vala',
    'src/plugin/media_device_selection.vala',
    'src/plugin/loader.vala',
    'src/plugin/registry.vala',
    'src/service/avatar_cache_worker.vala',
    'src/service/avatar_manager.vala',
    'src/service/blocking_manager.vala',
    'src/service/call_store.vala',
    'src/service/call_state.vala',
    'src/service/call_peer_state.vala',
    'src/service/jmi_archive_replay_registry.vala',
    'src/service/jmi_live_session_registry.vala',
    'src/service/jmi_recovered_proposal_store.vala',
    'src/service/calls.vala',
    'src/service/chat_interaction.vala',
    'src/service/connection_manager.vala',
    'src/service/contact_model.vala',
    'src/service/content_item_store.vala',
    'src/service/conversation_manager.vala',
    'src/service/counterpart_interaction_manager.vala',
    'src/service/database.vala',
    'src/service/displayed_state_manager.vala',
    'src/service/displayed_state_sync_owner.vala',
    'src/service/entity_capabilities_storage.vala',
    'src/service/entity_info.vala',
    'src/service/entity_time.vala',
    'src/service/fallback_body.vala',
    'src/service/file_manager.vala',
    'src/service/file_transfer_worker.vala',
    'src/service/file_transfer_storage.vala',
    'src/service/history_sync.vala',
    'src/service/history_diagnostics.vala',
    'src/service/invite_manager.vala',
    'src/service/jingle_file_transfers.vala',
    'src/service/certificate_manager.vala',
    'src/service/message_correction.vala',
    'src/service/archive_retractions.vala',
    'src/service/message_mentions.vala',
    'src/service/message_deletion.vala',
    'src/service/message_processor.vala',
    'src/service/message_snapshot_gate.vala',
    'src/service/muc_displayed_state_store.vala',
    'src/service/message_response_policy.vala',
    'src/service/message_storage.vala',
    'src/service/module_manager.vala',
    'src/service/muc_occupant_reducer.vala',
    'src/service/muc_occupant_worker.vala',
    'src/service/muc_manager.vala',
    'src/service/muc_room_avatar_manager.vala',
    'src/service/muc_invite_manager.vala',
    'src/service/muc_voice_request_manager.vala',
    'src/service/notification_events.vala',
    'src/service/occupant_id_store.vala',
    'src/service/pending_message_state_queue.vala',
    'src/service/presence_manager.vala',
    'src/service/replies.vala',
    'src/service/reactions.vala',
    'src/service/registration.vala',
    'src/service/roster_manager.vala',
    'src/service/search_processor.vala',
    'src/service/server_administration_command_session.vala',
    'src/service/server_administration_manager.vala',
    'src/service/sfs_metadata.vala',
    'src/service/stateless_file_sharing.vala',
    'src/service/stable_stanza_reference_resolver.vala',
    'src/service/stickers.vala',
    'src/service/feed_parser.vala',
    'src/service/feed_markup.vapi',
    'src/service/feed_store.vala',
    'src/service/feeds.vala',
    'src/service/social_feed.vala',
    'src/service/stream_interactor.vala',
    'src/service/user_search.vala',
    'src/service/util.vala',
    'src/util/account_http_session_pool.vala',
    'src/util/checksum_output_stream.vala',
    'src/util/display_name.vala',
    'src/util/file_utils.vala',
    'src/util/limit_input_stream.vala',
    'src/util/prefix_sniffing_input_stream.vala',
    'src/util/progress_output_stream.vala',
    'src/util/send_message.vala',
    'src/util/util.vala',
    'src/util/weak_map.vala',
    'src/util/weak_timeout.vala',
    'src/util/worker_readable_input_stream.vala',
    'src/util/xmpp_uri.vala',
)
sources += [version_vala]
c_args = [
    '-DGETTEXT_PACKAGE="dino"',
    '-DDINO_SYSTEM_LIBDIR_NAME="@0@"'.format(get_option('prefix') / get_option('libdir')),
    '-DDINO_SYSTEM_PLUGIN_DIR="@0@"'.format(get_option('prefix') / get_option('libdir') / get_option('plugindir')),
    '-DG_LOG_DOMAIN="libdino"',
]
if host_machine.system() == 'windows'
    # Vala 0.56 models GInputStream/GOutputStream buffers as uint8[], while
    # newer GLib headers expose the virtual function slots as void*/const void*.
    # The generated thunks are ABI-compatible, but GCC warns on the slot
    # assignment on current MSYS2.
    c_args += [
        '-DVALA_STRICT_C',
        '-Wno-incompatible-pointer-types',
        '-Wno-unused-function',
        '-Wno-unused-label',
    ]
endif
vala_args = []
if meson.get_compiler('vala').version().version_compare('=0.56.11')
    vala_args += ['-D', 'VALA_0_56_11']
endif
vala_args += ['-D', 'SOUP_3_0']
lib_vala_args = vala_args + [
    # This is to build internal vapi for tests
    '--header', vala_build_root / 'libdino' / 'libdino.h',
    '--internal-vapi', host_machine.system() == 'windows' ? '../libdino-internal.vapi' : meson.current_build_dir() / 'libdino-internal.vapi',
    '--internal-header', vala_build_root / 'libdino' / 'libdino-internal.h',
]
lib_dino = library('libdino', sources, c_args: c_args, vala_args: lib_vala_args, include_directories: include_directories('src'), dependencies: dependencies, name_prefix: '', version: '0.0', install: true, install_dir: [true, true, true], install_rpath: default_install_rpath)
dep_dino = declare_dependency(link_with: lib_dino, include_directories: include_directories('.', 'src'))
# This is to use the internal vapi instead of the regular one. Model both
# internal files generated by valac so C sources including the internal header
# cannot be compiled before libdino has produced it.
dino_internal_api = custom_target(
    'libdino-internal-api',
    command: [find_program('touch'), '@OUTPUT@'],
    output: [
        'libdino-internal.vapi',
        'libdino-internal.h',
    ],
    depends: lib_dino,
)
# MinGW cannot open UTF-8 absolute library paths from response files when the
# Windows code page differs. Keep the internal-VAPI link relative on Windows.
dino_internal_link = host_machine.system() == 'windows' ? fs.relative_to(lib_dino, meson.project_build_root()) : lib_dino.full_path()
dep_dino_internal = declare_dependency(link_args: [dino_internal_link], include_directories: include_directories('.', 'src'), sources: [dino_internal_api])

install_data('dino.deps', install_dir: get_option('datadir') / 'vala/vapi', install_tag: 'devel') # TODO: workaround for https://github.com/mesonbuild/meson/issues/9756
install_headers('src/dino_i18n.h')

test_sources = [
    'tests/common.vala',
    'tests/testcase.vala',
    'tests/jid.vala',
    'tests/weak_map.vala',
    'tests/file_manager.vala',
    'tests/file_send_target_scope.vala',
    'tests/stickers.vala',
    'tests/security.vala',
    'tests/key_manager_recovery.vala',
    'tests/profile_restore.vala',
    'tests/profile_maintenance.vala',
    'tests/profile_deletion.vala',
    'tests/profile_data_safety.vala',
    'tests/message_snapshot.vala',
    'tests/message_diagnostics.vala',
    'tests/history_diagnostics.vala',
    'tests/locale_search_path.vala',
    'tests/audit.vala',
    'tests/audit_file_transfer.vala',
    'tests/audit_srtp.vala',
    'tests/audit_entity.vala',
    'tests/audit_presence.vala',
    'tests/audit_avatar.vala',
    'tests/audit_account_removal.vala',
    'tests/audit_connection_manager.vala',
    'tests/roster_manager.vala',
    'tests/conversation_settings.vala',
    'tests/feeds.vala',
    'tests/audit_displayed_state.vala',
    'tests/audit_muc_manager.vala',
    'tests/audit_muc_voice_request_manager.vala',
    'tests/audit_muc_occupant_reducer.vala',
    'tests/audit_muc_occupant_worker.vala',
    'tests/audit_call_state.vala',
    'tests/audit_call_invites.vala',
    'tests/audit_jmi_lifecycle.vala',
    'tests/invites.vala',
    'tests/server_administration.vala',
    'tests/user_search.vala',
    'tests/password_change.vala',
    'tests/registration_form.vala',
    'tests/outgoing_encryption.vala',
    'tests/replies.vala',
    'tests/message_correction.vala',
    'tests/archive_retractions.vala',
    'tests/emoji_fallback.vala',
    'tests/message_mentions.vala',
    'tests/remote_xep0490_smoke.vala',
    'tests/remote_private_muc_smoke.vala',
    'tests/remote_jingle_s5b_smoke.vala',
]
test_c_args = c_args + ['-include', 'libdino-internal.h']

exe_libdino_test = executable('libdino-test', test_sources, c_args: test_c_args, vala_args: vala_args, dependencies: dependencies + [dep_sqlcipher, dep_dino_internal], build_rpath: '$ORIGIN', install: false)
libdino_test_env = environment()
libdino_test_env.set('XDG_DATA_HOME', meson.current_build_dir() / 'test-xdg-data')
libdino_test_env.set('XDG_CACHE_HOME', meson.current_build_dir() / 'test-xdg-cache')
# The profile-maintenance cases exercise real SQLCipher rekey/restore for all
# plugin databases; password derivation makes this suite deliberately expensive.
test('Tests for libdino', exe_libdino_test, env: libdino_test_env, timeout: 300)

exe_profile_lock_test = executable('profile-lock-test',
    ['tests/profile_lock.c', 'src/security/profile_lock.c'],
    include_directories: include_directories('src'),
    dependencies: [dep_glib, dep_gio])
test('Profile process lock', exe_profile_lock_test, timeout: 30)

profile_sync_link_args = []
if host_machine.system() != 'windows'
    profile_sync_link_args += ['-Wl,--wrap=fsync']
endif
exe_profile_sync_test = executable('profile-sync-test',
    ['tests/profile_restore_sync.c', 'src/security/profile_restore_sync.c'],
    include_directories: include_directories('src'),
    dependencies: [dep_glib, dep_gio], link_args: profile_sync_link_args)
test('Profile durable storage', exe_profile_sync_test, timeout: 30)
