project('Dino', 'c', 'cpp', 'vala', version: '2.3.6', license: 'GPL-3.0-or-later',
  meson_version: '>=1.3.0', default_options: ['buildtype=debugoptimized'])

# Security Hardening Flags
c_compiler = meson.get_compiler('c')
c_project_arguments = [
  '-fstack-protector-strong',
  '-D_FORTIFY_SOURCE=2',
  '-Wformat',
  '-Werror=format-security',
  # Suppress harmless warnings from Vala-generated C code
  '-Wno-unused-variable',
  '-Wno-unused-but-set-variable',
  '-Wno-address',
]
if c_compiler.get_id() == 'gcc'
  c_project_arguments += ['-Wno-discarded-qualifiers']
endif

add_project_arguments(
  c_project_arguments,
  language: 'c'
)
add_project_arguments(
  '-fstack-protector-strong',
  '-D_FORTIFY_SOURCE=2',
  '-Wformat',
  '-Werror=format-security',
  language: 'cpp'
)

fs = import('fs')
# Native Windows tools may decode Unicode absolute argv paths using the system
# code page. Ninja runs tools from the build root; keep our Vala paths relative.
vala_source_root = meson.project_source_root()
vala_build_root = meson.project_build_root()
if host_machine.system() == 'windows'
  vala_source_root = fs.relative_to(vala_source_root, meson.project_build_root())
  vala_build_root = '.'
endif

add_project_arguments(
  '--vapidir=' + vala_source_root / 'qlite/vapi',
  language: 'vala'
)

if host_machine.system() == 'windows'
  message('Forcing WINDOWS define for Vala')
  add_project_arguments('--define=WINDOWS', language: 'vala')
endif

gnome = import('gnome')
i18n = import('i18n')
python = import('python')

# plugin_crypto is enabled if any of the crypto plugins is enabled, auto if
# none of them are explicitly enabled but at least one is set to auto, or
# disabled if all of them are disabled.
plugin_crypto = get_option('plugin-ice')
foreach plugin : ['plugin-ice', 'plugin-omemo', 'plugin-rtp']
    if get_option(plugin).enabled() and not plugin_crypto.enabled()
        plugin_crypto = get_option(plugin)
    elif get_option(plugin).allowed() and not plugin_crypto.allowed()
        plugin_crypto = get_option(plugin)
    endif
endforeach

dep_gdk_pixbuf = dependency('gdk-pixbuf-2.0')
dep_gee = dependency('gee-0.8')
dep_gio = dependency('gio-2.0')
dep_glib = dependency('glib-2.0')
dep_gnutls = dependency('gnutls', disabler: true, required: get_option('plugin-ice'))
dep_gmodule = dependency('gmodule-2.0')
dep_gpgme = dependency('gpgme', disabler: true, required: get_option('plugin-openpgp'))
dep_gstreamer = dependency('gstreamer-1.0')
dep_gstreamer_app = dependency('gstreamer-app-1.0', disabler: true, required: get_option('plugin-rtp'))
dep_gstreamer_app_core = dependency('gstreamer-app-1.0')
dep_gstreamer_audio = dependency('gstreamer-audio-1.0', disabler: true, required: get_option('plugin-rtp'))
dep_gstreamer_rtp = dependency('gstreamer-rtp-1.0', disabler: true, required: get_option('plugin-rtp'))
dep_gstreamer_video = dependency('gstreamer-video-1.0', disabler: true, required: get_option('plugin-rtp'))
dep_gtk4 = dependency('gtk4')
dep_gtk4_x11 = dependency('gtk4-x11', required: false)
dep_x11 = dependency('x11', required: false)
dep_icu_uc = dependency('icu-uc')
dep_json_glib = dependency('json-glib-1.0')
dep_libadwaita = dependency('libadwaita-1', version: '>=1.5')
if host_machine.system() == 'windows'
    dep_libcanberra = disabler()
else
    dep_libcanberra = dependency('libcanberra', disabler: true, required: get_option('plugin-notification-sound'))
