# GL.iNet Opal (GL-SFT1200) — Turn It Into a True Layer-2 WiFi-to-Ethernet Bridge

> **Note:** this is the original **manual** route, kept for the full story and as
> reference. The [opal-bridge package](../README.md) automates everything below —
> plus dynamic subnet discovery (no hardcoded IPs), the physical mode switch, LED
> feedback and `opal.local`. Install the package unless you specifically want to
> build the setup by hand. Current internals: [ARCHITECTURE.md](ARCHITECTURE.md).

This guide converts the Opal from its stock "Repeater" mode (which is actually WISP: NAT + a separate subnet) into a **transparent L2 bridge** using `relayd`. When done, devices plugged into the Opal's Ethernet ports will:

- receive IP addresses from your main router's DHCP server,
- live in the same subnet as every other device on your network,
- receive broadcast/multicast traffic (UDP discovery, mDNS, etc.),
- be reachable from anywhere on your LAN.

> **Why this guide exists:** the Opal's web UI offers no real bridge mode. Its "Repeater" mode routes and NATs, putting wired clients on an isolated subnet (`192.168.8.0/24` by default). The Siflower SoC also runs a vendor OpenWrt 18.06 that is missing the `relayd` netifd integration, the GL.iNet `gl-repeater` daemon destroys/recreates the WiFi client interface at boot with an unpredictable name (`sta0` or `sta1`), and a proprietary hardware-NAT engine (`sfhnat`) races against `relayd` during boot. This guide works around all of that.

> **The honest contract:** the bridge comes up clean within ~1–2 minutes of boot (the time the WiFi client associates and the hotplug fires), and stays clean. Apart from a few lost packets during the association window, there is no degraded phase — the root cause of the historical instability (hairpin NAT, see Gotcha 2) is fixed by a one-line firewall exemption.

---

## What you need

- A GL.iNet Opal (GL-SFT1200), any recent stock firmware
- The SSID and password of the upstream WiFi network (your main router)
- The upstream router's subnet (this guide uses `192.168.1.0/24` as an example — **adapt every `192.168.1.x` address to your own network**)
- Two free IP addresses in that subnet, outside the DHCP pool if possible (examples here: `192.168.1.2` and `192.168.1.3`)
- A computer with SSH

---

## Step 1 — Initial setup out of the box

1. Power the Opal, connect to its default WiFi (SSID printed on the bottom) or plug your computer into a **LAN** port.
2. Browse to `http://192.168.8.1`, set an admin password.
3. In the GL.iNet dashboard, use **Repeater** mode to connect the Opal to your upstream WiFi (select SSID, enter the password). Yes, this is the NAT mode we're about to bypass — but it conveniently stores the WiFi credentials and manages the radio connection for us.
4. Confirm the Opal has Internet access.

## Step 2 — Install LuCI, enable SSH and log in

The advanced OpenWrt web interface (LuCI) is not installed by default on the Opal — the GL.iNet dashboard offers it as an optional install. Go to **System → Advanced Settings** in the GL.iNet dashboard and follow the prompt to install LuCI (requires Internet access, which you have from Step 1). It then becomes reachable at `http://192.168.8.1/cgi-bin/luci` with the same admin password. LuCI is not strictly required for this guide (everything is done over SSH), but it's useful for inspecting interfaces and logs, and installing it now avoids a chicken-and-egg problem later if the bridge misbehaves.

SSH is enabled by default with the admin password:

```sh
ssh root@192.168.8.1
```

If your SSH client refuses to connect (`no matching host key type found: ssh-rsa`), the Opal's old Dropbear only offers `ssh-rsa`. Force it:

```sh
ssh -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedKeyTypes=+ssh-rsa root@192.168.8.1
```

Consider adding a host entry to `~/.ssh/config` so you don't retype this:

```
Host opal
    HostName 192.168.1.2
    User root
    HostKeyAlgorithms +ssh-rsa
    PubkeyAcceptedKeyTypes +ssh-rsa
```

## Step 3 — Install relayd

```sh
opkg update
opkg install relayd
```

Note: on this firmware, `relayd` ships **without** the netifd proto script (`/lib/netifd/proto/relay.sh` does not exist), so the usual UCI `proto 'relay'` interface configuration will silently fail (`ifstatus` shows `NO_DEVICE`). Don't bother with it — we will run `relayd` directly. The `luci-proto-relay` package does not help either; it only contains LuCI UI files.

