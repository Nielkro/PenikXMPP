#!/usr/bin/env python3
#
# Minimal stdlib-only XMPP/Jingle S5B sender for the opt-in remote smoke.
# It intentionally does not import DinoX/xmpp-vala code.

import argparse
import base64
import codecs
import hashlib
import html
import os
import socket
import ssl
import sys
import threading
import time
import uuid
import xml.etree.ElementTree as ET


CLIENT_NS = "jabber:client"
STREAM_NS = "http://etherx.jabber.org/streams"
TLS_NS = "urn:ietf:params:xml:ns:xmpp-tls"
SASL_NS = "urn:ietf:params:xml:ns:xmpp-sasl"
BIND_NS = "urn:ietf:params:xml:ns:xmpp-bind"
JINGLE_NS = "urn:xmpp:jingle:1"
JINGLE_FT_NS = "urn:xmpp:jingle:apps:file-transfer:5"
JINGLE_S5B_NS = "urn:xmpp:jingle:transports:s5b:1"
SOCKS5_BYTESTREAMS_NS = "http://jabber.org/protocol/bytestreams"
STANZAS_NS = "urn:ietf:params:xml:ns:xmpp-stanzas"


class ForeignSenderError(Exception):
    pass


def qname(ns, name):
    return f"{{{ns}}}{name}"


def xml_attr(value):
    return html.escape(str(value), quote=True)


def xml_text(value):
    return html.escape(str(value), quote=False)


def elem_text(elem):
    return "".join(elem.itertext()) if elem is not None else ""


def jid_bare(jid):
    return jid.split("/", 1)[0]


def jid_localpart(jid):
    bare = jid_bare(jid)
    if "@" not in bare:
        raise ForeignSenderError("sender JID must include a localpart and domain")
    return bare.split("@", 1)[0]


def jid_domain(jid):
    bare = jid_bare(jid)
    if "@" not in bare:
        raise ForeignSenderError("sender JID must include a localpart and domain")
    return bare.split("@", 1)[1]


def calculate_dstaddr(sid, initiator_full_jid, target_full_jid):
    return hashlib.sha1((sid + initiator_full_jid + target_full_jid).encode("utf-8")).hexdigest()


def parse_ready_file(path):
    values = {}
    with open(path, "r", encoding="utf-8") as handle:
        for line in handle:
            key, sep, value = line.strip().partition("=")
            if sep:
                values[key] = value
    return values


