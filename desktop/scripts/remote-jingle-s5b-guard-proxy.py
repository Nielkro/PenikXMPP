#!/usr/bin/env python3
#
# Minimal stdlib-only SOCKS5 guard for the remote Jingle S5B proxy smokes.

import argparse
import ipaddress
import os
import select
import socket
import sys
import threading
import time


class GuardProxyError(Exception):
    pass


def recv_exact(sock, size):
    data = b""
    while len(data) < size:
        chunk = sock.recv(size - len(data))
        if not chunk:
            raise GuardProxyError("SOCKS5 client closed early")
        data += chunk
    return data


def atomic_write(path, text):
    tmp_path = path + ".tmp"
    with open(tmp_path, "w", encoding="utf-8") as handle:
        handle.write(text)
    os.replace(tmp_path, path)


def is_hex_dstaddr(host):
    if len(host) != 40:
        return False
    return all(c in "0123456789abcdefABCDEF" for c in host)


def is_blocked_destination(host, port):
    lowered = host.lower().rstrip(".")
    if lowered == "localhost" or lowered.endswith(".localhost"):
        return True, "localhost"
    if port == 0 and is_hex_dstaddr(host):
        return True, "jingle-s5b-dstaddr"
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        return False, ""
    if (address.is_loopback or address.is_private or address.is_link_local or
            address.is_multicast or address.is_reserved or address.is_unspecified):
        return True, "local-address"
    return False, ""


def read_key_file(path):
    values = {}
    if not path:
        return values
    try:
        with open(path, "r", encoding="utf-8") as handle:
            for line in handle:
                key, sep, value = line.strip().partition("=")
                if sep:
                    values[key] = value
    except FileNotFoundError:
        return {}
    return values


def destination_matches_allow_file(host, port, allow_file):
    values = read_key_file(allow_file)
    return values.get("host") == host and values.get("port") == str(port)


class Socks5GuardProxy:
    def __init__(self, host, port, ready_file, reject_file, allow_file, connect_file):
        self.host = host
        self.port = port
        self.ready_file = ready_file
        self.reject_file = reject_file
        self.allow_file = allow_file
        self.connect_file = connect_file
        self.server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.server.bind((self.host, self.port))
        self.server.listen(64)
        self.server.settimeout(0.5)
        self.running = True

    def serve_forever(self):
        bound_host, bound_port = self.server.getsockname()
        atomic_write(self.ready_file, f"host={bound_host}\nport={bound_port}\n")
        while self.running:
            try:
                conn, peer = self.server.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            thread = threading.Thread(target=self.handle_client, args=(conn, peer), daemon=True)
            thread.start()

    def close(self):
        self.running = False
        try:
            self.server.close()
        except OSError:
            pass

    def handle_client(self, conn, peer):
        upstream = None
        try:
            conn.settimeout(30)
            host, port = self.read_request(conn)
            blocked, reason = is_blocked_destination(host, port)
            allowed = destination_matches_allow_file(host, port, self.allow_file)
            if blocked and not allowed:
                self.write_reject_event(host, port, reason)
                self.send_reply(conn, 0x02, "0.0.0.0", 0)
                return

            upstream = socket.create_connection((host, port), 30)
            self.write_connect_event(host, port, "allowed-local" if blocked else "public")
            self.send_reply(conn, 0x00, "0.0.0.0", 0)
            self.relay(conn, upstream)
        except Exception:
            try:
                self.send_reply(conn, 0x01, "0.0.0.0", 0)
            except Exception:
                pass
        finally:
            for sock in (conn, upstream):
                if sock is not None:
                    try:
                        sock.close()
                    except OSError:
                        pass

    def read_request(self, conn):
        hello = recv_exact(conn, 2)
        if hello[0] != 0x05 or hello[1] == 0:
            raise GuardProxyError("invalid SOCKS5 hello")
        methods = recv_exact(conn, hello[1])
        if 0x00 not in methods:
            conn.sendall(b"\x05\xff")
            raise GuardProxyError("SOCKS5 client did not offer no-auth")
        conn.sendall(b"\x05\x00")

        request = recv_exact(conn, 4)
        version, command, _reserved, atyp = request
        if version != 0x05 or command != 0x01:
            raise GuardProxyError("unsupported SOCKS5 request")
        if atyp == 0x01:
            host = socket.inet_ntoa(recv_exact(conn, 4))
        elif atyp == 0x03:
            length = recv_exact(conn, 1)[0]
            host = recv_exact(conn, length).decode("idna")
        elif atyp == 0x04:
            host = socket.inet_ntop(socket.AF_INET6, recv_exact(conn, 16))
        else:
            raise GuardProxyError("unsupported SOCKS5 address type")
        port = int.from_bytes(recv_exact(conn, 2), "big")
        return host, port

    def send_reply(self, conn, code, bind_host, bind_port):
        address = socket.inet_aton(bind_host)
        conn.sendall(b"\x05" + bytes([code]) + b"\x00\x01" + address + bind_port.to_bytes(2, "big"))

    def relay(self, left, right):
        left.setblocking(False)
        right.setblocking(False)
        sockets = [left, right]
        while True:
            readable, _writable, exceptional = select.select(sockets, [], sockets, 30)
            if exceptional or not readable:
                return
            for source in readable:
                target = right if source is left else left
                data = source.recv(65536)
                if not data:
                    return
                target.sendall(data)

    def write_reject_event(self, host, port, reason):
        line = f"reject reason={reason} host={host} port={port} time={int(time.time())}\n"
        with open(self.reject_file, "a", encoding="utf-8") as handle:
            handle.write(line)
            handle.flush()

    def write_connect_event(self, host, port, reason):
        if not self.connect_file:
            return
        line = f"connect reason={reason} host={host} port={port} time={int(time.time())}\n"
        with open(self.connect_file, "a", encoding="utf-8") as handle:
            handle.write(line)
            handle.flush()


