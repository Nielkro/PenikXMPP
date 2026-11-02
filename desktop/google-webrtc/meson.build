dinox_google_webrtc_effect_support_sources = files(
    'src/dinox_webrtc_video_runtime.cpp',
    'src/dinox_webrtc_video_background_images.cpp',
    'src/dinox_webrtc_video_background_preparation.cpp',
    'src/dinox_webrtc_video_compositor.cpp',
    'src/dinox_webrtc_video_overlays.cpp',
    'vision/vision_client.cpp',
)
if host_machine.system() == 'windows'
    dinox_google_webrtc_effect_support_sources += files('vision/vision_process_windows.cpp')
else
    dinox_google_webrtc_effect_support_sources += files('vision/vision_process_posix.cpp')
endif
dinox_google_webrtc_sources = files(
    'src/dinox_webrtc.cpp',
    'src/dinox_webrtc_ipc.cpp',
    'src/dinox_webrtc_video_effects.cpp',
    'src/dinox_webrtc_video_decoder_factory.cpp',
    'src/dinox_webrtc_worker_proxy.cpp',
    'src/dinox_webrtc_video_ring.cpp',
) + dinox_google_webrtc_effect_support_sources
if host_machine.system() == 'windows'
    dinox_google_webrtc_sources += files('src/dinox_webrtc_video_mf_codec.cpp')
else
    dinox_google_webrtc_sources += files('src/dinox_webrtc_video_ffmpeg.cpp')
endif

dinox_google_webrtc_cpp_args = [
    '-std=c++20',
    '-DDINOX_WEBRTC_BUILDING_LIBRARY=1',
    '-DDINOX_WEBRTC_MILESTONE=152',
    '-DDINOX_WEBRTC_BRANCH="7977"',
    '-DDINOX_WEBRTC_COMMIT="6f37672d358475cd17544121a12494da454d85fb"',
    '-DDINOX_WEBRTC_ARTIFACT_ABI="dinox-libwebrtc-runtime-v2"',
    '-DDINOX_WEBRTC_INSTALLED_WORKER_PATH="' +
        (get_option('prefix') / get_option('libdir') / 'dinox' / 'dinox-webrtc-worker') + '"',
]
if get_option('google-libwebrtc-test-oracle')
    dinox_google_webrtc_cpp_args += ['-DDINOX_WEBRTC_ENABLE_IN_PROCESS_TEST_ORACLE=1']
endif

dinox_google_webrtc_include_directories = include_directories('include')

dinox_google_webrtc_dependencies = [
    dep_google_libwebrtc,
    dependency('gio-2.0'),
    dependency('threads'),
]

dinox_google_webrtc_private_libraries = []
if host_machine.system() != 'windows'
    dinox_google_webrtc_dependencies += meson.get_compiler('cpp').find_library('dl', required: true)
    # Only the wrapper loads the private hardware codecs. Standalone tests
    # using WebRTC's static utilities must not acquire these runtime imports.
    # Preserve archive ordering: Chromium's static codec definitions must be
    # resolved before adding the separate dynamic hardware codec libraries.
    dinox_google_webrtc_dependencies += declare_dependency(link_args: [
        '-Wl,--no-as-needed',
        google_libwebrtc_ffmpeg_avcodec_library,
        google_libwebrtc_ffmpeg_avutil_library,
        '-Wl,--as-needed',
    ])
endif

if host_machine.system() != 'windows'
    dinox_google_webrtc_dependencies += dependency('gio-unix-2.0')
    # Match the installed sibling layout for the private VA-API decoder loader.
    # This keeps development builds out of system FFmpeg and avoids embedding a
    # development-machine library path as a release fallback.
    foreach library : ['libavcodec-dinox-hw.so.62', 'libavutil-dinox-hw.so.60']
        dinox_google_webrtc_private_libraries += fs.copyfile(
            google_libwebrtc_lib_dir / library,
            library,
            install: true,
            install_dir: 'lib/dinox',
            install_mode: 'rwxr-xr-x',
        )
    endforeach
endif

