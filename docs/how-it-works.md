# How it works: the analysis

This is the technical write-up of how the problem was diagnosed and fixed on two real hubs.
The serial number is redacted, and the timestamps are local time from the captures.

## Setup used for the diagnosis

```
 [hub] --ethernet-- [Mac en7 192.168.77.1] ==NAT==> [Mac Wi-Fi en0] --> internet
                         tcpdump here                 tcpdump here
```

Capturing on both sides of the Mac made it possible to tell whether the Mac changed anything.

## 1. The hub gets online, but its check-in dies

Shortly after boot, the hub resolves `hub.api.surehub.io` and opens an HTTPS connection:

```
hub  > 1.1.1.1      A? hub.api.surehub.io
1.1.1.1 > hub       CNAME hub-api.production.surehub.io, A 3.33.146.192, A 15.197.140.15
hub  > 3.33.146.192.443  [S]   win 1200, mss 536
3.33.146.192 > hub       [S.]  win 65535, mss 1460
hub  > server            [P.]  60 bytes            <- TLS ClientHello
server > hub  seq    1:537     536 bytes            <- ServerHello + start of certificate
server > hub  seq  537:1073    536 bytes
server > hub  seq 1073:1609    536 bytes            <- already past the hub's 1200-byte window
server > hub  seq 1609:2145    ...
server > hub  ... up to 3753
hub  > server  ack 1073, win 128
hub  > server  ack 1201, win 0                      <- hub: "my buffer is full"
server > hub  [R]                                   <- reset, ~10 ms later
server > hub  [R] [R] [R] ...
```

It's the same pattern on every attempt, and the hub retries roughly every 7 minutes.

The Wi-Fi-side capture shows the same packets. The Mac forwards `win 1200` unchanged, and the
resets arrive from the internet with the same TTL (244) as the server's genuine data. **The
reset comes from Sure's AWS edge (Global Accelerator), not from the local network.**

### What the hub's TLS looks like

Decoded ClientHello (60 bytes):

- TLS 1.2 (`0x0303`)
- exactly **one** cipher suite: `0x003d` = `TLS_RSA_WITH_AES_256_CBC_SHA256`
- no SNI (server name) extension
- one extension: `signature_algorithms` = `rsa_pkcs1_sha256`

The server accepts this. Its ServerHello picks `0x003d` and it starts sending a **3957-byte
Certificate message**. So the cipher isn't the problem. The problem is that a ~4 KB server
flight has to go through a 1200-byte receive window.

## 2. Putting a relay in the middle

First attempt: a pf `rdr` rule redirecting the hub's port-443 traffic to a local relay. The SYNs
were translated, but never reached the listening socket. Most likely the VPN clients' pf anchors
on that Mac (Cloudflare WARP, NordVPN) were interfering. Rather than debug third-party firewall
rules, the approach changed to DNS:

- The Mac runs DHCP for the hub and hands out **itself** as the DNS server.
- `dns.py` answers `hub.api.surehub.io → 192.168.77.1` and forwards everything else.
- `relay.py` listens on `192.168.77.1:443` and opens a normal connection to the real
  `hub.api.surehub.io:443`.

AWS now talks to the Mac's TCP stack (normal window, no problem). The Mac's TCP stack talks to
the hub and respects its 1200-byte window:

```
server(relay) > hub  seq    1:537,  537:1073
hub > relay   ack 1073, win 128  ... ack 1073, win 1200
relay > hub   seq 1073:1609, 1609:2145
hub > relay   ack 2145 ...
...                                         <- paced, no resets
```

TLS record layout of the first successful session:

| Direction | Records |
|---|---|
| hub → cloud | ClientHello (55), ClientKeyExchange (262), ChangeCipherSpec, Finished (80), AppData (304), AppData (160) |
| cloud → hub | ServerHello (74), Certificate (3957), ServerHelloDone (4), ChangeCipherSpec, Finished (80), AppData (304), AppData (64) |

The full handshake completes and the hub verifies the certificate itself. The relay never sees
plaintext.

## 3. The answer the hub had been missing: update firmware

About 2 seconds after getting the response, the hub re-initialised its network (a new DHCP
request), resolved `hub.api.surehub.io` again, and connected to it on **port 80, plain HTTP**.
With a second relay on port 80:

```
POST /api/firmware HTTP/1.1
User-Agent: curl/7.22.0 (x86_64-pc-linux-gnu) libcurl/7.22.0 OpenSSL/1.0.1 ...
Host: hub.api.surehub.io
Content-Type: application/x-www-form-urlencoded

serial_number=H010-XXXXXXX&page=0&bootloader_version=1.177
```

```
HTTP/1.1 200 OK
Content-Type: application/x-firmware-update
Transfer-Encoding: chunked
Server: nginx

1024
<4 KB binary page>
```

The hub requests `page=0, 1, 2, …` with a new TCP connection per page. The download ran 57
pages for both hubs (bootloader 1.177) and took about one minute. The last response is short,
which marks the end. The hub then flashed the firmware and rebooted.

## 4. After the update

The new firmware behaves differently:

- It advertises a **3000-byte** receive window instead of 1200.
- It resolves `hub-api.production.surehub.io` (the CNAME target) directly, so it no longer
  matches the DNS override and goes **straight to AWS without the relay**. Those connections
  complete normally with no resets.
- It then resolves `iot.production.surehub.io` and opens **MQTT over TLS on port 8883** to AWS
  IoT, which is the persistent cloud connection the app uses. That's the "fixed" signal
  `status.sh` looks for.

So after one relayed check-in and the firmware download, the hub no longer needs the Mac and
works when plugged into a normal router.

## Why this probably happens

Inference, not confirmed with Sure: the cloud endpoint now sits behind AWS Global Accelerator
with a ~4 KB certificate chain. Hubs that kept getting updates never noticed. A hub that stayed
offline on old firmware has a TCP/TLS stack that can't take that first flight. Its zero-window
condition leads the edge to reset the connection, so the hub can't reach the endpoint that would
update it.

## Reproducing the analysis

`hub-up.sh` captures the hub port to `captures/hub-*.pcap`. Useful filters:

```bash
# the failing check-in (before the relay) / the relayed one
tcpdump -r captures/hub-*.pcap -n 'tcp port 443'

# firmware download progress
grep connected captures/relay80.log

# what the hub resolves
cat captures/dns.log

# the cloud (MQTT) connection
tcpdump -r captures/hub-*.pcap -n 'tcp port 8883'
```
