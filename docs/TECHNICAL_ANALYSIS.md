# Technical Analysis Report: Jio AirFiber 5G WAN for OpenWrt

> **Hardware Verified:** MediaTek Filogic (`mt7986` / `aarch64`) running **Official OpenWrt 25.12.6** and **OpenWrt Snapshot** on live Jio AirFiber 5G links.

---

## 1. Architectural Comparison

| Technical Dimension | Standard Community Baseline | This Toolkit (`v4` Production) | Root Cause & Impact |
| :--- | :--- | :--- | :--- |
| **WAN Topology** | Hardcoded to VLAN `1015` or single mode. | Dual-mode (`--untagged` recommended default, `--vlan1015` optional) with deduplicated `wan_dev` (`promisc='1'`). | Most Jio AirFiber ODUs / bridges deliver untagged RAs directly on `wan`; removing duplicate anonymous `wan` device sections prevents MAC conflicts while `promisc='1'` stops `mt7530` Proxy NDP frame drops. |
| **464XLAT & Private DNS** | Relies on ISP DNS64 `ipv4only.arpa` lookup and auto-spawned `464-wan6_4`. | Sets `wan6.iface_464xlat='0'` and `clat.ip6prefix='64:ff9b::/96'`. | Prevents duplicate `464-wan6_4` interfaces and allows `464-clat` to start cleanly even when `dnsmasq` forces private non-DNS64 Cloudflare/Google resolvers (`noresolv='1'`). |
| **464XLAT MTU Engine** | Default `464-clat` MTU (`1280`) or raised single MTU (`1380` / `1460`). | **Split MTU:** `1280` device MTU + `1260` IPv4 route MTU + `1220` `advmss` + `fw4` forward-chain `1220` TCP MSS clamp. | Eliminates silent Jio NAT64 TCP stalls and `kmod-nat46` return-path drops. Cut 10 MB IPv4 downloads from **19s → 3s** with **0 dropped packets**. |
| **LAN IPv6 (`odhcpd`)** | Relay mode without `wan6` master or split-MTU fixes. | Enables `wan6` (`master='1'`) + `lan` `ra`/`dhcpv6`/`ndp='relay'` by default, with `--ipv6-mode server` fallback. | Passes Jio's single `/64` SLAAC prefix directly to LAN clients so Windows/mobile devices get global `2409:...` IPv6 connectivity; `--ipv6-mode server` remains available if specific targets exhibit `allmulticast` flapping. |
| **Flow Offloading** | Often enabled (Software or MediaTek Hardware PPE). | Disabled (`flow_offloading='0'`, `flow_offloading_hw='0'`); `packet_steering='1'` enabled. | Hardware/software offloading bypasses `clat_mss_clamp` and breaks `kmod-nat46` flows; `packet_steering` safely distributes traffic across `mt7986` cores. |
| **Official 25.12.6 `odhcp6c`** | Assumes stock `odhcp6c` behaves identically across releases. | Atomically installs `mt7986` (`aarch64`) `odhcp6c`, `dhcpv6.sh`, `dhcpv6.script` (`chmod 0755`), validates protocol dump, backs up originals, and runs detached `network restart`. | Resolves the Official 25.12.6 `odhcp6c` regression without `ETXTBSY`, without LuCI `Unsupported protocol type`, and without SSH disconnects killing the script mid-run. |
| **Fresh-Flash Downloads** | `wget https://github.com/.../archive/refs/heads/main.tar.gz`. | `wget -4 https://codeload.github.com/.../tar.gz/refs/heads/main`. | Bypasses Jio DNS64 (`64:ff9b::`) stalls and `github.com` 302 redirect timeouts over temporary `wwan` connections. |

---

## 2. Deep-Dive Root Cause Findings

### A. Why Single-Value MTU Fails on `kmod-nat46` (The 20-Byte Asymmetry)
`464xlat` (`kmod-nat46`) translates IPv4 headers (20 bytes) into IPv6 headers (40 bytes) — a **+20-byte expansion**.
- Setting `464-clat` device MTU to `1380` and sending a `1380`-byte IPv4 packet produces a `1400`-byte IPv6 packet; when the `1400`-byte IPv6 reply returns into `464-clat`, Linux checks `1400 > 1380` and **drops the reply before `nat46` can translate it**.
- Raising `464-clat` to `1400` / route `1380` passes ICMP pings to `1.1.1.1`, but **stalls HTTPS TCP downloads** (`10 MB` takes `19s` vs `3s` on IPv6) because Jio's NAT64 gateway (`64:ff9b::/96`) enforces the **1280-byte RFC 8200 IPv6 minimum MTU** on TCP flows.

**Verified Split-MTU Fix:**
1. Device MTU `464-clat`: **`1280`** (accepts 1280-byte IPv6 replies cleanly).
2. IPv4 default route: **`mtu 1260 advmss 1220`** (caps router-originated IPv4 at 1260 bytes → 1280 bytes IPv6).
3. `nftables` (`fw4`) forward-chain mangle rule (`/etc/nftables.d/99-clat-mss.nft`): clamps **LAN-forwarded TCP SYN MSS to `1220`** in both directions.