lib_dinox_google_webrtc = shared_library(
    'dinox-google-webrtc',
    dinox_google_webrtc_sources,
    cpp_args: dinox_google_webrtc_cpp_args,
    include_directories: dinox_google_webrtc_include_directories,
    dependencies: dinox_google_webrtc_dependencies,
    link_depends: dinox_google_webrtc_private_libraries,
    install: true,
    install_dir: 'lib/dinox',
    build_rpath: host_machine.system() == 'windows' ? google_libwebrtc_private_build_rpath : '$ORIGIN:' + google_libwebrtc_private_build_rpath,
    install_rpath: host_machine.system() == 'windows' ? default_install_rpath : '$ORIGIN',
)

dep_dinox_google_webrtc = declare_dependency(
    link_with: lib_dinox_google_webrtc,
    include_directories: dinox_google_webrtc_include_directories,
)

dinox_google_webrtc_smoke = executable(
    'google-webrtc-wrapper-smoke',
    files('tests/wrapper_smoke.cpp'),
    dependencies: [dep_dinox_google_webrtc, dependency('threads')],
    install: false,
)

dinox_google_webrtc_video_codec_smoke = executable(
    'google-webrtc-video-codec-smoke',
    files('tests/video_codec_smoke.cpp'),
    cpp_args: ['-std=c++20'],
    include_directories: include_directories('src'),
    dependencies: [dep_dinox_google_webrtc, dep_google_libwebrtc],
    install: false,
)
test('google-webrtc-video-codec-smoke', dinox_google_webrtc_video_codec_smoke,
    timeout: 90)
test('google-webrtc-h264-runtime-fallback-smoke', dinox_google_webrtc_video_codec_smoke,
    args: ['--runtime-failure'], timeout: 90)

dinox_google_webrtc_hardware_rate_smoke = executable(
    'google-webrtc-hardware-rate-control-smoke',
    'tests/hardware_rate_control_smoke.cpp',
    include_directories: include_directories('src'),
    cpp_args: ['-std=c++20'],
    install: false,
)
test('google-webrtc-hardware-rate-control-smoke', dinox_google_webrtc_hardware_rate_smoke)

if host_machine.system() != 'windows'
    foreach direction : ['decode', 'encode']
        test('google-webrtc-h264-hardware-' + direction + '-smoke',
            dinox_google_webrtc_video_codec_smoke,
            args: ['--require-hardware-' + direction],
            timeout: 90,
        )
    endforeach
    test('google-webrtc-hardware-unavailable-fallback-smoke',
        dinox_google_webrtc_video_codec_smoke,
        args: ['--unavailable-device'],
        timeout: 90,
    )
endif

if get_option('google-libwebrtc-test-oracle')
    test(
        'google-webrtc-wrapper-smoke',
        dinox_google_webrtc_smoke,
        env: ['DINOX_WEBRTC_IN_PROCESS_TEST_ORACLE=1'],
    )
endif

dinox_google_webrtc_muji_sdp_smoke = executable(
    'google-webrtc-muji-sdp-smoke',
    files('tests/wrapper_smoke.cpp'),
    cpp_args: ['-DDINOX_WEBRTC_MUJI_SDP_SMOKE_ONLY=1'],
    dependencies: [dep_dinox_google_webrtc, dependency('threads')],
    install: false,
)
dinox_google_webrtc_ipc_smoke = executable(
    'google-webrtc-ipc-protocol-smoke',
    files('tests/ipc_protocol_smoke.cpp'),
    dependencies: [dep_dinox_google_webrtc],
    install: false,
)

test('google-webrtc-ipc-protocol-smoke', dinox_google_webrtc_ipc_smoke)

dinox_google_webrtc_video_ring_smoke = executable(
    'google-webrtc-video-ring-smoke',
    files(
        'src/dinox_webrtc_video_ring.cpp',
        'tests/video_ring_smoke.cpp',
    ),
    cpp_args: ['-std=c++20', '-DDINOX_WEBRTC_VIDEO_RING_TESTING=1'],
    include_directories: include_directories('src'),
    dependencies: [dependency('threads')],
    install: false,
)

