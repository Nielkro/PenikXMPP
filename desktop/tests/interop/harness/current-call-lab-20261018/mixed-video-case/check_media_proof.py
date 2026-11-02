"""Pure counter/identity proof checks; no SDK, native client or live media claims."""
import importlib.util
from pathlib import Path

spec = importlib.util.spec_from_file_location('media_case', Path(__file__).with_name('media_case.py'))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

ACCOUNTS = {r: r + '@invalid.test' for r in m.ROLES}
ROOM = 'group@conference.invalid.test'


def fixture(n):
    states = {'nora': {'calls': [], 'conference': {
        'room': ROOM, 'call_id': 'nora-group',
        'participants': [ACCOUNTS[r] + '/fixture' for r in m.ROLES]}}}
    for r in ('leon', 'felix'):
        states[r] = {'full_jid': ACCOUNTS[r] + '/fixture', 'sessions': [],
                     'call': {'id': r + '-group', 'room': ROOM, 'peers': 2, 'state': 'IN_PROGRESS'}}
    for a, b in m.PAIRS:
        sid = a + '-' + b
        for local, peer in ((a, b), (b, a)):
            if local == 'nora':
                row = {'session_id': sid, 'peer': ACCOUNTS[peer] + '/fixture',
                       'muji_room': ROOM, 'end_user_state': 'CONNECTED', 'media': ['VIDEO', 'AUDIO'],
                       'remote_video_frames': n, 'remote_video_width': 320,
                       'remote_video_height': 240, 'rtp_stats': []}
                for direction in ('inbound', 'outbound'):
                    for kind in ('audio', 'video'):
                        row['rtp_stats'].append({'id': sid + direction + kind,
                            'type': direction + '-rtp', 'kind': kind,
                            'packetsReceived': n, 'packetsSent': n,
                            'totalSamplesReceived': n, 'framesDecoded': n, 'framesEncoded': n})
                states['nora']['calls'].append(row)
            else:
                row = {'sid': sid, 'local': ACCOUNTS[local] + '/fixture',
                       'peer': ACCOUNTS[peer] + '/fixture', 'room': ROOM,
                       'wire_state': 'ACTIVE', 'peer_connection_state': 'CONNECTED',
                       'capture_running': 0}
                for f in ('audio_in_packets', 'audio_out_packets', 'audio_sink_samples',
                          'video_in_packets', 'video_out_packets', 'video_decoded',
                          'video_encoded', 'video_sink_frames'): row[f] = n
                states[local]['sessions'].append(row)
    return states


def prove(a, b):
    return m.delivery(a, b, m.PAIRS, ROOM, {'accounts': ACCOUNTS})


def rejected(change, tag):
    a, b = fixture(10), fixture(20)
    change(b)
    try: prove(a, b)
    except (AssertionError, KeyError, TypeError): return
    raise AssertionError('Invalid proof accepted: ' + tag)


def main():
    edges = prove(fixture(10), fixture(20))
    assert len(edges) == 6 and {(e['sender'], e['receiver']) for e in edges} == {
        (a, b) for p in m.PAIRS for a, b in (p, tuple(reversed(p)))}
    checks = 1
    # Every directed receiver must independently advance all receive-side evidence.
    for a, b in m.PAIRS:
        for sender, receiver in ((a, b), (b, a)):
            def corrupt(states, sender=sender, receiver=receiver):
                _, rows = m.endpoints(states, (a, b), ROOM, {'accounts': ACCOUNTS})
                row = rows[receiver]
                if receiver == 'nora': row['remote_video_frames'] = 10
                else: row['video_sink_frames'] = 10
            rejected(corrupt, sender + '->' + receiver + ' stalled sink'); checks += 1
    cases = [
        ('no audio PCM', lambda s: s['leon']['sessions'][0].update(audio_sink_samples=10)),
        ('no video encode', lambda s: s['felix']['sessions'][0].update(video_encoded=10)),
        ('no video packets', lambda s: s['felix']['sessions'][1].update(video_in_packets=10)),
        ('no actual decode', lambda s: s['leon']['sessions'][1].update(video_decoded=10)),
        ('physical capture', lambda s: s['felix']['sessions'][0].update(capture_running=1)),
        ('lost video', lambda s: s['nora']['calls'][0].update(media=['AUDIO'])),
        ('no decoded dimensions', lambda s: s['nora']['calls'][0].update(remote_video_width=0)),
        ('new RTP stream', lambda s: s['nora']['calls'][0]['rtp_stats'][0].update(id='replacement')),
        ('replaced SID', lambda s: s['leon']['sessions'][0].update(sid='replacement')),
        ('replaced native call', lambda s: s['leon']['call'].update(id='replacement')),
        ('replaced Android conference', lambda s: s['nora']['conference'].update(call_id='replacement')),
        ('wrong room', lambda s: s['felix']['sessions'][0].update(room='other@invalid.test')),
        ('wrong peer resource', lambda s: s['leon']['sessions'][1].update(peer=ACCOUNTS['felix'] + '/other')),
        ('wrong local account', lambda s: s['felix'].update(full_jid='other@invalid.test/fixture')),
        ('stale connection', lambda s: s['felix']['sessions'][0].update(peer_connection_state='DISCONNECTED')),
        ('float counter', lambda s: s['felix']['sessions'][0].update(video_encoded=20.0)),
        ('boolean counter', lambda s: s['felix']['sessions'][0].update(video_in_packets=True)),
    ]
    for tag, change in cases: rejected(change, tag); checks += 1
    print('PASS', checks, 'pure proof cases; no live media result')


if __name__ == '__main__': main()
