#!/usr/bin/env python3
"""HTTP/2-only DoH with signed DNS and the same real SOCKS5 route as HTTP/1.

Requires python-h2 in addition to the existing dnspython/cryptography fixtures.
There is no HTTP/1 fallback, so forcing HTTP/1 fails before any DNS answer.
"""
import importlib.util
import os
from pathlib import Path
import socketserver
import ssl
import subprocess
import sys
import tempfile
import threading

import h2.config
import h2.connection
import h2.events
import h2.exceptions

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("doh", Path(__file__).with_name("run-doh-fixture.py"))
doh = importlib.util.module_from_spec(spec)
spec.loader.exec_module(doh)
protocols = []


class Http2(socketserver.BaseRequestHandler):
    def handle(self):
        try:
            self.request.settimeout(10)
            with self.server.tls.wrap_socket(self.request, server_side=True) as sock:
                protocols.append(sock.selected_alpn_protocol())
                if sock.selected_alpn_protocol() != "h2":
                    return
                conn = h2.connection.H2Connection(config=h2.config.H2Configuration(
                    client_side=False, header_encoding="utf-8"))
                conn.initiate_connection()
                sock.sendall(conn.data_to_send())
                streams, pending = {}, {}
                while True:
                    data = sock.recv(65536)
                    if not data:
                        return
                    for event in conn.receive_data(data):
                        if isinstance(event, h2.events.RequestReceived):
                            streams[event.stream_id] = [dict(event.headers), bytearray()]
                        elif isinstance(event, h2.events.DataReceived):
                            streams[event.stream_id][1].extend(event.data)
                            conn.acknowledge_received_data(event.flow_controlled_length, event.stream_id)
                        elif isinstance(event, h2.events.StreamReset):
                            pending.pop(event.stream_id, None)
                            streams.pop(event.stream_id, None)
                        elif isinstance(event, h2.events.StreamEnded):
                            headers, wire = streams.pop(event.stream_id)
                            assert headers[":method"] == "POST"
                            assert headers["content-type"] == "application/dns-message"
                            path = headers[":path"]
                            query = doh.fixture.dns.message.from_wire(bytes(wire)).question[0]
                            doh.queries.append((query.name.to_text(), query.rdtype))
                            body = doh.fixture.answer(bytes(wire))
                            if path == "/redirect":
                                conn.send_headers(event.stream_id, [(":status", "302"),
                                    ("location", "https://forbidden.invalid/dns-query")], end_stream=True)
                                continue
                            if path == "/oversize":
                                body = b"0" * 65536
                            if path == "/wrong-id":
                                body = bytes([body[0] ^ 0xff]) + body[1:]
                            conn.send_headers(event.stream_id, [(":status", "200"),
                                ("content-type", "application/dns-message"), ("content-length", str(len(body)))])
                            pending[event.stream_id] = body
                        elif isinstance(event, h2.events.ConnectionTerminated):
                            return
                    for stream_id in list(pending):
                        while pending[stream_id]:
                            size = min(len(pending[stream_id]), conn.max_outbound_frame_size,
                                       conn.local_flow_control_window(stream_id))
                            if size <= 0:
                                break
                            part, pending[stream_id] = pending[stream_id][:size], pending[stream_id][size:]
                            conn.send_data(stream_id, part, end_stream=not pending[stream_id])
                        if not pending[stream_id]:
                            del pending[stream_id]
                    sock.sendall(conn.data_to_send())
        except (ConnectionError, TimeoutError, ssl.SSLError, h2.exceptions.H2Error):
            pass


class Server(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    with tempfile.TemporaryDirectory(prefix="dinox-doh-h2-") as tmp:
        certpath, keypath = doh.certificates(Path(tmp))
        tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls.load_cert_chain(certpath, keypath)
        tls.set_alpn_protocols(["h2"])
        with Server(("127.0.0.1", 0), Http2) as https, doh.fixture.Server(("127.0.0.1", 0), doh.Socks) as proxy:
            https.tls = tls
            proxy.https_port = https.server_address[1]
            threads = [threading.Thread(target=s.serve_forever, daemon=True) for s in (https, proxy)]
            for thread in threads:
                thread.start()
            env = dict(os.environ, DINOX_TEST_DOH_URL=f"https://resolver.invalid:{proxy.https_port}/dns-query",
                       DINOX_TEST_DOH_PROXY=f"socks5://127.0.0.1:{proxy.server_address[1]}",
                       DINOX_TEST_DOH_CA=str(certpath), DINOX_TEST_DNS_ANCHOR=f"{doh.fixture.ZONE} IN DS {doh.fixture.DS}")
            try:
                result = subprocess.run(sys.argv[1:], env=env, timeout=25, check=False)
                if result.returncode:
                    print("HTTP/2 diagnostics:", protocols, doh.queries, doh.destinations, file=sys.stderr)
                    return result.returncode
                assert protocols and all(p == "h2" for p in protocols), protocols
                assert ("dinox-test.", 48) in doh.queries
                assert ("_5222._tcp.good.dinox-test.", 52) in doh.queries
                assert doh.destinations and all(host in ("resolver.invalid", "wrong.invalid") for host, _ in doh.destinations)
                print("PASS HTTP/2-only DoH: validated DNSKEY/TLSA through SOCKS5; negative endpoints and closed route rejected")
                return 0
            finally:
                https.shutdown()
                proxy.shutdown()
                for thread in threads:
                    thread.join()


if __name__ == "__main__":
    sys.exit(main())
