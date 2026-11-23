# surehub-rescue

**Get an old Sure Petcare hub back online when it refuses to connect to the internet.**

If your Sure Petcare hub (for the SureFlap cat flap / pet door / feeder) is plugged into your
router, has power, but never comes online in the app, it may be stuck on firmware that is too
old to finish a secure connection to Sure's servers. It can't update because it can't connect,
and it can't connect because it needs the update.

This tool uses a Mac as a temporary go-between so the hub can connect once, download its
firmware update, and then work normally on its own.

> Not affiliated with or endorsed by Sure Petcare / Allflex / MSD Animal Health.
> Use on your own hub, on your own network. Your hub talks to the real Sure servers the whole
> time; nothing is faked except telling the hub to go via your Mac.

---

## Do I have this problem?

Likely yes if **all** of these are true:

- The hub is wired to your router with Ethernet, gets power, and its lights say it has no
  internet / cloud connection.
- Other devices on the same router work fine.
- The hub has been unused or offline for a long time (e.g. in a drawer, second-hand, or a
  spare unit).
- Resetting / power-cycling the hub and the router didn't help.

Want to be sure? See [Confirming the diagnosis](#confirming-the-diagnosis-optional).

## What you need

- A **Mac** with an internet connection (Wi-Fi is fine). Tested on macOS 26 (Apple Silicon).
  It uses only built-in tools that have been in macOS for years, so recent versions should
  work. Reports welcome.
- A **wired Ethernet port** on the Mac: built-in, a USB/Thunderbolt Ethernet adapter, or a dock.
- An **Ethernet cable** to plug the hub straight into the Mac.
- `python3` - already present if you have Xcode Command Line Tools or Homebrew. Check with
  `python3 --version`. If missing, run `xcode-select --install`.
- Your Mac admin password (the setup changes network settings).
- ~15 minutes.

No other software needs to be installed.

## Step-by-step

### 1. Download this repository

```bash
git clone https://github.com/ApaDoctor/surehub-rescue.git
cd surehub-rescue
```

(or download the ZIP from GitHub, unzip it, and `cd` into the folder in Terminal.)

### 2. Plug the hub into the Mac

Connect the hub's Ethernet port to the Mac's Ethernet port/adapter with a cable, and power the
hub on. Wait ~10 seconds for the link to come up.

Keep the Mac connected to the internet some other way (usually Wi-Fi).

### 3. Start the rescue

```bash
sudo ./hub-up.sh
```

It finds the Ethernet port the hub is on and the Mac's internet connection automatically and
prints them:

```
Hub port:      en7
Internet via:  en0
```

If it can't find the hub port, tell it explicitly. List ports with
`networksetup -listallhardwareports` and pass the hub one, e.g. `sudo ./hub-up.sh en7`.

### 4. Restart the hub

Unplug the hub's power for 5 seconds and plug it back in, so it asks the Mac for a network
address.

### 5. Watch it fix itself

```bash
./status.sh --watch
```

You'll see each step tick off:

```
Hub 192.168.77.10
  [x] got an IP address from the Mac
  [x] asked for hub.api.surehub.io (3 times)
  [x] HTTPS check-in through relay (2 connections)
  [x] firmware download: 57 pages so far (last at 19:24:26.24) - DO NOT UNPLUG
  [x] connected to Sure cloud (iot.production.surehub.io) - FIXED
```

The firmware download takes a few minutes (about 57 pages of 4 KB in our case), after which
the hub flashes itself and reboots. **Don't unplug the hub or let the Mac sleep during the
download.**

When you see **`connected to Sure cloud - FIXED`**, the hub is updated. Its lights should show
it's connected and it should appear online in the Sure Petcare app.

### 6. Put everything back

```bash
sudo ./hub-down.sh
```

This removes everything the rescue set up (network settings, DHCP, DNS, relays, captures) and
restores what was there before. Then plug the hub back into your router - with the new
firmware it connects on its own.

**More than one hub?** Do them one after another, or connect several via a small switch.
Each one gets its own address and shows up separately in `status.sh`.

---

## What actually goes wrong (short version)

1. When the hub starts, it checks in with `hub.api.surehub.io` over HTTPS.
2. Old firmware has a tiny network stack: it can only receive **1200 bytes at a time**.
3. The server answers with its security certificate chain, about **3.9 KB in one burst**.
4. The hub's buffer is instantly full, it says "wait", and Sure's AWS front end gives up and
   **resets the connection** within ~10 ms. Every time.
5. The reply the hub never receives is the one telling it to **update its firmware** - which
   would fix the problem.

The rescue makes the hub's DNS point `hub.api.surehub.io` at the Mac. A small relay on the Mac
opens a normal connection to the real server and passes the data to the hub at a pace the hub
can take. Encryption stays end-to-end between hub and Sure; the relay only forwards bytes. Once
the check-in succeeds, the hub downloads new firmware (plain HTTP, port 80, also relayed),
reboots, and the new firmware connects directly without help.

Full analysis with packet captures: [docs/how-it-works.md](docs/how-it-works.md).

## What the scripts change on your Mac

All of it is undone by `hub-down.sh`.

| What | Detail |
|---|---|
| Hub port IP | The hub Ethernet port gets `192.168.77.1/24` |
| DHCP | macOS's built-in `bootpd` hands hubs `192.168.77.10-50` on **that port only**. Any existing `/etc/bootpd.plist` is backed up and restored |
| Internet sharing | IP forwarding on, and one NAT rule in its own pf anchor (`com.apple/250.SureHubRescue`). The system's firewall rules are not touched |
| DNS | `dns.py` on `192.168.77.1:53` answers `hub.api.surehub.io` with the Mac and forwards everything else to `1.1.1.1` |
| Relays | `relay.py` on `192.168.77.1:443` and `:80` forwarding to the real `hub.api.surehub.io` |
| Capture | `tcpdump` of the hub port, saved to `captures/` (skip with `sudo env NO_CAPTURE=1 ./hub-up.sh`) |

Your Mac's own internet and the rest of your network are not affected. Only devices plugged
into the hub port use this DNS and relay.

## Privacy

`captures/` contains your hub's serial number, the firmware it downloaded, and packet captures
of its traffic. It is in `.gitignore` - **don't post it publicly**. If you open an issue, share
only the log lines you need, with the serial number removed. The encrypted HTTPS / MQTT traffic
can't be read by this tool. Only the plain-HTTP firmware download is visible.

## Troubleshooting

**`no wired port with a link found`**
The hub isn't detected. Check the cable and that the hub has power. Many adapters have a link
LED. Run `ifconfig` and look for an `enX` with `status: active`, then pass it:
`sudo ./hub-up.sh enX`.

**`status.sh` shows no hub**
Power-cycle the hub after running `hub-up.sh` so it requests a new address. Give it ~30
seconds.

**Stuck at "asked for hub.api.surehub.io" with no check-in**
Something on the Mac may be blocking incoming connections to Python. Check *System Settings >
Network > Firewall*. If it's on, allow incoming connections for `python3`, or turn it off during
the rescue. Check `captures/relay443.log` for errors.

**VPNs (Cloudflare WARP, NordVPN, corporate VPNs)**
The rescue worked with Cloudflare WARP and NordVPN installed. If the hub gets an address but
nothing goes through, try disconnecting the VPN during the rescue.

**Check-in works but there is no firmware download and no cloud connection**
Your hub may have a different problem than this one (e.g. it was removed from your account, or
it's faulty). Open an issue with your `status.sh` output.

**I use Internet Sharing already**
Turn off macOS Internet Sharing during the rescue. Both use `bootpd`. `hub-down.sh` restores
your previous `bootpd.plist`.

### Confirming the diagnosis (optional)

After `hub-up.sh`, before the hub gets anywhere, the capture shows the tell-tale pattern. Run
this from the repository folder:

```bash
tcpdump -r captures/hub-*.pcap -n 'tcp port 443' | head -30
```

Look for the hub advertising `win 1200`, the server sending more than that, the hub replying
`win 0`, and the server immediately sending `[R]` (reset). With the relay in place this pattern
disappears.

## Other platforms (untested)

The trick is generic. On a Linux box or a router running OpenWrt / dnsmasq you could:

1. Make the hub's DNS return your box's IP for `hub.api.surehub.io`, e.g. dnsmasq
   `address=/hub.api.surehub.io/192.168.1.2`.
2. Relay TCP 443 and 80 to the real server, e.g.
   `socat TCP-LISTEN:443,fork,reuseaddr TCP:hub.api.surehub.io:443` (same for 80). Make sure the
   relay box itself resolves `hub.api.surehub.io` through a resolver that is **not** overridden,
   or it will loop back to itself.

If you get this working on another platform, a PR with instructions is very welcome.

## Files

| File | Purpose |
|---|---|
| `hub-up.sh` | Start: network, DHCP, NAT, DNS, relays, capture |
| `status.sh` | Show progress per hub (no sudo) |
| `hub-down.sh` | Undo everything |
| `dns.py` | Minimal DNS responder (stdlib only) |
| `relay.py` | Minimal TCP relay (stdlib only) |
| `docs/how-it-works.md` | Detailed analysis with packet evidence |

## License

MIT - see [LICENSE](LICENSE).