class XmppClient:
    def __init__(self, jid, password, host=None, port=5222, timeout=30):
        self.jid = jid_bare(jid)
        self.localpart = jid_localpart(jid)
        self.domain = jid_domain(jid)
        self.password = password
        self.host = host or self.domain
        self.port = port
        self.timeout = timeout
        self.sock = None
        self.parser = None
        self.decoder = None
        self.depth = 0
        self.bound_jid = None

    def connect(self):
        self.sock = socket.create_connection((self.host, self.port), self.timeout)
        self.sock.settimeout(self.timeout)
        features = self.open_stream()
        if features.find(qname(TLS_NS, "starttls")) is None:
            raise ForeignSenderError("XMPP server did not offer STARTTLS")

        self.write("<starttls xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>")
        proceed = self.next_element(self.timeout)
        if proceed.tag != qname(TLS_NS, "proceed"):
            raise ForeignSenderError("XMPP server did not accept STARTTLS")

        context = ssl.create_default_context()
        self.sock = context.wrap_socket(self.sock, server_hostname=self.domain)
        features = self.open_stream()
        self.authenticate_plain(features)
        features = self.open_stream()
        self.bind_resource(features)

    def close(self):
        if self.sock is None:
            return
        try:
            self.write("</stream:stream>")
        except Exception:
            pass
        try:
            self.sock.close()
        except OSError:
            pass
        self.sock = None

    def reset_parser(self):
        self.parser = ET.XMLPullParser(events=("start", "end"))
        self.decoder = codecs.getincrementaldecoder("utf-8")()
        self.depth = 0

    def open_stream(self):
        self.reset_parser()
        self.write(
            "<?xml version='1.0'?>"
            "<stream:stream "
            f"to='{xml_attr(self.domain)}' "
            "version='1.0' "
            "xmlns='jabber:client' "
            "xmlns:stream='http://etherx.jabber.org/streams'>"
        )
        elem = self.next_element(self.timeout)
        if elem.tag != qname(STREAM_NS, "features"):
            raise ForeignSenderError(f"expected stream features, got {elem.tag}")
        return elem

    def authenticate_plain(self, features):
        mechanisms = features.find(qname(SASL_NS, "mechanisms"))
        offered = set()
        if mechanisms is not None:
            offered = {elem_text(m) for m in list(mechanisms)}
        if "PLAIN" not in offered:
            raise ForeignSenderError("XMPP server did not offer SASL PLAIN after STARTTLS")
        payload = base64.b64encode(f"\0{self.localpart}\0{self.password}".encode("utf-8")).decode("ascii")
        self.write(f"<auth xmlns='{SASL_NS}' mechanism='PLAIN'>{payload}</auth>")
        result = self.next_element(self.timeout)
        if result.tag != qname(SASL_NS, "success"):
            raise ForeignSenderError("SASL PLAIN authentication failed")

    def bind_resource(self, features):
        if features.find(qname(BIND_NS, "bind")) is None:
            raise ForeignSenderError("XMPP server did not offer resource binding")
        resource = "DinoX.ForeignS5B." + uuid.uuid4().hex[:8]
        iq_id = "bind-" + uuid.uuid4().hex
        stanza = (
            f"<iq type='set' id='{xml_attr(iq_id)}'>"
            f"<bind xmlns='{BIND_NS}'><resource>{xml_text(resource)}</resource></bind>"
            "</iq>"
        )
        result = self.send_iq_and_wait(stanza, iq_id, self.timeout)
        jid_elem = result.find(f".//{qname(BIND_NS, 'jid')}")
        self.bound_jid = elem_text(jid_elem)
        if not self.bound_jid:
            raise ForeignSenderError("resource bind result did not include a full JID")

    def write(self, text):
        if self.sock is None:
            raise ForeignSenderError("XMPP socket is not connected")
        self.sock.sendall(text.encode("utf-8"))

    def next_element(self, timeout):
        deadline = time.monotonic() + timeout
        while True:
            for event, elem in self.parser.read_events():
                if event == "start":
                    self.depth += 1
                    continue
                if event == "end":
                    if self.depth == 2:
                        self.depth -= 1
                        return elem
                    self.depth -= 1

            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("timed out waiting for XMPP stanza")
            self.sock.settimeout(min(remaining, 1.0))
            try:
                data = self.sock.recv(65536)
            except socket.timeout:
                continue
            if not data:
                raise ForeignSenderError("XMPP stream closed")
            self.parser.feed(self.decoder.decode(data))

    def send_iq_and_wait(self, stanza, iq_id, timeout, jingle_handler=None):
        self.write(stanza)
        return self.wait_for_iq(iq_id, timeout, jingle_handler)

    def wait_for_iq(self, iq_id, timeout, jingle_handler=None):
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError(f"timed out waiting for XMPP IQ {iq_id}")
            try:
                elem = self.next_element(remaining)
            except TimeoutError as exc:
                raise TimeoutError(f"timed out waiting for XMPP IQ {iq_id}") from exc
            if elem.tag != qname(CLIENT_NS, "iq"):
                elem.clear()
                continue

            handled = False
            if jingle_handler is not None:
                handled = jingle_handler.handle_iq(elem)

            if elem.get("id") == iq_id:
                iq_type = elem.get("type")
                if iq_type == "result":
                    return elem
                if iq_type == "error":
                    raise ForeignSenderError(f"XMPP IQ {iq_id} returned error")
                raise ForeignSenderError(f"XMPP IQ {iq_id} returned unexpected type {iq_type}")

            if not handled and elem.get("type") in ("get", "set"):
                self.send_iq_error_item_not_found(elem)
            elem.clear()

    def send_iq_result(self, iq):
        to_attr = iq.get("from")
        to_xml = f" to='{xml_attr(to_attr)}'" if to_attr else ""
        self.write(f"<iq type='result' id='{xml_attr(iq.get('id'))}'{to_xml}/>")

    def send_iq_error_item_not_found(self, iq):
        to_attr = iq.get("from")
        to_xml = f" to='{xml_attr(to_attr)}'" if to_attr else ""
        self.write(
            f"<iq type='error' id='{xml_attr(iq.get('id'))}'{to_xml}>"
            "<error type='cancel'>"
            f"<item-not-found xmlns='{STANZAS_NS}'/>"
            "</error>"
            "</iq>"
        )