endif
dep_libgcrypt = dependency('libgcrypt', disabler: true, required: plugin_crypto)
dep_libgcrypt_core = dependency('libgcrypt')  # Non-disabling: CSPRNG is always required
dep_libqrencode = dependency('libqrencode', disabler: true, required: get_option('plugin-omemo'))
dep_libsrtp2 = dependency('libsrtp2', disabler: true, required: plugin_crypto)
dep_libomemo_c = dependency('libomemo-c', version: '0.5.1', disabler: true, required: get_option('plugin-omemo'))
local_libomemo_c_root = get_option('local-libomemo-c-root')
local_libomemo_c_build_rpath = ''
if local_libomemo_c_root != ''
    if host_machine.system() == 'windows'
        error('local-libomemo-c-root is only for normal Linux build-tree runs')
    endif
    if not local_libomemo_c_root.startswith('/')
        error('local-libomemo-c-root must be an absolute path')
    endif
    local_libomemo_c_library = local_libomemo_c_root / 'lib/libomemo-c.so.0.5.1'
    local_protobuf_c_library = local_libomemo_c_root / 'lib/libprotobuf-c.so.1.0.0'
    if not fs.is_file(local_libomemo_c_library) or not fs.is_file(local_protobuf_c_library)
        error('local-libomemo-c-root does not contain the pinned libomemo-c 0.5.1 and protobuf-c 1.5.2 runtime')
    endif
    pkg_config = find_program('pkg-config')
    libomemo_c_prefix_check = run_command(
        pkg_config,
        '--variable=prefix',
        'libomemo-c',
        check: true,
    ).stdout().strip()
    if not fs.is_samepath(libomemo_c_prefix_check, local_libomemo_c_root)
        error('PKG_CONFIG_PATH selected libomemo-c from ' + libomemo_c_prefix_check + ', expected ' + local_libomemo_c_root)
    endif
    local_libomemo_c_build_rpath = local_libomemo_c_root / 'lib'
    message('Normal Linux build-tree uses pinned libomemo-c/protobuf-c runtime: ' + local_libomemo_c_root)
endif
dep_libsoup = dependency('libsoup-3.0', version: '>= 3.4')
dep_nice = dependency('nice', version: '>=0.1.15', disabler: true, required: get_option('plugin-ice'))
dep_m = meson.get_compiler('c').find_library('m', required: false)
# dep_sqlite3 = dependency('sqlite3', version: '>=3.24')
dep_sqlcipher = dependency('sqlcipher', version: '>=3.4')
if host_machine.system() == 'windows'
    dep_libsecret = dependency('libsecret-1', required: false)
else
    dep_libsecret = dependency('libsecret-1')
endif

dep_geoclue = dependency('libgeoclue-2.0', required: get_option('location-sharing'))

prog_bash = find_program('bash')
if host_machine.system() == 'windows' and prog_bash.full_path().to_lower().contains('system32')
    foreach candidate : ['/usr/bin/bash', 'C:/msys64/usr/bin/bash.exe']
        candidate_prog = find_program(candidate, required: false)
        if candidate_prog.found()
            prog_bash = candidate_prog
            break
        endif
    endforeach
endif

google_libwebrtc_artifact_root = get_option('google-libwebrtc-artifact-root')
google_libwebrtc_runtime_root = get_option('google-libwebrtc-runtime-root')
google_vision_runtime_base = get_option('google-vision-runtime-root')
google_libwebrtc_wrapper = get_option('google-libwebrtc-wrapper')
dep_google_libwebrtc = disabler()
dep_dinox_google_webrtc = disabler()
google_libwebrtc_prebuilt_runtime = false
google_libwebrtc_private_build_rpath = ''
google_libwebrtc_codec_source_filename = 'webrtc-m152-codec-sources-6f37672d3584-sha256-2b17c14cc13b.tar.gz'
if google_libwebrtc_runtime_root != '' and google_libwebrtc_artifact_root != ''
    error('Set either google-libwebrtc-runtime-root or google-libwebrtc-artifact-root, not both')
endif
if google_libwebrtc_runtime_root != '' and google_vision_runtime_base != ''
    error('Release runtimes contain their vision bundle; google-vision-runtime-root is only for development SDK builds')
