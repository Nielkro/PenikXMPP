# Copyright (C) 2025 Ralf Peter <dinox@handwerker.jetzt>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

subdir('po')
dependencies = [
    dep_dino,
    dep_gee,
    dep_glib,
    dep_gmodule,
    dep_gstreamer,
    dep_gstreamer_app_core,
    dep_gtk4,
    dep_icu_uc,
    dep_json_glib,
    dep_crypto_vala,
    dep_libadwaita,
    dep_libsoup,
    dep_m,
    dep_qlite,
    dep_xmpp_vala,
    meson.get_compiler('vala').find_library('posix'),
]

have_x11 = dep_gtk4_x11.found() and dep_x11.found()
if have_x11
    dependencies += [dep_gtk4_x11, dep_x11]
endif

# Source files (platform-independent)
sources = files(
    'vapi/dinox-gdk.vapi',
    'src/ibus_compat.c',
    'src/ui/sticker_animation_compat.c',
    'src/service/media_audio_playback_bridge.vala',
    'src/service/provider_directory.vala',
    'src/service/update_checker.vala',
    'src/view_model/account_connection_input.vala',
    'src/view_model/contact_list_model.vala',
    'src/view_model/contact_list_selection_model.vala',
    'src/view_model/contact_subscription_model.vala',
    'src/ui/add_conversation/add_conference_dialog.vala',
    'src/ui/add_conversation/add_contact_dialog.vala',
    'src/ui/add_conversation/add_groupchat_dialog.vala',
    'src/ui/add_conversation/room_browser_dialog.vala',
    'src/ui/add_conversation/contact_browser_dialog.vala',
    'src/ui/add_conversation/conference_details_fragment.vala',
    'src/ui/add_conversation/conference_list.vala',
    'src/ui/add_conversation/create_invite_dialog.vala',
    'src/ui/add_conversation/contact_list_view_row.vala',
    'src/ui/add_conversation/contact_roster_model_source.vala',
    'src/ui/add_conversation/contact_selection_view.vala',
    'src/ui/add_conversation/list_row.vala',
    'src/ui/add_conversation/roster_list.vala',
    'src/ui/add_conversation/select_contact_dialog.vala',
    'src/ui/add_conversation/select_jid_fragment.vala',
    'src/ui/add_conversation/user_search_dialog.vala',
    'src/ui/application.vala',
    'src/ui/interface_style.vala',
    'src/ui/window_controls.vala',
    'src/ui/interface_language.vala',
    'src/ui/bot_manager_dialog.vala',
    'src/ui/bot_provider_selection.vala',
    'src/ui/bot_create_dialog.vala',
    'src/ui/bot_api_json.vala',
    'src/ui/call_window/audio_settings_popover.vala',
    'src/ui/call_window/call_bottom_bar.vala',
    'src/ui/call_window/call_connection_details_window.vala',
    'src/ui/call_window/call_dialpad.vala',
    'src/ui/call_window/call_encryption_button.vala',
    'src/ui/call_window/call_window.vala',
    'src/ui/call_window/call_window_controller.vala',
    'src/ui/call_window/group_call_participant_list.vala',
    'src/ui/call_window/libwebrtc_video_widget.vala',
    'src/ui/call_window/participant_widget.vala',
    'src/ui/call_window/video_effects_popover.vala',
    'src/ui/call_window/video_settings_popover.vala',
    'src/ui/chat_input/media_message_recorder.vala',
    'src/ui/chat_input/recording_send_context.vala',
    'src/ui/chat_input/voice_recorder_popover.vala',
    'src/ui/chat_input/video_recorder_popover.vala',
    'src/ui/chat_input/encryption_input_status_policy.vala',
    'src/ui/chat_input/chat_input_controller.vala',
    'src/ui/chat_input/chat_text_view.vala',
    'src/ui/chat_input/encryption_button.vala',
    'src/ui/chat_input/occupants_tab_completer.vala',
    'src/ui/chat_input/smiley_converter.vala',
    'src/ui/chat_input/sticker_chooser.vala',
    'src/ui/chat_input/view.vala',
    'src/ui/contact_details/settings_provider.vala',
    'src/ui/conversation_content_view/audio_player_widget.vala',
    'src/ui/conversation_content_view/video_playback_lifecycle.vala',
    'src/ui/conversation_content_view/video_player_widget.vala',
    'src/ui/conversation_content_view/call_widget.vala',
    'src/ui/conversation_content_view/chat_state_populator.vala',
    'src/ui/conversation_content_view/content_populator.vala',
    'src/ui/conversation_content_view/conversation_item_skeleton.vala',
    'src/ui/conversation_content_view/conversation_content_host.vala',
    'src/ui/conversation_content_view/frame_render_queue.vala',
    'src/ui/conversation_content_view/chat_scroll_motion.vala',
    'src/ui/conversation_content_view/conversation_view.vala',
    'src/ui/conversation_content_view/date_separator_populator.vala',
    'src/ui/conversation_content_view/file_default_widget.vala',
    'src/ui/conversation_content_view/file_context_menu.vala',
    'src/ui/conversation_content_view/file_widget_controller.vala',
    'src/ui/conversation_content_view/file_image_widget.vala',
    'src/ui/conversation_content_view/file_transmission_progress.vala',
    'src/ui/conversation_content_view/file_widget.vala',
    'src/ui/conversation_content_view/file_meta_item.vala',
    'src/ui/conversation_content_view/item_actions.vala',
    'src/ui/conversation_content_view/message_action_target.vala',
    'src/ui/conversation_content_view/message_diagnostics.vala',
    'src/ui/conversation_content_view/message_mention_presentation.vala',
    'src/ui/conversation_content_view/message_widget.vala',
    'src/ui/conversation_content_view/quote_widget.vala',
    'src/ui/conversation_content_view/url_preview_widget.vala',
    'src/ui/conversation_content_view/reactions_widget.vala',
    'src/ui/conversation_content_view/subscription_notification.vala',
    'src/ui/conversation_content_view/expiry_notification.vala',
    'src/ui/conversation_content_view/voice_request_notification.vala',
    'src/ui/conversation_content_view/real_jid_visibility_notification.vala',
    'src/ui/conversation_content_view/unread_indicator_populator.vala',
    'src/ui/conversation_content_view/status_populator.vala',
    'src/ui/conversation_details.vala',
    'src/ui/hats_management_page.vala',
    'src/ui/muc_history_preferences.vala',
    'src/ui/conversation_selector/conversation_selector.vala',
    'src/ui/conversation_selector/conversation_selector_row.vala',
    'src/ui/conversation_selector/conversation_sidebar_layout.vala',
    'src/ui/conversation_titlebar/call_entry.vala',
    'src/ui/conversation_titlebar/menu_entry.vala',
    'src/ui/conversation_titlebar/notification_entry.vala',
    'src/ui/conversation_titlebar/occupants_entry.vala',
    'src/ui/conversation_titlebar/search_entry.vala',
    'src/ui/conversation_view.vala',
    'src/ui/conversation_view_controller.vala',
    'src/ui/file_transfer_input.vala',
    'src/ui/file_send_overlay.vala',
    'src/ui/pending_plaintext_send.vala',
    'src/ui/global_search.vala',
    'src/ui/main_window.vala',
    'src/ui/main_window_controller.vala',
    'src/ui/muc_admin_dialog.vala',
    'src/ui/server_administration_dialog.vala',
    'src/ui/notifier_freedesktop.vala',
    'src/ui/notifier_gnotifications.vala',
    'src/ui/occupant_menu/initial_snapshot_wait_policy.vala',
    'src/ui/occupant_menu/muc_member_list_section.vala',
    'src/ui/occupant_menu/list.vala',
    'src/ui/occupant_menu/list_row.vala',
    'src/ui/occupant_menu/view.vala',
    'src/ui/util/accounts_combo_box.vala',
    'src/ui/util/config.vala',
    'src/ui/util/data_forms.vala',
    'src/ui/util/server_administration_labels.vala',
    'src/ui/util/file_metadata_providers.vala',
    'src/ui/util/helper.vala',
    'src/ui/util/location_manager.vala',
    'src/ui/util/preference_group.vala',
    'src/ui/util/ui_timing.vala',
    'src/ui/util/size_request_box.vala',
    'src/ui/util/text_context_menu.vala',
    'src/ui/util/sizing_bin.vala',
    'src/ui/sticker_pack_import_dialog.vala',
    'src/ui/sticker_pack_folder_import_dialog.vala',
    'src/ui/sticker_manager.vala',
    'src/ui/widgets/avatar_picture.vala',
    'src/ui/widgets/date_separator.vala',
    'src/ui/widgets/fixed_ratio_picture.vala',
    'src/ui/widgets/natural_size_increase.vala',
    'src/view_model/account_details.vala',
    'src/view_model/conversation_details.vala',
    'src/view_model/preferences_dialog.vala',
    'src/view_model/preferences_row.vala',
    'src/windows/preferences_window/account_preferences_subpage.vala',
    'src/windows/preferences_window/accounts_preferences_page.vala',
    'src/windows/preferences_window/add_account_dialog.vala',
    'src/windows/preferences_window/certificate_warning_dialog.vala',
    'src/windows/preferences_window/change_password_dialog.vala',
    'src/windows/preferences_window/contacts_preferences_page.vala',
    'src/windows/preferences_window/preferences_contact_list_view_row.vala',
    'src/windows/preferences_window/encryption_preferences_page.vala',
    'src/windows/preferences_window/general_preferences_page.vala',
    'src/windows/preferences_window/audio_video_preferences_page.vala',
    'src/windows/preferences_window/preferences_dialog.vala',
    'src/windows/conversation_details.vala',
    'src/ui/feeds_dialog.vala',
)