class JingleState:
    def __init__(self, client, sid, expected_peer, content_name, s5b_sid):
        self.client = client
        self.sid = sid
        self.expected_peer = expected_peer
        self.content_name = content_name
        self.s5b_sid = s5b_sid
        self.session_accept = None
        self.session_accept_count = 0
        self.selected_candidate = None
        self.candidate_error = False
        self.terminated = False
        self.terminate_reason = None

    def handle_iq(self, iq):
        jingle = iq.find(qname(JINGLE_NS, "jingle"))
        if jingle is None or jingle.get("sid") != self.sid:
            return False
        from_attr = iq.get("from")
        if from_attr and jid_bare(from_attr) != jid_bare(self.expected_peer):
            return False

        action = jingle.get("action")
        if action == "session-accept":
            self.session_accept = jingle
            self.session_accept_count += 1
        elif action == "transport-info":
            candidate = self.parse_candidate_used(jingle)
            if candidate is not None:
                self.selected_candidate = candidate
            if self.has_candidate_error(jingle):
                self.candidate_error = True
        elif action == "session-terminate":
            self.terminated = True
            self.terminate_reason = self.parse_terminate_reason(jingle)

        self.client.send_iq_result(iq)
        return True

    def parse_candidate_used(self, jingle):
        for content in jingle.findall(qname(JINGLE_NS, "content")):
            transport = content.find(qname(JINGLE_S5B_NS, "transport"))
            if transport is None:
                continue
            candidate_used = transport.find(qname(JINGLE_S5B_NS, "candidate-used"))
            if candidate_used is not None:
                return candidate_used.get("cid")
        return None

    def has_candidate_error(self, jingle):
        for content in jingle.findall(qname(JINGLE_NS, "content")):
            transport = content.find(qname(JINGLE_S5B_NS, "transport"))
            if transport is not None and transport.find(qname(JINGLE_S5B_NS, "candidate-error")) is not None:
                return True
        return False

    def parse_terminate_reason(self, jingle):
        reason = jingle.find(qname(JINGLE_NS, "reason"))
        if reason is None:
            return None
        for child in list(reason):
            if child.tag.startswith("{" + JINGLE_NS + "}") and child.tag != qname(JINGLE_NS, "text"):
                return child.tag.split("}", 1)[1]
        return None

    def wait_until(self, predicate, timeout):
        deadline = time.monotonic() + timeout
        while not predicate():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return False
            try:
                elem = self.client.next_element(remaining)
            except TimeoutError:
                return False
            if elem.tag == qname(CLIENT_NS, "iq"):
                handled = self.handle_iq(elem)
                if not handled and elem.get("type") in ("get", "set"):
                    self.client.send_iq_error_item_not_found(elem)
            elem.clear()
        return True

    def validate_session_accept(self):
        if self.session_accept_count != 1:
            raise ForeignSenderError(f"expected one session-accept, got {self.session_accept_count}")
        content = self.session_accept.find(qname(JINGLE_NS, "content"))
        if content is None or content.get("name") != self.content_name:
            raise ForeignSenderError("session-accept used an unexpected content name")
        transport = content.find(qname(JINGLE_S5B_NS, "transport"))
        if transport is None or transport.get("sid") != self.s5b_sid:
            raise ForeignSenderError("session-accept used an unexpected S5B transport")

    def session_accept_candidates(self):
        candidates = []
        if self.session_accept is None:
            return candidates
        for content in self.session_accept.findall(qname(JINGLE_NS, "content")):
            transport = content.find(qname(JINGLE_S5B_NS, "transport"))
            if transport is None:
                continue
            for candidate in transport.findall(qname(JINGLE_S5B_NS, "candidate")):
                candidates.append({
                    "cid": candidate.get("cid") or "",
                    "type": candidate.get("type") or "",
                    "host": candidate.get("host") or "",
                    "port": candidate.get("port") or "",
                })
        return candidates

    def validate_no_direct_session_accept_candidates(self):
        direct_candidates = [
            candidate for candidate in self.session_accept_candidates()
            if candidate["type"] == "direct"
        ]
        if direct_candidates:
            details = ", ".join(
                f"{candidate['cid']}@{candidate['host']}:{candidate['port']}"
                for candidate in direct_candidates
            )
            raise ForeignSenderError(f"receiver published direct candidates in no-direct mode: {details}")


