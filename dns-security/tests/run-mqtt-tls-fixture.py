#!/usr/bin/env python3
"""Count real MQTT CONNECT packets and SNI; no public broker or credentials."""
import datetime
import os
from pathlib import Path
import socketserver
import ssl
import subprocess
import sys
import tempfile
import threading
import time
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID

class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(5)
        try:
            time.sleep(0.12)
            with self.server.tls.wrap_socket(self.request, server_side=True) as sock:
                packet = sock.recv(4096)
                if packet:
                    assert packet[0] == 0x10 and b"FIXTURE-SECRET" in packet
                    self.server.connects.append(packet)
                    sock.sendall(b"\x20\x02\x00\x00")
        except (ConnectionError, TimeoutError, ssl.SSLError):
            pass
        except Exception as error:
            self.server.errors.append(str(error))

class SlowFinishHandler(socketserver.BaseRequestHandler):
    def handle(self):
        # The native probe deliberately waits for the original DNS evidence's
        # ten-second TTL after checking the certificate. Keep this socket open
        # so the assertion that no MQTT CONNECT arrives remains meaningful.
        self.request.settimeout(15)
        incoming, outgoing = ssl.MemoryBIO(), ssl.MemoryBIO()
        tls = self.server.tls.wrap_bio(incoming, outgoing, server_side=True)
        try:
            complete = False
            while not complete:
                data = self.request.recv(16384)
                if not data:
                    return
                incoming.write(data)
                try:
                    tls.do_handshake()
                    complete = True
                except ssl.SSLWantReadError:
                    pass
                reply = outgoing.read()
                if complete:
                    # Peer has verified our certificate and sent its Finished.
                    # The native probe changes evidence when receiving ours.
                    self.server.finished += 1
                    time.sleep(0.2)
                if reply:
                    self.request.sendall(reply)
            data = self.request.recv(16384)
            if data:
                incoming.write(data)
                try:
                    packet = tls.read()
                    if packet:
                        self.server.connects.append(packet)
                except (ssl.SSLWantReadError, ssl.SSLZeroReturnError):
                    pass
        except (ConnectionError, TimeoutError, ssl.SSLError):
            pass

class Server(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = True

def main():
    with tempfile.TemporaryDirectory(prefix="dinox-mqtt-dane-") as tmp:
        # Includes a Cyrillic/spaced CA path, loaded through GLib, not OpenSSL fopen.
        folder = Path(tmp) / "Проверка TLS"
        folder.mkdir()
        key = ec.generate_private_key(ec.SECP256R1())
        name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "mqtt.invalid")])
        now = datetime.datetime.now(datetime.timezone.utc)
        cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name)
            .public_key(key.public_key()).serial_number(1)
            .not_valid_before(now - datetime.timedelta(days=1)).not_valid_after(now + datetime.timedelta(days=1))
            .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
            .add_extension(x509.SubjectAlternativeName([x509.DNSName("mqtt.invalid")]), critical=False)
            .sign(key, hashes.SHA256()))
        ca, keyfile = folder / "ca.pem", folder / "key.pem"
        ca.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
        keyfile.write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
            serialization.NoEncryption()))
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(ca, keyfile)
        names = []
        context.set_servername_callback(lambda sock, name, ctx: names.append(name))
        delayed_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        delayed_context.minimum_version = delayed_context.maximum_version = ssl.TLSVersion.TLSv1_2
        delayed_context.load_cert_chain(ca, keyfile)
        delayed_context.set_servername_callback(lambda sock, name, ctx: names.append(name))
        with Server(("127.0.0.1", 0), Handler) as server, Server(("127.0.0.1", 0), SlowFinishHandler) as delayed:
            delayed.tls, delayed.connects, delayed.finished = delayed_context, [], 0
            delayed_thread = threading.Thread(target=delayed.serve_forever, daemon=True)
            delayed_thread.start()
            server.tls, server.connects, server.errors = context, [], []
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            env = dict(os.environ, DINOX_TEST_CA=str(ca), DINOX_TEST_PORT=str(server.server_address[1]), DINOX_TEST_SLOW_FINISH_PORT=str(delayed.server_address[1]))
            result = subprocess.run(sys.argv[1:], env=env, timeout=45)
            server.shutdown()
            thread.join()
            delayed.shutdown()
            delayed_thread.join()
            assert delayed.finished == 2 and not delayed.connects, (delayed.finished, delayed.connects)
            assert result.returncode == 0, result.returncode
            assert not server.errors, server.errors
            assert len(server.connects) == 3, len(server.connects)
            assert len(names) == 11 and names.count("mqtt.invalid") == 10 and names.count("wrong.invalid") == 1, names
            print("PASS: only 3 accepted connections sent MQTT CONNECT; all 8 rejected connections sent none; original SNI retained")
if __name__ == "__main__":
    main()
