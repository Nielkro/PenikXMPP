#!/usr/bin/env python3
"""Independent SCRAM server oracle over real TLS. Loopback only; no credentials.

Runs the production SASL module via sasl-tls-probe. Python hashlib/hmac verifies
client proofs including h/t, then supplies the independently calculated server
proof. Also proves that rejected challenges cause no password-proof response.
"""
import base64
import hashlib
import hmac
import os
from pathlib import Path
import re
import socketserver
import ssl
import subprocess
import sys
import tempfile
import threading
import xml.etree.ElementTree as ET

NS = 'urn:ietf:params:xml:ns:xmpp-sasl'
HEADER = (b"<stream:stream xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams' "
          b"from='example.test' version='1.0' id='fixture'>")
PASSWORD = 'пароль-Über'.encode()


def b64(value):
    return base64.b64encode(value).decode()


def recv_until(sock, marker):
    data = b''
    while marker not in data:
        try:
            part = sock.recv(4096)
        except (ConnectionError, ssl.SSLError):
            break
        if not part:
            break
        data += part
        assert len(data) < 32768
    return data


def send_sasl(sock, tag, text):
    sock.sendall(f"<{tag} xmlns='{NS}'>{b64(text.encode())}</{tag}>".encode())


def fields(text):
    return dict(item.split('=', 1) for item in text.split(','))


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        sock = self.request
        sock.settimeout(6)
        cfg = self.server.cfg
        try:
            if cfg['transport'] == 'starttls':
                initial = recv_until(sock, b'>')
                assert b'<auth' not in initial
                sock.sendall(HEADER + b"<stream:features><starttls xmlns='urn:ietf:params:xml:ns:xmpp-tls'/></stream:features>")
                assert b'<starttls' in recv_until(sock, b'/>')
                sock.sendall(b"<proceed xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>")
            sock = self.server.tls.wrap_socket(sock, server_side=True)
            recv_until(sock, b'>')
            methods = cfg['methods']
            types = cfg.get('types')
            features = "<stream:features><mechanisms xmlns='%s'>%s</mechanisms>" % (
                NS, ''.join('<mechanism>%s</mechanism>' % m for m in methods))
            if types is not None:
                features += "<sasl-channel-binding xmlns='urn:xmpp:sasl-cb:0'>" + ''.join(
                    "<channel-binding type='%s'/>" % t for t in types) + '</sasl-channel-binding>'
            sock.sendall(HEADER + (features + '</stream:features>').encode())
            data = recv_until(sock, b'</auth>')
            if cfg['expect_auth'] is False:
                assert b'<auth' not in data, 'credentials sent despite policy rejection'
                return
            auth = ET.fromstring(data)
            method = auth.attrib['mechanism']
            assert method == cfg['selected'], (method, cfg['selected'])
            initial = base64.b64decode(auth.text).decode()
            if method == 'PLAIN':
                assert initial == '\0тест\0' + PASSWORD.decode()
                sock.sendall(f"<success xmlns='{NS}'/>".encode())
                self.server.proof_checked = True
                return
            gs2, bare = initial.split(',,', 1)
            gs2 += ',,'
            assert fields(bare)['n'] == 'тест'
            nonce = fields(bare)['r'] + 'fixture-server-nonce'
            algorithm = method.removesuffix('-PLUS').replace('SCRAM-SHA-', 'sha')
            digest = lambda value: hashlib.new(algorithm, value).digest()
            mac = lambda key, value: hmac.new(key, value, algorithm).digest()
            value = '\x1e'.join(sorted(methods))
            if types is not None:
                value += '\x1f' + '\x1e'.join(sorted(types))
            hash_value = b64(digest(value.encode()))
            salt = b'fixture salt 1234'
            challenge = f'r={nonce},s={b64(salt)},i=4096'
            mode = cfg.get('mode', 'protected')
            if mode != 'legacy' and mode != 'missing-h':
                challenge += ',h=' + ('AAAA' if mode == 'bad-h' else hash_value)
            if mode not in ('legacy', 'missing-h'):
                version = '0304' if cfg['version'] == ssl.TLSVersion.TLSv1_3 else '0303'
                if mode == 'bad-t':
                    version = '0303' if version == '0304' else '0304'
                challenge += ',t=' + version
            if mode == 'duplicate-h':
                challenge += ',h=' + hash_value
            if mode == 'empty-t':
                challenge = re.sub(r',t=[^,]+', ',t=', challenge)
            signed_challenge = challenge
            if mode == 'strip-h':
                challenge = re.sub(r',h=[^,]+', '', challenge)
            if mode == 'strip-t':
                challenge = re.sub(r',t=[^,]+', '', challenge)
            send_sasl(sock, 'challenge', challenge)
            data = recv_until(sock, b'</response>')
            if cfg.get('reject_challenge'):
                assert b'<response' not in data, 'proof leaked after rejected challenge'
                return
            final = base64.b64decode(ET.fromstring(data).text).decode()
            parts = fields(final)
            expected_cb = gs2.encode()
            if method.endswith('-PLUS'):
                assert gs2 == 'p=tls-server-end-point,,'
                expected_cb += self.server.cert_hash
            assert base64.b64decode(parts['c']) == expected_cb
            assert parts['r'] == nonce
            transcript = (bare + ',' + signed_challenge + ',' + final.rsplit(',p=', 1)[0]).encode()
            salted = hashlib.pbkdf2_hmac(algorithm, PASSWORD, salt, 4096)
            client_key = mac(salted, b'Client Key')
            signature = mac(digest(client_key), transcript)
            expected_proof = bytes(a ^ b for a, b in zip(client_key, signature))
            if mode in ('strip-h', 'strip-t'):
                assert not hmac.compare_digest(base64.b64decode(parts['p']), expected_proof), 'stripped attribute escaped transcript binding'
                self.server.proof_checked = True
                sock.sendall(f"<failure xmlns='{NS}'><not-authorized/></failure>".encode())
                return
            assert hmac.compare_digest(base64.b64decode(parts['p']), expected_proof), 'client proof mismatch'
            self.server.proof_checked = True
            server_signature = mac(mac(salted, b'Server Key'), transcript)
            if mode == 'bad-v':
                server_signature = bytes(len(server_signature))
            send_sasl(sock, 'success', 'v=' + b64(server_signature))
        except Exception as error:
            self.server.errors.append(repr(error))
        finally:
            sock.close()