test('google-webrtc-video-ring-smoke', dinox_google_webrtc_video_ring_smoke)

dinox_google_webrtc_executor_smoke = executable(
    'google-webrtc-executor-smoke',
    files(
        'src/dinox_webrtc_executor.cpp',
        'tests/executor_smoke.cpp',
    ),
    cpp_args: ['-std=c++20'],
    include_directories: include_directories('src'),
    dependencies: [dependency('threads')],
    install: false,
)

test('google-webrtc-executor-smoke', dinox_google_webrtc_executor_smoke)

dinox_google_webrtc_video_effects_smoke = executable(
    'google-webrtc-video-effects-smoke',
    files(
        'src/dinox_webrtc_video_effects.cpp',
        'tests/video_effects_smoke.cpp',
    ) + dinox_google_webrtc_effect_support_sources,
    cpp_args: ['-std=c++20'],
    include_directories: [
        include_directories('src'),
        dinox_google_webrtc_include_directories,
    ],
    dependencies: [dep_google_libwebrtc, dependency('threads')] +
        (host_machine.system() == 'windows' ? [] : [meson.get_compiler('cpp').find_library('dl')]),
    install: false,
)

test('google-webrtc-video-effects-smoke', dinox_google_webrtc_video_effects_smoke)

dinox_google_webrtc_video_pipeline_effects_smoke = executable(
    'google-webrtc-video-pipeline-effects-smoke',
    'tests/video_pipeline_effects_smoke.cpp',
    dependencies: [dep_dinox_google_webrtc, dependency('threads')],
    install: false,
)

test(
    'google-webrtc-video-pipeline-effects-smoke',
    dinox_google_webrtc_video_pipeline_effects_smoke,
    timeout: 30,
)

dinox_google_webrtc_vision_fake_worker = executable(
    'google-webrtc-vision-fake-worker',
    'vision/vision_client_fake_worker.cpp',
    cpp_args: ['-std=c++20'],
    dependencies: [dependency('threads')],
    install: false,
)
dinox_google_webrtc_video_pipeline_privacy_smoke = executable(
    'google-webrtc-video-pipeline-privacy-smoke',
    'tests/video_pipeline_privacy_smoke.cpp',
    cpp_args: ['-std=c++20'],
    dependencies: [dep_dinox_google_webrtc, dependency('threads')],
    install: false,
)
test('google-webrtc-video-pipeline-privacy-smoke',
    dinox_google_webrtc_video_pipeline_privacy_smoke,
    args: [dinox_google_webrtc_vision_fake_worker.full_path()],
    timeout: 30,
)
test('google-webrtc-video-pipeline-privacy-watchdog-smoke',
    dinox_google_webrtc_video_pipeline_privacy_smoke,
    args: [dinox_google_webrtc_vision_fake_worker.full_path(), '--watchdog'],
    timeout: 30,
)
if get_option('google-libwebrtc-test-oracle')
    test('google-webrtc-video-pipeline-privacy-callback-gate-smoke',
        dinox_google_webrtc_video_pipeline_privacy_smoke,
        args: [dinox_google_webrtc_vision_fake_worker.full_path(), '--callback-gate'],
        env: ['DINOX_WEBRTC_IN_PROCESS_TEST_ORACLE=1'],
        timeout: 30,
    )
endif

dinox_google_webrtc_video_background_api_smoke = executable(
    'google-webrtc-video-background-api-smoke',
    'tests/video_background_api_smoke.cpp',
    cpp_args: ['-std=c++20'],
    dependencies: [dep_dinox_google_webrtc, dependency('threads')],
    install: false,
)
test('google-webrtc-video-background-api-smoke',
    dinox_google_webrtc_video_background_api_smoke,
    args: [dinox_google_webrtc_vision_fake_worker.full_path()],
    timeout: 30,
)
dinox_google_webrtc_video_vision_geometry_golden = executable(
    'google-webrtc-video-vision-geometry-golden',
    'tests/video_vision_geometry_golden.cpp',
    cpp_args: ['-std=c++20'],
    include_directories: include_directories('src'),
    install: false,
)
test('google-webrtc-video-vision-geometry-golden',dinox_google_webrtc_video_vision_geometry_golden)