# Platform-specific systray implementation
if host_machine.system() == 'windows'
    sources += files('src/ui/windows_font_settings.vala')
    sources += files('src/ui/systray_windows.vala')
    sources += files('src/ui/systray_win32.c')
    sources += files('src/ui/notifier_windows.vala')
    sources += files('src/ui/toast_win32.c')
    sources += files('src/ui/certstore_win32.c')
else
    sources += files('src/ui/systray.vala')
    sources += files('src/ui/systray_sni_dbus.c')
    sources += files('src/ui/systray_dbusmenu.c')
endif

main_resources = gnome.compile_resources(
    'resources',
    'data/gresource.xml',
    source_dir: 'data',
)
sources += main_resources

c_args = [
    '-DG_LOG_DOMAIN="dino"',
    '-DGETTEXT_PACKAGE="dino"',
    '-DLOCALE_INSTALL_DIR="@0@"'.format(get_option('prefix') / get_option('localedir')),
    '-I' + meson.current_source_dir() / 'src/ui',
    '-I' + meson.current_source_dir() / 'src',
]
if host_machine.system() == 'linux'
    sources += files('src/appimage_tls_trust.vala')
    exe_appimage_tls_trust_test = executable('appimage-tls-trust-test',
        ['src/appimage_tls_trust.vala', 'tests/appimage_tls_trust_test.vala'],
        dependencies: [dep_glib, dep_gio],
        install: false)
    test('AppImage system TLS trust', exe_appimage_tls_trust_test,
        args: [meson.current_source_dir() / 'tests/fixtures/appimage-tls'])

    # The private IBus client is never added to the normal library search path.
    # Package paths also resolve relative to the executable for AppImage use.
    ibus_compat_install_path = get_option('prefix') / get_option('libdir') / 'dinox/ibus-compat/libibus-1.0.so.5.0.530'
    ibus_compat_source_path = ''
    if local_libomemo_c_root != ''
        ibus_compat_source_path = local_libomemo_c_root / 'lib/dinox/ibus-compat/libibus-1.0.so.5.0.530'
        if fs.is_file(ibus_compat_source_path)
            install_data(ibus_compat_source_path, install_dir: get_option('libdir') / 'dinox/ibus-compat')
            install_data(local_libomemo_c_root / 'lib/dinox/ibus-compat/METADATA',
                install_dir: get_option('libdir') / 'dinox/ibus-compat')
            install_subdir(local_libomemo_c_root / 'share/dinox/custom-dependency-licenses/ibus-compat',
                install_dir: get_option('datadir') / 'licenses/dinox/third-party')
            install_subdir(local_libomemo_c_root / 'share/dinox/corresponding-sources/ibus-compat',
                install_dir: get_option('datadir') / 'licenses/dinox/corresponding-sources')
            install_data('../scripts/prepare-ibus-compat.sh',
                install_dir: get_option('datadir') / 'licenses/dinox/corresponding-sources/ibus-compat')
        endif
    endif
    c_args += [
        '-DDINOX_IBUS_COMPAT_INSTALL_PATH="@0@"'.format(ibus_compat_install_path),
        '-DDINOX_IBUS_COMPAT_SOURCE_PATH="@0@"'.format(ibus_compat_source_path),
    ]
    dep_dl = meson.get_compiler('c').find_library('dl', required: false)
    if dep_dl.found()
        dependencies += dep_dl
    endif