endif
if google_libwebrtc_runtime_root != ''
    google_vision_runtime_base = google_libwebrtc_runtime_root / (host_machine.system() == 'windows' ? 'bin' : 'lib')
    runtime_check_script = host_machine.system() == 'windows' ? 'scripts/check-libwebrtc-windows-runtime.sh' : 'scripts/check-libwebrtc-linux-runtime.sh'
    google_libwebrtc_check = run_command(
        prog_bash,
        meson.current_source_dir() / runtime_check_script,
        google_libwebrtc_runtime_root,
        check: false,
    )
    if google_libwebrtc_check.returncode() != 0
        error('Google/libwebrtc runtime validation failed:\n' + google_libwebrtc_check.stdout() + google_libwebrtc_check.stderr())
    endif
    if not google_libwebrtc_wrapper.disabled()
        runtime_library = host_machine.system() == 'windows' ? google_libwebrtc_runtime_root / 'lib/libdinox-google-webrtc.dll.a' : google_libwebrtc_runtime_root / 'lib/libdinox-google-webrtc.so'
        runtime_link_library = host_machine.system() == 'windows' ? fs.relative_to(runtime_library, meson.project_build_root()) : runtime_library
        runtime_binary = host_machine.system() == 'windows' ? google_libwebrtc_runtime_root / 'bin/dinox-google-webrtc.dll' : google_libwebrtc_runtime_root / 'lib/libdinox-google-webrtc.so'
        runtime_worker = host_machine.system() == 'windows' ? google_libwebrtc_runtime_root / 'bin/dinox-webrtc-worker.exe' : google_libwebrtc_runtime_root / 'lib/dinox-webrtc-worker'
        dep_dinox_google_webrtc = declare_dependency(
            include_directories: include_directories('google-webrtc/include'),
            link_args: [runtime_link_library],
        )
        google_libwebrtc_prebuilt_runtime = true
        install_data(
            runtime_binary,
            runtime_worker,
            install_dir: 'lib/dinox',
            install_mode: 'rwxr-xr-x',
        )
        google_libwebrtc_runtime_notices = [
            google_libwebrtc_runtime_root / 'LICENSE',
            google_libwebrtc_runtime_root / 'LICENSE.md',
            google_libwebrtc_runtime_root / 'PATENTS',
            google_libwebrtc_runtime_root / 'manifest.json',
        ]
        if fs.is_file(google_libwebrtc_runtime_root / 'WEBRTC-CODECS.json')
            google_libwebrtc_runtime_notices += [
                google_libwebrtc_runtime_root / 'WEBRTC-CODECS.json',
                google_libwebrtc_runtime_root / 'WEBRTC-GN-ARGS.gn',
            ]
            if host_machine.system() == 'windows'
                install_data('scripts/libwebrtc-windows-runtime/CODEC-SOURCES.md',
                    install_dir: get_option('datadir') / 'licenses/dinox/google-libwebrtc')
            else
                install_data(
                    google_libwebrtc_runtime_root / 'sources' / google_libwebrtc_codec_source_filename,
                    install_dir: get_option('datadir') / 'licenses/dinox/google-libwebrtc/sources',
                )
            endif
        endif
        if host_machine.system() != 'windows'
            install_data(
                google_libwebrtc_runtime_root / 'lib/libavcodec-dinox-hw.so.62',
                google_libwebrtc_runtime_root / 'lib/libavutil-dinox-hw.so.60',
                install_dir: 'lib/dinox',
                install_mode: 'rwxr-xr-x',
            )
            google_libwebrtc_runtime_notices += [
                google_libwebrtc_runtime_root / 'FFMPEG-LICENSE',
                google_libwebrtc_runtime_root / 'LIBVA-LICENSE',
                google_libwebrtc_runtime_root / 'FFMPEG-VP8-VAAPI.json',
                google_libwebrtc_runtime_root / 'NVIDIA-CODEC-HEADERS-LICENSE',
            ]
        elif fs.is_file(google_libwebrtc_runtime_root / 'FFMPEG-WINDOWS-HARDWARE.json')
            install_data(
                google_libwebrtc_runtime_root / 'bin/avcodec-dinox-hw-62.dll',
                google_libwebrtc_runtime_root / 'bin/avutil-dinox-hw-60.dll',
                install_dir: 'lib/dinox',
            )
            google_libwebrtc_runtime_notices += [
                google_libwebrtc_runtime_root / 'FFMPEG-LICENSE',
                google_libwebrtc_runtime_root / 'FFMPEG-WINDOWS-HARDWARE.json',
            ]
            install_data(
                google_libwebrtc_runtime_root / 'sources/ffmpeg-mf-dynamic-bitrate.patch',
                install_dir: get_option('datadir') / 'licenses/dinox/google-libwebrtc/sources',
            )
        endif
        install_data(
            google_libwebrtc_runtime_notices,
            install_dir: get_option('datadir') / 'licenses/dinox/google-libwebrtc',
        )
        if host_machine.system() != 'windows'
            install_data(
                google_libwebrtc_runtime_root / 'sources/ffmpeg-8.1.2.tar.xz',
                google_libwebrtc_runtime_root / 'sources/libva-2.20.0.tar.gz',
                google_libwebrtc_runtime_root / 'sources/nv-codec-headers-n8.1.24.15.tar.gz',
                google_libwebrtc_runtime_root / 'sources/ffmpeg-dinox-symbol-versions.patch',
                install_dir: get_option('datadir') / 'licenses/dinox/google-libwebrtc/sources',
            )
        endif
        message('Prebuilt Google/libwebrtc runtime enabled: ' + google_libwebrtc_runtime_root)
    endif