class Socks5Listener:
    def __init__(self, dstaddr, timeout, listen_host="127.0.0.1", listen_port=0, warmup_connections=0):
        self.dstaddr = dstaddr
        self.timeout = timeout
        self.warmup_connections = warmup_connections
        self.server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.server.bind((listen_host, listen_port))
        self.server.listen(1)
        self.server.settimeout(0.2)
        self.port = self.server.getsockname()[1]
        self.accepted = threading.Event()
        self.connected = threading.Event()
        self.warmup_done = threading.Event()
        self.stop_event = threading.Event()
        self.accept_count = 0
        self.warmup_connection_handles = []
        self.error = None
        self.connection = None
        self.thread = threading.Thread(target=self.run, name="foreign-s5b-listener", daemon=True)

    def start(self):
        self.thread.start()

    def close(self):
        self.stop_event.set()
        try:
            self.server.close()
        except OSError:
            pass
        if self.connection is not None:
            try:
                self.connection.close()
            except OSError:
                pass
        for conn in self.warmup_connection_handles:
            try:
                conn.close()
            except OSError:
                pass
        self.warmup_connection_handles = []

    def status_summary(self):
        error = f", error={self.error}" if self.error is not None else ""
        return (
            f"accepted={self.accepted.is_set()}, attempts={self.accept_count}, "
            f"connected={self.connected.is_set()}{error}"
        )

    def run(self):
        deadline = time.monotonic() + self.timeout
        try:
            for _index in range(self.warmup_connections):
                conn = self.accept_until(deadline, "timed out waiting for S5B warmup connection")
                print("foreign-s5b-warmup-connected", file=sys.stderr, flush=True)
                self.warmup_connection_handles.append(conn)
            self.warmup_done.set()

            last_error = None
            while not self.stop_event.is_set() and time.monotonic() < deadline:
                conn = self.accept_until(deadline, "timed out waiting for S5B connection")
                self.accept_count += 1
                self.accepted.set()
                print("foreign-s5b-listener-accepted", file=sys.stderr, flush=True)
                try:
                    self.handle_connection(conn)
                    self.connection = conn
                    self.connected.set()
                    print("foreign-s5b-listener-connected", file=sys.stderr, flush=True)
                    return
                except ForeignSenderError as exc:
                    last_error = exc
                    try:
                        conn.close()
                    except OSError:
                        pass
                    if str(exc) != "S5B peer closed during handshake":
                        raise
                    print(f"foreign-s5b-listener-retry: {exc}", file=sys.stderr, flush=True)
            if last_error is not None:
                raise last_error
            raise TimeoutError("timed out waiting for S5B connection")
        except Exception as exc:
            self.error = exc
            print(f"foreign-s5b-listener-error: {exc}", file=sys.stderr, flush=True)
            self.warmup_done.set()
            self.connected.set()

    def accept_until(self, deadline, timeout_message):
        while not self.stop_event.is_set() and time.monotonic() < deadline:
            try:
                conn, _addr = self.server.accept()
                return conn
            except socket.timeout:
                continue
        raise TimeoutError(timeout_message)

    def recv_exact(self, conn, size):
        data = b""
        while len(data) < size:
            chunk = conn.recv(size - len(data))
            if not chunk:
                raise ForeignSenderError("S5B peer closed during handshake")
            data += chunk
        return data

    def handle_connection(self, conn):
        conn.settimeout(self.timeout)
        hello = self.recv_exact(conn, 2)
        if hello[0] != 0x05 or hello[1] == 0:
            raise ForeignSenderError("invalid SOCKS5 hello")
        methods = self.recv_exact(conn, hello[1])
        if 0x00 not in methods:
            raise ForeignSenderError("SOCKS5 peer did not offer no-auth")
        conn.sendall(b"\x05\x00")

        request = self.recv_exact(conn, 4)
        if request[0] != 0x05 or request[1] != 0x01 or request[3] != 0x03:
            raise ForeignSenderError("invalid SOCKS5 connect request")
        dst_len = self.recv_exact(conn, 1)[0]
        dst = self.recv_exact(conn, dst_len)
        port = self.recv_exact(conn, 2)
        if dst.decode("ascii") != self.dstaddr or port != b"\x00\x00":
            raise ForeignSenderError("unexpected XEP-0260 dstaddr")

        response = b"\x05\x00\x00\x03" + bytes([len(self.dstaddr)]) + self.dstaddr.encode("ascii") + b"\x00\x00"
        conn.sendall(response)

    def wait_connected(self, timeout):
        if not self.connected.wait(timeout):
            raise TimeoutError("timed out waiting for S5B connection")
        if self.error is not None:
            raise self.error
        if self.connection is None:
            raise ForeignSenderError("S5B listener did not expose a connection")
        return self.connection

    def wait_warmup(self, timeout):
        if not self.warmup_done.wait(timeout):
            raise TimeoutError("timed out waiting for S5B warmup connection")
        if self.error is not None:
            raise self.error

    def ensure_not_connected(self, grace_seconds):
        deadline = time.monotonic() + grace_seconds
        while time.monotonic() < deadline:
            if self.accepted.wait(min(0.1, max(0.0, deadline - time.monotonic()))):
                raise ForeignSenderError("S5B direct listener was contacted")
            if self.connected.wait(min(0.1, max(0.0, deadline - time.monotonic()))):
                if self.error is not None:
                    raise ForeignSenderError(f"S5B direct listener was contacted and failed: {self.error}")
                raise ForeignSenderError("S5B direct listener was contacted")
        if self.accepted.is_set():
            raise ForeignSenderError("S5B direct listener was contacted")
        if self.connected.is_set():
            if self.error is not None:
                raise ForeignSenderError(f"S5B direct listener was contacted and failed: {self.error}")
            raise ForeignSenderError("S5B direct listener was contacted")


def connect_to_socks5_candidate(host, port, dstaddr, timeout):
    sock = socket.create_connection((host, port), timeout)
    try:
        sock.settimeout(timeout)
        sock.sendall(b"\x05\x01\x00")
        response = recv_exact_socket(sock, 2, "SOCKS5 proxy greeting")
        if response != b"\x05\x00":
            raise ForeignSenderError("SOCKS5 proxy did not accept no-auth")

        dstaddr_bytes = dstaddr.encode("ascii")
        if len(dstaddr_bytes) > 255:
            raise ForeignSenderError("S5B dstaddr is too long")
        request = (
            b"\x05\x01\x00\x03" +
            bytes([len(dstaddr_bytes)]) +
            dstaddr_bytes +
            b"\x00\x00"
        )
        sock.sendall(request)

        header = recv_exact_socket(sock, 4, "SOCKS5 proxy connect reply")
        if header[0] != 0x05 or header[1] != 0x00:
            raise ForeignSenderError("SOCKS5 proxy did not connect the XEP-0065 dstaddr")
        atyp = header[3]
        if atyp == 0x01:
            recv_exact_socket(sock, 6, "SOCKS5 proxy IPv4 reply")
        elif atyp == 0x03:
            host_len = recv_exact_socket(sock, 1, "SOCKS5 proxy domain reply length")[0]
            recv_exact_socket(sock, host_len + 2, "SOCKS5 proxy domain reply")
        elif atyp == 0x04:
            recv_exact_socket(sock, 18, "SOCKS5 proxy IPv6 reply")
        else:
            raise ForeignSenderError("SOCKS5 proxy returned an unsupported reply address type")
        return sock
    except Exception:
        try:
            sock.close()
        except OSError:
            pass
        raise