## Step 4 — Re-address the LAN into the upstream subnet

The Opal's `lan` (the bridge holding the Ethernet ports) must get an IP **inside the upstream subnet**, and its local DHCP server must be disabled so it stops competing with your main router.

```sh
# Management IP for the Opal itself (adapt to your subnet)
uci set network.lan.ipaddr='192.168.1.2'
uci set network.lan.netmask='255.255.255.0'

# Disable the local DHCP server on lan
uci set dhcp.lan.ignore='1'

uci commit network
uci commit dhcp
/etc/init.d/network restart
```

**Your SSH session will drop.** Reconnect on the new address:

```sh
ssh root@192.168.1.2
```

Two useful facts at this point:

- The WiFi client interface (managed by GL.iNet's `gl-repeater`) gets its own DHCP lease from the upstream router. If you reserve an IP for the Opal's WiFi MAC on your main router, that reservation applies to this interface — not to `192.168.1.2`.
- If you ever lock yourself out, a power-cycle restores the last committed UCI config; a 10-second reset-button press restores factory defaults. The board also has a serial header (115200 8N1, 3.3 V) as a last resort.

## Step 5 — Understand the two gotchas before automating

**Gotcha 1 — the interface name is not stable.** The WiFi client interface is named `sta0` *or* `sta1`, and the name can change between reboots because `gl-repeater` destroys and recreates interfaces during its startup sequence. Any script must detect the active one (the one holding an `inet` address) instead of hardcoding it.

**Gotcha 2 — the real killer: hairpin NAT.** How this bridge actually works: relayd does proxy-ARP (wired clients resolve every WiFi-side IP to the Opal's own MAC) and installs per-host routes; the **kernel** then forwards the unicast traffic (you can verify: TTL is decremented). But the stock firewall has `masq='1'` on the wan zone, which includes the WiFi client interface. So forwarded client traffic toward the *WiFi-side subnet itself* (the hairpin case — same subnet on both sides, exactly what a bridge produces) gets **masqueraded to the Opal's own WAN IP**, and the return de-NAT of that hairpin flow breaks (packets classed INVALID and dropped by the wan zone's "Prevent NAT leakage" rule). Symptom: wired clients reach the Internet fine, but pinging the upstream router or any WiFi-side host loses most or all packets. Whether a given boot ended up working was a race over which path captured each flow first — which is why the failure looked random and resisted every timing-based fix.

The definitive fix is a one-line exemption — never masquerade traffic that stays inside the local subnet (which is architecturally correct for a bridge anyway):

```sh
iptables -t nat -I zone_wan_postrouting 1 -d 192.168.1.0/24 -j ACCEPT
```

**Gotcha 3 — fw3 erases the fix on every reload.** The GL.iNet firmware reloads the firewall (`fw3`) after every interface event, rebuilding the zone chains and silently discarding the exemption rule. The hotplug script below therefore re-installs the rule on every ifup *and* runs a 3-minute guard loop that re-checks it every 10 s (an `iptables -C` probe is nearly free). Related warning: leave `firewall.@defaults[0].flow_offloading` / `flow_offloading_hw` at their stock value of `1` — disabling them makes things worse, not better.

## Step 6 — Hotplug script: relaunch relayd on every WiFi (re)connection

This is the core of the setup. Every time the WiFi client interface comes up — at boot, after a reconnection, after a band change — the script installs the hairpin-NAT exemption, relaunches `relayd` on the interface netifd reports, starts a 3-minute guard that re-installs the NAT rule if an fw3 reload erases it, and schedules one safety relaunch at +2 minutes (self-cancelling if a newer ifup occurs).

Create `/etc/hotplug.d/iface/99-relayd-bridge`:

```sh
cat > /etc/hotplug.d/iface/99-relayd-bridge << 'EOF'
#!/bin/sh
# L2 bridge: relayd + masquerade exemption for intra-subnet (hairpin) traffic.
# Root cause of instability: wan-zone MASQUERADE applied to hairpin flows
# (wired LAN -> same-subnet WiFi side); return de-NAT broke (INVALID/DROP).
# fw3 reload (triggered after every ifup) erases the rule -> guard loop.
[ "$INTERFACE" = "wwan" ] || exit 0
[ "$ACTION" = "ifup" ] || exit 0
STA_IF="$DEVICE"
[ -z "$STA_IF" ] && exit 0
STAMP=$(date +%s)
echo "$STAMP" > /tmp/relayd.lastevent

ensure_nat_rule() {
    iptables -t nat -C zone_wan_postrouting -d 192.168.1.0/24 -j ACCEPT 2>/dev/null || \
        iptables -t nat -I zone_wan_postrouting 1 -d 192.168.1.0/24 -j ACCEPT 2>/dev/null
}

relaunch() {
    kill $(pgrep relayd) 2>/dev/null
    sleep 1
    ( /usr/sbin/relayd -I br-lan -I "$1" -L 192.168.1.3 -B -D > /tmp/relayd.log 2>&1 & )
    echo "$(date) relayd relaunched on $1 ($2)" >> /tmp/relayd-bridge.trace
}

sleep 2
ensure_nat_rule
relaunch "$STA_IF" "immediate"

# 3-minute guard: re-install the NAT rule if an fw3 reload wipes it
(
    i=0
    while [ $i -lt 18 ]; do
        sleep 10
        [ "$(cat /tmp/relayd.lastevent 2>/dev/null)" = "$STAMP" ] || exit 0
        ensure_nat_rule
        i=$((i+1))
    done
) &

# Safety net: one relayd retry at +2 min, self-cancelled by any newer ifup
(
    sleep 120
    [ "$(cat /tmp/relayd.lastevent 2>/dev/null)" = "$STAMP" ] || exit 0
    ip addr show "$STA_IF" 2>/dev/null | grep -q "inet " || exit 0
    relaunch "$STA_IF" "retry-1"
) &
EOF
chmod +x /etc/hotplug.d/iface/99-relayd-bridge
```

What the `relayd` flags mean:

| Flag | Purpose |
|---|---|
| `-I br-lan` | first bridged interface: the Ethernet ports |
| `-I <staX>` | second bridged interface: the WiFi client uplink |
| `-L 192.168.1.3` | local address relayd uses to reach the bridge itself (pick a free IP) |
| `-B` | forward broadcasts (needed for UDP discovery, DHCP broadcasts) |
| `-D` | forward DHCP (lets wired clients get leases from the upstream router) |

## Step 7 — Disable the stock relayd managers

The relayd *package* ships an init service and a hotplug script that restart relayd with the (broken) UCI configuration on every interface event, fighting your setup. Neutralize both:

```sh
/etc/init.d/relayd disable
/etc/init.d/relayd stop 2>/dev/null
mv /etc/hotplug.d/iface/30-relay /root/30-relay.bak   # package hotplug, restarts relayd on ANY iface event
```

Also add the NAT exemption to `/etc/rc.local` (before `exit 0`) as a belt-and-braces for early boot:

```sh
iptables -t nat -C zone_wan_postrouting -d 192.168.1.0/24 -j ACCEPT 2>/dev/null || \
    iptables -t nat -I zone_wan_postrouting 1 -d 192.168.1.0/24 -j ACCEPT 2>/dev/null
```

## Step 8 — Test

Trigger the hotplug path without rebooting:

```sh
ifdown wwan; sleep 3; ifup wwan
sleep 10
cat /tmp/relayd-bridge.trace
ps | grep relayd
```

Then from a computer plugged into an Opal **LAN** port:

1. Renew DHCP — you should get an address from your **main router's** pool (e.g. `192.168.1.x`, not `192.168.8.x`).
2. `ping` the main router's IP — steady replies, no loss. (~50% loss right after an ifup is the known degraded regime: wait for the delayed kick, at most ~2 minutes.)
3. Ping the wired client from another device on the LAN — it should answer.

Finally, reboot the Opal. Within ~1–2 minutes the ping should be clean and stay clean. Check `cat /tmp/relayd-bridge.trace` (an `(immediate)` entry per ifup) and confirm the NAT rule survived the boot-time fw3 reloads: `iptables-save -t nat | grep 192.168.1.0/24`. Validate with a second reboot.

## Step 9 — Optional polish

- **Turn off the Opal's own WiFi broadcast** (dashboard → WIRELESS) if you only want the wired bridge; it keeps *receiving* the upstream WiFi regardless.
- **Reserve `192.168.1.2` and `192.168.1.3`** (or your equivalents) outside the upstream DHCP pool so nothing collides.
- **Monitoring:** `iwinfo <staX> info` shows the uplink signal (aim for better than −70 dBm; every wall matters more than distance). The stock dashboard doesn't show it in this mode.

---

## Quick troubleshooting table

| Symptom | Likely cause | Fix |
|---|---|---|
| Wired client gets a `192.168.8.x` address | Still in stock WISP/NAT mode, DHCP local server active | Re-do Step 4 |
| Wired clients reach Internet but lose most packets to the upstream router / WiFi-side hosts | Hairpin-NAT: the masquerade exemption rule is missing (fw3 reload erased it, or hotplug didn't run) | `iptables-save -t nat \| grep 192.168.1.0/24`; re-install by hand or `ifdown wwan; ifup wwan`; verify the hotplug script exists and is executable |
| Wired client has Internet but can't reach the main router or LAN peers | relayd not running; traffic is being NATed by the kernel instead | `ps \| grep relayd`, check `/tmp/relayd-bridge.trace` |
| `uci` relay interface shows `NO_DEVICE` | Missing netifd proto script on this firmware | Expected — ignore UCI, use the direct-launch approach of this guide |
| SSH refuses with `ssh-rsa` error | Old Dropbear on the Opal | Add the `HostKeyAlgorithms`/`PubkeyAcceptedKeyTypes` options (Step 2) |
| Locked out after an IP change | Wrong subnet/typo | Power-cycle (restores committed config) or 10 s reset (factory) |

## What performance to expect

Rough orders of magnitude, assuming a good 5 GHz link (the −55/−60 dBm range; check yours with `iwinfo <staX> info`). These are reasoned estimates, not lab numbers — measure your own setup with iperf3 if it matters.

| Path | Expected real-world TCP throughput | Added latency |
|---|---|---|
| Laptop → upstream WiFi directly (decent 2×2 AC/AX client) | ~250–450 Mbps | — |
| Wired client → Opal bridge → upstream WiFi | ~100–250 Mbps | +1–5 ms vs direct WiFi |

Why the bridge is slower than a direct laptop connection:

- **The radio is the same class but the silicon behind it isn't.** The Opal's AC1200 radio peaks at 867 Mbps PHY on 5 GHz (VHT80 2×2), similar to a laptop card — but every bridged packet is then forwarded in **software** by the dual-core 1 GHz MIPS CPU (the proprietary hardware NAT does not accelerate the bridge's hairpin path). CPU, not radio, is usually the ceiling.
- **Antennas and placement.** A laptop's antennas plus your freedom to sit anywhere generally beat a small router parked near an Ethernet drop. Every dB of signal counts double here since the bridge halves nothing but adds its own hop.
- **2.4 GHz fallback hurts.** If `gl-repeater` associates on 2.4 GHz (it switches bands on its own — the `channel` field of `iwinfo` tells you), expect a fraction of the above: HT20 at long range can mean 20–60 Mbps real.

What this means in practice: for the bridge's natural use cases — IoT boards, MQTT, SSH, telemetry, web UIs, moderate file transfers — the bridge is transparent. For sustained large transfers (backups, media libraries) it works but is the slowest link in the chain; a direct connection or wired backhaul will beat it. Latency overhead is small enough for interactive use (SSH, VNC) but this is not a gaming-grade link.

Quick self-measurement: `opkg install iperf3` on the Opal (server) and run `iperf3 -c` from a wired client, then compare with the same test from your laptop on WiFi directly.

## Known limitations

- The bridge is a proxy-ARP relay, not a true 802.11 4-address WDS: exotic non-IP protocols may not traverse it. IPv4, DHCP, broadcast UDP and mDNS work.
- Total throughput is bounded by the WiFi uplink and the modest SoC (fine for IoT, telemetry, SSH, web; don't expect wire-speed gigabit).
- The NAT exemption is re-installed reactively (on ifup + a 3-minute guard); an unexpected fw3 reload outside any interface event could remove it until the next event. None was observed in practice, but if you hit it, any `ifdown wwan; ifup wwan` restores everything.
- The exact firmware component that decides masquerade-vs-exempt on a given boot was never pinned down; this guide makes the exemption unconditional instead, which is the architecturally correct behavior for a bridge anyway.
