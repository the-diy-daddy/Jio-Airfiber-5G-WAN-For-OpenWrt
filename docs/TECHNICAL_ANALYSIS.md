# Technical Analysis Report: Jio Airfiber 5G WAN For OpenWrt

> **Scope Note:** This report documents our empirically verified **Jio Airfiber 5G WAN For OpenWrt** (OpenWrt 25.12.6 & Snapshot) architecture compared against standard Jio AirFiber OpenWrt 5G WAN community baselines (VLAN 1015 + `464xlat` + `odhcpd` relay + WAN-LED monitoring). Every metric and kernel behavior below was verified directly on live MediaTek `mt7986` hardware connected to Jio 5G.

---

## 1. Architectural Comparison

| Technical Dimension | Standard Jio AirFiber Community Baseline | Jio Airfiber 5G WAN For OpenWrt (25.12.6 + Snapshot) | Root Cause & Impact |
| :--- | :--- | :--- | :--- |
| **WAN Topology** | Typically hardcoded to VLAN `1015` (`wan.1015`) or single-mode setup. | Dual-mode (`--untagged` or `--vlan1015`) with deduplicated `wan_dev` (`promisc='1'`). | Bridges/test ODUs often pass untagged RAs directly on `wan`; removing stock anonymous `wan` device entries prevents UCI MAC conflicts while `promisc='1'` stops `mt7530` Proxy NDP drops. |
| **464XLAT Bring-Up & DNS** | Relies on ISP DNS64 `ipv4only.arpa` lookup and default `iface_464xlat`. | Sets `wan6.iface_464xlat='0'` and `clat.ip6prefix='64:ff9b::/96'`. | Prevents duplicate `464-wan6_4` interfaces and lets `464-clat` start cleanly while forcing private non-DNS64 Cloudflare/Google DNS (`noresolv='1'`). |
| **464XLAT MTU Strategy** | Default `464-clat` MTU (`1280`) or raised single MTU (`1460` / `1380`). | **Split MTU:** `1280` device MTU + `1260` IPv4 route MTU + `1220` `advmss` + `fw4` forward-chain `1220` TCP MSS clamp. | Eliminates silent NAT64 drops and `nat46` return-path kernel drops. Cut 10 MB IPv4 download time from **19s → 3s** with **0 dropped packets**. |
| **LAN IPv6 (`odhcpd` Relay)** | Often enables `ra='relay'`, `dhcpv6='relay'`, `ndp='relay'`. | Disables `odhcpd` `ndp='relay'` on `wan6`/`lan`. | Prevents `odhcpd` and `464xlat` from fighting over `wan` `allmulticast` mode (which caused kernel flapping every ~100 ms and throughput collapse). |
| **Flow Offloading** | Often enabled (Software or MediaTek Hardware PPE). | Explicitly disabled (`flow_offloading='0'`, `flow_offloading_hw='0'`); `packet_steering='1'` enabled. | MediaTek PPE and software flow offloading bypass `mtu_fix`/MSS rules and stall `kmod-nat46` (`464-clat`) flows; `packet_steering` safely distributes load across `mt7986` cores. |
| **Official 25.12.6 `odhcp6c`** | Assumes stock `odhcp6c` works identically across releases. | Auto-installs working `mt7986` (`aarch64`) `odhcp6c`, `dhcpv6.sh`, and `dhcpv6.script` (`chmod 0755`), restarts `netifd`, backs up originals, and registers in `/etc/sysupgrade.conf`. | Official 25.12.6 exhibits an `odhcp6c` regression on Jio SLAAC links; `0755` permissions on `/lib/netifd/proto/dhcpv6.sh` and `network restart` ensure `netifd` registers `dhcpv6` cleanly without LuCI errors. |
| **WAN LED Telemetry** | Dedicated WAN-LED script tied to interface status. | Auto-detecting `procd` daemon (`jio-wan-led.sh`) testing live IPv6 & 464XLAT IPv4 reachability, excluding Wi-Fi LEDs. | Distinguishes healthy dual-stack (solid) vs. IPv6-only/CLAT-down (slow blink) vs. WAN offline (red/fast blink). |

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

### B. `netifd` Protocol Registration (`chmod 0755` & `network restart`)
`netifd` executes scripts in `/lib/netifd/proto/` during daemon startup (`network restart`) to discover registered protocol handlers. If `/lib/netifd/proto/dhcpv6.sh` is saved as `0644` (non-executable) or only `network reload` is called after replacing it, `netifd` omits `dhcpv6` from `ubus call network get_proto_handlers` and LuCI reports `Unsupported protocol type`. Enforcing `chmod 0755` on all three files (`odhcp6c`, `dhcpv6.sh`, `dhcpv6.script`) and running `/etc/init.d/network restart` guarantees immediate registration.

### C. Explicit `ip6prefix='64:ff9b::/96'` with Private DNS
When `dnsmasq` is locked to non-DNS64 upstream resolvers (`1.1.1.1`, `8.8.8.8`, `2606:4700:4700::1111`), `464xlatcfg` cannot synthesize the NAT64 prefix via `ipv4only.arpa`. Setting `network.clat.ip6prefix='64:ff9b::/96'` and `network.wan6.iface_464xlat='0'` brings up a single, clean `464-clat` interface without leaking DNS queries to Jio.

### D. `odhcpd` NDP Relay vs. `464xlat` `allmulticast` Flapping
Enabling `odhcpd` `ndp='relay'` on a single SLAAC `/64` link causes `odhcpd` and `464xlat` to toggle `wan` `allmulticast` mode every ~100 ms, collapsing throughput. Disabling `ndp='relay'` eliminates the flapping permanently.

---

## 3. Credits

- **The DIY Daddy** ([github.com/the-diy-daddy](https://github.com/the-diy-daddy)) — Author, live hardware testing, and repository maintenance.
- **marufagul** ([github.com/marufagul/jio-airfiber-openwrt-5g-wan](https://github.com/marufagul/jio-airfiber-openwrt-5g-wan)) — Original inspiration for OpenWrt Jio AirFiber 5G WAN automation and WAN-LED status monitoring.
- **Google Gemini** — Empirical packet-level debugging, split-MTU/MSS architecture, `allmulticast` conflict isolation, universal script engineering, and technical documentation.
