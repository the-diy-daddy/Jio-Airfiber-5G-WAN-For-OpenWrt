# Technical Analysis Report: Jio AirFiber 5G WAN for OpenWrt

> **Hardware Verified:** MediaTek Filogic (`mt7986` / `aarch64`) running **Official OpenWrt 25.12.6** and **OpenWrt Snapshot** on both **Untagged SLAAC** and **VLAN `1015` DHCPv6-PD** Jio AirFiber 5G ODUs.

---

## 1. Architectural Comparison

| Technical Dimension | Standard Community Baseline | This Toolkit (`v8` Zero-Touch Engine) | Root Cause & Impact |
| :--- | :--- | :--- | :--- |
| **WAN Topology & Discovery** | Hardcoded to VLAN `1015` or untagged only. | Automatic ODU detection (`--auto`) plus explicit `--untagged`, `--vlan 1015`, `--vlan 960`, and `--vlan <ID>`. | Jio ODUs vary by firmware/region (untagged SLAAC `/64` vs VLAN `1015` stateful DHCPv6 `IA_NA`+`IA_PD`). Active probing detects the live `2409:` internet link while ignoring management-only VLANs (`2405:200:.../118`). |
| **VLAN DHCPv6 (`UnspecFail`)** | Random UUID DUID (`0004...`) + `reqaddress='try'`. | Deterministic MAC-based DUID-LL (`00030001<mac>`) + `reqaddress='force'` + clean `802.1Q` `mtu='1500'` (no `promisc`). | Prevents Jio BNG `status-code UnspecFail` rejections and stops `odhcp6c` from silently falling back to stateless `inf-req` (DNS-only) with zero IPv6 addresses. |
| **464XLAT Source-Specific Routing (`IA_PD`)** | Leaves `clat.ip6addr` unset (or hardcoded statically to an old prefix). | Installs `/etc/hotplug.d/iface/98-clat-iapd` to dynamically pin `clat.ip6addr` to `<IA_PD_PREFIX>464` whenever `wan6` comes up/updates. | Prevents `464xlat` from picking an unroutable random address inside the `IA_NA` subnet (`0` outbound packets on `wan.1015`) while automatically surviving Jio `IA_PD` prefix rotations and reboots. |
| **464XLAT & Private DNS** | Relies on ISP DNS64 `ipv4only.arpa` lookup and auto-spawned `464-wan6_4`. | Sets `wan6.iface_464xlat='0'`, `clat.ip6prefix='64:ff9b::/96'`, and Google + Cloudflare IPv4/IPv6 DNS on WAN, `dnsmasq` (`noresolv='1'`), and LAN. | Eliminates duplicate `464-wan6_4` interfaces and enforces private non-ISP DNS across both router and LAN clients without breaking NAT64. |
| **464XLAT Split-MTU Engine** | Default `464-clat` MTU (`1280`) or raised single MTU (`1380` / `1460`). | **Split MTU:** `1280` device MTU + `1260` IPv4 route MTU + `1220` `advmss` + `fw4` forward-chain `1220` TCP MSS clamp. | Eliminates silent Jio NAT64 TCP stalls and `kmod-nat46` return-path drops. Cut 10 MB IPv4 downloads from **19s → 3s** with **0 dropped packets**. |
| **LAN IPv6 (`odhcpd`)** | Fixed relay or ULA-only server mode regardless of ODU type. | Automatic `--ipv6-mode auto`: native `server` mode (`lan.ip6assign='64'`) for VLAN `IA_PD` ODUs, `relay` (`wan6` master → `lan`) for untagged SLAAC ODUs. | Hands global `2409:...` IPv6 addresses to LAN devices on both ODU types without unnecessary relay overhead on `IA_PD` links. |
| **Flow Offloading & Firewall** | Often leaves offloading enabled or lacks `Allow-464XLAT`. | Disables `flow_offloading` / `flow_offloading_hw`, enables `packet_steering='1'`, adds `Allow-464XLAT` IPv6 rule. | Offloading bypasses `clat_mss_clamp` and breaks `kmod-nat46` flows; `packet_steering` safely distributes load across `mt7986` cores. |
| **Official 25.12.6 `odhcp6c` & Packages** | Manual package installs & tarball downloads to `/tmp`. | Direct one-liner (`wget -4 -qO- ... \| sh`), auto `apk`/`opkg` installs, atomic `0755` `odhcp6c` install with backup/rollback, detached `netifd` restart. | Eliminates `ETXTBSY`, LuCI `Unsupported protocol type`, and mid-run SSH disconnects on fresh flashes. |

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
When `dnsmasq` is locked to Google/Cloudflare DNS (`noresolv='1'`), `464xlatcfg` cannot auto-discover the NAT64 prefix via `ipv4only.arpa` (`AAAA`). Setting `network.clat.ip6prefix='64:ff9b::/96'` and `network.wan6.iface_464xlat='0'` brings up a single, clean `464-clat` interface without leaking DNS queries to Jio.