dinox_google_webrtc_video_vision_preprocess_rows_golden = executable(
    'google-webrtc-video-vision-preprocess-rows-golden',
    'tests/video_vision_preprocess_rows_golden.cpp',
    cpp_args: ['-std=c++20'],
    include_directories: include_directories('src'),
    install: false,
)
test('google-webrtc-video-vision-preprocess-rows-golden', dinox_google_webrtc_video_vision_preprocess_rows_golden)

dinox_google_webrtc_video_overlay_rows_golden = executable(
    'google-webrtc-video-overlay-rows-golden',
    ['src/dinox_webrtc_video_overlays.cpp', 'tests/video_overlay_rows_golden.cpp'],
    cpp_args: ['-std=c++20'],
    include_directories: include_directories('src'),
    install: false,
)
test('google-webrtc-video-overlay-rows-golden', dinox_google_webrtc_video_overlay_rows_golden)

dinox_google_webrtc_video_compositor_scratch_rows_golden = executable(
    'google-webrtc-video-compositor-scratch-rows-golden',
    ['src/dinox_webrtc_video_compositor.cpp', 'tests/video_compositor_scratch_rows_golden.cpp'],
    cpp_args: ['-std=c++20'],
    include_directories: include_directories('src'),
    install: false,
)
test('google-webrtc-video-compositor-scratch-rows-golden', dinox_google_webrtc_video_compositor_scratch_rows_golden)

dinox_google_webrtc_video_compositor_uniform_mask_golden = executable(
    'google-webrtc-video-compositor-uniform-mask-golden',
    ['src/dinox_webrtc_video_compositor.cpp', 'tests/video_compositor_uniform_mask_golden.cpp'],
    cpp_args: ['-std=c++20'],
    include_directories: include_directories('src'),
    install: false,
)
test('google-webrtc-video-compositor-uniform-mask-golden', dinox_google_webrtc_video_compositor_uniform_mask_golden)

# Kept out of the normal test suite because the release-profile measurement
# uses a 30-second warm-up followed by a 60-second sample for Direct, cold Off,
# Grayscale and Warm tone. scripts/measure-video-effects-baseline.py drives this
# executable, samples the external worker process and writes the reproducible
# report.
dinox_google_webrtc_video_effects_baseline = executable(
    'google-webrtc-video-effects-baseline',
    'tests/video_effects_baseline.cpp',
    dependencies: [dep_dinox_google_webrtc, dependency('threads')],
    install: false,
)

dinox_google_webrtc_worker = executable(
    'dinox-webrtc-worker',
    files('src/dinox_webrtc_worker_main.cpp'),
    cpp_args: ['-std=c++20'],
    dependencies: [dep_dinox_google_webrtc, dependency('threads')],
    install: true,
    install_dir: 'lib/dinox',
)

foreach codec : ['H264', 'VP9', 'VP8']
    test('google-webrtc-' + codec.to_lower() + '-call-smoke',
        dinox_google_webrtc_smoke,
        env: [
            'DINOX_WEBRTC_VIDEO_CODEC_SMOKE_ONLY=' + codec,
            'DINOX_WEBRTC_IN_PROCESS_TEST_ORACLE=0',
            'DINOX_WEBRTC_WORKER_PATH=' + dinox_google_webrtc_worker.full_path(),
        ],
        depends: [dinox_google_webrtc_worker],
        timeout: 90,
    )
endforeach

test('google-webrtc-muji-sdp-smoke', dinox_google_webrtc_muji_sdp_smoke,
    env: [
        'DINOX_WEBRTC_IN_PROCESS_TEST_ORACLE=0',
        'DINOX_WEBRTC_WORKER_PATH=' + dinox_google_webrtc_worker.full_path(),
    ],
    depends: [dinox_google_webrtc_worker],
    timeout: 30,
)

