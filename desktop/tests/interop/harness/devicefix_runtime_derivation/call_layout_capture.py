"""Bounded display-only captures of an existing three-person audio call.

Imported inside the already admitted scenario, never a new ADB/runtime owner.
These captures require later visual review; they cannot declare a layout PASS.
"""
from pathlib import Path
import re
import subprocess
import time
import uuid
import xml.etree.ElementTree as ET


def parse_display(saved):
    def override(kind, value):
        pattern = r'\d+x\d+' if kind == 'size' else r'\d+'
        assert re.fullmatch(r'Physical ' + kind + ': ' + pattern
                            + r'(?:\nOverride ' + kind + ': ' + pattern + r')?', value)
        match = re.search(r'^Override ' + kind + ': (.+)$', value, re.M)
        return match.group(1) if match else None
    result = {key: override(key, saved['wm_' + key]) for key in ('size', 'density')}
    assert re.fullmatch(r'(?:free|lock [0-3])', saved['wm_rotation'])
    for key, pattern in (('accelerometer_rotation', '[01]'), ('user_rotation', '[0-3]'),
                         ('font_scale', r'(?:\d+(?:\.\d*)?|\.\d+)')):
        value = saved[key]
        assert value == 'null' or re.fullmatch(pattern, value), 'Unknown original setting'
    return result


def restore_commands(saved):
    parsed = parse_display(saved)
    commands = [['shell', '-T', 'wm', key, parsed[key] or 'reset']
                for key in ('size', 'density')]
    for key in ('font_scale', 'user_rotation', 'accelerometer_rotation'):
        value = saved[key]
        commands.append(['shell', '-T', 'settings', 'delete', 'system', key]
                        if value == 'null' else
                        ['shell', '-T', 'settings', 'put', 'system', key, value])
    commands.append(['shell', '-T', 'wm', 'user-rotation', *saved['wm_rotation'].split()])
    return commands