endif
vala_args = [
    '--vapidir=' + (vala_source_root / 'main/vapi'),
]
if host_machine.system() == 'linux'
    vala_args += ['-D', 'LINUX']
endif
message('VAPI DIR: ' + (meson.current_source_dir() / 'vapi'))
if dep_libqrencode.found()
    dependencies += dep_libqrencode
    vala_args += [
        '--vapidir=' + (vala_source_root / 'plugins/omemo/vapi'),
        '--pkg', 'libqrencode',
        '-D', 'HAVE_QRENCODE',
    ]
endif
cc = meson.get_compiler('c')
windows_system_deps = []
if host_machine.system() == 'windows'
    vala_args += ['--pkg', 'systray_win32']
    vala_args += ['--pkg', 'toast_win32']
    vala_args += ['--pkg', 'certstore_win32']
    # Current MSYS2/GCC warns about helper functions and error labels emitted by
    # Vala but intentionally left unused after code generation.
    c_args += ['-Wno-unused-function', '-Wno-unused-label']
    windows_system_deps = [cc.find_library('shell32'), cc.find_library('user32'), cc.find_library('gdi32'),
                           cc.find_library('ole32'), cc.find_library('propsys'),
                           cc.find_library('shlwapi'), cc.find_library('crypt32')]
    dependencies += windows_system_deps
else
    vala_args += ['--pkg', 'systray_sni_dbus']
    vala_args += ['--pkg', 'systray_dbusmenu']
    vala_args += ['-D', 'HAVE_MALLOC_TRIM']
endif
if have_x11
    vala_args += ['-D', 'HAVE_X11']
endif
if dep_geoclue.found()
    dependencies += dep_geoclue
    vala_args += ['-D', 'HAVE_GEOCLUE']
endif
summary('Location sharing (XEP-0080)', dep_geoclue.found(), bool_yn: true, section: 'Plugins')
if dep_gtk4.version() == 'unknown' or dep_gtk4.version().version_compare('>=4.6')
    vala_args += ['-D', 'GTK_4_6']
endif
if dep_gtk4.version() == 'unknown' or dep_gtk4.version().version_compare('>=4.8')
    vala_args += ['-D', 'GTK_4_8']
endif
if dep_gtk4.version() == 'unknown' or dep_gtk4.version().version_compare('>=4.12')
    vala_args += ['-D', 'GTK_4_12']
endif
if dep_gtk4.version() == 'unknown' or dep_gtk4.version().version_compare('>=4.14')
    vala_args += ['-D', 'GTK_4_14']
    sources += files('src/ui/conversation_content_view/file_transmission_progress.c')
endif

# Compatibility wrapper for deprecated GValueArray (used by GStreamer level element)
sources += files('src/ui/chat_input/gva_compat.c')

if dep_libadwaita.version() == 'unknown' or dep_libadwaita.version().version_compare('>=1.4')
    vala_args += ['-D', 'Adw_1_4']
endif
if meson.get_compiler('vala').version().version_compare('>=0.56.5') and meson.get_compiler('vala').version().version_compare('<0.58')
    vala_args += ['-D', 'VALA_0_56_GREATER_5']
endif
if meson.get_compiler('vala').version().version_compare('>=0.56.11') and meson.get_compiler('vala').version().version_compare('<0.58')
    vala_args += ['-D', 'VALA_0_56_GREATER_11']
endif
if meson.get_compiler('vala').version().version_compare('=0.56.11')
    vala_args += ['-D', 'VALA_0_56_11']
endif
if meson.get_compiler('vala').version().version_compare('=0.56.12')
    vala_args += ['-D', 'VALA_0_56_12']
endif