endif
if google_libwebrtc_artifact_root != ''
  if host_machine.system() == 'windows'
    google_vision_runtime_base = google_libwebrtc_artifact_root / 'bin'
    google_libwebrtc_manifest = google_libwebrtc_artifact_root / 'manifest.json'
    google_libwebrtc_license = google_libwebrtc_artifact_root / 'LICENSE'
    google_libwebrtc_third_party_licenses = google_libwebrtc_artifact_root / 'LICENSE.md'
    google_libwebrtc_patents = google_libwebrtc_artifact_root / 'PATENTS'
    google_libwebrtc_windows_dll = google_libwebrtc_artifact_root / 'bin/dinox-google-webrtc.dll'
    google_libwebrtc_windows_worker = google_libwebrtc_artifact_root / 'bin/dinox-webrtc-worker.exe'
    google_libwebrtc_windows_import = google_libwebrtc_artifact_root / 'lib/libdinox-google-webrtc.dll.a'

    google_libwebrtc_check = run_command(
      prog_bash,
      meson.current_source_dir() / 'scripts/check-libwebrtc-windows-runtime.sh',
      google_libwebrtc_artifact_root,
      check: false,
    )
    if google_libwebrtc_check.returncode() != 0
      error('Google/libwebrtc Windows runtime validation failed:\n' + google_libwebrtc_check.stdout() + google_libwebrtc_check.stderr())
    endif

    if not google_libwebrtc_wrapper.disabled()
      dep_dinox_google_webrtc = declare_dependency(
        include_directories: include_directories('google-webrtc/include'),
        link_args: [fs.relative_to(google_libwebrtc_windows_import, meson.project_build_root())],
      )
      google_libwebrtc_prebuilt_runtime = true
      install_data(google_libwebrtc_windows_dll, install_dir: get_option('bindir'))
      install_data(google_libwebrtc_windows_worker, install_dir: get_option('bindir'))
      install_data(
        google_libwebrtc_license,
        google_libwebrtc_third_party_licenses,
        google_libwebrtc_patents,
        google_libwebrtc_manifest,
        install_dir: get_option('datadir') / 'licenses/dinox/google-libwebrtc',
      )
      if fs.is_file(google_libwebrtc_artifact_root / 'WEBRTC-CODECS.json')
        install_data(
          google_libwebrtc_artifact_root / 'WEBRTC-CODECS.json',
          google_libwebrtc_artifact_root / 'WEBRTC-GN-ARGS.gn',
          install_dir: get_option('datadir') / 'licenses/dinox/google-libwebrtc',
        )
        install_data('scripts/libwebrtc-windows-runtime/CODEC-SOURCES.md',
          install_dir: get_option('datadir') / 'licenses/dinox/google-libwebrtc')
      endif
      if fs.is_file(google_libwebrtc_artifact_root / 'FFMPEG-WINDOWS-HARDWARE.json')
        install_data(
          google_libwebrtc_artifact_root / 'bin/avcodec-dinox-hw-62.dll',
          google_libwebrtc_artifact_root / 'bin/avutil-dinox-hw-60.dll',
          install_dir: get_option('bindir'),
        )
        install_data(
          google_libwebrtc_artifact_root / 'FFMPEG-LICENSE',
          google_libwebrtc_artifact_root / 'FFMPEG-WINDOWS-HARDWARE.json',
          install_dir: get_option('datadir') / 'licenses/dinox/google-libwebrtc',
        )
        install_data(
          google_libwebrtc_artifact_root / 'sources/ffmpeg-mf-dynamic-bitrate.patch',
          install_dir: get_option('datadir') / 'licenses/dinox/google-libwebrtc/sources',
        )
      endif
      message('Prebuilt Google/libwebrtc Windows runtime enabled: ' + google_libwebrtc_artifact_root)
    endif
  else
    google_libwebrtc_include_dir = google_libwebrtc_artifact_root / 'include'
    google_libwebrtc_lib_dir = google_libwebrtc_artifact_root / 'lib'
    google_libwebrtc_library = google_libwebrtc_lib_dir / 'libwebrtc.a'
    google_libwebrtc_video_library = google_libwebrtc_lib_dir / 'libwebrtc-dinox-video.a'
    google_libwebrtc_ffmpeg_avcodec_library = google_libwebrtc_lib_dir / 'libavcodec-dinox-hw.so'
    google_libwebrtc_ffmpeg_avutil_library = google_libwebrtc_lib_dir / 'libavutil-dinox-hw.so'
    google_libwebrtc_ffmpeg_include_dir = google_libwebrtc_artifact_root / 'include/ffmpeg-vp8-vaapi'
    google_libwebrtc_libcxx_library = google_libwebrtc_lib_dir / 'libc++.a'
    google_libwebrtc_libcxxabi_library = google_libwebrtc_lib_dir / 'libc++abi.a'
    google_libwebrtc_libcxx_config_dir = google_libwebrtc_artifact_root / 'toolchain/libcxx-config'
    google_libwebrtc_libcxx_include_dir = google_libwebrtc_artifact_root / 'toolchain/libcxx/include'
    google_libwebrtc_libcxxabi_include_dir = google_libwebrtc_artifact_root / 'toolchain/libcxxabi/include'
    google_libwebrtc_manifest = google_libwebrtc_artifact_root / 'manifest.json'
    google_libwebrtc_license = google_libwebrtc_artifact_root / 'LICENSE'
    google_libwebrtc_third_party_licenses = google_libwebrtc_artifact_root / 'LICENSE.md'
    google_libwebrtc_patents = google_libwebrtc_artifact_root / 'PATENTS'
    google_libwebrtc_ffmpeg_license = google_libwebrtc_artifact_root / 'FFMPEG-LICENSE'
    google_libwebrtc_libva_license = google_libwebrtc_artifact_root / 'LIBVA-LICENSE'
    google_libwebrtc_ffmpeg_manifest = google_libwebrtc_artifact_root / 'FFMPEG-VP8-VAAPI.json'
    google_libwebrtc_ffmpeg_source = google_libwebrtc_artifact_root / 'sources/ffmpeg-8.1.2.tar.xz'
    google_libwebrtc_libva_source = google_libwebrtc_artifact_root / 'sources/libva-2.20.0.tar.gz'

    if not fs.is_dir(google_libwebrtc_artifact_root)
        error('google-libwebrtc-artifact-root does not exist or is not a directory: ' + google_libwebrtc_artifact_root)
    endif
    if not fs.is_dir(google_libwebrtc_include_dir)
        error('google-libwebrtc artifact is missing include/: ' + google_libwebrtc_include_dir)
    endif
    if not fs.is_dir(google_libwebrtc_lib_dir)
        error('google-libwebrtc artifact is missing lib/: ' + google_libwebrtc_lib_dir)
    endif

    foreach required_file : [
        google_libwebrtc_manifest,
        google_libwebrtc_license,
        google_libwebrtc_third_party_licenses,
        google_libwebrtc_patents,
        google_libwebrtc_ffmpeg_license,
        google_libwebrtc_libva_license,
        google_libwebrtc_ffmpeg_manifest,
        google_libwebrtc_ffmpeg_source,
        google_libwebrtc_libva_source,
        google_libwebrtc_library,
        google_libwebrtc_video_library,
        google_libwebrtc_ffmpeg_avcodec_library,
        google_libwebrtc_ffmpeg_avutil_library,
        google_libwebrtc_libcxx_library,
        google_libwebrtc_libcxxabi_library,
        google_libwebrtc_include_dir / 'api/create_peerconnection_factory.h',
        google_libwebrtc_include_dir / 'api/peer_connection_interface.h',
        google_libwebrtc_ffmpeg_include_dir / 'libavcodec/avcodec.h',
        google_libwebrtc_ffmpeg_include_dir / 'libavutil/hwcontext_vaapi.h',
        google_libwebrtc_ffmpeg_include_dir / 'va/va.h',
        google_libwebrtc_include_dir / 'logging/rtc_event_log/events/rtc_event_ice_candidate_pair.h',
        google_libwebrtc_libcxx_config_dir / '__config_site',
        google_libwebrtc_libcxx_include_dir / 'vector',
        google_libwebrtc_libcxxabi_include_dir / 'cxxabi.h',
    ]
        if not fs.is_file(required_file)
            error('google-libwebrtc artifact is missing required file: ' + required_file)
        endif
    endforeach

    google_libwebrtc_check = run_command(
        prog_bash,
        meson.current_source_dir() / 'scripts/check-libwebrtc-artifact.sh',
        google_libwebrtc_artifact_root,
        check: false,
    )
    if google_libwebrtc_check.returncode() != 0
        error('google-libwebrtc artifact validation failed:\n' + google_libwebrtc_check.stdout() + google_libwebrtc_check.stderr())
    endif

    if google_libwebrtc_wrapper.disabled()
        message('Google/libwebrtc artifact validation enabled without wrapper compile: ' + google_libwebrtc_artifact_root)
    else
        google_libwebrtc_compile_args = [
            '-I' + google_libwebrtc_include_dir,
            '-I' + google_libwebrtc_ffmpeg_include_dir,
            '-nostdinc++',
            '-I' + google_libwebrtc_libcxx_config_dir,
            '-isystem' + google_libwebrtc_libcxx_include_dir,
            '-isystem' + google_libwebrtc_libcxxabi_include_dir,
            '-DABSL_ALLOCATOR_NOTHROW=1',
            '-DNDEBUG',
            '-DRTC_ENABLE_VP9',
            '-DWEBRTC_USE_H264',
            '-DUSE_GLIB=1',
            '-DUSE_UDEV',
            '-DWEBRTC_HAVE_SCTP',
            '-DWEBRTC_INCLUDE_INTERNAL_AUDIO_DEVICE',
            '-DWEBRTC_LINUX',
            '-DWEBRTC_POSIX',
            '-DDINOX_WEBRTC_ENABLE_VP8_VAAPI_DECODER=1',
            '-D_LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_EXTENSIVE',
            '-D_LIBCPP_DISABLE_VISIBILITY_ANNOTATIONS',
            '-D_LIBCXXABI_DISABLE_VISIBILITY_ANNOTATIONS',
        ]

        google_libwebrtc_link_args = [
            '-fuse-ld=lld',
            '-nostdlib++',
            google_libwebrtc_library,
            google_libwebrtc_video_library,
            google_libwebrtc_libcxx_library,
            google_libwebrtc_libcxxabi_library,
            '-lX11',
            '-l:libva-drm.so.2',
            '-l:libva.so.2',
            '-latomic',
            '-pthread',
            '-ldl',
            '-lm',
            '-lrt',
        ]
        google_libwebrtc_private_build_rpath = google_libwebrtc_lib_dir

        cpp = meson.get_compiler('cpp')
        google_libwebrtc_compiler_is_usable = true
        google_libwebrtc_compiler_error = ''
        if cpp.get_id() != 'clang'
            google_libwebrtc_compiler_is_usable = false
            google_libwebrtc_compiler_error = 'google-libwebrtc-wrapper requires Clang >= 21 because the pinned Chromium libc++ headers are not supported by GCC. Use CXX=/path/to/webrtc/src/third_party/llvm-build/Release+Asserts/bin/clang++ or a system Clang >= 21.'
        elif not cpp.version().version_compare('>=21.0.0')
            google_libwebrtc_compiler_is_usable = false
            google_libwebrtc_compiler_error = 'google-libwebrtc-wrapper requires Clang >= 21 because the pinned Chromium libc++ headers require newer compiler builtins. Found Clang ' + cpp.version()
        endif

        if google_libwebrtc_compiler_is_usable
            google_libwebrtc_compile_args += ['-Wno-nullability-completeness']
            dep_google_libwebrtc = declare_dependency(
                compile_args: google_libwebrtc_compile_args,
                link_args: google_libwebrtc_link_args,
            )
            message('Google/libwebrtc development/proof artifact enabled (Linux release packages require google-libwebrtc-runtime-root): ' + google_libwebrtc_artifact_root)
        elif google_libwebrtc_wrapper.enabled()
            error(google_libwebrtc_compiler_error)
        else
            message('Google/libwebrtc artifact validation passed, wrapper auto-disabled: ' + google_libwebrtc_compiler_error)
        endif
    endif
  endif
