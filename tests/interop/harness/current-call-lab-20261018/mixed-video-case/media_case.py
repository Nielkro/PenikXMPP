"""Injected mixed legacy-video case; the existing owner supplies guarded operations.

No bootstrap, credentials, process start or standalone entry point lives here.
The caller must pin this file and retain its recorder/session/cleanup guards.
Media delivery is separate from the unchanged single-fingerprint auth observer.
"""
import time

ROLES = ('nora', 'leon', 'felix')
PAIRS = (('nora', 'leon'), ('nora', 'felix'), ('leon', 'felix'))
PREFIX = {'RINGING': 'DINO_ENTITIES_CALL_STATE_',
          'IN_PROGRESS': 'DINO_ENTITIES_CALL_STATE_',
          'ACTIVE': 'DINO_PLUGINS_GOOGLE_WEBRTC_SIGNALING_STATE_',
          'CONNECTED': 'DINOX_WEBRTC_PEER_CONNECTION_STATE_',
          'AVAILABLE': 'DINO_PARTICIPANT_INVITE_AVAILABILITY_'}


def enum_is(value, name):
    return value in (name, PREFIX[name] + name)


def count(value):
    assert type(value) is int and value >= 0, 'Missing or invalid actual media counter'
    return value


def stream(row, direction, kind):
    rows = [s for s in row['rtp_stats'] if s['type'] == direction + '-rtp'
            and s.get('kind', s.get('mediaType')) == kind]
    assert len(rows) == 1, 'Ambiguous or missing actual RTP stream'
    assert type(rows[0]['id']) is str and rows[0]['id']
    return rows[0]


def counters(role, row):
    if role != 'nora':
        assert row['capture_running'] == 0, 'Physical capture must remain suppressed'
        return {key: count(row[field]) for key, field in {
            'audio_rx': 'audio_in_packets', 'audio_tx': 'audio_out_packets',
            'pcm': 'audio_sink_samples', 'video_rx': 'video_in_packets',
            'video_tx': 'video_out_packets', 'decoded': 'video_decoded',
            'encoded': 'video_encoded', 'sink': 'video_sink_frames'}.items()}
    assert len(row['media']) == 2 and set(row['media']) == {'AUDIO', 'VIDEO'}
    ai, ao = stream(row, 'inbound', 'audio'), stream(row, 'outbound', 'audio')
    vi, vo = stream(row, 'inbound', 'video'), stream(row, 'outbound', 'video')
    assert count(row['remote_video_width']) > 0 and count(row['remote_video_height']) > 0
    return {'audio_rx': count(ai['packetsReceived']), 'audio_tx': count(ao['packetsSent']),
            'pcm': count(ai['totalSamplesReceived']), 'video_rx': count(vi['packetsReceived']),
            'video_tx': count(vo['packetsSent']), 'decoded': count(vi['framesDecoded']),
            'encoded': count(vo['framesEncoded']), 'sink': count(row['remote_video_frames']),
            'stream_ids': [ai['id'], ao['id'], vi['id'], vo['id']]}


def endpoints(states, pair, room, context):
    a, b = pair
    for role in pair:
        if role != 'nora':
            assert states[role]['full_jid'].startswith(context['accounts'][role] + '/')
    host = b if a == 'nora' else a
    peer_bare = context['accounts'][a] if a == 'nora' else context['accounts'][b]
    rows = [s for s in states[host]['sessions']
            if s['peer'].split('/', 1)[0] == peer_bare and s.get('room') == room
            and enum_is(s.get('wire_state'), 'ACTIVE')
            and enum_is(s.get('peer_connection_state'), 'CONNECTED')]
    assert len(rows) == 1, 'Missing or ambiguous connected native session'
    first = rows[0]
    assert first['local'] == states[host]['full_jid']
    if a == 'nora':
        assert first['peer'].startswith(context['accounts']['nora'] + '/')
        assert context.setdefault('nora_full_jid', first['peer']) == first['peer']
        other = [c for c in states['nora']['calls']
                 if c['session_id'] == first['sid'] and c['peer'] == first['local']
                 and c.get('muji_room') == room and c['end_user_state'] == 'CONNECTED']
        assert len(other) == 1
        counters('nora', other[0]); counters(b, first)
        return first['sid'], {'nora': other[0], b: first}
    other = [s for s in states[b]['sessions'] if s['sid'] == first['sid']
             and s.get('room') == room and enum_is(s.get('wire_state'), 'ACTIVE')
             and enum_is(s.get('peer_connection_state'), 'CONNECTED')]
    assert len(other) == 1 and first['peer'] == states[b]['full_jid']
    assert other[0]['local'] == first['peer'] and other[0]['peer'] == first['local']
    counters(a, first); counters(b, other[0])
    return first['sid'], {a: first, b: other[0]}