def build_session_initiate(sender_full, receiver_full, sid, content_name, s5b_sid,
                           file_name, file_size, cid, candidate_host, candidate_port,
                           candidate_jid, candidate_type):
    dstaddr = calculate_dstaddr(s5b_sid, sender_full, receiver_full)
    return (
        f"<jingle xmlns='{JINGLE_NS}' action='session-initiate' "
        f"initiator='{xml_attr(sender_full)}' sid='{xml_attr(sid)}'>"
        f"<content creator='initiator' name='{xml_attr(content_name)}' senders='initiator'>"
        f"<description xmlns='{JINGLE_FT_NS}'>"
        "<file>"
        f"<name>{xml_text(file_name)}</name>"
        f"<size>{file_size}</size>"
        "</file>"
        "</description>"
        f"<transport xmlns='{JINGLE_S5B_NS}' mode='tcp' sid='{xml_attr(s5b_sid)}' dstaddr='{xml_attr(dstaddr)}'>"
        f"<candidate cid='{xml_attr(cid)}' host='{xml_attr(candidate_host)}' jid='{xml_attr(candidate_jid)}' "
        f"port='{candidate_port}' priority='8267775' type='{xml_attr(candidate_type)}'/>"
        "</transport>"
        "</content>"
        "</jingle>"
    )


def build_candidate_error(sender_full, sid, content_name, s5b_sid):
    return (
        f"<jingle xmlns='{JINGLE_NS}' action='transport-info' "
        f"initiator='{xml_attr(sender_full)}' sid='{xml_attr(sid)}'>"
        f"<content creator='initiator' name='{xml_attr(content_name)}' senders='initiator'>"
        f"<transport xmlns='{JINGLE_S5B_NS}' sid='{xml_attr(s5b_sid)}'>"
        "<candidate-error/>"
        "</transport>"
        "</content>"
        "</jingle>"
    )


def build_activated(sender_full, sid, content_name, s5b_sid, cid):
    return (
        f"<jingle xmlns='{JINGLE_NS}' action='transport-info' "
        f"initiator='{xml_attr(sender_full)}' sid='{xml_attr(sid)}'>"
        f"<content creator='initiator' name='{xml_attr(content_name)}' senders='initiator'>"
        f"<transport xmlns='{JINGLE_S5B_NS}' sid='{xml_attr(s5b_sid)}'>"
        f"<activated cid='{xml_attr(cid)}'/>"
        "</transport>"
        "</content>"
        "</jingle>"
    )


def build_proxy_activate(s5b_sid, receiver_full):
    return (
        f"<query xmlns='{SOCKS5_BYTESTREAMS_NS}' sid='{xml_attr(s5b_sid)}'>"
        f"<activate>{xml_text(receiver_full)}</activate>"
        "</query>"
    )


def build_session_terminate(sender_full, sid, reason):
    return (
        f"<jingle xmlns='{JINGLE_NS}' action='session-terminate' "
        f"initiator='{xml_attr(sender_full)}' sid='{xml_attr(sid)}'>"
        "<reason>"
        f"<{xml_attr(reason)}/>"
        "</reason>"
        "</jingle>"
    )


def write_candidate_info(path, cid, host, port, jid, candidate_type):
    tmp_path = path + ".tmp"
    with open(tmp_path, "w", encoding="utf-8") as handle:
        handle.write(f"cid={cid}\n")
        handle.write(f"host={host}\n")
        handle.write(f"port={port}\n")
        handle.write(f"jid={jid}\n")
        handle.write(f"type={candidate_type}\n")
    os.replace(tmp_path, path)


def iq_set(payload, to_jid):
    iq_id = "foreign-" + uuid.uuid4().hex
    stanza = f"<iq type='set' to='{xml_attr(to_jid)}' id='{xml_attr(iq_id)}'>{payload}</iq>"
    return iq_id, stanza


def validate_port(value, name):
    try:
        port = int(value)
    except (TypeError, ValueError):
        raise ForeignSenderError(f"{name} must be an integer between 1 and 65535")
    if port < 1 or port > 65535:
        raise ForeignSenderError(f"{name} must be an integer between 1 and 65535")
    return port


def read_socks_reply(sock):
    header = recv_exact_socket(sock, 4, "Tor SOCKS reply")
    if header[0] != 0x05 or header[1] != 0x00:
        raise ForeignSenderError("Tor SOCKS did not connect to the hidden service")
    atyp = header[3]
    if atyp == 0x01:
        recv_exact_socket(sock, 6, "Tor SOCKS IPv4 reply")
    elif atyp == 0x03:
        host_len = recv_exact_socket(sock, 1, "Tor SOCKS domain reply length")[0]
        recv_exact_socket(sock, host_len + 2, "Tor SOCKS domain reply")
    elif atyp == 0x04:
        recv_exact_socket(sock, 18, "Tor SOCKS IPv6 reply")
    else:
        raise ForeignSenderError("Tor SOCKS returned an unsupported reply address type")


