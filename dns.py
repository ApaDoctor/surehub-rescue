#!/usr/bin/env python3
"""surehub-rescue DNS responder for the hub subnet.

Answers hub.api.surehub.io with this Mac's hub-side IP so the hub connects to relay.py.
Every other name is forwarded unchanged to a normal resolver. Every query is logged,
which is also how status.sh tracks progress.

Only devices plugged into the Mac's hub port use this resolver; the Mac itself and the
rest of your network are not affected.

Env:
  LISTEN_IP     default 192.168.77.1
  RELAY_IP      default = LISTEN_IP
  UPSTREAM_DNS  default 1.1.1.1
  OVERRIDE      comma-separated names to point at the relay (default hub.api.surehub.io)
"""
import datetime
import os
import socket
import struct

LISTEN_IP = os.environ.get("LISTEN_IP", "192.168.77.1")
RELAY_IP = os.environ.get("RELAY_IP", LISTEN_IP)
UPSTREAM = (os.environ.get("UPSTREAM_DNS", "1.1.1.1"), 53)
OVERRIDE = {n.strip().lower().rstrip(".") for n in
            os.environ.get("OVERRIDE", "hub.api.surehub.io").split(",") if n.strip()}


def log(msg):
    print(f"{datetime.datetime.now():%H:%M:%S.%f} {msg}", flush=True)


def parse_question(pkt):
    """Return (qname, qtype, offset just past the question)."""
    i, labels = 12, []
    while pkt[i]:
        n = pkt[i]
        labels.append(pkt[i + 1:i + 1 + n].decode(errors="replace"))
        i += 1 + n
    qtype = struct.unpack(">H", pkt[i + 1:i + 3])[0]
    return ".".join(labels).lower(), qtype, i + 5


def spoofed_answer(pkt, qend, qtype):
    answers = b""
    if qtype == 1:  # A record -> relay; other types (AAAA etc.) get an empty NOERROR
        answers = b"\xc0\x0c" + struct.pack(">HHIH", 1, 1, 60, 4) + socket.inet_aton(RELAY_IP)
    header = pkt[:2] + b"\x81\x80" + struct.pack(">HHHH", 1, 1 if answers else 0, 0, 0)
    return header + pkt[12:qend] + answers


def main():
    srv = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    srv.bind((LISTEN_IP, 53))
    log(f"dns listening on {LISTEN_IP}:53, {sorted(OVERRIDE)} -> {RELAY_IP}, others -> {UPSTREAM[0]}")
    while True:
        pkt, addr = srv.recvfrom(4096)
        try:
            name, qtype, qend = parse_question(pkt)
        except (IndexError, struct.error):
            continue
        if name in OVERRIDE:
            log(f"{addr[0]} {name} type={qtype} -> RELAY {RELAY_IP}")
            srv.sendto(spoofed_answer(pkt, qend, qtype), addr)
            continue
        up = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        up.settimeout(3)
        try:
            up.sendto(pkt, UPSTREAM)
            resp, _ = up.recvfrom(4096)
            srv.sendto(resp, addr)
            log(f"{addr[0]} {name} type={qtype} -> forwarded")
        except OSError as e:
            log(f"{addr[0]} {name} type={qtype} -> upstream error {e!r}")
        finally:
            up.close()


if __name__ == "__main__":
    main()