# Windows-specific: embed icon in .exe and use GUI subsystem (no terminal window)
extra_link_args = []
extra_objects = []
if host_machine.system() == 'windows'
    # Use GUI subsystem so double-clicking dinox.exe doesn't open a console window
    extra_link_args += ['-mwindows']

    # Compile Windows resources to embed the app icon and UTF-8 process
    # manifest in the executable.
    windows_mod = import('windows')
    win_res = windows_mod.compile_resources(
        'data/dinox.rc',
        depend_files: files('data/dinox.ico', 'data/dinox.exe.manifest'),
    )
    sources += win_res

    # Console helper with binary pipes; do not inherit DinoX's -mwindows.
    # Keep libarchive local to this Windows target and preserve its manifest
    # by copying the built executable unchanged into the portable package.
    windows_backup_archive = executable('dinox-backup-tar',
        files('src/windows_backup_archive.c'), win_res,
        dependencies: [dependency('libarchive')],
        win_subsystem: 'console',
        install: true,
    )
    test('Windows backup archive runtime', prog_python,
        args: [files('tests/windows_backup_archive_runtime_test.py'), windows_backup_archive],
        timeout: 120,
    )
endif

exe_dino = executable('dinox', sources, files('src/main.vala'), c_args: c_args, vala_args: vala_args, link_args: extra_link_args, dependencies: dependencies, install: true, install_rpath: default_install_rpath, win_subsystem: 'windows')

# Exercise the actual application widget sources without starting the
# application, accounts or network services. Meson's Vala object extraction
# loses source subdirectories, so compile the same sources with a test entry.
exe_language_settings_probe = executable('language-settings-probe',
    sources, files('tests/language_settings_probe.c', 'tests/language_settings_main.vala'),
    c_args: c_args, vala_args: vala_args, dependencies: dependencies, install: false,
    build_rpath: '$ORIGIN/../libdino')

# Install app icons (PNG sizes for better systray support)
install_data('data/icons/hicolor/scalable/apps/im.dinox.dinox.svg', install_dir: get_option('datadir') / 'icons/hicolor/scalable/apps')
install_data('data/icons/hicolor/16x16/apps/im.dinox.dinox.png', install_dir: get_option('datadir') / 'icons/hicolor/16x16/apps')
install_data('data/icons/hicolor/32x32/apps/im.dinox.dinox.png', install_dir: get_option('datadir') / 'icons/hicolor/32x32/apps')
install_data('data/icons/hicolor/48x48/apps/im.dinox.dinox.png', install_dir: get_option('datadir') / 'icons/hicolor/48x48/apps')
install_data('data/icons/hicolor/128x128/apps/im.dinox.dinox.png', install_dir: get_option('datadir') / 'icons/hicolor/128x128/apps')
install_data('data/icons/hicolor/256x256/apps/im.dinox.dinox.png', install_dir: get_option('datadir') / 'icons/hicolor/256x256/apps')
install_data('data/icons/hicolor/512x512/apps/im.dinox.dinox.png', install_dir: get_option('datadir') / 'icons/hicolor/512x512/apps')

# Install metadata and desktop files
install_data('data/im.dinox.dinox.appdata.xml', install_dir: get_option('datadir') / 'metainfo')
install_data('data/im.dinox.dinox.desktop', install_dir: get_option('datadir') / 'applications')
install_data('data/im.dinox.dinox.service', install_dir: get_option('datadir') / 'dbus-1/services')

# UI ViewModel Tests (pure GObject, no display needed)
test_sources = [
    'src/ui/bot_provider_selection.vala',
    'tests/bot_provider_selection_test.vala',
    'tests/common.vala',
    'tests/testcase.vala',
    'tests/account_connection_input_test.vala',
    'tests/contact_list_model_test.vala',
    'tests/contact_list_selection_model_test.vala',
    'tests/contact_roster_model_source_test.vala',
    'tests/contact_subscription_model_test.vala',
    'tests/initial_snapshot_wait_policy_test.vala',
    'tests/muc_member_list_section_test.vala',
    'tests/muc_status_messages_test.vala',
    'tests/preferences_row_test.vala',
    'tests/data_form_view_model_test.vala',
    'tests/server_administration_labels_test.vala',
    'tests/provider_directory_test.vala',
    'tests/update_checker_test.vala',
    'tests/media_audio_playback_bridge_test.vala',
    'tests/video_playback_lifecycle_test.vala',
    'tests/file_transfer_input_test.vala',
    'tests/recording_send_context_test.vala',
    'tests/pending_plaintext_send_test.vala',
    'tests/encryption_input_status_policy_test.vala',
    'tests/message_diagnostics_test.vala',
    'tests/audit_ui_helpers.vala',
    'src/view_model/preferences_row.vala',
    'src/view_model/account_connection_input.vala',
    'src/ui/util/data_forms.vala',
    'src/ui/util/server_administration_labels.vala',
    'src/service/provider_directory.vala',
    'src/service/update_checker.vala',
    'src/service/media_audio_playback_bridge.vala',
    'src/ui/conversation_content_view/video_playback_lifecycle.vala',
    'src/ui/file_transfer_input.vala',
    'src/ui/chat_input/recording_send_context.vala',
    'src/ui/pending_plaintext_send.vala',
    'src/ui/chat_input/encryption_input_status_policy.vala',
    'src/ui/conversation_content_view/message_diagnostics.vala',
    'src/view_model/contact_list_model.vala',
    'src/view_model/contact_list_selection_model.vala',
    'src/view_model/contact_subscription_model.vala',
    'src/ui/add_conversation/contact_roster_model_source.vala',
    'src/ui/occupant_menu/initial_snapshot_wait_policy.vala',
    'src/ui/occupant_menu/muc_member_list_section.vala',
    'src/ui/conversation_content_view/status_populator.vala',
    'src/ui/util/ui_timing.vala',
    'src/ui/util/helper.vala',
    main_resources,
]
test_deps = [
    # libdino imports crypto-vala, but dep_dino_internal uses a raw link path.
    # Declare it here so Meson includes its DLL directory in the Windows test PATH.
    dep_crypto_vala,
    dep_gee,
    dep_gio,
    dep_glib,
    dep_gstreamer,
    dep_gstreamer_app_core,
    dep_gtk4,
    dep_icu_uc,
    dep_json_glib,
    dep_libadwaita,
    dep_libsoup,
    dep_m,
    dep_qlite,
    dep_xmpp_vala,
]
test_deps += windows_system_deps
main_test_c_args = c_args + ['-include', 'libdino-internal.h']
exe_main_test = executable('main-test', test_sources,
    c_args: main_test_c_args,
    vala_args: vala_args,
    dependencies: test_deps + [dep_dino_internal],
    build_rpath: '$ORIGIN/../libdino',
    install: false)