### B. `netifd` Protocol Registration (`chmod 0755` + Atomic Install + Detached Restart)
1. `netifd` only loads scripts in `/lib/netifd/proto/` that have executable (`0755`) permissions and only rescans them on a full `/etc/init.d/network restart` (not `reload`). Installing `dhcpv6.sh` as `0644` causes LuCI to show `Unsupported protocol type` on `wan6`.
2. Overwriting a running `/usr/sbin/odhcp6c` in place with `cp -f` can fail with `ETXTBSY` (`Text file busy`). Staging to `*.jio-new.$$`, applying `chmod 0755`, and renaming with `mv -f` avoids `ETXTBSY`.
3. Running `/etc/init.d/network restart` synchronously over SSH drops `br-lan`/Wi-Fi and sends `SIGHUP` to the shell. Using `trap '' HUP`, committing and `sync`ing all configs first, and running `network restart` in a detached background subshell (logging to `/tmp/jio-network-restart.log`) guarantees 100% completion.

### C. Explicit `ip6prefix='64:ff9b::/96'` with Non-DNS64 Resolvers
When `dnsmasq` is locked to Cloudflare/Google DNS (`noresolv='1'`), `464xlatcfg` cannot auto-discover the NAT64 prefix via `ipv4only.arpa` (`AAAA`). Setting `network.clat.ip6prefix='64:ff9b::/96'` and `network.wan6.iface_464xlat='0'` brings up a single, clean `464-clat` interface without leaking DNS queries to Jio.

### D. `odhcpd` NDP Relay vs. `464xlat` `allmulticast` Flapping
Enabling `odhcpd` `ndp='relay'` on a single SLAAC `/64` link causes `odhcpd` and `464xlat` to toggle `wan` `allmulticast` mode every ~100 ms:
```text
mt7530-mdio mdio-bus:1f wan: entered allmulticast mode
mt7530-mdio mdio-bus:1f wan: left allmulticast mode
```
Because Jio 5G provides only a single `/64` SLAAC prefix (no DHCPv6-PD), `jio-airfiber-5g-wan.sh` enables `odhcpd` IPv6 relay (`wan6` `master='1'` + `lan` `ra`/`dhcpv6`/`ndp='relay'`) by default so LAN clients receive global `2409:...` IPv6 addresses. If a specific router/kernel build exhibits `allmulticast` flapping under relay mode, re-run with `--ipv6-mode server` to disable `ndp='relay'` cleanly.

---


### E. VLAN `1015` Stateful DHCPv6 (`UnspecFail`), DUID-LL, and `reqaddress='force'`
Packet captures on Jio AirFiber VLAN `1015` ODUs (`fe80::200:4ff:fe40:440`) revealed a completely different provisioning flow from untagged SLAAC ODUs:
1. The Router Advertisement on VLAN `1015` carries `Flags [none]` and **no SLAAC prefix** — IPv6 is assigned strictly via stateful DHCPv6 (`IA_NA` + `IA_PD /64`).
2. Freshly flashed OpenWrt generates a random UUID DUID (`0004...`), which caused the Jio BNG to answer `SOLICIT` with **`status-code UnspecFail`**.
3. With `reqaddress='try'`, `odhcp6c` fell back to stateless `inf-req` (retrieving only Jio DNS `2405:200:800::3`), leaving `wan6` `"up": true` with zero IPv6 addresses, zero default route, and `464-clat` stuck in `NO_DEVICE`.
4. Meanwhile, the same ODU also emitted VLAN `960` RAs advertising `2405:200:185:960::122:1400/118` — an internal Jio management/ACS VLAN, not public internet.

**Verified Fix (Automated in `--auto` and `--vlan <ID>`):**
- Use a deterministic MAC-based **DUID-LL** (`option clientid '00030001<mac_hex>'`) and **`option reqaddress 'force'`** so `odhcp6c` never falls back to stateless `inf-req`.
- Keep physical `wan` clean (no `promisc='1'`), configure `802.1Q` `wan.<vid>` with `mtu='1500'`, add the `Allow-464XLAT` IPv6 firewall rule, set `network.lan.ip6assign='64'`, and run `odhcpd` in native **`server`** mode (not `relay`) to distribute the delegated `IA_PD` `/64` prefix cleanly to LAN clients.

---

## 3. Live Verification Snapshot (OpenWrt 25.12.6)

```text
wan6      : "up": true | "proto": "dhcpv6" | "device": "wan" | 2409:40d0:12d2:ee3:21a:79ff:feb6:566c
464-clat  : mtu 1280
IPv4 route: default scope link metric 2048 mtu 1260 advmss 1220
ping -6   : 2606:4700:4700::1111 — 0% packet loss (45.2 ms avg)
ping -4   : 1.1.1.1              — 0% packet loss (25.1 ms avg)
api.ipify : 152.58.120.249
```

#### VLAN `1015` Stateful DHCPv6 (`IA_NA` + `IA_PD`) Verification
```text
wan6      : "up": true | "device": "wan.1015" | IA_NA: 2409:4090:20c4:fc00:8784:95a1:8df6:42ca | IA_PD: 2409:4090:20c4:fc06::/64
464-clat  : mtu 1280 | default scope link metric 2048 mtu 1260 advmss 1220
ping -6   : 2606:4700:4700::1111 — 0% packet loss (45.3 ms avg)
ping -4   : 1.1.1.1              — 0% packet loss (50.2 ms avg)
api.ipify : 49.36.33.14
```
