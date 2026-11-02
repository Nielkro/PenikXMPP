#!/usr/bin/env python3
"""Prove that failed TLSA never reaches XMPP headers/SASL on the live socket."""
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

HEADER = (b"<stream:stream xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams' "
          b"from='xmpp.invalid' version='1.0' id='fixture'>")
FEATURES = (b"<stream:features><mechanisms xmlns='urn:ietf:params:xml:ns:xmpp-sasl'>"
            b"<mechanism>PLAIN</mechanism></mechanisms></stream:features>")


def read_until(sock, marker):
    data = b""
    while marker not in data:
        part = sock.recv(4096)
        if not part:
            return data
        data += part
        assert len(data) < 16384
    return data


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        sock = self.request
        sock.settimeout(5)
        tls = None
        try:
            if self.server.starttls:
                before = read_until(sock, b">")
                if not before:
                    return
                assert b"<auth" not in before and b"<resume" not in before
                sock.sendall(HEADER + b"<stream:features><starttls xmlns='urn:ietf:params:xml:ns:xmpp-tls'/></stream:features>")
                request = read_until(sock, b"/>")
                if not request:
                    return
                assert b"<starttls" in request and b"<auth" not in request
                sock.sendall(b"<proceed xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>")
            time.sleep(0.12)  # Allows the evidence-expiry test to cross its deadline.
            tls = self.server.tls.wrap_socket(sock, server_side=True)
            application = read_until(tls, b">")
            if not application:
                return
            self.server.headers.append(application)
            tls.sendall(HEADER + FEATURES)
            auth = read_until(tls, b"</auth>")
            self.server.auth.append(auth)
            assert b"<auth" in auth and b"FIXTURE-CREDENTIAL" not in auth
        except (ConnectionError, TimeoutError, ssl.SSLError):
            pass
        except Exception as error:
            self.server.errors.append(repr(error))
        finally:
            if tls is not None:
                tls.close()


class Server(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    with tempfile.TemporaryDirectory(prefix="dinox-xmpp-dane-") as directory:
        key = ec.generate_private_key(ec.SECP256R1())
        name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "xmpp.invalid")])
        now = datetime.datetime.now(datetime.timezone.utc)
        cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name)
                .public_key(key.public_key()).serial_number(1)
                .not_valid_before(now - datetime.timedelta(days=1))
                .not_valid_after(now + datetime.timedelta(days=1))
                .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
                .add_extension(x509.SubjectAlternativeName([x509.DNSName("xmpp.invalid")]), critical=False)
                .sign(key, hashes.SHA256()))
        certificate_dir = Path(directory) / "Проверка TLS"
        certificate_dir.mkdir()
        certpath = certificate_dir / "Сертификат.pem"
        keypath = certificate_dir / "key.pem"
        certpath.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
        keypath.write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                             serialization.NoEncryption()))
        tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls.load_cert_chain(certpath, keypath)
        with Server(("127.0.0.1", 0), Handler) as direct, Server(("127.0.0.1", 0), Handler) as start:
            threads = []
            for server, starttls in ((direct, False), (start, True)):
                server.starttls, server.tls = starttls, tls
                server.headers, server.auth, server.errors = [], [], []
                thread = threading.Thread(target=server.serve_forever, daemon=True)
                thread.start()
                threads.append(thread)
            env = dict(os.environ, DINOX_TEST_XMPP_CA=str(certpath),
                       DINOX_TEST_TLS_PORT=str(direct.server_address[1]),
                       DINOX_TEST_STARTTLS_PORT=str(start.server_address[1]))
            try:
                result = subprocess.run(sys.argv[1:], env=env, timeout=35, check=False)
                if result.returncode:
                    return result.returncode
                for server in (direct, start):
                    assert not server.errors, server.errors
                    assert len(server.headers) == 6, (server.starttls, server.headers)
                    assert len(server.auth) == 6, (server.starttls, server.auth)
                print("PASS: only 6 matching DANE connections and 6 ordinary TLS connections sent XMPP headers/SASL; all 14 negative cases sent none")
                return 0
            finally:
                direct.shutdown()
                start.shutdown()
                for thread in threads:
                    thread.join()


if __name__ == "__main__":
    sys.exit(main())