main_test_env = environment()
main_test_env.set(
    'DBUS_SYSTEM_BUS_ADDRESS',
    'unix:path=' + (meson.current_build_dir() / 'test-no-system-bus'))
test('Tests for main', exe_main_test, env: main_test_env)

exe_language_catalog_probe = executable('language-catalog-probe',
    ['tests/language_catalog_probe.vala', 'src/ui/interface_language.vala'],
    c_args: c_args, vala_args: vala_args, dependencies: dependencies,
    build_rpath: '$ORIGIN/../libdino', install: false)
test('All application catalog languages', prog_python,
    args: [meson.project_source_root() / 'scripts/check-runtime-languages.py',
           '--build-dir', meson.project_build_root(), '--probe', exe_language_catalog_probe],
    depends: exe_language_catalog_probe, suite: 'languages', timeout: 120)

test('Provider snapshot update regression', prog_python,
    args: [meson.project_source_root() / 'scripts/test-provider-snapshot-update.py'])

test('Conversation selector latest query regression', prog_python,
    args: [
        files('tests/conversation_selector_latest_query_test.py'),
        files('src/ui/conversation_selector/conversation_selector_row.vala'),
    ])

test('Conversation selector cleanup regression', prog_python,
    args: [
        files('tests/conversation_selector_cleanup_regression_test.py'),
        files('src/ui/conversation_selector/conversation_selector.vala'),
        files('src/ui/conversation_selector/conversation_selector_row.vala'),
    ])

test('Clear history dialog regression', prog_python,
    args: [
        files('tests/clear_history_dialog_regression_test.py'),
        files('src/ui/util/helper.vala'),
        files('po/de.po'),
    ])

test('Conversation retention regression', prog_python,
    args: [
        files('tests/conversation_retention_regression_test.py'),
        files('src/ui/conversation_content_view/conversation_view.vala'),
        files('src/ui/conversation_content_view/conversation_item_skeleton.vala'),
        files('src/ui/conversation_content_view/message_widget.vala'),
        files('src/ui/conversation_content_view/file_image_widget.vala'),
    ])

test('Conversation media lifecycle regression', prog_python,
    args: [
        files('tests/conversation_media_lifecycle_regression_test.py'),
        files('src/ui/conversation_content_view/reactions_widget.vala'),
        files('src/ui/conversation_content_view/audio_player_widget.vala'),
        files('src/ui/conversation_content_view/video_player_widget.vala'),
    ])

test('Contact list virtualization regression', prog_python,
    args: [
        files('tests/contact_list_virtualization_test.py'),
        files('src/ui/add_conversation/select_contact_dialog.vala'),
        files('src/ui/add_conversation/contact_selection_view.vala'),
        files('src/ui/add_conversation/contact_list_view_row.vala'),
        files('src/ui/add_conversation/add_conference_dialog.vala'),
        files('src/windows/preferences_window/contacts_preferences_page.vala'),
        files('src/windows/preferences_window/preferences_contact_list_view_row.vala'),
        files('src/ui/application.vala'),
    ])

test('Windows backup Unicode regression', prog_python,
    args: [
        files('tests/windows_backup_unicode_regression_test.py'),
        files('src/ui/application.vala'),
        files('src/main.vala'),
    ])

test('MUC member popover input regression', prog_python,
    args: [
        files('tests/occupant_menu_input_regression_test.py'),
        files('src/ui/conversation_titlebar/occupants_entry.vala'),
        files('src/ui/occupant_menu/list.vala'),
        files('src/ui/occupant_menu/list_row.vala'),
        files('src/ui/occupant_menu/muc_member_list_section.vala'),
        files('src/ui/occupant_menu/view.vala'),
        files('src/ui/conversation_content_view/conversation_item_skeleton.vala'),
        files('src/ui/conversation_selector/conversation_selector_row.vala'),
        files('src/ui/util/helper.vala'),
        files('src/ui/conversation_details.vala'),
        files('src/ui/add_conversation/add_groupchat_dialog.vala'),
        files('src/ui/systray_win32.c'),
        files('src/ui/systray_win32.h'),
        files('vapi/systray_win32.vapi'),
    ])

test('MUC sliced snapshot interleave regression', prog_python,
    args: [
        files('tests/muc_snapshot_apply_interleave_test.py'),
        files('src/ui/occupant_menu/list.vala'),
    ])

test('MUC room avatar cache-only regression', prog_python,
    args: [
        files('tests/muc_room_avatar_cache_only_regression_test.py'),
        files('src/ui/add_conversation/conference_list.vala'),
        meson.project_source_root() / 'libdino/src/service/muc_room_avatar_manager.vala',
        meson.project_source_root() / 'xmpp-vala/src/module/xep/0486_muc_avatars.vala',
        meson.project_source_root() / 'libdino/src/service/muc_manager.vala',
    ])

test('MUC real JID visibility notification regression', prog_python,
    args: [
        files('tests/real_jid_visibility_notification_test.py'),
        files('src/ui/conversation_content_view/real_jid_visibility_notification.vala'),
        files('src/ui/conversation_content_view/conversation_view.vala'),
    ])