def recv_exact_socket(sock, size, context):
    data = b""
    while len(data) < size:
        chunk = sock.recv(size - len(data))
        if not chunk:
            raise ForeignSenderError(f"{context} closed early")
        data += chunk
    return data


def is_transient_tor_warmup_error(exc):
    message = str(exc)
    return (
        message == "Tor SOCKS did not connect to the hidden service" or
        message.endswith("closed early")
    )


def warm_up_tor_hidden_service(socks_host, socks_port, onion_host, onion_port, timeout):
    host_bytes = onion_host.encode("ascii")
    if len(host_bytes) > 255:
        raise ForeignSenderError("onion hostname is too long for SOCKS domain form")
    request = (
        b"\x05\x01\x00\x03" +
        bytes([len(host_bytes)]) +
        host_bytes +
        bytes([(onion_port >> 8) & 0xff, onion_port & 0xff])
    )

    deadline = time.monotonic() + timeout
    last_error = None
    while time.monotonic() < deadline:
        attempt_timeout = max(0.5, min(5.0, deadline - time.monotonic()))
        try:
            with socket.create_connection((socks_host, socks_port), attempt_timeout) as sock:
                sock.settimeout(attempt_timeout)
                sock.sendall(b"\x05\x01\x00")
                response = recv_exact_socket(sock, 2, "Tor SOCKS greeting")
                if response != b"\x05\x00":
                    raise ForeignSenderError("Tor SOCKS did not accept no-auth warmup")
                sock.sendall(request)
                read_socks_reply(sock)
                return
        except (OSError, TimeoutError) as exc:
            last_error = exc
        except ForeignSenderError as exc:
            if not is_transient_tor_warmup_error(exc):
                raise
            last_error = exc
        time.sleep(min(1.0, max(0.0, deadline - time.monotonic())))
    raise ForeignSenderError(f"Tor SOCKS did not connect to the hidden service: {last_error}")