endif

prog_git = find_program('git', required: false)
prog_python = python.find_installation()

test('Windows compiler Unicode path adapter', prog_python,
    args: [files('scripts/windows-compiler-paths.py'), '--self-test'])

if google_vision_runtime_base != ''
    if google_libwebrtc_wrapper.disabled()
        error('google-vision-runtime-root requires an enabled Google/libwebrtc wrapper')
    endif
    google_vision_platform = host_machine.system() == 'windows' ? 'windows' : 'linux'
    google_vision_check = run_command(prog_python,
        meson.current_source_dir() / 'scripts/check-vision-runtime.py',
        '--base', google_vision_runtime_base, '--platform', google_vision_platform,
        check: false,
    )
    if google_vision_check.returncode() != 0
        error('Vision runtime validation failed:\n' + google_vision_check.stdout() + google_vision_check.stderr())
    endif
    google_vision_worker = google_vision_platform == 'windows' ? 'dinox-vision-worker.exe' : 'dinox-vision-worker'
    install_data(google_vision_runtime_base / google_vision_worker,
        install_dir: 'lib/dinox', install_mode: 'rwxr-xr-x')
    install_data(
        google_vision_runtime_base / 'dinox-vision-runtime-manifest.json',
        google_vision_runtime_base / 'dinox-vision-SHA256SUMS',
        install_dir: 'lib/dinox',
    )
    install_subdir(google_vision_runtime_base / 'dinox-vision-models', install_dir: 'lib/dinox')
    install_subdir(google_vision_runtime_base / 'dinox-vision-licenses', install_dir: 'lib/dinox')
    install_data('scripts/check-vision-runtime.py',
        install_dir: get_option('libexecdir'), rename: 'dinox-vision-runtime-gate',
        install_mode: 'rwxr-xr-x')