test('MUC role status null regression', prog_python,
    args: [
        files('tests/muc_role_status_regression_test.py'),
        files('src/ui/conversation_content_view/status_populator.vala'),
    ])

test('MUC voice request chat UX regression', prog_python,
    args: [
        files('tests/muc_voice_request_chat_ux_test.py'),
        files('data/chat_input.ui'),
        files('src/ui/chat_input/view.vala'),
        files('src/ui/chat_input/chat_input_controller.vala'),
        files('src/ui/application.vala'),
        files('src/ui/conversation_details.vala'),
        meson.current_source_dir() / 'meson.build',
    ])

# GTK widget runtime coverage. This is registered only when xvfb-run is
# available so normal headless builds still compile the executable but do not
# require a real display server.
ui_runtime_test_sources = [
    'tests/ui_runtime_common.vala',
    'tests/muc_history_preferences_runtime.vala',
    'tests/history_reload_shortcut_runtime.vala',
    'tests/testcase.vala',
    'tests/call_bottom_bar_runtime.vala',
    'tests/call_window_stub.vala',
    'tests/file_default_widget_runtime.vala',
    'src/ui/util/size_request_box.vala',
    'tests/file_transfer_input_runtime.vala',
    'tests/file_widget_controller_runtime.vala',
    'tests/file_widget_stub.vala',
    'src/ui/conversation_content_view/file_widget.vala',
    'tests/video_recorder_popover_runtime.vala',
    'tests/message_action_target_runtime.vala',
    'tests/widget_focus_lifecycle_runtime.vala',
    'tests/server_administration_text_runtime.vala',
    'tests/provider_directory_ui_runtime.vala',
    'tests/user_search_runtime.vala',
    'tests/contact_selection_view_runtime.vala',
    'tests/sticker_runtime.vala',
    'tests/sticker_animation_runtime.vala',
    'tests/audio_video_preferences_runtime.vala',
    'tests/audio_player_runtime.vala',
    'tests/video_player_runtime.vala',
    'tests/voice_recorder_runtime.vala',
    'tests/conversation_sidebar_runtime.vala',
    'tests/frame_render_queue_runtime.vala',
    'tests/conversation_selector_row_runtime.vala',
    'tests/message_mention_runtime.vala',
    'tests/chat_preview_layout_runtime.vala',
    'tests/responsive_content_runtime.vala',
    'tests/conversation_details_runtime.vala',
    'tests/occupant_hat_badges_runtime.vala',
    'tests/occupant_list_runtime.vala',
    'tests/occupant_ui_application_stub.vala',
    'tests/hats_management_runtime.vala',
    'tests/hats_command_dialog_runtime.vala',
    'tests/feeds_runtime.vala',
    'tests/login_protection_status_runtime.vala',
    'src/ui/feeds_dialog.vala',
    'src/ui/util/text_context_menu.vala',
    'tests/chat_font_preferences_runtime.vala',
    'tests/interface_style_runtime.vala',
    'tests/interface_language_runtime.vala',
    'src/ui/interface_language.vala',
    'src/ui/interface_style.vala',
    'src/ui/window_controls.vala',
    'tests/windows_font_settings_runtime.vala',
    'src/windows/preferences_window/general_preferences_page.vala',
    'src/ui/windows_font_settings.vala',
    'src/ui/occupant_menu/initial_snapshot_wait_policy.vala',
    'src/ui/occupant_menu/muc_member_list_section.vala',
    'src/ui/occupant_menu/list.vala',
    'src/ui/occupant_menu/list_row.vala',
    'src/ui/occupant_menu/view.vala',
    'tests/chat_text_view_runtime.vala',
    'tests/recording_send_context_test.vala',
    'tests/encryption_input_status_policy_test.vala',
    'src/ui/chat_input/chat_text_view.vala',
    'src/ui/chat_input/occupants_tab_completer.vala',
    'src/ui/chat_input/smiley_converter.vala',
    'src/ui/chat_input/view.vala',
    'src/ui/chat_input/encryption_button.vala',
    'src/ui/chat_input/encryption_input_status_policy.vala',
    'src/ui/chat_input/recording_send_context.vala',
    'src/ui/conversation_content_view/message_diagnostics.vala',
    'src/ui/conversation_content_view/message_mention_presentation.vala',
    'src/ui/conversation_content_view/url_preview_widget.vala',
    'src/ui/conversation_content_view/reactions_widget.vala',
    'src/ui/conversation_selector/conversation_sidebar_layout.vala',
    'src/ui/conversation_content_view/frame_render_queue.vala',
    'src/ui/conversation_content_view/chat_scroll_motion.vala',
    'src/ui/conversation_selector/conversation_selector.vala',
    'src/ui/conversation_selector/conversation_selector_row.vala',
    'src/ui/widgets/avatar_picture.vala',
    'src/ui/add_conversation/add_contact_dialog.vala',
    'src/view_model/contact_subscription_model.vala',
    'src/windows/preferences_window/audio_video_preferences_page.vala',
    'src/ui/chat_input/media_message_recorder.vala',
    'src/ui/chat_input/voice_recorder_popover.vala',
    'src/ui/chat_input/gva_compat.c',
    'src/service/media_audio_playback_bridge.vala',
    'src/ui/conversation_content_view/audio_player_widget.vala',
    'src/ui/conversation_content_view/video_player_widget.vala',
    'src/ui/conversation_content_view/video_playback_lifecycle.vala',
    'src/ui/chat_input/sticker_chooser.vala',
    'src/ui/sticker_manager.vala',
    'src/ui/sticker_pack_import_dialog.vala',
    'src/ui/sticker_pack_folder_import_dialog.vala',
    'src/ui/util/accounts_combo_box.vala',
    'src/ui/chat_input/video_recorder_popover.vala',
    'src/ui/call_window/audio_settings_popover.vala',
    'src/ui/call_window/call_bottom_bar.vala',
    'src/ui/call_window/call_dialpad.vala',
    'src/ui/call_window/video_effects_popover.vala',
    'src/ui/call_window/video_settings_popover.vala',
    'src/ui/conversation_content_view/file_default_widget.vala',
    'src/ui/conversation_content_view/file_context_menu.vala',
    'src/ui/conversation_content_view/file_image_widget.vala',
    'src/ui/conversation_content_view/file_transmission_progress.vala',
    'src/ui/widgets/fixed_ratio_picture.vala',
    'src/ui/sticker_animation_compat.c',
    'src/ui/conversation_content_view/file_widget_controller.vala',
    'src/ui/conversation_content_view/message_action_target.vala',
    'src/ui/add_conversation/contact_selection_view.vala',
    'src/ui/add_conversation/user_search_dialog.vala',
    'src/ui/util/data_forms.vala',
    'src/ui/util/helper.vala',
    'src/ui/util/preference_group.vala',
    'src/windows/conversation_details.vala',
    'src/view_model/conversation_details.vala',
    'src/ui/conversation_details.vala',
    'src/ui/hats_management_page.vala',
    'src/ui/contact_details/settings_provider.vala',
    'src/ui/muc_admin_dialog.vala',
    'src/ui/add_conversation/select_contact_dialog.vala',
    'src/ui/add_conversation/contact_roster_model_source.vala',
    'src/ui/muc_history_preferences.vala',
    'src/ui/conversation_titlebar/menu_entry.vala',
    'src/ui/conversation_titlebar/notification_entry.vala',
    'src/ui/util/sizing_bin.vala',
    'src/ui/conversation_titlebar/call_entry.vala',
    'src/ui/util/ui_timing.vala',
    'src/view_model/contact_list_model.vala',
    'src/view_model/contact_list_selection_model.vala',
    'src/view_model/preferences_row.vala',
    main_resources,
]
if host_machine.system() == 'windows'
    ui_runtime_test_sources += files('src/ui/systray_win32.c')
