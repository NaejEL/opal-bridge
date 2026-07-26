# opal-bridge — architecture and hardware notes

Everything here was established **on the device** (GL-SFT1200, vendor OpenWrt 18.06,
kernel 4.14.90, busybox 1.29.3 ash). Where a mechanism was discovered the hard way,
the dead ends are documented too — so nobody walks into them again.

## 1. The bridge core

The stock "Repeater" is WISP: NAT plus an isolated `192.168.8.0/24`. The bridge
personality replaces it with `relayd` (proxy-ARP + per-host routes; the kernel
forwards unicast, TTL is decremented — that TTL is also how you can *prove* traffic
crosses the Opal).

**The root cause that cost three days:** the stock firewall has `masq='1'` on the
wan zone, which includes the WiFi client interface. Hairpin flows (wired LAN →
same-subnet WiFi side — exactly what a bridge produces) got MASQUERADEd to the
Opal's own WAN IP; the return de-NAT broke (INVALID → dropped by the "Prevent NAT
leakage" rule). Whether a boot "worked" was a race over which path captured each
flow first, which made the failure look random and immune to timing fixes. The fix
is one architecturally-correct rule — never masquerade traffic that stays inside
the local subnet:

```sh
iptables -t nat -I zone_wan_postrouting 1 -d <SUBNET> -j ACCEPT
```

**fw3 erases that rule after every interface ifup.** The hotplug script therefore
re-installs it on every wwan ifup and runs a 3-minute guard loop re-checking every
10 s. A reload can still catch the few-second window between an ifup and the next
guard tick — observed live, self-heals at the next tick.

Dead ends (do **not** revisit): rp_filter (already 0), conntrack/neigh flushes,
disabling `flow_offloading` (makes it *worse* — leave at 1), blacklisting the
`sfhnat` module, timing barriers. The full saga: [TUTORIAL.md](TUTORIAL.md).

## 2. Dynamic subnet discovery (the V2 hotplug script)

`files/etc/hotplug.d/iface/99-relayd-bridge`, fired on every `wwan` ifup:

- Reads the sta interface's DHCP lease (`ip -4 addr` + `ipcalc.sh`) — the WiFi
  client interface is `sta0` *or* `sta1` and the name changes between boots
  (`gl-repeater` destroys/recreates interfaces at will), so it always uses the
  interface netifd reports, never a stored name.
- Derives two service IPs from the **top of the subnet** (management LAN IP and
  relayd's `-L` address), using 32-bit integer math bounded inside
  `(NETWORK, BROADCAST)` — works on any prefix, bails out below 4 usable hosts.
- Verifies each candidate free with `arping` on **both** segments (staX *and*
  br-lan): until relayd bridges them, the wired side is a separate L2 domain and a
  wired host squatting the candidate would be invisible from the WiFi side.
- Persists `SUBNET/LAN_IP/RELAY_IP` in `/etc/opal-mode/bridge-state`; on a known
  subnet it reuses them (fast path), on a new subnet it re-picks.
- Re-addresses `lan` when the **runtime** br-lan address differs from the target
  (comparing against uci is not enough — config and runtime can drift apart).

**netifd gotcha (verified):** only `ubus call network reload` makes netifd re-read
committed uci config. An interface down/up re-applies the **stale in-memory**
config — the trace says "re-addressed" while br-lan still holds the old IP. Note
`/sbin/ifup` triggers an implicit reload, which can mask the bug in tests.

Residual risk, accepted: the upstream DHCP server may later lease a service IP to
another client (pools rarely reach the top of the subnet; arping verified them free
at pick time).

## 3. The mode state machine

`files/usr/bin/opal-mode` — `{bridge|router|status|apply-boot}`, all mutations
under `flock` on a dedicated `/var/lock/opal-mode.lock` (**never** reuse
`gl-switch.lock`: the gl-switch hook already runs under it — instant deadlock).

- **Missing `/etc/opal-mode/current` = uninitialized, not "bridge".** A fresh
  install must run `apply_bridge` once, otherwise `dhcp.lan.ignore` is never set
  and dnsmasq becomes a rogue DHCP server on the bridged home LAN.
- `apply_router` restores **only the deltas** bridge mode touches (lan
  ipaddr/netmask read from the snapshot via `uci -c`, plus `dhcp.lan.ignore`) —
  no whole-file copies, so user changes and gl-repeater's wwan section survive.
- The stock snapshot (`/etc/opal-mode/router/`) is captured once at install and
  **refreshed every time the device leaves router mode**, so settings changed in
  router mode survive round-trips.
- Hot bridge→router closes the hotplug entry gate *first* (`current=router`),
  invalidates the guard stamps, kills relayd, applies the deltas, then a +25 s
  janitor sweeps whatever an in-flight hotplug run (its arping scan runs tens of
  seconds) may have re-created behind it.
- Hot router→bridge is just: `dhcp.lan.ignore=1`, `current=bridge`, `ifup wwan` —
  the validated hotplug path does the rest.

### Boot ordering

`files/etc/init.d/opal-mode`, `START=15` — before dnsmasq/firewall (19) and
network (20): `apply-boot` reads the switch GPIO and applies the right config
**before any consumer starts**. Fail-safe: unreadable GPIO keeps the current mode.

### The slide switch

GPIO 1, label `switch` in `/sys/kernel/debug/gpio`. Verified mapping:
**hi → "released" → gl-switch action `off`; lo → "pressed" → `on`** (yes,
inverted-looking — hi is BRIDGE by user convention). Two traps, both verified:

- The debugfs line carries **trailing spaces** after `hi`/`lo` — match
  `*" hi"*`, never `*hi` anchored at end-of-string.
- The input layer **replays the switch position ~1 min after boot** as a real
  gl-switch event. `apply-boot` touches `/tmp/opal-mode.boot-done` and the hook
  exits when the sentinel is absent; mode idempotence catches the rest. Without
  both guards, a switch moved while powered off could reboot the device mid-rcS.

Hook wiring: `uci set switch-button.@main[0].func='bridgemode'` +
`/etc/gl-switch.d/bridgemode.sh`. The GL dispatcher's guard rails only apply to
its own known functions — unknown ones pass straight through.

## 4. The LED

`/sys/class/leds` is **empty** on the sft1200: the LED is an **I2C controller at
0x30 on bus 0**, driven through GL's `gl_i2c_led` (solid/flash/breath, blue/white/
both, three flash speeds). The stock `gl_led` daemon rewrites the LED every 2 s
from WAN status — the package disables it permanently (like the stock relayd
managers) and `opal-led` owns the LED with the state language from the README.