endif

test(
    'video-effects-baseline-sampler-self-test',
    prog_python,
    args: [meson.current_source_dir() / 'scripts/measure-video-effects-baseline.py', '--self-test'],
    timeout: 15,
)

if import('fs').is_file('VERSION') and meson.version().version_compare('>=1.4.0')
    version_file = files('VERSION')[0]
    version_file_path = version_file.full_path()
else
    version_file = 'invalid'
    version_file_path = meson.current_source_dir() / 'VERSION'
endif

default_install_rpath = ''
if get_option('set-install-rpath')
    default_install_rpath = get_option('prefix') / get_option('libdir')
endif

if google_libwebrtc_wrapper.enabled() and not dep_google_libwebrtc.found() and not google_libwebrtc_prebuilt_runtime
    error('google-libwebrtc-wrapper requires a valid google-libwebrtc-runtime-root or google-libwebrtc-artifact-root')
endif

subdir('qlite')
subdir('dns-security')
subdir('xmpp-vala')
subdir('crypto-vala')
if not google_libwebrtc_prebuilt_runtime and (google_libwebrtc_wrapper.enabled() or (google_libwebrtc_wrapper.allowed() and dep_google_libwebrtc.found()))
    subdir('google-webrtc')
endif
if google_libwebrtc_prebuilt_runtime
    # Package/release baselines must measure the immutable runtime that will be
    # shipped, not a separately compiled development wrapper.
    executable(
        'google-webrtc-video-effects-baseline',
        'google-webrtc/tests/video_effects_baseline.cpp',
        dependencies: [dep_dinox_google_webrtc, dependency('threads')],
        install: false,
    )
