#!/usr/bin/env python3
"""surehub-rescue TCP relay.

The hub is told (by dns.py) that hub.api.surehub.io lives at this Mac. It connects here,
and we open our own ordinary TCP connection to the real hub.api.surehub.io and copy bytes
both ways.

Why this helps: old hub firmware advertises a 1200-byte TCP receive window. The Sure
cloud's AWS edge sends its ~3.9 KB TLS certificate chain in one burst, overruns that
window and resets the connection. Here, the Mac's TCP stack talks to AWS with a normal
window and then feeds the hub at the pace it can handle.

TLS is NOT terminated or modified - the hub still talks end-to-end encrypted to the real
server and verifies its certificate as usual. We only relay bytes.

Env:
  RELAY_PORT    port to listen on (443 for the check-in, 80 for firmware download)
  LISTEN_IP     default 192.168.77.1
  UPSTREAM_HOST default hub.api.surehub.io
  UPSTREAM_PORT default = RELAY_PORT
  CAPTURE=0     don't write raw byte streams to captures/streams/
"""
import asyncio
import datetime
import os

LISTEN = (os.environ.get("LISTEN_IP", "192.168.77.1"), int(os.environ.get("RELAY_PORT", "443")))
UPSTREAM_HOST = os.environ.get("UPSTREAM_HOST", "hub.api.surehub.io")
UPSTREAM_PORT = int(os.environ.get("UPSTREAM_PORT", LISTEN[1]))
CAPTURE = os.environ.get("CAPTURE", "1") != "0"
OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "captures", "streams")


def log(msg):
    print(f"{datetime.datetime.now():%H:%M:%S.%f} {msg}", flush=True)


class _NullDump:
    def write(self, _):
        pass

    def flush(self):
        pass

    def close(self):
        pass


def open_dump(path):
    return open(path, "wb") if CAPTURE else _NullDump()


async def pipe(reader, writer, dump, tag, conn_id):
    total = 0
    try:
        while data := await reader.read(65536):
            total += len(data)
            dump.write(data)
            dump.flush()
            writer.write(data)
            await writer.drain()
    except (ConnectionError, OSError) as e:
        log(f"[{conn_id}] {tag} error: {e!r}")
    finally:
        log(f"[{conn_id}] {tag} closed after {total} bytes")
        try:
            if writer.can_write_eof():
                writer.write_eof()
        except OSError:
            pass


async def handle(hub_r, hub_w):
    peer = hub_w.get_extra_info("peername")
    conn_id = f"{LISTEN[1]}-{datetime.datetime.now():%Y%m%d-%H%M%S%f}"
    log(f"[{conn_id}] hub {peer} connected -> {UPSTREAM_HOST}:{UPSTREAM_PORT}")
    try:
        up_r, up_w = await asyncio.open_connection(UPSTREAM_HOST, UPSTREAM_PORT)
    except OSError as e:
        log(f"[{conn_id}] upstream connect failed: {e!r}")
        hub_w.close()
        return
    log(f"[{conn_id}] upstream connected {up_w.get_extra_info('peername')}")
    base = os.path.join(OUT_DIR, conn_id)
    d1, d2 = open_dump(base + ".hub2cloud.bin"), open_dump(base + ".cloud2hub.bin")
    try:
        await asyncio.gather(
            pipe(hub_r, up_w, d1, "hub->cloud", conn_id),
            pipe(up_r, hub_w, d2, "cloud->hub", conn_id),
        )
    finally:
        d1.close()
        d2.close()
        for w in (hub_w, up_w):
            w.close()
    log(f"[{conn_id}] done")


async def main():
    if CAPTURE:
        os.makedirs(OUT_DIR, exist_ok=True)
    server = await asyncio.start_server(handle, *LISTEN, reuse_address=True)
    log(f"relay listening on {LISTEN}, upstream {UPSTREAM_HOST}:{UPSTREAM_PORT}")
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
