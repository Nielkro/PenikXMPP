dependencies = [
    dep_crypto_vala,
    dep_dino,
    dep_gee,
    dep_glib,
    dep_gmodule,
    dep_gstreamer,
    dep_gstreamer_app,
    dep_gstreamer_audio,
    dep_gstreamer_rtp,
    dep_gstreamer_video,
    dep_gtk4,
    dep_m,
    dep_qlite,
    dep_xmpp_vala,
]

c_args = [
    '-DG_LOG_DOMAIN="rtp"',
]
cpp_args = c_args
link_args = []
vala_args = []
if host_machine.system() != 'windows'
    vala_args += ['-D', 'HAVE_MALLOC_TRIM']
endif

sources = files(
    'src/codec_util.vala',
    'src/device.vala',
    'src/gst_fixes.c',
    'src/module.vala',
    'src/plugin.vala',
    'src/register_plugin.vala',
    'src/stream.vala',
    'src/video_widget.vala',
)

if dep_gstreamer_rtp.version() == 'unknown' or dep_gstreamer_rtp.version().version_compare('>=1.16')
    vala_args += ['-D', 'GST_1_16']
endif
if dep_gstreamer_rtp.version() == 'unknown' or dep_gstreamer_rtp.version().version_compare('>=1.18')
    vala_args += ['-D', 'GST_1_18']
endif
if dep_gstreamer_rtp.version() == 'unknown' or dep_gstreamer_rtp.version().version_compare('>=1.20')
    vala_args += ['-D', 'GST_1_20']
endif
if meson.get_compiler('vala').version().version_compare('<0.56.1')
    vala_args += ['--vapidir', vala_source_root / 'plugins/rtp/vapi']
endif
if get_option('plugin-rtp-h264').allowed()
    vala_args += ['-D', 'ENABLE_H264']
endif
if get_option('plugin-rtp-msdk').allowed()
    vala_args += ['-D', 'ENABLE_MSDK']
endif

option_vaapi_enabled = get_option('plugin-rtp-vaapi').enabled() or (get_option('plugin-rtp-vaapi').allowed() and dep_gstreamer_rtp.version().version_compare('>=1.26'))
if option_vaapi_enabled
    vala_args += ['-D', 'ENABLE_VAAPI']
endif

option_v4l2_enabled = get_option('plugin-rtp-v4l2').enabled()
if option_v4l2_enabled
    vala_args += ['-D', 'ENABLE_V4L2']
endif

option_v4l2_sl_enabled = (get_option('plugin-rtp-v4l2-sl').allowed() and dep_gstreamer_rtp.version().version_compare('>=1.26'))
if option_v4l2_sl_enabled
    vala_args += ['-D', 'ENABLE_V4L2SL']
endif

lib_rtp = shared_library('rtp', sources, name_prefix: '', c_args: c_args, cpp_args: cpp_args, vala_args: vala_args, link_args: link_args, include_directories: include_directories('src'), dependencies: dependencies, install: true, install_dir: get_option('libdir') / get_option('plugindir'), install_rpath: default_install_rpath)
dep_rtp = declare_dependency(link_with: lib_rtp, include_directories: include_directories('.'))
summary('Voice/video calls (rtp)', dep_rtp.found(), bool_yn: true, section: 'Plugins')

if dep_rtp.found()
    summary('H264 codec', get_option('plugin-rtp-h264').allowed(), section: 'RTP configuration')
    summary('Intel MediaSDK', get_option('plugin-rtp-msdk').allowed(), section: 'RTP configuration')
    summary('Video Acceleration API', option_vaapi_enabled, section: 'RTP configuration')
    summary('V4L2 API (stateful)', option_v4l2_enabled, section: 'RTP configuration')
    summary('V4L2 API (stateless)', option_v4l2_sl_enabled, section: 'RTP configuration')
endif