endif
subdir('libdino')
# The matrix follows the actual packaged languages; new languages cannot silently
# disappear from runtime validation. The catalog probe checks all three lists.
offered_test_languages = ['en'] + run_command(prog_python, '-c',
    'import pathlib,sys; print(" ".join(line.split("#",1)[0] for line in pathlib.Path(sys.argv[1]).read_text().splitlines()))',
    meson.project_source_root() / 'main/po/LINGUAS', check: true).stdout().strip().split()
subdir('main')
subdir('plugins')

# Test the shared codec contract even when Google/libwebrtc is selected and the
# legacy GStreamer call plugin is disabled. No codec pipeline is started here.
rtp_locale_test = executable('rtp-codec-locale-test',
    files('plugins/rtp/src/codec_util.vala', 'plugins/rtp/tests/locale_codec.vala'),
    dependencies: [dep_glib, dep_gio, dep_gee, dep_gstreamer, dep_xmpp_vala], install: false)
test('RTP locale codec boundaries', rtp_locale_test)

# Exercise actual parser/dispatch/serialization boundaries under both a decimal
# comma locale and Turkish ASCII case rules. The runner verifies the locale;
# unavailable locale data is an explicit skip, never a silent C-locale pass.
locale_boundary_runner = files('scripts/run-locale-boundary-tests.py')
locale_boundary_cases = [
    {'name': 'XMPP wire format', 'command': [exe_xmpp_vala_test,
        '-p', '/EntityCapsAudit/LOCALE_caps_hash_uses_octet_order',
        '-p', '/ProtocolParserAudit/LOCALE_location_numbers_and_timestamps_keep_wire_format',
        '-p', '/JingleSdpBridgeAudit/LOCALE_fmtp_tokens_keep_ascii_case_rules']},
    {'name': 'Update URL', 'command': [exe_main_test,
        '-p', '/UpdateChecker/official_host_case_is_independent_of_system_locale',
        '-p', '/BotProviderSelection']},
    {'name': 'MIME and download errors', 'command': [exe_libdino_test,
        '-p', '/EntityAudit/LOCALE_esfs_cipher_and_url_use_ascii_rules',
        '-p', '/Stickers/technical_mime_and_extensions_ignore_system_case_rules',
        '-p', '/FileManagerTest/FileManager_localized_timeout_schedules_retry']},
]
if is_variable('exe_bot_test')
    locale_boundary_cases += [{'name': 'Bot commands', 'command': [exe_bot_test,
        '-p', '/PermissionUtils/LOCALE_provider_ids_and_command_permissions_are_language_independent']}]