def self_test():
    blocked, reason = is_blocked_destination("127.0.0.1", 7777)
    if not blocked or reason != "local-address":
        raise AssertionError("loopback reject self-test failed")
    blocked, reason = is_blocked_destination("0" * 40, 0)
    if not blocked or reason != "jingle-s5b-dstaddr":
        raise AssertionError("S5B dstaddr reject self-test failed")
    blocked, _reason = is_blocked_destination("example.com", 5222)
    if blocked:
        raise AssertionError("public host allow self-test failed")
    allow_path = f"/tmp/dinox-guard-self-test-allow-{os.getpid()}"
    try:
        atomic_write(allow_path, "host=127.0.0.1\nport=7777\n")
        if not destination_matches_allow_file("127.0.0.1", 7777, allow_path):
            raise AssertionError("candidate allow self-test failed")
        if destination_matches_allow_file("127.0.0.1", 7778, allow_path):
            raise AssertionError("candidate allow mismatch self-test failed")
    finally:
        try:
            os.unlink(allow_path)
        except FileNotFoundError:
            pass


def main():
    parser = argparse.ArgumentParser(description="Run a local SOCKS5 guard proxy for remote Jingle S5B proxy smokes.")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--ready-file", required=False)
    parser.add_argument("--reject-file", required=False)
    parser.add_argument("--allow-file", required=False,
                        help="key file containing host/port allowed even if normally local/private")
    parser.add_argument("--connect-file", required=False,
                        help="append successful CONNECT events to this file")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return 0
    if not args.ready_file or not args.reject_file:
        raise GuardProxyError("--ready-file and --reject-file are required")

    proxy = Socks5GuardProxy(args.host, args.port, args.ready_file, args.reject_file,
                             args.allow_file, args.connect_file)
    try:
        proxy.serve_forever()
    finally:
        proxy.close()
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:
        print(f"remote-jingle-s5b-guard-proxy-error: {exc}", file=sys.stderr)
        sys.exit(1)
