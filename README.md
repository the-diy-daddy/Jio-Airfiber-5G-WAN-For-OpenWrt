<div align="center">

# Jio AirFiber 5G WAN for OpenWrt

**100% automatic dual-stack IPv6 (Auto-VLAN / Untagged SLAAC / DHCPv6-PD) + 464XLAT (`kmod-nat46`) toolkit for Jio AirFiber 5G ODUs on OpenWrt**

[![OpenWrt](https://img.shields.io/badge/OpenWrt-25.12.x%20%7C%20Snapshot-00B5E2?style=for-the-badge&logo=openwrt&logoColor=white)](https://openwrt.org/)
[![Target](https://img.shields.io/badge/Target-MediaTek%20Filogic%20MT7986-2B3137?style=for-the-badge)](https://openwrt.org/docs/techref/hardware/soc/soc.mediatek)
[![Protocol](https://img.shields.io/badge/Stack-IPv6%20%2B%20464XLAT-10B981?style=for-the-badge)](#why-this-toolkit)
[![License](https://img.shields.io/badge/License-Personal%20Non--Commercial-E11D48?style=for-the-badge)](LICENSE)
[![YouTube](https://img.shields.io/badge/YouTube-The%20DIY%20Daddy-FF0000?style=for-the-badge&logo=youtube&logoColor=white)](https://www.youtube.com/@the_diy_daddy)

[Quick Start](#quick-start) •
[One-Line Setup](#step-4-run-the-one-line-setup-script) •
[CLI Reference](#cli-options) •
[Verification](#step-5-switch-to-jio-5g-wan--verify) •
[Technical Report](docs/TECHNICAL_ANALYSIS.md) •
[Credits](CREDITS.md)

</div>

---

## Why This Toolkit?

Different Jio AirFiber 5G ODUs use completely different WAN handshakes — some send **untagged SLAAC `/64`**, while others require **802.1Q VLAN `1015` (or custom VLANs) with stateful DHCPv6 `IA_NA` + `IA_PD`**. Standard OpenWrt installs hit **NAT64 TCP stalls**, **BNG `UnspecFail` rejections**, **source-specific IPv6 routing drops on `464-clat`**, **missing LAN IPv6**, and an **`odhcp6c` regression on Official OpenWrt 25.12.6**.

| Feature | What It Automates |
| :--- | :--- |
| **Direct One-Liner + Auto Package Install** | Pipe directly from GitHub (`wget -4 -qO- ... \| sh -s -- ...`) — no `/tmp` tarball extraction required. Automatically installs `464xlat`, `kmod-nat46`, `ip-tiny`, `luci-proto-ipv6`, and `tcpdump-mini` via `apk`/`opkg`. |
| **Auto VLAN Detection (`--auto`) & Custom `--vlan <ID>`** | Sniffs and probes your live Jio ODU on `wan`, filters out internal management VLANs (e.g. VLAN `960` `2405:200:.../118`), and automatically configures **untagged `wan`**, **VLAN `1015`**, **VLAN `960`**, or any custom 802.1Q VLAN ID. |
| **VLAN DHCPv6-PD (`UnspecFail`) + Dynamic `98-clat-iapd` Hook** | Automatically sets `reqaddress='force'`, deterministic MAC-based DUID-LL (`00030001<mac>`), clean `802.1Q` `mtu='1500'` (no `promisc`), `Allow-464XLAT` firewall rule, `lan.ip6assign='64'`, native `odhcpd` `server` mode, and **`/etc/hotplug.d/iface/98-clat-iapd`** to keep `network.clat.ip6addr` dynamically pinned inside Jio's live `IA_PD` `/64` prefix across reboots & prefix rotations. |
| **Untagged SLAAC + IPv6 Relay** | On untagged SLAAC-only ODUs, automatically configures `wan_dev` (`promisc='1'`) and `odhcpd` IPv6 relay (`wan6` master → `lan`) so LAN devices receive global `2409:...` IPv6 addresses. |
| **Zero-Drop Split-MTU Engine (`1280 / 1260 / 1220`)** | Sets `464-clat` device MTU to `1280`, IPv4 route MTU to `1260` (`advmss 1220`), and `fw4` forward-chain TCP MSS clamping to `1220` — cutting 10 MB IPv4 downloads from **19s → 3s** with **0 drops**. |
| **Google + Cloudflare DNS (WAN & LAN) + Auto 25.12.x `odhcp6c` Fix** | Applies Google (`8.8.8.8` / `2001:4860:4860::8888`) & Cloudflare (`1.1.1.1` / `2606:4700:4700::1111`) IPv4/IPv6 DNS across WAN, `dnsmasq`, and LAN; atomically installs the verified `mt7986` `odhcp6c` bundle (`0755`) on Official 25.12.x with rollback backup. |

---

## Measured Performance (Live `mt7986` Hardware)

| Test | Default OpenWrt / Single MTU | This Toolkit (`1280 / 1260 / 1220` + Auto `IA_PD`) |
| :--- | :---: | :---: |
| **10 MB IPv4 Download over 464XLAT** | `19s` (TCP stalls & drops) | **`3s`** (`13,589` pkts · **`0` errors · `0` drops**) |
| **Untagged ODU Dual-Stack Ping** | Fails / drops on 25.12.6 | **IPv6 `45.2 ms` · IPv4 `25.1 ms` (`0%` loss)** |
| **VLAN `1015` ODU Dual-Stack Ping** | `UnspecFail` / `100%` IPv4 loss | **IPv6 `43.1 ms` · IPv4 `42.8 ms` (`0%` loss)** |
| **LAN Global IPv6 (`2409:...`)** | ULA-only (`fd...`) | **Full dual-stack (Auto `relay` or `IA_PD` `server`)** |

> [!NOTE]
> Full packet-level root cause analysis (including the VLAN `1015` `UnspecFail` / DUID-LL trace, source-specific `IA_NA` vs `IA_PD` routing drops, and split-MTU benchmarks) is documented in **[`docs/TECHNICAL_ANALYSIS.md`](docs/TECHNICAL_ANALYSIS.md)**.

---

## Quick Start

### Step 1: Flash OpenWrt (Stock Official or Custom Build)

Flash **OpenWrt Official 25.12.x** or **SNAPSHOT** on your router. Because the setup script automatically downloads and installs all missing packages via `apk`/`opkg` over temporary Wi-Fi (`wwan`), a stock Official image works out of the box — or you can pre-bundle these packages in **[OpenWrt Firmware Selector](https://firmware-selector.openwrt.org/)**:

```text
luci 464xlat kmod-nat46 ip-tiny luci-proto-ipv6 ca-bundle
```

<details>
<summary><strong>Optional: First-Boot Wi-Fi Script (<code>uci-defaults</code>) & Package Details</strong> (click to expand)</summary>

| Package | Role |
| :--- | :--- |
| `464xlat` | Userspace CLAT daemon translating IPv4 traffic over Jio's IPv6-only 5G link (`64:ff9b::/96`). |
| `kmod-nat46` | Kernel module providing stateless IPv4 ↔ IPv6 translation (`464-clat` interface). |
| `ip-tiny` | Full `iproute2` binary required for `mtu` and `advmss` route flags. |
| `luci-proto-ipv6` | LuCI web UI support for DHCPv6/SLAAC and IPv6 interfaces. |
| `tcpdump-mini` | Installed automatically on-demand when `--auto` VLAN detection runs. |

Paste [`scripts/uci-defaults-wifi.sh`](scripts/uci-defaults-wifi.sh) into **Script to run on first boot (uci-defaults)** in Firmware Selector if you want 2.4 GHz & 5 GHz Wi-Fi (`OpenWrt-Jio5G` / `12345678`) enabled immediately after flashing.

</details>

---

### Step 2: Connect Temporary Internet (`wwan`) & Plug In Jio ODU

1. Open LuCI at `http://192.168.1.1`, go to **Network → Wireless**, click **Scan**, and join your phone hotspot or existing Wi-Fi as a **Client** (`wwan`) in the `wan` firewall zone.
2. Plug the **Jio AirFiber 5G ODU** Ethernet cable into your router's **WAN** port *(required for automatic VLAN detection)*.

---

### Step 3: Connect Over SSH

```sh
ssh root@192.168.1.1
```

---

### Step 4: Run the One-Line Setup Script

Run **one** command below directly over SSH — it installs missing packages (`464xlat`, `kmod-nat46`, `ip-tiny`, `luci-proto-ipv6`, `tcpdump-mini`), patches `odhcp6c` on Official 25.12.x `mt7986`, detects your ODU's WAN topology, installs both hotplug hooks (`98-clat-iapd` & `99-clat-mtu`), sets Google + Cloudflare DNS, and runs a live post-restart self-check *(replace the MAC with your paired Jio router's WAN MAC, or omit `--mac` to keep factory MAC)*:

#### Option A — Recommended: 100% Automatic (`--auto` is the default with `-y`) *(replace the MAC with your paired Jio router's WAN MAC, or omit `--mac` to keep factory MAC)*:

```sh
wget -4 -qO- https://raw.githubusercontent.com/the-diy-daddy/Jio-Airfiber-5G-WAN-For-OpenWrt/main/scripts/jio-airfiber-5g-wan.sh | sh -s -- --mac "A1:B2:C3:D4:E5:F6" -y
```

#### Option B — Force Untagged `wan` (SLAAC `/64` + IPv6 Relay) *(replace the MAC with your paired Jio router's WAN MAC, or omit `--mac` to keep factory MAC)*:

```sh
wget -4 -qO- https://raw.githubusercontent.com/the-diy-daddy/Jio-Airfiber-5G-WAN-For-OpenWrt/main/scripts/jio-airfiber-5g-wan.sh | sh -s -- --untagged --mac "A1:B2:C3:D4:E5:F6" -y
```

#### Option C — Force VLAN `1015` (Stateful DHCPv6 `IA_NA` + `IA_PD` + Auto `98-clat-iapd`) *(replace the MAC with your paired Jio router's WAN MAC, or omit `--mac` to keep factory MAC)*:

```sh
wget -4 -qO- https://raw.githubusercontent.com/the-diy-daddy/Jio-Airfiber-5G-WAN-For-OpenWrt/main/scripts/jio-airfiber-5g-wan.sh | sh -s -- --vlan 1015 --mac "A1:B2:C3:D4:E5:F6" -y
```

#### Option D — Force VLAN `960` or Any Custom VLAN ID *(replace the MAC with your paired Jio router's WAN MAC, or omit `--mac` to keep factory MAC)*:

```sh
wget -4 -qO- https://raw.githubusercontent.com/the-diy-daddy/Jio-Airfiber-5G-WAN-For-OpenWrt/main/scripts/jio-airfiber-5g-wan.sh | sh -s -- --vlan 960 --mac "A1:B2:C3:D4:E5:F6" -y
```

> [!TIP]
> Add `--no-restart` to any command above if you want your SSH/LuCI session to stay connected while you remove temporary `wwan` and reboot manually.

---

### Step 5: Switch to Jio 5G WAN & Verify

1. In LuCI (**Network → Wireless** and **Network → Interfaces**), disable or remove your temporary `wwan` Wi-Fi client so all IPv4 traffic routes over Jio `464-clat`.
2. Reboot the router:
   ```sh
   reboot
   ```
3. Wait **1–2 minutes** for the Jio IPv6 handshake, then verify via SSH:

```sh
ifstatus wan6 | grep -E '"up"|"proto"|"device"|"address"|"target"'
cat /proc/net/nat46/control
ip link show dev 464-clat | grep -o 'mtu [0-9]*'
ip route show dev 464-clat
nft list chain inet fw4 clat_mss_clamp
ping -6 -c 2 2606:4700:4700::1111
ping -4 -c 2 1.1.1.1
wget -4 -qO- -T 5 https://api.ipify.org && echo ""
```

#### Expected Healthy Output
```text
"up": true,
"proto": "dhcpv6",
"device": "wan.1015",   # or "wan" on untagged ODUs
"address": "2409:xxxx:xxxx:xxxx::xxxx",
local.v6 2409:xxxx:xxxx:xxxx::464/128 ... remote.v6 64:ff9b::/96
mtu 1280
default scope link metric 2048 mtu 1260 advmss 1220
... maxseg size set 1220
2 packets transmitted, 2 packets received, 0% packet loss
2 packets transmitted, 2 packets received, 0% packet loss
49.36.xxx.xxx
```

---

## CLI Options

<details>
<summary><strong>Full <code>jio-airfiber-5g-wan.sh</code> CLI Reference & Standalone Rollback</strong> (click to expand)</summary>

| Flag | Description |
| :--- | :--- |
| `--auto` | Auto-detect untagged vs VLAN ID on live `wan` link (default when `-y` is passed without a mode). |
| `--untagged` | Force untagged `wan` mode (SLAAC `/64` + IPv6 relay). |
| `--vlan <ID>` | Force any 802.1Q VLAN ID (`1`–`4094`), e.g. `--vlan 1015` or `--vlan 960`. |
| `--vlan1015` / `--vlan960` | Shorthands for `--vlan 1015` and `--vlan 960`. |
| `--mac "<MAC>"` | Clone a paired WAN MAC address (also auto-generates DUID-LL `00030001<mac>` in VLAN mode). |
| `--clientid "<HEX>"` | Override the DHCPv6 Client-ID / DUID manually. |
| `--ipv6-mode <mode>` | `auto` (default: `relay` for untagged, `server` for VLAN `IA_PD`), `relay`, or `server`. |
| `--nat64-prefix "<CIDR>"` | Override Jio NAT64 IPv6 prefix (default: `64:ff9b::/96`). |
| `--led` / `--no-led` | Enable (default) or skip installing the `jio-wan-led` status daemon. |
| `--odhcp6c-fix` / `--no-odhcp6c-fix` | Force or skip the Official 25.12.x `mt7986` `odhcp6c` patch (auto-detected by default). |
| `--no-pkg-install` | Skip automatic `apk`/`opkg` package installation (for offline custom images). |
| `--no-restart` | Write & commit everything to flash without triggering `network restart`. |
| `-y`, `--yes` | Non-interactive mode — accept defaults for any omitted options. |

#### Standalone `mt7986` `odhcp6c` Patch & Rollback
```sh
wget -4 -qO- https://raw.githubusercontent.com/the-diy-daddy/Jio-Airfiber-5G-WAN-For-OpenWrt/main/scripts/apply-mt7986-odhcp6c.sh | sh -s -- --rollback
```

#### Inspect Setup & Post-Restart Self-Check Logs
```sh
cat /tmp/jio-5g-setup.log
cat /tmp/jio-network-restart.log
```

</details>

<details>
<summary><strong>Quick Troubleshooting</strong> (click to expand)</summary>

- **VLAN `1015` gets `"up": true` with DNS `2405:200:800::3` but no `2409:...` IP:** Pass your paired Jio router's exact WAN MAC via `--mac` (so the script generates `clientid='00030001<mac>'` and `reqaddress='force'`), and power-cycle the ODU for 60 seconds if you just unplugged the stock Jio router.
- **IPv6 works on VLAN `1015`, but `ping -4 1.1.1.1` has 100% loss:** Check `cat /proc/net/nat46/control` and verify `local.v6` ends in `::464/128` inside your `IA_PD` prefix. Trigger a manual sync anytime with `INTERFACE=wan6 ACTION=ifup /etc/hotplug.d/iface/98-clat-iapd`.
- **Note on VLAN `960`:** On many Jio ODUs, VLAN `960` is Jio's internal management/ACS VLAN (`2405:200:.../118`), not public internet. `--auto` automatically skips management-only VLANs.
- **IPv4 still routing via phone hotspot:** Delete or disable `wwan` in LuCI (`ip -4 route` should show only `464-clat` as the default route).

</details>

---

## Repository Layout

```text
Jio-Airfiber-5G-WAN-For-OpenWrt/
├── README.md                           # Main guide & direct one-line setup
├── LICENSE                             # Personal, non-commercial license & video terms
├── CREDITS.md                          # Acknowledgments & contributors
├── .gitattributes                      # Enforces Unix LF scripts & binary odhcp6c
├── docs/
│   └── TECHNICAL_ANALYSIS.md           # Packet-level root cause analysis & benchmarks
├── files/
│   ├── odhcp6c                         # Verified mt7986 (aarch64) ELF binary
│   ├── dhcpv6.sh                       # netifd dhcpv6 protocol handler
│   └── dhcpv6.script                   # odhcp6c state hook script
└── scripts/
    ├── jio-airfiber-5g-wan.sh          # Universal zero-touch setup + auto-VLAN + auto-pkg + IA_PD hook
    ├── apply-mt7986-odhcp6c.sh         # Standalone Official 25.12.x odhcp6c fix & rollback
    ├── jio-wan-led.sh                  # Standalone WAN/464XLAT LED status monitor
    └── uci-defaults-wifi.sh            # First-boot Wi-Fi enable script (Firmware Selector)
```

---

## Credits & License

- **Author & Maintainer:** **The DIY Daddy** ([GitHub](https://github.com/the-diy-daddy) · [YouTube `@the_diy_daddy`](https://www.youtube.com/@the_diy_daddy))
- **Acknowledgments:** Full credits to **[marufagul](https://github.com/marufagul)** and **Google Gemini** in **[CREDITS.md](CREDITS.md)**.

> [!WARNING]
> **Copyright © 2026 The DIY Daddy.** Strictly for **personal, non-commercial use**. Creating, publishing, or monetizing video content based on this repository is prohibited without prior written permission — see **[LICENSE](LICENSE)** for full terms.