class Server(socketserver.TCPServer):
    allow_reuse_address = True


def cases():
    for transport in ('tls', 'starttls'):
        for version in (ssl.TLSVersion.TLSv1_2, ssl.TLSVersion.TLSv1_3):
            base = dict(transport=transport, version=version, expect_auth=True, expected='ok', allow=True)
            for algorithm in ('1', '256', '512'):
                for plus in (False, True):
                    selected = 'SCRAM-SHA-' + algorithm + ('-PLUS' if plus else '')
                    yield dict(base, methods=['PLAIN', selected, 'Z-UNKNOWN'],
                               selected=selected, types=['tls-server-end-point'] if plus else None)
            for mode, error in [('bad-h', 'sasl-downgrade-detected'), ('bad-t', 'tls-version-mismatch'),
                                ('duplicate-h', 'invalid-scram-challenge'), ('empty-t', 'invalid-scram-challenge'),
                                ('bad-v', 'invalid-scram-proof'), ('legacy', 'ok')]:
                yield dict(base, methods=['SCRAM-SHA-256'], selected='SCRAM-SHA-256', mode=mode,
                           expected=error, reject_challenge=error != 'ok' and mode != 'bad-v')
            for allow, seen, expected in [(False, False, 'plain-disabled'), (True, False, 'ok'),
                                           (True, True, 'plain-downgrade-blocked')]:
                yield dict(base, methods=['PLAIN'], selected='PLAIN', allow=allow, seen=seen,
                           expected=expected, expect_auth=expected == 'ok')
            for mode in ('protected', 'missing-h'):
                yield dict(base, methods=['SCRAM-SHA-256-PLUS', 'SCRAM-SHA-256'], selected='SCRAM-SHA-256',
                           types=['future-binding'], mode=mode, reject_challenge=mode == 'missing-h',
                           expected='sasl-downgrade-detected' if mode == 'missing-h' else 'ok')
            yield dict(base, methods=['SCRAM-SHA-256-PLUS', 'PLAIN'], selected='PLAIN',
                       types=['future-binding'], expect_auth=False, expected='channel-binding-required')
            for mode in ('strip-h', 'strip-t'):
                yield dict(base, methods=['SCRAM-SHA-256'], selected='SCRAM-SHA-256', mode=mode, expected='server-failure')
            yield dict(base, methods=['SCRAM-SHA-256'], selected='SCRAM-SHA-256', store_fail=True,
                       expected='scram-pin-storage-failed')
            yield dict(base, methods=['PLAIN'], selected='PLAIN', allow=True, strict=True,
                       expect_auth=False, expected='channel-binding-required')