endif
if dep_gtk4.version() == 'unknown' or dep_gtk4.version().version_compare('>=4.14')
    ui_runtime_test_sources += files('src/ui/conversation_content_view/file_transmission_progress.c')
endif
exe_main_ui_runtime_test = executable('main-ui-runtime-test', ui_runtime_test_sources,
    c_args: main_test_c_args,
    vala_args: vala_args,
    dependencies: test_deps + [dep_dino_internal, dep_gstreamer, dep_gstreamer_app_core],
    build_rpath: '$ORIGIN/../libdino',
    install: false)
ui_runtime_test_variables = {
    'GSETTINGS_BACKEND': 'memory',
    'NO_AT_BRIDGE': '1',
    'G_DEBUG': 'fatal-warnings,fatal-criticals',
    'XDG_DATA_HOME': meson.current_build_dir() / 'test-xdg-data',
    'XDG_CACHE_HOME': meson.current_build_dir() / 'test-xdg-cache',
    'DBUS_SYSTEM_BUS_ADDRESS': 'unix:path=' + (meson.current_build_dir() / 'test-no-system-bus'),
}
ui_runtime_test_env = environment(ui_runtime_test_variables + {'GTK_A11Y': 'none'})
if host_machine.system() == 'windows'
    test('Login protection UI runtime', exe_main_ui_runtime_test,
        args: ['-p', '/LoginProtectionStatusRuntime'],
        env: ui_runtime_test_env,
        timeout: 60)
    test('Interface style UI runtime', exe_main_ui_runtime_test,
        args: ['-p', '/InterfaceStyleRuntime'],
        env: ui_runtime_test_env,
        timeout: 60)
