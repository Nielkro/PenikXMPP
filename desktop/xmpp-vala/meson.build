dependencies = [
    dep_gee,
    dep_gio,
    dep_glib,
    dep_icu_uc,
    dep_libgcrypt_core,
    dep_m,
]
sources = files(
    'src/core/direct_tls_xmpp_stream.vala',
    'src/core/dns_security_connection.vala',
    'src/core/dns_security_policy.vala',
    'src/core/io_xmpp_stream.vala',
    'src/core/module_flag.vala',
    'src/core/namespace_state.vala',
    'src/core/stanza_attribute.vala',
    'src/core/stanza_node.vala',
    'src/core/stanza_reader.vala',
    'src/core/stanza_writer.vala',
    'src/core/starttls_xmpp_stream.vala',
    'src/core/stream_connect.vala',
    'src/core/tls_xmpp_stream.vala',
    'src/core/xmpp_log.vala',
    'src/core/xmpp_stream.vala',
    'src/glib_fixes.vapi',
    'src/module/bind.vala',
    'src/module/bookmarks_provider.vala',
    'src/module/conference.vala',
    'src/module/iq/module.vala',
    'src/module/iq/stanza.vala',
    'src/module/jid.vala',
    'src/module/message/module.vala',
    'src/module/message/stanza.vala',
    'src/module/presence/flag.vala',
    'src/module/presence/module.vala',
    'src/module/presence/stanza.vala',
    'src/module/roster/flag.vala',
    'src/module/roster/item.vala',
    'src/module/roster/module.vala',
    'src/module/roster/versioning_module.vala',
    'src/module/sasl.vala',
    'src/module/session.vala',
    'src/module/stanza.vala',
    'src/module/stanza_error.vala',
    'src/module/stream_error.vala',
    'src/module/util.vala',
    'src/module/xep/0004_data_forms.vala',
    'src/module/xep/0030_service_discovery/flag.vala',
    'src/module/xep/0030_service_discovery/identity.vala',
    'src/module/xep/0030_service_discovery/info_result.vala',
    'src/module/xep/0030_service_discovery/item.vala',
    'src/module/xep/0030_service_discovery/items_result.vala',
    'src/module/xep/0030_service_discovery/module.vala',
    'src/module/xep/0045_muc/flag.vala',
    'src/module/xep/0045_muc/module.vala',
    'src/module/xep/0045_muc/status_code.vala',
    'src/module/xep/0047_in_band_bytestreams.vala',
    'src/module/xep/0048_bookmarks.vala',
    'src/module/xep/0048_conference.vala',
    'src/module/xep/0394_message_markup.vala',
    'src/module/xep/0049_private_xml_storage.vala',
    'src/module/xep/0050_ad_hoc_commands.vala',
    'src/module/xep/0054_vcard/module.vala',
    'src/module/xep/0055_search.vala',
    'src/module/xep/0059_result_set_management.vala',
    'src/module/xep/0060_pubsub.vala',
    'src/module/xep/0065_socks5_bytestreams.vala',
    'src/module/xep/0066_out_of_band_data.vala',
    'src/module/xep/0077_in_band_registration.vala',
    'src/module/xep/0080_user_location.vala',
    'src/module/xep/0082_date_time_profiles.vala',
    'src/module/xep/0084_user_avatars.vala',
    'src/module/xep/0085_chat_state_notifications.vala',
    'src/module/xep/0092_software_version.vala',
    'src/module/xep/0104_http_scheme_url_data.vala',
    'src/module/xep/0115_entity_capabilities.vala',
    'src/module/xep/0166_jingle/component.vala',
    'src/module/xep/0166_jingle/content.vala',
    'src/module/xep/0166_jingle/content_description.vala',
    'src/module/xep/0166_jingle/content_node.vala',
    'src/module/xep/0166_jingle/content_security.vala',
    'src/module/xep/0166_jingle/content_transport.vala',
    'src/module/xep/0166_jingle/jingle_flag.vala',
    'src/module/xep/0166_jingle/jingle_module.vala',
    'src/module/xep/0166_jingle/jingle_structs.vala',
    'src/module/xep/0166_jingle/reason_element.vala',
    'src/module/xep/0166_jingle/session.vala',
    'src/module/xep/0166_jingle/session_info.vala',
    'src/module/xep/0167_jingle_rtp/content_parameters.vala',
    'src/module/xep/0167_jingle_rtp/content_type.vala',
    'src/module/xep/0167_jingle_rtp/jingle_rtp_module.vala',
    'src/module/xep/0167_jingle_rtp/libwebrtc_jingle_adapter.vala',
    'src/module/xep/0167_jingle_rtp/payload_type.vala',
    'src/module/xep/0167_jingle_rtp/sdp_bridge.vala',
    'src/module/xep/0167_jingle_rtp/session_info_type.vala',
    'src/module/xep/0167_jingle_rtp/stream.vala',
    'src/module/xep/0176_jingle_ice_udp/candidate.vala',
    'src/module/xep/0176_jingle_ice_udp/jingle_ice_udp_module.vala',
    'src/module/xep/0176_jingle_ice_udp/transport_parameters.vala',
    'src/module/xep/0177_jingle_raw_udp.vala',
    'src/module/xep/0184_message_delivery_receipts.vala',
    'src/module/xep/0191_blocking_command.vala',
    'src/module/xep/0198_stream_management.vala',
    'src/module/xep/0199_ping.vala',
    'src/module/xep/0203_delayed_delivery.vala',
    'src/module/xep/0215_external_service_discovery.vala',
    'src/module/xep/0231_bits_of_binary.vala',
    'src/module/xep/0234_jingle_file_transfer.vala',
    'src/module/xep/0249_direct_muc_invitations.vala',
    'src/module/xep/0260_jingle_socks5_bytestreams.vala',
    'src/module/xep/0261_jingle_in_band_bytestreams.vala',
    'src/module/xep/0264_jingle_content_thumbnails.vala',
    'src/module/xep/0272_muji.vala',
    'src/module/xep/0280_message_carbons.vala',
    'src/module/xep/0292_vcard4/module.vala',
    'src/module/xep/0297_stanza_forwarding.vala',
    'src/module/xep/0298_coin.vala',
    'src/module/xep/0300_cryptographic_hashes.vala',
    'src/module/xep/0308_last_message_correction.vala',
    'src/module/xep/0313_2_message_archive_management.vala',
    'src/module/xep/0313_message_archive_management.vala',
    'src/module/xep/0333_chat_markers.vala',
    'src/module/xep/0334_message_processing_hints.vala',
    'src/module/xep/0353_jingle_message_initiation.vala',
    'src/module/xep/0359_unique_stable_stanza_ids.vala',
    'src/module/xep/0363_http_file_upload.vala',
    'src/module/xep/0367_message_attaching.vala',
    'src/module/xep/0372_references.vala',
    'src/module/xep/0373_openpgp.vala',
    'src/module/xep/0374_openpgp_content.vala',
    'src/module/xep/0380_explicit_encryption.vala',
    'src/module/xep/0384_omemo/omemo_decryptor.vala',
    'src/module/xep/0384_omemo/omemo_encryptor.vala',
    'src/module/xep/0384_omemo/omemo2_encryptor.vala',
    'src/module/xep/0384_omemo/omemo2_decryptor.vala',
    'src/module/xep/0391_jingle_encrypted_transports.vala',
    'src/module/xep/0420_sce/sce.vala',    'src/module/xep/0392_consistent_color/consistent_color.vala',
    'src/module/xep/0392_consistent_color/hsluv.vala',
    'src/module/xep/0402_bookmarks2.vala',
    'src/module/xep/0410_muc_self_ping.vala',
    'src/module/xep/0421_occupant_ids.vala',
    'src/module/xep/0424_message_retraction.vala',
    'src/module/xep/0425_message_moderation.vala',
    'src/module/xep/0428_fallback_indication.vala',
    'src/module/xep/0444_reactions.vala',
    'src/module/xep/0446_file_metadata_element.vala',
    'src/module/xep/0447_stateless_file_sharing.vala',
    'src/module/xep/0449_stickers.vala',
    'src/module/xep/0461_replies.vala',
    'src/module/xep/0482_call_invites.vala',
    'src/module/xep/0486_muc_avatars.vala',
    'src/module/xep/0490_message_displayed_synchronization.vala',
    'src/util.vala',
)
c_args = [
    '-DG_LOG_DOMAIN="xmpp-vala"',
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
vala_args = [
    '--vapidir', vala_source_root / 'xmpp-vala/vapi',
    '--vapidir', vala_source_root / 'crypto-vala/vapi',
]
if dep_unbound.found()
    dependencies += dep_dns_security
    vala_args += ['-D', 'HAVE_DNSSEC']
endif
if meson.get_compiler('vala').version().version_compare('=0.56.11')
    vala_args += ['-D', 'VALA_0_56_11']
endif

# GLib version feature guards
glib_version = dep_glib.version()
if glib_version.version_compare('>=2.60')
    vala_args += ['-D', 'GLIB_2_60']
endif
if glib_version.version_compare('>=2.66')
    vala_args += ['-D', 'GLIB_2_66']
endif
if glib_version.version_compare('>=2.74')
    vala_args += ['-D', 'GLIB_2_74']
endif
if glib_version.version_compare('>=2.70')
    vala_args += ['-D', 'GLIB_2_70']
endif

lib_xmpp_vala = library('xmpp-vala', sources, c_args: c_args, vala_args: vala_args, dependencies: dependencies, version: '0.1', install: true, install_dir: [true, true, true], install_rpath: default_install_rpath)
dep_xmpp_vala = declare_dependency(link_with: lib_xmpp_vala, include_directories: include_directories('.'))

install_data('xmpp-vala.deps', install_dir: get_option('datadir') / 'vala/vapi', install_tag: 'devel') # TODO: workaround for https://github.com/mesonbuild/meson/issues/9756

test_sources = [
    'tests/common.vala',
    'tests/testcase.vala',

    'tests/jid.vala',
    'tests/stanza.vala',
    'tests/color.vala',
    'tests/util.vala',
    'tests/vcard4.vala',
    'tests/emoji_markup.vala',
    'tests/xep_0448.vala',
    'tests/xep_0486_muc_avatars.vala',
    'tests/sasl_channel_binding.vala',
    'tests/sasl_security.vala',
    'tests/dns_security_policy.vala',
    'tests/stream_management.vala',
    'tests/mam.vala',
    'tests/data_forms_delta.vala',
    'tests/audit_stream_management.vala',
    'tests/audit_omemo.vala',
    'tests/audit_openpgp.vala',
    'tests/audit_stanza_entry.vala',
    'tests/audit_crypto_hash.vala',
    'tests/audit_entity_caps.vala',
    'tests/audit_protocol_parsers.vala',
    'tests/audit_util_extra.vala',
    'tests/audit_xep_roundtrips.vala',
    'tests/audit_socks5.vala',
    'tests/audit_muc.vala',
    'tests/audit_muc_voice_request.vala',
    'tests/audit_presence.vala',
    'tests/audit_avatar.vala',
    'tests/audit_muji.vala',
    'tests/audit_malformed_stanzas.vala',
    'tests/audit_null_safety.vala',
    'tests/audit_adversarial.vala',
    'tests/audit_carbons_forwarding.vala',
    'tests/audit_pubsub.vala',
    'tests/audit_http_upload.vala',
    'tests/audit_blocking.vala',
    'tests/reconnect_startup.vala',
    'tests/audit_sce.vala',
    'tests/audit_jingle_ft.vala',
    'tests/audit_registration_commands.vala',
    'tests/audit_search.vala',
    'tests/audit_mam_jmi_moderation.vala',
    'tests/audit_jingle_sdp_bridge.vala',
    'tests/jingle_rtcp_feedback_test.vala',
    'tests/audit_iq_interceptor.vala',
    'tests/audit_iq_request_filters.vala',
    'tests/xep_0490_message_displayed_synchronization.vala',
]
exe_xmpp_vala_test = executable('xmpp-vala-test', test_sources, c_args: c_args, vala_args: vala_args, dependencies: dependencies + dep_xmpp_vala, install: false)
test('Tests for xmpp-vala', exe_xmpp_vala_test)
sasl_tls_probe = executable('sasl-tls-probe', 'tests/sasl_tls_probe.vala',
    c_args: c_args, vala_args: vala_args, dependencies: dependencies + dep_xmpp_vala, install: false)
sasl_python = find_program('python3', required: false)
sasl_openssl = find_program('openssl', required: false)
if sasl_python.found() and sasl_openssl.found()
    test('SASL TLS downgrade protection', sasl_python,
        args: [files('tests/run-sasl-tls-fixture.py'), sasl_tls_probe, sasl_openssl.full_path()], timeout: 120)
endif
if dep_unbound.found()
    dns_discovery_test = executable('dns-discovery-test', 'tests/dns_discovery.vala',
        'src/core/dns_security_policy.vala', 'src/core/dns_security_connection.vala',
        vala_args: ['-D', 'HAVE_DNSSEC', '-D', 'DNSSEC_TEST'],
        dependencies: [dep_dns_security, dep_gee], install: false)
    exe_xmpp_dane_test = executable('xmpp-dane-test', 'tests/dane_stream.vala',
        c_args: c_args, vala_args: vala_args, dependencies: dependencies + dep_xmpp_vala, install: false)
    if dns_python.found() and dns_fixture_modules.returncode() == 0
        test('XMPP DANE pre-authentication gate', dns_python,
            args: [files('tests/run-dane-stream-fixture.py'), exe_xmpp_dane_test], timeout: 40)
        test('DNSSEC XMPP service discovery', dns_python,
            args: [files('../dns-security/tests/run-discovery-fixture.py'), dns_discovery_test], timeout: 40)
    endif
endif
# Isolate the actual 30-second IQ response timeout from other tests' mock requests.
test('IQ response timeout', exe_xmpp_vala_test,
    args: ['-p', '/IqRequestFilterAudit/callback_response_timeout_preserves_await_response_phase'],
    env: ['DINOX_TEST_IQ_RESPONSE_TIMEOUT=1'],
    timeout: 45)
