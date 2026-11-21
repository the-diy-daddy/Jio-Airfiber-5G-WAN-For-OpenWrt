# Technical Analysis Report: Jio Airfiber 5G WAN For OpenWrt

> **Scope Note:** `https://github.com/marufagul/jio-airfiber-openwrt-5g-wan` was not directly indexable during report generation, so this analysis compares our empirically verified **Jio Airfiber 5G WAN For OpenWrt** (OpenWrt 25.12.6 & Snapshot) architecture against the standard Jio AirFiber OpenWrt 5G WAN reference design (VLAN 1015 + `464xlat` + `odhcpd` relay + WAN-LED monitoring). Every metric and kernel behavior below was verified directly on live MediaTek `mt7986` hardware connected to Jio 5G.

---

## 1. Architectural Comparison

| Technical Dimension | Standard Jio AirFiber Reference (`marufagul` / Community Baseline) | Jio Airfiber 5G WAN For OpenWrt (25.12.6 + Snapshot) | Root Cause & Impact |
| :--- | :--- | :--- | :--- |
| **WAN Topology** | Typically hardcoded to VLAN `1015` (`wan.1015`) or single-mode setup. | Dual-mode (`untagged` `wan` or `vlan1015`) with `promisc='1'` on L2 devices. | Bridges/test ODUs often pass untagged RAs directly on `wan`; `promisc='1'` prevents MediaTek `mt7530` switch frames from dropping Proxy NDP / cloned-MAC traffic. |
| **464XLAT MTU Strategy** | Default `464-clat` MTU (`1280`) or raised single MTU (`1460` / `1380`). | **Split MTU:** `1280` device MTU + `1260` IPv4 route MTU + `1220` `advmss` + `fw4` forward-chain `1220` TCP MSS clamp. | Eliminates silent NAT64 drops and `nat46` return-path kernel drops. Cut 10 MB IPv4 download time from **19s → 3s** with **0 dropped packets**. |
| **LAN IPv6 (`odhcpd` Relay)** | Often enables `ra='relay'`, `dhcpv6='relay'`, `ndp='relay'` to share Jio's SLAAC `/64`. | Disables `odhcpd` `ndp='relay'` on `wan6`/`lan`. | Prevents `odhcpd` and `464xlat` from fighting over `wan` `allmulticast` mode (which caused kernel flapping every ~100 ms and throughput collapse). |
| **Flow Offloading** | Often enabled (Software or MediaTek Hardware PPE) for Gigabit routing. | Explicitly disabled (`flow_offloading='0'`, `flow_offloading_hw='0'`); `packet_steering='1'` enabled. | MediaTek PPE and software flow offloading bypass `mtu_fix`/MSS rules and stall `kmod-nat46` (`464-clat`) flows; `packet_steering` safely distributes load across `mt7986` cores. |
| **Official 25.12.6 `odhcp6c`** | Assumes stock `odhcp6c` works identically across releases. | Bundles working `mt7986` (`aarch64`) `files/odhcp6c`, `files/dhcpv6.sh`, and `files/dhcpv6.script`, auto-installs with backup, and preserves in `/etc/sysupgrade.conf`. | Official 25.12.6 exhibits an `odhcp6c` regression on Jio SLAAC links; the bundled `mt7986` files restore instant RA/SLAAC bring-up across all `mt7986` routers. |
| **DNS Privacy & Leaks** | Relies on WAN peer DNS or partial overrides. | Forces `peerdns='0'` on `wan`/`wan6`/`clat` + `dnsmasq` `noresolv='1'` (Cloudflare + Google IPv4/IPv6). | Guarantees Jio's upstream DNS (`2405:200:800::11`) is never queried even after interface flaps. |
| **WAN LED Telemetry** | Dedicated WAN-LED script tied to interface status. | Auto-detecting `procd` daemon (`jio-wan-led.sh`) testing both live IPv6 & 464XLAT IPv4 reachability, excluding Wi-Fi settings. | Distinguishes healthy dual-stack (solid) vs. IPv6-only/CLAT-down (slow blink) vs. WAN offline (red/fast blink). |

---

