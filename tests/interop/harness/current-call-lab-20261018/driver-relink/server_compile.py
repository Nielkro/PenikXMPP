#!/usr/bin/env python3
"""Relink the unchanged private observer against pinned current call inputs only."""
from pathlib import Path
import hashlib
import json
import os
import resource
import shlex
import subprocess
import time

ROOT = Path('/work')
HERE = ROOT / 'native-current-driver'
ARTIFACTS = HERE / 'artifacts'
PAYLOAD = Path('/opt/interop/payload/lib')
MANIFEST_SHA = '326a6a57c711950ca9bb8c3a9c6861c7ec03aa049681a00a77d3f19c5412b1b1'
PACKAGES = ['gmodule-2.0', 'glib-2.0', 'gio-2.0', 'gee-0.8', 'json-glib-1.0',
            'libadwaita-1', 'libomemo-c', 'libgcrypt']
PC_PACKAGES = ['json-glib-1.0', 'libadwaita-1', 'gee-0.8', 'gmodule-2.0']


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n')
    path.chmod(0o600)


def main():
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    assert os.getpriority(os.PRIO_PROCESS, 0) == 19
    assert sha(HERE / 'input-manifest.json') == MANIFEST_SHA
    manifest = json.loads((HERE / 'input-manifest.json').read_bytes())
    assert manifest['scope'] == 'CURRENT_WIRE_PREBUILT_IQ_RUNTIME_DRIVER_ONLY_EXISTING_IMAGE_DERIVATION'
    assert not ARTIFACTS.exists(), 'Never overwrite an actual run'
    protected = {}
    for name, item in manifest['files'].items():
        path = HERE / name
        assert not Path(name).is_absolute() and '..' not in Path(name).parts
        assert path.is_relative_to(HERE / 'inputs')
        assert path.is_file() and not path.is_symlink()
        assert path.stat().st_size == item['bytes'] and sha(path) == item['sha256']
        protected[str(path)] = item['sha256']
    for name, expected in manifest['retained_payload_sha256'].items():
        path = PAYLOAD / name
        assert sha(path) == expected, ('Read-only retained payload differs', name)
        protected[str(path)] = expected
    runtime = HERE / 'inputs/qualified-runtime'
    metadata = json.loads((runtime / 'manifest.json').read_bytes())
    assert (metadata['wrapper_abi'], metadata['ipc_protocol_version']) == (40, 10)
    assert metadata['target_os'] == 'linux' and metadata['target_cpu'] == 'x64'
    assert sha(runtime / 'include/dinox_webrtc.h') == sha(HERE / 'inputs/current/google-webrtc/include/dinox_webrtc.h')
    current = HERE / 'inputs/current'
    libraries = {name: HERE / path for name, path in manifest['link_libraries'].items()}
    libraries.update({name: PAYLOAD / name for name in manifest['retained_link_libraries']})
    iq_library = libraries['libxmpp-vala.so.0']
    core_library = libraries['libdino.so.0']
    omemo_library = libraries['omemo.so']
    library_path = ':'.join(map(str, [omemo_library.parent, core_library.parent,
                                    runtime / 'lib', PAYLOAD]))
    env = {**os.environ, 'LD_LIBRARY_PATH': library_path, 'G_DEBUG': 'fatal-criticals'}
    ARTIFACTS.mkdir(parents=True)
    receipt = {'result': 'INCOMPLETE', 'input_manifest_sha256': MANIFEST_SHA,
               'server_compile_sha256': sha(__file__), 'product_commit': manifest['product_commit'],
               'protected_inputs_sha256': protected, 'commands': [],
               'core_plugin_IQ_native_SDK_JNI_rebuilt': False,
               'driver_only_compile': True, 'account_profile_or_media_runtime': False,
               'existing_builder_image': manifest['builder_image']['id'],
               'historical_compiler_cache_required': False,
               'runtime_wrapper_abi': 40, 'runtime_ipc': 10}
    deadline = time.monotonic() + 1200

    def command(argv, log, custom_env=None):
        remaining = deadline - time.monotonic()
        assert remaining > 0, 'The bounded driver-only deadline expired'
        receipt['commands'].append(list(map(str, argv)))
        with log.open('ab') as output:
            output.write((shlex.join(list(map(str, argv))) + '\n').encode())
            output.flush()
            result = subprocess.run(argv, stdout=output, stderr=subprocess.STDOUT,
                                    env=custom_env, timeout=min(180, remaining))
        return result.returncode

    def symbols(path, required, log):
        assert command(['nm', '-D', '--defined-only', str(path)], log) == 0
        names = {line.split()[-1] for line in log.read_text().splitlines() if line.split()}
        assert set(required) <= names, ('Required actual symbols missing', str(path), set(required) - names)

    def loader(path, log):
        assert command(['ldd', '-r', str(path)], log, env) == 0
        text = log.read_text()
        assert 'not found' not in text and 'undefined symbol:' not in text
        for name in ('libdino.so.0', 'libxmpp-vala.so.0'):
            assert name + ' => ' + str(libraries[name]) + ' (' in text
        return text

    try:
        config_log = ARTIFACTS / 'compiler-versions-and-pkgconfig.log'
        for argv in (['valac', '--version'], ['cc', '--version']):
            assert command(argv, config_log) == 0
        for name, required in manifest['required_symbols'].items():
            symbols(libraries[name], required, ARTIFACTS / ('symbols-' + name + '.log'))
        loader(omemo_library, ARTIFACTS / 'plugin-loader.log')
        receipt['plugin_loader_log_sha256'] = sha(ARTIFACTS / 'plugin-loader.log')
        # Matching workers are loader-checked without starting a media process.
        for name in ('dinox-webrtc-worker', 'dinox-vision-worker', 'libavcodec-dinox-hw.so.62',
                     'libavutil-dinox-hw.so.60', 'libdinox-google-webrtc.so'):
            log = ARTIFACTS / ('runtime-loader-' + name + '.log')
            assert command(['ldd', '-r', str(runtime / 'lib' / name)], log, env) == 0
            text = log.read_text()
            assert 'not found' not in text and 'undefined symbol:' not in text
            if name == 'dinox-webrtc-worker':
                assert 'libdinox-google-webrtc.so => ' + str(libraries['libdinox-google-webrtc.so']) + ' (' in text
        remaining = deadline - time.monotonic()
        assert remaining > 0
        cflags = shlex.split(subprocess.check_output(['pkg-config', '--cflags'] + PC_PACKAGES,
                                                   text=True, timeout=min(30, remaining)))
        remaining = deadline - time.monotonic()
        assert remaining > 0
        ldflags = shlex.split(subprocess.check_output(['pkg-config', '--libs'] + PC_PACKAGES,
                                                    text=True, timeout=min(30, remaining)))
        receipt['pkg_config_cflags'], receipt['pkg_config_libs'] = cflags, ldflags
        out = HERE / 'generated/native-driver'
        out.mkdir(parents=True)
        artifacts = ARTIFACTS / 'native-driver'
        artifacts.mkdir()
        compiler_log = artifacts / 'compiler.log'
        selected = [HERE / name for name in manifest['selected_sources']]
        assert len(selected) == len(set(selected))
        assert current / 'plugins/google-webrtc/src/engine_jingle_wire_session.vala' in selected
        assert not any('fixed-engine_jingle_wire_session.vala' in str(p) for p in selected)
        args = ['valac', '-C', '--debug', '--define=GOOGLE_WEBRTC_EFFECT_TEST', '--directory', str(out),
                '--basedir', str(ROOT), '--library', 'iq-wire-engine', '--header', str(out / 'iq-wire-engine.h'),
                '--vapi', str(out / 'iq-wire-engine.vapi'), '--vapidir', str(current / 'qlite/vapi'),
                '--vapidir', str(current / 'plugins/omemo/vapi')]
        for package in PACKAGES:
            args += ['--pkg', package]
        assert command(args + list(map(str, selected)), compiler_log) == 0, 'Driver Vala compile failed'
        includes = [out, omemo_library.parent, current / 'build/xmpp-vala',
                    current / 'google-webrtc/include', current / 'plugins/google-webrtc/src',
                    HERE / 'inputs/plugins/omemo/src', current / 'libdino/src',
                    current / 'build/libdino', current / 'build/qlite', current / 'build/crypto-vala',
                    Path('/opt/dinox-deps/include')]
        objects = []
        for index, source in enumerate(sorted(out.rglob('*.c'))):
            obj = out / ('unit-' + str(index) + '.o')
            args = ['cc', '-c', '-g', '-O0', '-pthread', '-fPIC', '-DGETTEXT_PACKAGE="dino"']
            args += ['-I' + str(path) for path in includes] + cflags + [str(source), '-o', str(obj)]
            assert command(args, compiler_log) == 0, 'Driver C compile failed'
            objects.append(str(obj))
        assert objects
        binary = artifacts / 'dinox-interop-current'
        args = ['cc', '-o', str(binary)] + objects + ['-Wl,--start-group']
        args += [str(path) for path in libraries.values()] + ldflags
        args += ['-Wl,--end-group', '-Wl,-rpath,' + library_path, '-Wl,-rpath-link,' + library_path, '-lm']
        assert command(args, compiler_log) == 0, 'Driver link failed'
        actual_loader = loader(binary, artifacts / 'actual-loader.log')
        for name in ('omemo.so', 'libdinox-google-webrtc.so', 'libomemo-c.so.0'):
            assert name + ' => ' + str(libraries[name]) + ' (' in actual_loader
        test_log = artifacts / 'no-argument.log'
        exit_code = command([str(binary)], test_log, env)
        assert exit_code == 2 and 'Expected one isolated command-directory path' in test_log.read_text(errors='replace')
        receipt.update({'result': 'PASS_CURRENT_DRIVER_ONLY_PROFILE_FREE',
                        'binary_sha256': sha(binary), 'test_exit_code': exit_code,
                        'compiler_log_sha256': sha(compiler_log), 'test_log_sha256': sha(test_log),
                        'loader_log_sha256': sha(artifacts / 'actual-loader.log'),
                        'actual_link_libraries': {name: {'path': str(path), 'sha256': sha(path)} for name, path in libraries.items()},
                        'selected_sources_sha256': {str(path): sha(path) for path in selected},
                        'generated_c_units': len(objects)})
    finally:
        receipt['cgroup_observation'] = {name: (Path('/sys/fs/cgroup') / name).read_text().strip()
            for name in ['cpu.max', 'memory.max', 'memory.swap.max', 'memory.peak', 'memory.events']
            if (Path('/sys/fs/cgroup') / name).is_file()}
        receipt['children_peak_rss_kib'] = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
        receipt['protected_inputs_unchanged'] = all(sha(path) == expected for path, expected in protected.items())
        write_json(ARTIFACTS / 'receipt.json', receipt)
        assert receipt['protected_inputs_unchanged'], 'Protected payload/input bytes changed'
    print(receipt['result'], flush=True)


if __name__ == '__main__':
    main()