def capture(r, op, write, output, room):
    output = Path(output)
    assert not (output / 'layout-exact-restore-required.json').exists(), 'Never repeat an uncertain capture'
    cfg = r.control_settings('nora')
    session = r.read(cfg['state'] / 'live-session.json')
    assert session['batch_deadline_unix'] - time.time() >= 360, 'Keep exact-restore reserve'
    prefix, env = r.adb_command('nora'), r.environment('nora')
    started = time.monotonic()
    working_deadline = started + 120
    restoring = False

    def cli(tail, label, binary=False):
        r.control_settings('nora')
        remaining = (started + 300 if restoring else working_deadline) - time.monotonic()
        assert remaining > 0, 'Bounded display capture/restore deadline'
        result = subprocess.run([*prefix, *tail], env=env, stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                timeout=min(20, remaining))
        write('layout-' + label + '-command.json', {
            'arguments': tail, 'exit': result.returncode,
            'stderr': result.stderr.decode(errors='replace')[:4096]})
        assert result.returncode == 0, 'Display command failed; no blind retry'
        assert len(result.stdout) <= (12 * 1024**2 if binary else 2 * 1024**2)
        return result.stdout

    queries = {'wm_size': ['wm', 'size'], 'wm_density': ['wm', 'density'],
               'wm_rotation': ['wm', 'user-rotation'],
               **{key: ['settings', 'get', 'system', key]
                  for key in ('accelerometer_rotation', 'user_rotation', 'font_scale')}}

    def settings(label):
        return {key: cli(['shell', '-T', *tail], label + '-' + key).decode().strip()
                for key, tail in queries.items()}

    def scope(label):
        value = op('nora', 'layout-' + label, {'op': 'stats'})
        assert value['account'] == r.OWN['nora'] and value['online']
        assert value['conference']['room'] == room and len(value['calls']) == 2
        calls = sorted((c['session_id'], c['peer'], c['muji_room']) for c in value['calls'])
        assert len({c[0] for c in calls}) == 2 and all(c[2] == room for c in calls)
        assert {c[1].split('/', 1)[0] for c in calls} == {r.OWN['leon'], r.OWN['felix']}
        assert all(c['end_user_state'] == 'CONNECTED' and c['media'] == ['AUDIO']
                   for c in value['calls'])
        actual = {'account': value['account'], 'room': room,
                  'call_id': value['conference']['call_id'], 'legs': calls,
                  'device_id': value['own_device_id'],
                  'fingerprint': value['own_legacy_fingerprint']}
        write('layout-' + label + '-call-scope.json', actual)
        return actual

    saved = settings('before')
    parse_display(saved)
    expected = scope('before')
    write('layout-exact-restore-required.json', {'settings': saved, 'restored': False})
    error, failures, captures = None, [], []
    try:
        # Test-only binding to the actual existing SID, not a JOIN/new-call proof.
        sid, peer, _ = expected['legs'][0]
        cli(['shell', '-T', 'su', '0', 'am', 'start', '-W', '-a',
             'android.intent.action.VIEW', '-n',
             r.v1.PACKAGE + '/eu.siacs.conversations.ui.RtpSessionActivity',
             '--es', 'account', expected['account'], '--es', 'with', peer,
             '--es', 'session_id', sid], 'bind-existing-call-once')
        assert scope('after-binding') == expected
        for label, size, density, rotation in (
                ('phone-portrait', '1080x1920', '420', '0'),
                ('phone-landscape', '1080x1920', '420', '1'),
                ('virtual-tablet', '2560x1600', '320', '0')):
            for tail in (['wm', 'size', size], ['wm', 'density', density],
                         ['wm', 'user-rotation', 'lock', rotation]):
                cli(['shell', '-T', *tail], label + '-' + tail[1])
            time.sleep(1)
            assert scope(label) == expected, 'Display change affected the actual call'
            config = cli(['shell', '-T', 'am', 'get-config'], label + '-configuration').decode()
            write('layout-' + label + '-configuration.json', {'actual_configuration': config,
                  'virtual_window_configuration': True, 'physical_tablet_tested': False})
            guest = '/data/local/tmp/dinox-layout-' + uuid.uuid4().hex + '.xml'
            try:
                cli(['shell', '-T', 'uiautomator', 'dump', guest], label + '-dump')
                raw = cli(['shell', '-T', 'cat', guest], label + '-read')
            finally:
                cli(['shell', '-T', 'rm', '-f', guest], label + '-remove-own-dump')
            tree = ET.fromstring(raw)
            xml = output / ('layout-' + label + '.xml')
            xml.write_bytes(raw); xml.chmod(0o600)
            png = cli(['exec-out', 'screencap', '-p'], label + '-screenshot', binary=True)
            assert png.startswith(b'\x89PNG\r\n\x1a\n')
            image = output / ('layout-' + label + '.png')
            image.write_bytes(png); image.chmod(0o600)
            captures.append({'view': label, 'xml': str(xml), 'png': str(image),
                             'node_count': len(list(tree.iter('node')))})
    except BaseException as caught:
        error = caught
    finally:
        restoring = True
        for index, command in enumerate(restore_commands(saved)):
            try: cli(command, 'restore-' + str(index))
            except BaseException as caught:
                failures.append({'step': index, 'type': type(caught).__name__, 'detail': str(caught)})
        try:
            readback = settings('restored')
            write('layout-restored-settings-readback.json', readback)
            assert readback == saved, 'Exact original display settings were not restored'
        except BaseException as caught:
            failures.append({'step': 'readback', 'type': type(caught).__name__, 'detail': str(caught)})
        write('layout-captures-result.json', {
            'result': 'CAPTURED_VISUAL_REVIEW_REQUIRED' if not error and not failures else 'PARTIAL',
            'captures': captures, 'scope': expected, 'restore_errors': failures,
            'capture_error': str(error) if error else None,
            'exact_original_settings_restored': not failures,
            'layout_pass_claimed': False, 'call_media_or_auth_pass_claimed': False})
    assert not failures, 'Display restoration incomplete; inspect owned guest before shutdown'
    if error: raise error