endif
if is_variable('mqtt_locale_test')
    locale_boundary_cases += [{'name': 'MQTT values', 'command': [mqtt_locale_test]}]
endif
if is_variable('exe_openpgp_test')
    locale_boundary_cases += [{'name': 'GPG paths and MIME', 'command': [exe_openpgp_test,
        '-p', '/GPGKeylistParser/LOCALE_windows_paths_preserve_drive_and_unicode',
        '-p', '/FileDecryptor/detects_pgp_mime_type']}]
endif
locale_ui_command = []
if host_machine.system() == 'windows'
    locale_ui_command = [exe_main_ui_runtime_test]
elif xvfb_run.found()
    locale_ui_command = [xvfb_run.full_path(), '-a', '--server-args=-screen 0 1024x768x24', exe_main_ui_runtime_test]
endif
if locale_ui_command.length() > 0
    # xdotool must only target an isolated Xvfb display. Windows still runs
    # the portable composer/Unicode tests, without skipping its whole UI group.
    locale_native_keys = []
    if host_machine.system() != 'windows'
        locale_native_keys = ['-p', '/ChatTextViewRuntime/native_enter_keys_respect_send_mode_selection_and_composition']
    endif
    locale_settings_command = [exe_language_settings_probe]
    if host_machine.system() != 'windows'
        locale_settings_command = [xvfb_run.full_path(), '-a', '--server-args=-screen 0 1024x768x24', exe_language_settings_probe]
    endif
    locale_boundary_cases += [{'name': 'Native settings and dialogs', 'command': locale_settings_command}]
    locale_boundary_cases += [{'name': 'HTML and media widgets', 'command': locale_ui_command + [
        '-p', '/ChatPreviewLayoutRuntime/html_tokens_and_unicode_offsets_are_locale_independent',
        '-p', '/FileDefaultWidgetRuntime/uppercase_mime_selects_media_player_in_system_locale',
        '-p', '/StickerRuntime/LOCALE_raster_mime_and_extensions_use_ascii_rules',
        '-p', '/ServerAdministrationTextRuntime',
        '-p', '/ChatTextViewRuntime/rich_draft_restores_unicode_styles_and_caret_selection'] + locale_native_keys + [
        '-p', '/InterfaceLanguageRuntime',
        '-p', '/AudioVideoPreferencesRuntime/identical_names_preserve_selected_device_and_saved_identity',
        '-p', '/LoginProtectionStatusRuntime',
        '-p', '/FeedsRuntime/native_text_menus_preserve_unicode_selection_and_clipboard',
        '-p', '/HatsCommandDialogRuntime/editing_preserves_identity_custom_hue_and_form_fields']}]
endif
if is_variable('exe_omemo_test')
    locale_boundary_cases += [{'name': 'OMEMO byte and session boundaries', 'command': [exe_omemo_test,
        '-p', '/DecryptLogic', '-p', '/DecryptFailureStage', '-p', '/EncryptSafetyCheck']}]
endif
if is_variable('transport_command_test')
    locale_boundary_cases += [{'name': 'Tor Unicode process paths', 'command': [transport_command_test]}]
endif
if is_variable('rtp_locale_test')
    locale_boundary_cases += [{'name': 'RTP native codec caps', 'command': [rtp_locale_test]}]
endif
foreach boundary_locale : offered_test_languages
    foreach boundary : locale_boundary_cases
        test('Locale ' + boundary_locale + ' - ' + boundary['name'], prog_python,
            args: [locale_boundary_runner, '--locale', boundary_locale, '--'] + boundary['command'],
            env: ui_runtime_test_env, suite: 'locale-boundaries', timeout: 120)
    endforeach
endforeach

if host_machine.system() == 'windows'
    # The internal VAPI dependencies deliberately avoid link_with. Their
    # relative link arguments do not expose DLL directories to Meson's PATH
    # heuristic, so keep those build-tree DLLs available to native tests.
    internal_test_env = environment()
    internal_test_env.prepend('PATH', [
        meson.project_build_root() / 'libdino',
        meson.project_build_root() / 'plugins/omemo',
        meson.project_build_root() / 'plugins/openpgp',
        meson.project_build_root() / 'plugins/ice',
        meson.project_build_root() / 'plugins/http-files',
    ], separator: ';')
    if google_vision_runtime_base != ''
        internal_test_env.prepend('PATH', google_vision_runtime_base, separator: ';')
    endif
    add_test_setup('windows_internal_libraries', env: internal_test_env, is_default: true)
endif

summary('Google/libwebrtc native wrapper', dep_dinox_google_webrtc.found(), bool_yn: true, section: 'Google/libwebrtc')