endif
xvfb_run = find_program('xvfb-run', required: false)
if xvfb_run.found()
    test('Tests for main UI runtime', xvfb_run,
        args: [
            '--auto-servernum',
            '--server-args=-screen 0 1024x768x24',
            exe_main_ui_runtime_test,
        ],
        env: ui_runtime_test_env,
        timeout: 120)
    test('Interface style high contrast runtime', xvfb_run,
        args: [
            '--auto-servernum',
            '--server-args=-screen 0 1024x768x24',
            exe_main_ui_runtime_test,
            '-p', '/InterfaceStyleRuntime/switch_palettes_restore_classic_and_preserve_semantic_colors',
        ],
        env: environment(ui_runtime_test_variables + {'ADW_DEBUG_HIGH_CONTRAST': '1'}),
        timeout: 60)
    # The normal suite disables AT contexts; exercise native seek controls and
    # responsive reparenting separately with accessibility enabled.
    test('Tests for audio player accessibility runtime', xvfb_run,
        args: [
            '--auto-servernum',
            '--server-args=-screen 0 1280x768x24',
            exe_main_ui_runtime_test,
            '-p', '/AudioPlayerRuntime',
        ],
        env: environment(ui_runtime_test_variables + {'GTK_A11Y': 'test'}),
        timeout: 30)
    test('Tests for MUC history preferences accessibility runtime', xvfb_run,
        args: [
            '--auto-servernum',
            '--server-args=-screen 0 1024x768x24',
            exe_main_ui_runtime_test,
            '-p', '/MucHistoryPreferencesRuntime',
        ],
        env: environment(ui_runtime_test_variables + {'GTK_A11Y': 'test'}),
        timeout: 30)
    test('Tests for conversation sidebar accessibility runtime', xvfb_run,
        args: [
            '--auto-servernum',
            '--server-args=-screen 0 1280x768x24',
            exe_main_ui_runtime_test,
            '-p', '/ConversationSidebarRuntime',
            '-p', '/ConversationSelectorRowRuntime',
        ],
        env: environment(ui_runtime_test_variables + {'GTK_A11Y': 'test'}),
        timeout: 60)
    if find_program('xdotool', required: false).found()
        test('Tests for message sending keyboard runtime', xvfb_run,
            args: [
                '--auto-servernum',
                '--server-args=-screen 0 1024x768x24',
                exe_main_ui_runtime_test,
                '-p', '/ChatTextViewRuntime/native_enter_keys_respect_send_mode_selection_and_composition',
            ],
            env: environment(ui_runtime_test_variables + {
                'GTK_A11Y': 'none', 'GDK_BACKEND': 'x11',
                'GTK_IM_MODULE': 'gtk-im-context-simple', 'DINOX_TEST_NATIVE_KEYS': '1',
            }),
            timeout: 30)
    endif
    test('Tests for chat render scheduling runtime', xvfb_run,
        args: [
            '--auto-servernum',
            '--server-args=-screen 0 1024x768x24',
            exe_main_ui_runtime_test,
            '-p', '/FrameRenderQueueRuntime',
        ],
        env: environment(ui_runtime_test_variables + {'GTK_A11Y': 'test'}),
        timeout: 30)
    test('Tests for message mention accessibility runtime', xvfb_run,
        args: [
            '--auto-servernum',
            '--server-args=-screen 0 1024x768x24',
            exe_main_ui_runtime_test,
            '-p', '/MessageMentionRuntime',
        ],
        env: environment(ui_runtime_test_variables + {'GTK_A11Y': 'test'}),
        timeout: 30)
    test('Tests for hats and member list accessibility runtime', xvfb_run,
        args: [
            '--auto-servernum',
            '--server-args=-screen 0 1024x768x24',
            exe_main_ui_runtime_test,
            '-p', '/OccupantHatBadgesRuntime',
            '-p', '/OccupantListRuntime',
            '-p', '/HatsManagementRuntime',
            '-p', '/HatsCommandDialogRuntime',
        ],
        env: environment(ui_runtime_test_variables + {'GTK_A11Y': 'test'}),
        timeout: 90)
    test('Tests for chat font preferences accessibility runtime', xvfb_run,
        args: [
            '--auto-servernum',
            '--server-args=-screen 0 1280x1024x24',
            exe_main_ui_runtime_test,
            '-p', '/ChatFontPreferencesRuntime',
            '-p', '/WindowsFontSettingsRuntime',
        ],
        env: environment(ui_runtime_test_variables + {'GTK_A11Y': 'test'}),
        timeout: 60)
    test('Tests for responsive chat accessibility runtime', xvfb_run,
        args: [
            '--auto-servernum',
            '--server-args=-screen 0 1280x768x24',
            exe_main_ui_runtime_test,
            '-p', '/MessageMentionRuntime',
            '-p', '/ChatPreviewLayoutRuntime',
            '-p', '/ResponsiveContentRuntime',
            '-p', '/ConversationDetailsRuntime',
        ],
        env: environment(ui_runtime_test_variables + {'GTK_A11Y': 'test'}),
        timeout: 60)
endif

# Real tray protocol/native code with isolated application state. No account,
# user bus, Shell notification icon or installed application is touched.
if host_machine.system() == 'windows'
    exe_systray_native_test = executable('systray-native-test',
        files('tests/systray_win32_runtime.c'),
        dependencies: [dep_glib] + windows_system_deps,
        c_args: ['-Wno-unused-parameter'],
        install: false)
    test('Windows tray Unicode and lifecycle', exe_systray_native_test,
        suite: 'systray',
        env: environment({'TEMP': meson.current_build_dir(), 'TMP': meson.current_build_dir()}),
        timeout: 60)
else
    exe_systray_fixture = executable('systray-runtime-fixture',
        files('tests/systray_runtime_fixture.vala', 'src/ui/systray.vala',
              'src/ui/systray_sni_dbus.c', 'src/ui/systray_dbusmenu.c'),
        dependencies: [dep_gtk4, dep_libadwaita, dep_gee, dep_gio, dep_m],
        c_args: c_args,
        include_directories: include_directories('src/ui'),
        vala_args: ['--target-glib=2.66', '--vapidir=' + (vala_source_root / 'main/vapi'),
                    '--pkg=systray_sni_dbus', '--pkg=systray_dbusmenu'],
        install: false)
    tray_dbus_run = find_program('dbus-run-session', required: false)
    tray_dbus_proxy = find_program('xdg-dbus-proxy', required: false)
    tray_python_gi = run_command(prog_python, '-c', 'from gi.repository import Gio, GLib', check: false)
    if xvfb_run.found() and tray_dbus_run.found() and tray_python_gi.returncode() == 0
        foreach tray_locale : offered_test_languages
            foreach tray_watcher : ['org.kde.StatusNotifierWatcher', 'org.x.StatusNotifierWatcher']
                tray_test_args = [
                    '--config-file', meson.current_source_dir() / 'tests/systray_test_bus.conf', '--',
                    xvfb_run.full_path(), '-a', prog_python.full_path(),
                    meson.current_source_dir() / 'tests/systray_dbus_runtime.py',
                    exe_systray_fixture,
                    meson.project_source_root() / 'im.dinox.dinox.json',
                    meson.current_source_dir() / 'data/icons/hicolor',
                    '--catalogs', meson.current_build_dir() / 'po',
                    '--language', tray_locale, '--watcher', tray_watcher,
                ]
                if tray_locale in ['ar', 'arz', 'he', 'ur']
                    tray_test_args += ['--rtl']
                endif
                if tray_dbus_proxy.found()
                    tray_test_args += ['--proxy']
                endif
                test('Tray ' + tray_locale + ' ' + tray_watcher, tray_dbus_run,
                    args: tray_test_args, suite: 'systray', timeout: 30)
            endforeach
        endforeach
    endif
endif