### D. `odhcpd` IPv6 Relay vs. Native `IA_PD` Server Mode
- On **untagged SLAAC ODUs**, Jio provides only a single `/64` prefix with no DHCPv6-PD, so `jio-airfiber-5g-wan.sh` enables `odhcpd` IPv6 relay (`wan6` `master='1'` + `lan` `ra`/`dhcpv6`/`ndp='relay'`) so LAN clients receive global `2409:...` addresses. (If a specific router/kernel build exhibits `allmulticast` flapping under relay mode, re-run with `--ipv6-mode server`.)
- On **VLAN `1015` ODUs**, Jio delegates a dedicated `/64` via `IA_PD`, so `jio-airfiber-5g-wan.sh` automatically selects native `odhcpd` `server` mode (`lan.ip6assign='64'`), avoiding relay overhead completely.

### E. VLAN `1015` Stateful DHCPv6 (`UnspecFail`), DUID-LL, and `reqaddress='force'`
Packet captures on Jio AirFiber VLAN `1015` ODUs (`fe80::200:4ff:fe40:440`) revealed a completely different provisioning flow from untagged SLAAC ODUs:
1. The Router Advertisement on VLAN `1015` carries `Flags [none]` and **no SLAAC prefix** — IPv6 is assigned strictly via stateful DHCPv6 (`IA_NA` + `IA_PD /64`).
2. Freshly flashed OpenWrt generates a random UUID DUID (`0004...`), which caused the Jio BNG to answer `SOLICIT` with **`status-code UnspecFail`**.
3. With `reqaddress='try'`, `odhcp6c` fell back to stateless `inf-req` (retrieving only Jio DNS `2405:200:800::3`), leaving `wan6` `"up": true` with zero IPv6 addresses, zero default route, and `464-clat` stuck in `NO_DEVICE`.
4. Meanwhile, the same ODU also emitted VLAN `960` RAs advertising `2405:200:185:960::122:1400/118` — an internal Jio management/ACS VLAN, not public internet.

**Verified Fix:** Use a deterministic MAC-based **DUID-LL** (`option clientid '00030001<mac_hex>'`) and **`option reqaddress 'force'`** on clean `802.1Q` `wan.<vid>` (`mtu='1500'`, no `promisc='1'`).

### F. Source-Specific IPv6 Routing Drop on `464-clat` (`IA_NA` vs. `IA_PD`)
On VLAN `1015` links with both `IA_NA` (`/128`) and `IA_PD` (`/64`), OpenWrt installs **source-specific (`from`) default IPv6 routes**:
```text
default from 2409:4090:20c4:fc00:8784:95a1:8df6:42ca via fe80::200:4ff:fe40:440 dev wan.1015 metric 384
default from 2409:4090:20c4:fc06::/64                via fe80::200:4ff:fe40:440 dev wan.1015 metric 384
```
When `network.clat.ip6addr` is left unset, `464xlat` synthesizes a random address inside the `IA_NA` `/64` (e.g. `2409:4090:20c4:fc00:b36:a12c:41f:e748/128`), which matches **neither** source-specific route — causing the kernel to drop **100% of translated IPv4 packets before they ever leave `wan.1015`** (`0 packets captured` on `tcpdump`, even while `ping -6 64:ff9b::1.1.1.1` succeeds).

**Verified Dynamic Fix (`/etc/hotplug.d/iface/98-clat-iapd`):**
- Triggers on every `wan6` `ifup` / `ifupdate` event (and once inside the post-restart watchdog).
- Reads the active `IA_PD` prefix via `ifstatus wan6 | jsonfilter -e '@["ipv6-prefix"][0].address'`.
- Automatically pins `network.clat.ip6addr` to `<IA_PD_PREFIX>464` (e.g. `2409:4090:20c4:fc06::464`) and bounces `clat` only when the prefix changes or `/proc/net/nat46/control` is out of sync.
- On untagged SLAAC-only ODUs (no `ipv6-prefix`), automatically clears any stale `clat.ip6addr` and exits cleanly.

---

## 3. Live Verification Snapshots (OpenWrt 25.12.6)

#### Untagged SLAAC ODU (`wan`)
```text
wan6      : "up": true | "proto": "dhcpv6" | "device": "wan" | 2409:40d0:12d2:ee3:21a:79ff:feb6:566c
464-clat  : mtu 1280 | default scope link metric 2048 mtu 1260 advmss 1220
ping -6   : 2606:4700:4700::1111 — 0% packet loss (45.2 ms avg)
ping -4   : 1.1.1.1              — 0% packet loss (25.1 ms avg)
api.ipify : 152.58.120.249
```

#### VLAN `1015` Stateful DHCPv6 (`IA_NA` + `IA_PD` + `98-clat-iapd`)
```text
wan6      : "up": true | "device": "wan.1015" | IA_NA: 2409:4090:20c4:fc00:8784:95a1:8df6:42ca | IA_PD: 2409:4090:20c4:fc06::/64
nat46     : local.v4 192.0.0.1/32 | local.v6 2409:4090:20c4:fc06::464/128 | remote.v6 64:ff9b::/96
464-clat  : mtu 1280 | default scope link metric 2048 mtu 1260 advmss 1220
ping -6   : 2606:4700:4700::1111 — 0% packet loss (43.1 ms avg)
ping -4   : 1.1.1.1              — 0% packet loss (42.8 ms avg)
api.ipify : 49.36.33.127
```