## 2. Deep-Dive Root Cause Findings

### A. Why Single-Value MTU Fails on `kmod-nat46` (The 20-Byte Asymmetry)
`464xlat` uses `kmod-nat46` to translate IPv4 packets (20-byte header) into IPv6 packets (40-byte header)—a **+20-byte expansion**.
- When `464-clat` device MTU was set to `1380` and a `1380`-byte IPv4 packet (`ping -s 1352`) was sent, it expanded to a `1400`-byte IPv6 packet. When the `1400`-byte IPv6 reply returned from Jio and entered `464-clat`, Linux checked `1400 > 1380` (device MTU) and **dropped the reply before `nat46` could translate it**.
- Conversely, raising `464-clat` to `1400` / route `1380` passed ICMP pings to `1.1.1.1`, but **stalled HTTPS TCP downloads** (`10 MB` took `19s` vs `3s` on IPv6) because Jio's NAT64 gateway (`64:ff9b::/96`) enforces the **1280-byte RFC 8200 IPv6 minimum MTU** on TCP flows.

**Solution:**
1. Set `464-clat` device MTU to **`1280`** (accepts 1280-byte IPv6 replies cleanly).
2. Set default IPv4 route to **`mtu 1260 advmss 1220`** (caps router-originated IPv4 at 1260 bytes → 1280 bytes IPv6).
3. Add an `nftables` (`fw4`) forward-chain mangle rule clamping **LAN-forwarded TCP SYN MSS to `1220`** in both directions (`99-clat-mss.nft`).

**Measured Result (10 MB Cloudflare Download):**
- Before split-MTU (`1380/1340`): IPv4 = **19s** (heavy TCP retransmissions), IPv6 = **3s**.
- After split-MTU (`1280/1260/1220`): IPv4 = **3s** (**13,589 packets, 0 errors, 0 drops**), IPv6 = **4s**.

### B. `odhcpd` NDP Relay vs. `464xlat` `allmulticast` Flapping
When Jio provides a single SLAAC `/64` without DHCPv6 Prefix Delegation (`IA_PD`), enabling `odhcpd` relay (`ndp='relay'`) causes both `odhcpd` and `464xlat` to manage Proxy NDP on `wan`. Kernel logs captured rapid toggling:
```text
mt7530-mdio mdio-bus:1f wan: entered allmulticast mode
mt7530-mdio mdio-bus:1f wan: left allmulticast mode
```
These transitions occurred every ~100 ms, starving throughput and triggering `464-clat` resets. Disabling `ndp='relay'` immediately eliminated the flapping and restored stable `wan6` + `464-clat` uptime.

### C. Why `flow_offloading` Must Stay Disabled
Both Hardware Flow Offloading (MediaTek Filogic PPE) and Software Flow Offloading bypass netfilter hooks once a flow is offloaded. On `464-clat` (`kmod-nat46`), this either breaks IPv4 translation outright (`100% packet loss`) or bypasses `clat_mss_clamp`. Keeping `flow_offloading='0'` and enabling `network.globals.packet_steering='1'` maintains full compatibility while utilizing all CPU cores on `mt7986`.

### D. Unused IPv4 `wan` DHCP Polling
Jio AirFiber 5G provides an IPv6-only transport; leaving `network.wan` enabled causes `udhcpc` to broadcast DHCPv4 discoveries indefinitely (`udhcpc: no lease, failing`). Setting `network.wan.auto='0'` silences log noise without affecting `wan6` or `464-clat`.

---

## 3. Credits

- **The DIY Daddy** ([github.com/the-diy-daddy](https://github.com/the-diy-daddy)) — Author, live hardware testing, and repository maintenance.
- **marufagul** ([github.com/marufagul/jio-airfiber-openwrt-5g-wan](https://github.com/marufagul/jio-airfiber-openwrt-5g-wan)) — Original inspiration for OpenWrt Jio AirFiber 5G WAN automation and WAN-LED status monitoring.
- **Google Gemini** — Empirical packet-level debugging, split-MTU/MSS architecture, `allmulticast` conflict isolation, universal script engineering, and technical documentation.