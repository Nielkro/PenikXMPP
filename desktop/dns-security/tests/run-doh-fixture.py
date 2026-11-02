#!/usr/bin/env python3
"""Local HTTPS + SOCKS5 fixture. resolver.invalid MUST reach the proxy as a name.

No certificate exceptions: the child process gets this fixture's temporary CA.
The DNS response generator and public test key come from run-resolver-fixture.
"""
import datetime
import http.server
import importlib.util
import os
from pathlib import Path
import select
import socket
import socketserver
import ssl
import struct
import subprocess
import sys
import tempfile
import threading

sys.dont_write_bytecode = True

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID

spec = importlib.util.spec_from_file_location("fixture", Path(__file__).with_name("run-resolver-fixture.py"))
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)
queries = []
destinations = []


class Http(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        assert self.path in ("/dns-query", "/redirect", "/oversize", "/wrong-id")
        assert self.headers["Content-Type"] == "application/dns-message"
        wire = self.rfile.read(int(self.headers["Content-Length"]))
        query = fixture.dns.message.from_wire(wire).question[0]
        queries.append((query.name.to_text(), query.rdtype))
        body = fixture.answer(wire)
        if self.path == "/redirect":
            self.send_response(302)
            self.send_header("Location", "https://forbidden.invalid/dns-query")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if self.path == "/oversize":
            body = b"0" * 65536
        if self.path == "/wrong-id":
            body = bytes([body[0] ^ 0xff]) + body[1:]
        self.send_response(200)
        self.send_header("Content-Type", "application/dns-message")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        pass


def read_exact(sock, size):
    result = bytearray()
    while len(result) < size:
        part = sock.recv(size - len(result))
        if not part:
            raise EOFError()
        result.extend(part)
    return bytes(result)


class Socks(socketserver.BaseRequestHandler):
    def handle(self):
        try:
            self.request.settimeout(10)
            version, count = read_exact(self.request, 2)
            assert version == 5
            assert 0 in read_exact(self.request, count)
            self.request.sendall(b"\x05\x00")
            version, command, reserved, atype = read_exact(self.request, 4)
            assert (version, command, reserved, atype) == (5, 1, 0, 3)
            length = read_exact(self.request, 1)[0]
            host = read_exact(self.request, length).decode("ascii")
            port, = struct.unpack("!H", read_exact(self.request, 2))
            destinations.append((host, port))
            assert host in ("resolver.invalid", "wrong.invalid") and port == self.server.https_port
            with socket.create_connection(("127.0.0.1", port), timeout=10) as upstream:
                self.request.sendall(b"\x05\x00\x00\x01\x7f\x00\x00\x01\x00\x00")
                while True:
                    ready, _, _ = select.select([self.request, upstream], [], [], 10)
                    if not ready:
                        return
                    for source in ready:
                        data = source.recv(16384)
                        if not data:
                            return
                        (upstream if source is self.request else self.request).sendall(data)
        except (EOFError, ConnectionError, TimeoutError):
            pass


def certificates(directory):
    key = ec.generate_private_key(ec.SECP256R1())
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "resolver.invalid")])
    now = datetime.datetime.now(datetime.timezone.utc)
    cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name)
            .public_key(key.public_key()).serial_number(1)
            .not_valid_before(now - datetime.timedelta(days=1))
            .not_valid_after(now + datetime.timedelta(days=1))
            .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
            .add_extension(x509.SubjectAlternativeName([x509.DNSName("resolver.invalid")]), critical=False)
            .sign(key, hashes.SHA256()))
    certpath = Path(directory) / "ca.pem"
    keypath = Path(directory) / "key.pem"
    certpath.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
    keypath.write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                         serialization.NoEncryption()))
    return certpath, keypath


def main():
    with tempfile.TemporaryDirectory(prefix="dinox-doh-test-") as directory:
        certpath, keypath = certificates(directory)
        tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls.load_cert_chain(certpath, keypath)
        with http.server.ThreadingHTTPServer(("127.0.0.1", 0), Http) as https, \
                fixture.Server(("127.0.0.1", 0), Socks) as proxy:
            https.socket = tls.wrap_socket(https.socket, server_side=True)
            proxy.https_port = https.server_port
            threads = [threading.Thread(target=s.serve_forever, daemon=True) for s in (https, proxy)]
            for thread in threads:
                thread.start()
            env = dict(os.environ, DINOX_TEST_DOH_URL=f"https://resolver.invalid:{https.server_port}/dns-query",
                       DINOX_TEST_DOH_PROXY=f"socks5://127.0.0.1:{proxy.server_address[1]}",
                       DINOX_TEST_DOH_CA=str(certpath), DINOX_TEST_DNS_ANCHOR=f"{fixture.ZONE} IN DS {fixture.DS}")
            try:
                result = subprocess.run(sys.argv[1:], env=env, timeout=25, check=False)
                if result.returncode:
                    return result.returncode
                assert destinations, "SOCKS5 route was not used"
                assert all(host in ("resolver.invalid", "wrong.invalid") for host, _port in destinations), "Redirect escaped endpoint restriction"
                assert ("dinox-test.", 48) in queries, "DNSKEY did not traverse HTTPS/SOCKS5"
                assert ("_5222._tcp.good.dinox-test.", 52) in queries
                print(f"Proxy observed {len(queries)} DNS messages including validation keys; no local resolver bootstrap")
                return 0
            finally:
                https.shutdown()
                proxy.shutdown()
                for thread in threads:
                    thread.join()


if __name__ == "__main__":
    sys.exit(main())