def delivery(before, after, pairs, room, context):
    edges, sids = [], []
    roles = set(sum((list(p) for p in pairs), []))
    for role in roles - {'nora'}:
        assert before[role]['full_jid'] == after[role]['full_jid']
        assert before[role]['call']['id'] == after[role]['call']['id']
        for states in (before, after):
            assert enum_is(states[role]['call']['state'], 'IN_PROGRESS')
            assert states[role]['call'].get('room') == room
    if room:
        for states in (before, after):
            assert states['nora']['conference']['room'] == room
        assert before['nora']['conference']['call_id'] == after['nora']['conference']['call_id']
    for pair in pairs:
        sid, old = endpoints(before, pair, room, context)
        sid2, new = endpoints(after, pair, room, context)
        assert sid == sid2, 'Call replaced between media samples'
        sids.append(sid)
        for sender, receiver in (pair, tuple(reversed(pair))):
            tx0, tx1 = counters(sender, old[sender]), counters(sender, new[sender])
            rx0, rx1 = counters(receiver, old[receiver]), counters(receiver, new[receiver])
            for c0, c1 in ((tx0, tx1), (rx0, rx1)):
                assert c0.get('stream_ids') == c1.get('stream_ids'), 'RTP stream replaced'
            values = {'audio_tx': [tx0['audio_tx'], tx1['audio_tx']],
                      'audio_rx': [rx0['audio_rx'], rx1['audio_rx']],
                      'pcm': [rx0['pcm'], rx1['pcm']],
                      'video_tx': [tx0['video_tx'], tx1['video_tx']],
                      'video_rx': [rx0['video_rx'], rx1['video_rx']],
                      'encoded': [tx0['encoded'], tx1['encoded']],
                      'decoded': [rx0['decoded'], rx1['decoded']],
                      'sink': [rx0['sink'], rx1['sink']]}
            assert all(b > a for a, b in values.values()), 'No directed AV/RTP/PCM/frame delivery'
            edges.append({'sid': sid, 'sender': sender, 'receiver': receiver, **values})
    assert len(set(sids)) == len(pairs), 'Different peer pairs share a session ID'
    return edges


def scenario(op, write, context, sleep=time.sleep, clock=time.monotonic):
    """One start, one real DinoX add-participant action, one exact invite accept."""
    assert set(context['accounts']) == set(ROLES)
    def observe(tag):
        return {r: op(r, tag, {'op': 'stats'} if r == 'nora' else None) for r in ROLES}
    def wait(read, ready):
        deadline = clock() + 90
        while True:
            value = read()
            if ready(value): return value
            assert clock() < deadline, 'Bounded observation failed; no mutation retry'
            sleep(1)
    def media(tag, pairs, room):
        def ready(states):
            try:
                for pair in pairs: endpoints(states, pair, room, context)
                return True
            except (AssertionError, KeyError, TypeError): return False
        wait(lambda: observe(tag + '-readiness'), ready)
        samples = [observe(tag + '-sample1')]; sleep(4)
        samples.append(observe(tag + '-sample2'))
        edges = delivery(*samples, pairs, room, context)
        write(tag + '-media.json', {'room': room, 'edges': edges,
              'directed_edges': len(edges), 'call_auth': 'NOT_PROVEN_BY_MEDIA',
              'physical_quality_tested': False})
        return samples[-1]
    for role, peer in (('nora', 'leon'), ('leon', 'nora')):
        op(role, 'select-direct-legacy-once', {'op': 'prepare_crypto', 'peer': peer, 'encryption': 'legacy'})
    sid = op('nora', 'video-start-once', {'op': 'start_call', 'peer': 'leon', 'video': True})['session_id']
    context['direct_sid'] = sid
    leon = wait(lambda: op('leon', 'observe-direct-incoming'),
                lambda s: enum_is((s.get('call') or {}).get('state'), 'RINGING'))
    assert leon['call']['counterpart'].startswith(context['accounts']['nora'] + '/')
    context['native']['leon'].add(leon['call']['id'])
    op('leon', 'accept-exact-direct-once', {'op': 'accept_call', 'call_id': leon['call']['id']})
    direct = media('original-direct-video', PAIRS[:1], None)
    assert endpoints(direct, PAIRS[0], None, context)[0] == sid
    promoted = op('leon', 'add-felix-once', {'op': 'add_participant',
                  'call_id': direct['leon']['call']['id'], 'peer': 'felix'})
    assert enum_is(promoted['invitation_result'], 'AVAILABLE')
    room = context['room'] = promoted['call']['room']
    for role in ('leon', 'felix'):
        op(role, 'authorize-actual-invited-room', {'op': 'authorize_room', 'room': room})
    felix = wait(lambda: op('felix', 'observe-new-room-invite'),
                 lambda s: enum_is((s.get('call') or {}).get('state'), 'RINGING'))
    call = felix['call']
    assert call['invited_room'].split('/', 1)[0] == room and call['inviter'] == promoted['full_jid']
    context['native']['felix'].add(call['id'])
    op('felix', 'accept-exact-room-invite-once', {'op': 'accept_call', 'call_id': call['id']})
    full = media('mixed-three-video', PAIRS, room)
    conf = full['nora']['conference']
    assert conf['room'] == room
    expected = {full[r]['full_jid'] for r in ('leon', 'felix')}
    assert expected <= set(conf['participants']) <= expected | {context['nora_full_jid']}
    for role in ('leon', 'felix'):
        assert full[role]['call']['room'] == room and full[role]['call']['peers'] == 2
        assert enum_is(full[role]['call']['state'], 'IN_PROGRESS')
    write('scenario-result.json', {'result': 'SIX_DIRECTED_AV_MEDIA_EDGES_AUTH_SEPARATE',
          'room': room, 'pair_sids': {':'.join(p): endpoints(full, p, room, context)[0] for p in PAIRS},
          'directed_edges': 6, 'requested_encryption': 'legacy-OMEMO1', 'DinoX_PQ_enabled': False,
          'auth_observer': 'UNCHANGED_SINGLE_FINGERPRINT_MULTI_NODE_AV_NOT_INDIVIDUALLY_PROVEN',
          'normal_end_requires_cleanup_receipt': True, 'physical_quality_tested': False})


if __name__ == '__main__':
    raise SystemExit('This case requires the existing guarded owner; standalone execution is forbidden')
