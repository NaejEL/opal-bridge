# opal-bridge

Turn a stock **GL.iNet Opal (GL-SFT1200)** into a dual-personality device — no reflash, one package:

| Switch position | Personality | What you get |
| --- | --- | --- |
| **Toward the dot** (the side of the reset button) | **BRIDGE** | True layer-2 WiFi→Ethernet bridge: wired clients get DHCP **from your main router**, live in the same subnet, receive broadcast/mDNS. What the stock firmware calls "Repeater" is WISP (NAT + isolated subnet) — this is the real thing. |
| **Away from the dot** | **ROUTER** | Untouched stock GL.iNet behavior: WISP repeater, wired WAN, local AP, `192.168.8.1` dashboard. The travel mode. |

The physical slide switch selects the mode: it is read **at boot**, and flipping it **while running** switches modes live (no reboot). Zero hardcoded IPs — the bridge discovers whatever subnet the upstream WiFi hands out and adapts, including when you move between networks (home box, phone hotspot, hotel AP).

## The LED speaks

| LED | Meaning |
| --- | --- |
| off | unknown / booting / transition starting |
| blue blinking | bridge converging (subnet discovery, ~30–60 s) |
| **blue solid** | **bridge OK** |
| white blinking | switching to router mode |
| **white solid** | **router OK** |
| blue/white fast alternating | bridge failed (no free IPs on the subnet) |

## Install

On a fresh/stock Opal, first do the usual initial setup: browse to
`http://192.168.8.1`, set the admin password, and join your upstream WiFi from
the **Repeater** page (the install needs Internet access). Then — SSH is not
usable out of the box — go to **System → Advanced Settings** and install
**LuCI**; from that point on SSH and scp accept `root` + your admin password.

1. Download `opal-bridge_<version>_all.ipk` from [Releases](../../releases).
2. Copy it to the Opal and install (from a machine on the Opal's network — stock address is `192.168.8.1`):

   ```sh
   scp -O -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedKeyTypes=+ssh-rsa \
       opal-bridge_*.ipk root@192.168.8.1:/tmp/
   ssh -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedKeyTypes=+ssh-rsa \
       root@192.168.8.1 "opkg update && opkg install /tmp/opal-bridge_*.ipk"
   ```

   > The `ssh-rsa` options are required: the Opal's old Dropbear offers no newer
   > host-key algorithm, and recent OpenSSH clients refuse it by default.
   > The `opkg update` matters on a stock device: `relayd` (our dependency) is
   > pulled from the GL.iNet feed, which needs fresh package lists — so the Opal
   > must have Internet access (upstream WiFi joined) when you install.

3. **Set the slide switch** to the mode you want and **reboot**. Done — the switch now drives the device, at boot and live.

Install on a **stock-configured** device (router mode, upstream WiFi already joined via the GL.iNet "Repeater" page): the installer captures your router configuration at that moment and restores it every time you flip back.

### Optional: the `opal.local` alias

With mDNS you never have to hunt for the management IP again — `http://opal.local` reaches the dashboard in both modes, on any subnet:

```sh
ssh -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedKeyTypes=+ssh-rsa \
    root@192.168.8.1 "opkg update && opkg install avahi-nodbus-daemon && /usr/lib/opal-bridge/setup-mdns"
```

## Everyday use

- **Flip the switch** — that's it. Bridge→router completes in seconds; router→bridge converges in ~30–60 s (watch the LED).
- After a mode change, wired clients keep their old DHCP lease until they renew: unplug/replug the cable (or `ipconfig /renew`). This is a hardware limitation — the Ethernet PHYs cannot be bounced in software on this SoC.
- Finding the Opal in bridge mode: `http://opal.local`, or the **top of the subnet** (last free IPs below the broadcast address, e.g. `.253`/`.254` on a `/24`), or read it from the device: `cat /etc/opal-mode/bridge-state`.
- Status from SSH:

```text
# opal-mode status
mode    : bridge (switch: bridge)
subnet  : 192.168.1.0/24
lan ip  : 192.168.1.253   relay ip : 192.168.1.252
relayd  : running
nat     : hairpin exemption present
```

`opal-mode bridge` / `opal-mode router` switch modes from the CLI (hot; add `--reboot` to reboot instead).

## Troubleshooting

| Symptom | What it means / what to do |
| --- | --- |
| LED alternating blue/white | No free IPs found on the upstream subnet (or subnet too small). Check the upstream network, then `ifdown wwan; ifup wwan` or reboot. |
| Wired client stuck with an old address after a mode flip | Expected — replug the cable or renew the lease. |
| `opal.local` not resolving on one PC while other devices resolve it | Local resolver issue on that PC (VPN LAN-discovery settings, stale mDNS cache) — the Opal side answers fine. Use the IP meanwhile. |
| `console.gl-inet.com` unreachable in bridge mode | Expected: that name only exists when the Opal is your DNS server (router mode). In bridge mode use `http://opal.local` or the IP — LuCI is at `http://<ip>/cgi-bin/luci`. |
| "Bad Gateway" from the web UI right after a mode change | Services are still settling during convergence. Wait for the solid LED, then reload. |
| Bridge briefly loses 1–2 pings right after boot or an uplink change | relayd warm-up while it relearns hosts; settles within seconds. |
| Everything broken, want stock back | `opkg remove opal-bridge` — restores the stock configuration and services. |

## What it is — and isn't

- **IP-transparent L2 bridge**: wired clients get DHCP from the upstream router, live in its subnet, receive broadcast/mDNS. That's what the stock firmware cannot do.
- Against ordinary upstream APs (ISP boxes, hotels): **not MAC-transparent** — like every non-WDS WiFi bridge, traffic crosses the WiFi link with the Opal's own MAC, so the main router's device list shows one device holding several IPs. Per-client DHCP leases and **MAC reservations still work** (the real client MAC travels inside the DHCP payload).
- **Against a WDS-capable upstream AP (e.g. OpenWrt with `option wds '1'`): full MAC transparency** — see below.

## WDS mode (experimental): real MAC passthrough

When your upstream AP accepts 4-address clients, opal-bridge can replace the
relay with a **true kernel L2 bridge over WiFi** — wired clients appear
upstream with their **real MAC addresses**, exactly as if they were cabled.
Yes, on the very hardware whose vendor flag says `nowds`.

Try it once per network, from SSH (~1 min of disruption, falls back safely):

```sh
opal-mode wds-try
```

On success the verdict is cached: from then on, **every convergence on that
network upgrades itself to WDS automatically** (boot, reconnection, subnet
change — no interaction). On failure the device stays on the universal relay
path, and unknown networks always start there — hotels and ISP boxes behave
exactly as before. `opal-mode status` tells you which path is active. The
WDS engine picks the band deterministically (5 GHz first when viable),
re-evaluates it periodically on the idle radio, and falls back to the relay
path if the link cannot be recovered.

## Under the hood

Technical documentation lives in [`docs/`](docs/):

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — how the whole thing works: the hairpin-NAT root cause, dynamic subnet discovery, the mode state machine, boot ordering, the LED controller, the hardware facts (and traps) of this SoC.
- [`docs/TUTORIAL.md`](docs/TUTORIAL.md) — the original step-by-step **manual** setup (the package automates all of it), kept for the full story, performance expectations and limitations.

## Compatibility

GL-SFT1200 (Opal) on stock GL.iNet firmware (vendor OpenWrt 18.06, kernel 4.14). Nothing is reflashed; `opkg remove opal-bridge` returns the device to stock.
