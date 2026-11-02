#!/usr/bin/env python3
"""Exercise the product MqttClient against two isolated loopback endpoints."""
import os
import socketserver
import subprocess
import sys
import threading

connects = []
proxy_connections = []


class Broker(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(5)
        try:
            assert self.request.recv(1) == b"\x10"
            remaining, scale = 0, 1
            while True:
                byte = self.request.recv(1)[0]
                remaining += (byte & 127) * scale
                if not byte & 128:
                    break
                scale *= 128
            packet = bytearray()
            while len(packet) < remaining:
                packet.extend(self.request.recv(remaining - len(packet)))
            assert packet[:7] == b"\x00\x04MQTT\x05"
            connects.append(bytes(packet))
            self.request.sendall(b"\x20\x03\x00\x00\x00")
            while self.request.recv(4096):
                pass
        except (ConnectionError, TimeoutError):
            pass


class PendingProxy(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(3)
        proxy_connections.append(True)
        try:
            # Hold the SOCKS handshake until cancellation; no external socket.
            while self.request.recv(4096):
                pass
        except (ConnectionError, TimeoutError):
            pass


class Server(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    with Server(("127.0.0.1", 0), Broker) as broker, Server(("127.0.0.1", 0), PendingProxy) as proxy:
        threads = [threading.Thread(target=s.serve_forever, daemon=True) for s in (broker, proxy)]
        for thread in threads:
            thread.start()
        try:
            env = dict(os.environ, DINOX_TEST_MQTT_PORT=str(broker.server_address[1]),
                       DINOX_TEST_PROXY_PORT=str(proxy.server_address[1]))
            result = subprocess.run(sys.argv[1:], env=env, timeout=15, check=False)
            if result.returncode:
                return result.returncode
            assert len(connects) == 2, f"Only the two explicitly unprotected fixture connections may send CONNECT: {len(connects)}"
            assert proxy_connections, "Cancellation did not reach the pending proxy handshake"
            print("PASS wire counts: two baseline CONNECT packets, none from rejected policies/cancelled DNS")
            return 0
        finally:
            broker.shutdown()
            proxy.shutdown()
            for thread in threads:
                thread.join()


if __name__ == "__main__":
    sys.exit(main())