def run_sender(args):
    sender_jid = require_env("DINOX_REMOTE_JINGLE_S5B_SENDER_JID")
    sender_password = require_env("DINOX_REMOTE_JINGLE_S5B_SENDER_PASSWORD")
    receiver_full = args.receiver_full_jid or os.environ.get("DINOX_REMOTE_JINGLE_S5B_RECEIVER_FULL_JID")
    if not receiver_full:
        ready_file = os.environ.get("DINOX_REMOTE_JINGLE_S5B_READY_FILE")
        if ready_file:
            receiver_full = parse_ready_file(ready_file).get("bound_jid")
    if not receiver_full:
        raise ForeignSenderError("receiver full JID is required")

    payload_path = args.payload or os.environ.get("DINOX_REMOTE_JINGLE_S5B_PAYLOAD_FILE")
    if not payload_path:
        raise ForeignSenderError("payload file is required")
    with open(payload_path, "rb") as handle:
        payload = handle.read()
    file_name = args.name or os.environ.get("DINOX_REMOTE_JINGLE_S5B_EXPECTED_NAME")
    if not file_name:
        raise ForeignSenderError("file name is required")

    timeout = args.timeout
    host = os.environ.get("DINOX_REMOTE_JINGLE_S5B_HOST") or None
    port = int(os.environ.get("DINOX_REMOTE_JINGLE_S5B_PORT", "5222"))
    client = XmppClient(sender_jid, sender_password, host=host, port=port, timeout=timeout)
    listener = None
    proxy_conn = None
    try:
        client.connect()
        sender_full = client.bound_jid
        jingle_sid = "foreign-jingle-s5b-" + str(uuid.uuid4())
        s5b_sid = "foreign-s5b-" + str(uuid.uuid4())
        content_name = "foreign-file-offer"
        candidate_type = args.candidate_type
        cid = f"foreign-{candidate_type}-" + str(uuid.uuid4())
        dstaddr = calculate_dstaddr(s5b_sid, sender_full, receiver_full)
        candidate_host = args.candidate_host or "127.0.0.1"
        candidate_port = validate_port(args.candidate_port, "--candidate-port") if args.candidate_port is not None else None
        candidate_jid = args.candidate_jid or sender_full
        if candidate_type == "proxy" and not args.candidate_jid:
            raise ForeignSenderError("--candidate-jid is required for proxy candidates")
        listener_port = validate_port(args.listen_port, "--listen-port") if args.listen_port is not None else 0
        warmup_requested = args.onion_warmup_socks_host is not None or args.onion_warmup_socks_port is not None
        if warmup_requested and (args.onion_warmup_socks_host is None or args.onion_warmup_socks_port is None):
            raise ForeignSenderError("--onion-warmup-socks-host and --onion-warmup-socks-port must be set together")
        if warmup_requested and not candidate_host.endswith(".onion"):
            raise ForeignSenderError("--onion-warmup-socks-host requires an .onion candidate host")
        if candidate_type == "direct":
            listener = Socks5Listener(
                dstaddr,
                timeout,
                listen_host=args.listen_host,
                listen_port=listener_port,
                warmup_connections=1 if warmup_requested else 0)
            listener.start()
            if args.candidate_port is None:
                candidate_port = listener.port
            if warmup_requested:
                warm_up_tor_hidden_service(
                    args.onion_warmup_socks_host,
                    validate_port(args.onion_warmup_socks_port, "--onion-warmup-socks-port"),
                    candidate_host,
                    candidate_port,
                    timeout)
                listener.wait_warmup(timeout)
        else:
            if args.listen_port is not None or args.listen_host != "127.0.0.1":
                raise ForeignSenderError("--listen-host/--listen-port are only valid for direct candidates")
            if args.candidate_port is None:
                raise ForeignSenderError("--candidate-port is required for proxy candidates")
        if args.candidate_info_file:
            write_candidate_info(
                args.candidate_info_file,
                cid,
                candidate_host,
                candidate_port,
                candidate_jid,
                candidate_type)

        state = JingleState(client, jingle_sid, receiver_full, content_name, s5b_sid)
        initiate = build_session_initiate(
            sender_full, receiver_full, jingle_sid, content_name, s5b_sid,
            file_name, len(payload), cid, candidate_host, candidate_port,
            candidate_jid, candidate_type)
        iq_id, stanza = iq_set(initiate, receiver_full)
        client.send_iq_and_wait(stanza, iq_id, timeout, state)

        if not state.wait_until(lambda: state.session_accept is not None or state.terminated, timeout):
            raise TimeoutError("timed out waiting for session-accept")
        if state.terminated:
            raise ForeignSenderError(f"session terminated before accept: {state.terminate_reason}")
        state.validate_session_accept()
        if args.expect_no_direct_candidates:
            state.validate_no_direct_session_accept_candidates()

        if args.expect_no_connect:
            if not state.wait_until(
                    lambda: state.candidate_error or state.terminated or state.selected_candidate is not None,
                    timeout):
                raise TimeoutError("timed out waiting for candidate-error or session-terminate")
            if state.selected_candidate == cid:
                raise ForeignSenderError("receiver selected the direct candidate in no-direct mode")
            if state.selected_candidate is not None:
                raise ForeignSenderError(f"receiver selected an unexpected candidate in no-direct mode: {state.selected_candidate}")
            if state.candidate_error and not state.terminated:
                terminate = build_session_terminate(sender_full, jingle_sid, "failed-transport")
                iq_id, stanza = iq_set(terminate, receiver_full)
                client.send_iq_and_wait(stanza, iq_id, timeout, state)
            if listener is not None:
                listener.ensure_not_connected(args.no_connect_grace)
            print("foreign-jingle-s5b-sender-no-direct-ok")
            return

        if candidate_type == "proxy":
            proxy_conn = connect_to_socks5_candidate(candidate_host, candidate_port, dstaddr, timeout)
            wait_summary = "proxy-connected"
        else:
            wait_summary = listener.status_summary()
        if not state.wait_until(
                lambda: state.selected_candidate == cid or state.terminated or (listener is not None and listener.connected.is_set()),
                timeout):
            raise TimeoutError(f"timed out waiting for candidate-used ({wait_summary})")
        if listener is not None and listener.connected.is_set() and listener.error is not None:
            raise listener.error
        if state.selected_candidate != cid and not state.terminated:
            if not state.wait_until(lambda: state.selected_candidate == cid or state.terminated, timeout):
                raise TimeoutError(f"timed out waiting for candidate-used ({wait_summary})")
        if state.terminated:
            raise ForeignSenderError(f"session terminated before candidate selection: {state.terminate_reason}")
        if candidate_type == "proxy":
            conn = proxy_conn
        else:
            conn = listener.wait_connected(timeout)

        candidate_error = build_candidate_error(sender_full, jingle_sid, content_name, s5b_sid)
        iq_id, stanza = iq_set(candidate_error, receiver_full)
        client.send_iq_and_wait(stanza, iq_id, timeout, state)
        if candidate_type == "proxy":
            activate = build_proxy_activate(s5b_sid, receiver_full)
            iq_id, stanza = iq_set(activate, candidate_jid)
            client.send_iq_and_wait(stanza, iq_id, timeout, state)

            activated = build_activated(sender_full, jingle_sid, content_name, s5b_sid, cid)
            iq_id, stanza = iq_set(activated, receiver_full)
            client.send_iq_and_wait(stanza, iq_id, timeout, state)

        conn.sendall(payload)
        conn.shutdown(socket.SHUT_WR)

        if not state.wait_until(lambda: state.terminated, timeout):
            raise TimeoutError("timed out waiting for session-terminate")
        if state.terminate_reason != "success":
            raise ForeignSenderError(f"session terminated with reason {state.terminate_reason}")
        print("foreign-jingle-s5b-sender-ok")
    finally:
        if listener is not None:
            listener.close()
        if proxy_conn is not None:
            try:
                proxy_conn.close()
            except OSError:
                pass
        client.close()


