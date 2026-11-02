#!/usr/bin/env python3
"""Offline, cryptographically signed DNS fixture; no real accounts or public DNS.

Needs Python dnspython and cryptography. The private key below is deliberately
public test material, generated from scalar 1, and MUST NOT be used in production.
Run with the compiled resolver-test executable as the only argument.
"""
import os
import socketserver
import struct
import subprocess
import sys
import threading
import time

import dns.dnssec
import dns.flags
import dns.message
import dns.name
import dns.rcode
import dns.rdatatype
import dns.rrset
from cryptography.hazmat.primitives.asymmetric import ec

ZONE = dns.name.from_text("dinox-test.")
KEY = ec.derive_private_key(1, ec.SECP256R1())
DNSKEY = dns.dnssec.make_dnskey(KEY.public_key(), "ECDSAP256SHA256", flags=257)
KEYSET = dns.rrset.from_rdata(ZONE, 60, DNSKEY)
DS = dns.dnssec.make_ds(ZONE, DNSKEY, "SHA256")


def signed(rrset):
    now = int(time.time())
    signature = dns.dnssec.sign(rrset, KEY, ZONE, DNSKEY,
                               inception=now - 3600, expiration=now + 86400)
    return [rrset, dns.rrset.from_rdata(rrset.name, 60, signature)]


def answer(wire):
    query = dns.message.from_wire(wire)
    response = dns.message.make_response(query)
    response.flags |= dns.flags.AA | dns.flags.RA
    question = query.question[0]
    name = question.name.to_text()
    if not question.name.is_subdomain(ZONE):
        raise AssertionError(f"Unexpected query outside isolated fixture: {name}")
    if name == "timeout.dinox-test.":
        return None
    if name == "servfail.dinox-test.":
        response.set_rcode(dns.rcode.SERVFAIL)
    elif question.rdtype == dns.rdatatype.DNSKEY and question.name == ZONE:
        response.answer.extend(signed(KEYSET))
    elif name in ("alias.dinox-test.", "forged-alias.dinox-test."):
        alias = dns.rrset.from_text(name, 60, "IN", "CNAME", "good.dinox-test.")
        if name == "alias.dinox-test.":
            response.answer.extend(signed(alias))
        else:
            response.answer.append(alias)
        response.answer.extend(signed(dns.rrset.from_text("good.dinox-test.", 60, "IN", "A", "192.0.2.10")))
    elif question.rdtype == dns.rdatatype.A:
        rrset = dns.rrset.from_text(name, 60, "IN", "A", "192.0.2.10")
        if name == "forged.dinox-test.":
            # An AD bit from an untrusted forwarder is not signature evidence.
            response.flags |= dns.flags.AD
            response.answer.append(rrset)
        else:
            response.answer.extend(signed(rrset))
            if name == "broken.dinox-test.":
                response.answer[0] = dns.rrset.from_text(name, 60, "IN", "A", "192.0.2.99")
    elif question.rdtype == dns.rdatatype.TLSA:
        response.answer.extend(signed(dns.rrset.from_text(name, 60, "IN", "TLSA", "3 1 1 " + "ab" * 32)))
    else:
        response.authority.extend(signed(dns.rrset.from_text(
            ZONE, 60, "IN", "SOA", "ns.dinox-test. hostmaster.dinox-test. 1 3600 600 86400 60")))
        response.authority.extend(signed(dns.rrset.from_text(
            name, 60, "IN", "NSEC", "z.dinox-test. A RRSIG NSEC")))
    return response.to_wire()


class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        self.connection.settimeout(5)
        try:
            while True:
                prefix = self.rfile.read(2)
                if len(prefix) != 2:
                    return
                length, = struct.unpack("!H", prefix)
                wire = self.rfile.read(length)
                if len(wire) != length:
                    return
                response = answer(wire)
                if response is not None:
                    self.wfile.write(struct.pack("!H", len(response)) + response)
                    self.wfile.flush()
        except (ConnectionError, TimeoutError):
            pass


class Server(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    with Server(("127.0.0.1", 0), Handler) as server:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        env = dict(os.environ, DINOX_TEST_DNS_FORWARDER=f"127.0.0.1@{server.server_address[1]}",
                   DINOX_TEST_DNS_ANCHOR=f"{ZONE} IN DS {DS}")
        try:
            return subprocess.run(sys.argv[1:], env=env, timeout=30, check=False).returncode
        finally:
            server.shutdown()
            thread.join()


if __name__ == "__main__":
    sys.exit(main())
