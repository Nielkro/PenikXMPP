#!/usr/bin/env python3
"""Signed SRV/address/TLSA discovery, with actual Unbound validation."""
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import threading

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("fixture", Path(__file__).with_name("run-resolver-fixture.py"))
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)
dns = fixture.dns
queries = []


def answer(wire):
    query = dns.message.from_wire(wire)
    response = dns.message.make_response(query)
    response.flags |= dns.flags.AA | dns.flags.RA
    question = query.question[0]
    name = question.name.to_text()
    queries.append((name, question.rdtype))
    assert question.name.is_subdomain(fixture.ZONE), name

    def rr(owner, kind, *values):
        return dns.rrset.from_text(owner, 60, "IN", kind, *values)

    def nodata():
        response.authority.extend(fixture.signed(rr(fixture.ZONE, "SOA", "ns.dinox-test. hostmaster.dinox-test. 1 3600 600 86400 60")))
        # A narrow interval proves this owner's missing type without claiming
        # that its TLSA descendants do not exist (aggressive NSEC caching).
        response.authority.extend(fixture.signed(rr(name, "NSEC", "\\001." + name + " A RRSIG NSEC")))

    if question.rdtype == dns.rdatatype.DNSKEY:
        response.answer.extend(fixture.signed(fixture.KEYSET))
    elif question.rdtype == dns.rdatatype.SRV:
        if ".denied." in name:
            response.answer.extend(fixture.signed(rr(name, "SRV", "0 0 0 .")))
        elif name.startswith("_xmpps") or ".absent." in name:
            nodata()
        else:
            owner = name
            if ".srv-alias." in name:
                owner = "_xmpp-client._tcp.good.dinox-test."
                response.answer.extend(fixture.signed(rr(name, "CNAME", owner)))
            target = name.removeprefix("_xmpp-client._tcp.")
            srv = rr(owner, "SRV", f"10 1 5522 {target}", f"20 3 5523 {target}")
            response.answer.extend(fixture.signed(srv))
            if ".bogus." in name:
                response.answer[0] = rr(owner, "SRV", "0 1 666 attacker.dinox-test.")
    elif question.rdtype == dns.rdatatype.A:
        if "address-alias." in name:
            response.answer.extend(fixture.signed(rr(name, "CNAME", "good.dinox-test.")))
            name = "good.dinox-test."
        response.answer.extend(fixture.signed(rr(name, "A", "127.0.0.1")))
    elif question.rdtype == dns.rdatatype.TLSA:
        if "no-tlsa." in name:
            nodata()
        else:
            response.answer.extend(fixture.signed(rr(name, "TLSA", "3 1 1 " + "ab" * 32)))
            if "forged-tlsa." in name:
                response.answer[0] = rr(name, "TLSA", "3 1 1 " + "cd" * 32)
    else:
        nodata()
    return response.to_wire()


def main():
    fixture.answer = answer
    with fixture.Server(("127.0.0.1", 0), fixture.Handler) as server:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        env = dict(os.environ, DINOX_TEST_DNS_FORWARDER=f"127.0.0.1@{server.server_address[1]}",
                   DINOX_TEST_DNS_ANCHOR=f"{fixture.ZONE} IN DS {fixture.DS}")
        try:
            result = subprocess.run(sys.argv[1:], env=env, timeout=30, check=False)
            if result.returncode:
                print("Fixture queries:", queries, file=sys.stderr)
                return result.returncode
            assert ("_5522._tcp.good.dinox-test.", 52) in queries
            assert ("_5523._tcp.good.dinox-test.", 52) in queries
            assert ("_5222._tcp.absent.dinox-test.", 52) in queries
            assert not any("attacker" in name for name, _kind in queries)
            print("PASS: authenticated target ports used for TLSA; forged delegation never resolved")
            return 0
        finally:
            server.shutdown()
            thread.join()


if __name__ == "__main__":
    sys.exit(main())