def main():
    probe, openssl = sys.argv[1:3]
    with tempfile.TemporaryDirectory(prefix='dinox-sasl-') as tmp:
        folder = Path(tmp) / 'Проверка TLS'
        folder.mkdir()
        cert, key = folder / 'Сертификат.pem', folder / 'key.pem'
        subprocess.run([openssl, 'req', '-x509', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:P-256',
                        '-sha256', '-nodes', '-keyout', 'key.pem', '-out', 'cert.pem', '-days', '1',
                        '-subj', '/CN=example.test', '-addext', 'subjectAltName=DNS:example.test'],
                       cwd=folder, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        # Python sets the Unicode working directory through CreateProcessW.
        # The native OpenSSL CLI only sees ASCII relative output filenames;
        # the production GIO client still receives the Cyrillic CA filename.
        (folder / 'cert.pem').replace(cert)
        cert_hash = hashlib.sha256(ssl.PEM_cert_to_DER_cert(cert.read_text())).digest()
        for number, cfg in enumerate(cases(), 1):
            tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            tls.minimum_version = tls.maximum_version = cfg['version']
            tls.load_cert_chain(cert, key)
            with Server(('127.0.0.1', 0), Handler) as server:
                server.cfg, server.tls, server.cert_hash = cfg, tls, cert_hash
                server.errors, server.proof_checked = [], False
                thread = threading.Thread(target=server.handle_request, daemon=True)
                thread.start()
                result = subprocess.run([probe, str(server.server_address[1]), str(cert), cfg['transport'],
                                         'allow' if cfg.get('allow') else 'deny', 'seen' if cfg.get('seen') else 'new',
                                         'strict' if cfg.get('strict') else 'normal', cfg['expected'],
                                         'storage-fail' if cfg.get('store_fail') else 'store-ok',
                                         'offers-plus' if any(m in ('SCRAM-SHA-1-PLUS', 'SCRAM-SHA-256-PLUS',
                                                                   'SCRAM-SHA-512-PLUS') for m in cfg['methods']) else 'no-plus'],
                                        capture_output=True, text=True, timeout=10)
                thread.join(timeout=7)
                assert not thread.is_alive(), 'fixture server timed out'
                assert result.returncode == 0, (cfg, result.stdout, result.stderr, server.errors)
                assert not server.errors, (cfg, server.errors)
                if cfg['expected'] in ('ok', 'server-failure', 'scram-pin-storage-failed') or cfg.get('mode') == 'bad-v':
                    assert server.proof_checked, 'independent proof verification was not reached'
                print(f"PASS {number}: {cfg['transport']} {cfg['version'].name} {cfg['selected']} {cfg.get('mode', '')} -> {cfg['expected']}")
        print(f'PASS: {number} real TLS authentication cases; independent proofs and rejected-write checks')


if __name__ == '__main__':
    main()
