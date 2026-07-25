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
| Bridge briefly loses 1–2 pings right after boot or an uplink change | relayd warm-up while it relearns hosts; settles within seconds. |
| Everything broken, want stock back | `opkg remove opal-bridge` — restores the stock configuration and services. |

## Under the hood

Technical documentation lives in [`docs/`](docs/):

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — how the whole thing works: the hairpin-NAT root cause, dynamic subnet discovery, the mode state machine, boot ordering, the LED controller, the hardware facts (and traps) of this SoC.
- [`docs/TUTORIAL.md`](docs/TUTORIAL.md) — the original step-by-step **manual** setup (the package automates all of it), kept for the full story, performance expectations and limitations.

## Compatibility

GL-SFT1200 (Opal) on stock GL.iNet firmware (vendor OpenWrt 18.06, kernel 4.14). Nothing is reflashed; `opkg remove opal-bridge` returns the device to stock.