> **⚠ The controller is write-only and fragile.** A single read attempt (`i2cget`,
> `i2cdetect -r`) wedges the whole I2C bus: every subsequent write fails, the LED
> freezes, and only a **power cycle** recovers it. Verified the hard way. Also:
> a controller reset (`0x00 0x1F`) clears the per-channel brightness registers
> `0x06`/`0x07` — restore them (`0x0a` each) or the LED misbehaves.

## 5. mDNS (`opal.local`)

`avahi-nodbus-daemon` from the GL feed works. Recipe (shipped as
`/usr/lib/opal-bridge/setup-mdns`): hostname `opal`, `allow-interfaces=br-lan`
in `avahi-daemon.conf` (otherwise the staX address is announced too and clients
may resolve to the wrong side), enable + start. Avahi follows br-lan across mode
flips and subnet changes on its own.

**Dead end — do not revisit:** `umdns` (16 KB, tempting) installs but never
initializes on this vendor build: no ubus registration, nothing bound on 5353,
epoll-sleeping on a single socket forever, no error anywhere, `jail=0` changes
nothing. Almost certainly an ABI mismatch with GL's libubox/libubus.

## 6. Packaging

`build.sh` → `build/opal-bridge_<ver>_all.ipk` (format:
`tar.gz{debian-binary, control.tar.gz, data.tar.gz}`; `Architecture: all` is
accepted by the vendor opkg). Everything in `ipk/postinst` is idempotent —
verified by installing over a hand-configured device.

- **opkg cannot be called from a postinst** (the install lock is held) — that is
  why avahi is detected on the filesystem and `setup-mdns` prints the manual
  recipe instead of installing it.
- `prerm` returns the device to router mode **by design** — an uninstall (or
  `--force-reinstall`) from a wired client will move the management IP mid-
  operation and drop your SSH session. opkg finishes on its own; plan for it.
- Stock things the package neutralizes (postinst) and restores (postrm):
  `/etc/init.d/relayd` + `30-relay` hotplug (they fight the bridge), `gl_led`.

## 7. Device access & recovery

- SSH: old Dropbear, `ssh-rsa` only (`-o HostKeyAlgorithms=+ssh-rsa
  -o PubkeyAcceptedKeyTypes=+ssh-rsa`); key goes in
  `/etc/dropbear/authorized_keys`.
- Power-cycle restores the last committed uci config; 10 s reset = factory.
- Serial: 3.3 V UART pads, 115200 8N1. U-Boot TFTP recovery: hold reset at boot,
  `192.168.1.1`.

## 8. MAC transparency and the 4addr investigation

relayd rewrites L2: every frame on the WiFi link carries the Opal's MAC
(802.11 3-address rule — a client cannot transmit foreign source MACs), while
the DHCP relay preserves `chaddr`, which is why per-client leases and MAC
reservations on the upstream router keep working. The upstream's device list
lumping everything under one MAC is cosmetic and structural, not fixable
within relayd.

True MAC passthrough = 4addr (modern WDS) on both ends, which would also make
relayd unnecessary (the sta joins br-lan directly). Probed on device
(2026-07-26):

- `/proc/gl-hw-info/nowds` = 1 — GL hides their WDS mode on this hardware.
- `iw phy`: managed / AP / **AP-VLAN** / monitor / P2P (AP-VLAN = the 4addr-AP
  plumbing exists in the stack); legacy `wds` iface type → `Not supported`.
- Creating a **managed VIF with `4addr on` succeeds on both radios** — more
  promising than GL's flag suggests. `set 4addr on` on the live sta returns
  EBUSY (interface must be down/fresh, and gl-repeater owns it).
- Untested beyond that: association and data path need an AP that accepts
  4addr clients (OpenWrt `option wds '1'`); ISP boxes don't. ESP32 SoftAP
  can't either (no WDS in ESP-IDF) — an ESP32 in promiscuous mode could at
  least verify 4-address frame emission.

## 9. Test protocol (what "works" means)

Single ping from a wired client to the upstream gateway — **never two pings in
parallel** (Windows shares one sequence counter across targets; interleaved
output once faked a "1 of 2 lost" pattern that cost a full day). Success =
clean ping within ~2 min of boot, surviving `ifdown wwan; sleep 3; ifup wwan`,
and after moving to a different-subnet network. Bridge health signature (tcpdump
on staX): healthy = frames leave with client source IPs preserved; broken = only
NATed (wwan IP) sources. TTL 63 from the gateway proves the path crosses the
Opal (64 would be a direct path).