def require_env(name):
    value = os.environ.get(name)
    if not value:
        raise ForeignSenderError(f"{name} must be set")
    return value


def self_test():
    expected = "d84e557f5b9a144b0115842c62fd7cbb26a568a4"
    actual = calculate_dstaddr("sid", "initiator@example.test/res", "responder@example.test/res")
    if actual != expected:
        raise AssertionError("dstaddr self-test failed")
    stanza = build_session_initiate(
        "initiator@example.test/res", "responder@example.test/res",
        "sid", "file", "s5b-sid", "example.txt", 3,
        "cid", "exampleonionaddress.onion", 7777, "initiator@example.test/res", "direct")
    if "host='exampleonionaddress.onion'" not in stanza or "port='7777'" not in stanza:
        raise AssertionError("candidate host/port self-test failed")
    proxy_stanza = build_session_initiate(
        "initiator@example.test/res", "responder@example.test/res",
        "sid", "file", "s5b-sid", "example.txt", 3,
        "cid2", "proxy.example.test", 7777, "proxy.example.test", "proxy")
    if "jid='proxy.example.test'" not in proxy_stanza or "type='proxy'" not in proxy_stanza:
        raise AssertionError("proxy candidate self-test failed")
    activated = build_activated("initiator@example.test/res", "sid", "file", "s5b-sid", "cid2")
    if "<activated cid='cid2'/>" not in activated:
        raise AssertionError("activated transport-info self-test failed")
    activate = build_proxy_activate("s5b-sid", "responder@example.test/res")
    if "<activate>responder@example.test/res</activate>" not in activate:
        raise AssertionError("proxy activate self-test failed")
    if validate_port("7777", "test") != 7777:
        raise AssertionError("port validation self-test failed")
    warmup_listener = Socks5Listener("unused", 1, warmup_connections=1)
    warmup_listener.close()

    class PollingSocket:
        def __init__(self):
            self.recv_calls = 0

        def settimeout(self, _timeout):
            pass

        def recv(self, _size):
            self.recv_calls += 1
            if self.recv_calls == 1:
                raise socket.timeout()
            return (
                b"<stream:stream xmlns:stream='http://etherx.jabber.org/streams' "
                b"xmlns='jabber:client'><features/></stream:stream>"
            )

    client = XmppClient("sender@example.test", "unused", timeout=1)
    client.reset_parser()
    client.sock = PollingSocket()
    elem = client.next_element(2)
    if elem.tag != qname(CLIENT_NS, "features"):
        raise AssertionError("socket timeout polling self-test failed")


def main():
    parser = argparse.ArgumentParser(description="Send a minimal XEP-0234/XEP-0260 Jingle S5B file offer.")
    parser.add_argument("--run", action="store_true", help="perform the live XMPP send")
    parser.add_argument("--receiver-full-jid")
    parser.add_argument("--payload")
    parser.add_argument("--name")
    parser.add_argument("--timeout", type=int, default=int(os.environ.get("DINOX_REMOTE_JINGLE_S5B_TIMEOUT_SECONDS", "60")))
    parser.add_argument("--expect-no-connect", action="store_true",
                        help="expect session negotiation to fail cleanly without any connection to the direct S5B listener")
    parser.add_argument("--expect-no-direct-candidates", action="store_true",
                        help="fail if the receiver session-accept publishes direct S5B candidates")
    parser.add_argument("--no-connect-grace", type=float, default=2.0,
                        help="seconds to keep the direct S5B listener open after the clean failure signal")
    parser.add_argument("--candidate-info-file",
                        help="write the offered S5B candidate cid, host and port before sending session-initiate")
    parser.add_argument("--candidate-host",
                        help="S5B candidate host to advertise; defaults to 127.0.0.1")
    parser.add_argument("--candidate-port",
                        help="S5B candidate port to advertise; defaults to the local listener port")
    parser.add_argument("--candidate-jid",
                        help="S5B candidate JID to advertise; required for proxy candidates")
    parser.add_argument("--candidate-type", choices=("direct", "proxy"), default="direct",
                        help="S5B candidate type to advertise; defaults to direct")
    parser.add_argument("--listen-host", default="127.0.0.1",
                        help="local host for the S5B listener; defaults to 127.0.0.1")
    parser.add_argument("--listen-port",
                        help="local port for the S5B listener; defaults to an ephemeral port")
    parser.add_argument("--onion-warmup-socks-host",
                        help="Tor SOCKS host used to warm up the advertised onion candidate after binding the S5B listener")
    parser.add_argument("--onion-warmup-socks-port",
                        help="Tor SOCKS port used with --onion-warmup-socks-host")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return 0
    if not args.run:
        raise ForeignSenderError("use --run to perform the live XMPP send")
    run_sender(args)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:
        print(f"foreign-jingle-s5b-sender-error: {exc}", file=sys.stderr)
        sys.exit(1)