install_data(
    google_libwebrtc_license,
    google_libwebrtc_third_party_licenses,
    google_libwebrtc_patents,
    google_libwebrtc_ffmpeg_license,
    google_libwebrtc_libva_license,
    google_libwebrtc_ffmpeg_manifest,
    google_libwebrtc_manifest,
    google_libwebrtc_artifact_root / 'WEBRTC-CODECS.json',
    google_libwebrtc_artifact_root / 'WEBRTC-GN-ARGS.gn',
    google_libwebrtc_artifact_root / 'NVIDIA-CODEC-HEADERS-LICENSE',
    install_dir: get_option('datadir') / 'licenses/dinox/google-libwebrtc',
)

if host_machine.system() != 'windows'
    install_data(
        google_libwebrtc_ffmpeg_source,
        google_libwebrtc_libva_source,
        google_libwebrtc_artifact_root / 'sources' / google_libwebrtc_codec_source_filename,
        google_libwebrtc_artifact_root / 'sources/nv-codec-headers-n8.1.24.15.tar.gz',
        google_libwebrtc_artifact_root / 'sources/ffmpeg-dinox-symbol-versions.patch',
        install_dir: get_option('datadir') / 'licenses/dinox/google-libwebrtc/sources',
    )
endif

if host_machine.system() != 'windows'
    executable(
        'google-webrtc-vp8-probe-fixture-generator',
        'tests/generate_vp8_probe_frames.cpp',
        cpp_args: ['-std=c++20'],
        dependencies: [dep_google_libwebrtc, dependency('threads')],
        build_by_default: false,
        install: false,
    )
    dinox_google_webrtc_vp8_qualification_smoke = executable(
        'google-webrtc-vp8-qualification-smoke',
        'tests/vp8_decode_qualification_smoke.cpp',
        cpp_args: ['-std=c++20'],
        include_directories: include_directories('src'),
        install: false,
    )
    test('google-webrtc-vp8-qualification-smoke',
        dinox_google_webrtc_vp8_qualification_smoke)

    dinox_google_webrtc_vp8_decoder_smoke = executable(
        'google-webrtc-vp8-decoder-smoke',
        files('tests/vp8_decoder_smoke.cpp'),
        cpp_args: ['-std=c++20'],
        include_directories: include_directories('src'),
        dependencies: [dep_dinox_google_webrtc, dep_google_libwebrtc],
        install: false,
    )

    test(
        'google-webrtc-vp8-software-decoder-smoke',
        dinox_google_webrtc_vp8_decoder_smoke,
    )
    test(
        'google-webrtc-vp8-vaapi-decoder-smoke',
        dinox_google_webrtc_vp8_decoder_smoke,
        args: ['--require-hardware'],
    )
    test(
        'google-webrtc-vp8-automatic-decoder-smoke',
        dinox_google_webrtc_vp8_decoder_smoke,
        args: ['--automatic'],
    )

    dinox_google_webrtc_worker_smoke = executable(
        'google-webrtc-worker-smoke',
        files('tests/worker_smoke.cpp'),
        dependencies: [dep_dinox_google_webrtc],
        install: false,
    )

    test(
        'google-webrtc-worker-smoke',
        dinox_google_webrtc_worker_smoke,
        args: [dinox_google_webrtc_worker.full_path()],
        depends: [dinox_google_webrtc_worker],
        timeout: 20,
    )

    dinox_google_webrtc_process_engine_smoke = executable(
        'google-webrtc-process-engine-smoke',
        files('tests/process_engine_smoke.cpp'),
        dependencies: [dep_dinox_google_webrtc, dependency('threads')],
        install: false,
    )

    test(
        'google-webrtc-process-engine-smoke',
        dinox_google_webrtc_process_engine_smoke,
        env: [
            'DINOX_WEBRTC_WORKER_PATH=' + dinox_google_webrtc_worker.full_path(),
            'DINOX_WEBRTC_ENABLE_TEST_FAULTS=1',
        ],
        depends: [dinox_google_webrtc_worker],
        timeout: 20,
    )
endif
