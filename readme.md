<div align="center">

# Jio Airfiber 5G WAN For OpenWrt

**Production-Tested SLAAC IPv6 + 464XLAT (`kmod-nat46`) Automation for MediaTek Filogic (`mt7986`) Routers**

[![OpenWrt](https://img.shields.io/badge/OpenWrt-25.12.x%20%7C%20Snapshot-00B5E2?style=for-the-badge&logo=openwrt&logoColor=white)](https://openwrt.org/)
[![Platform](https://img.shields.io/badge/Platform-MediaTek%20Filogic%20mt7986-2E7D32?style=for-the-badge)](https://openwrt.org/docs/techref/hardware/soc/soc.mediatek.filogic)
[![IPv4 over IPv6](https://img.shields.io/badge/Transport-464XLAT%20Split--MTU-FF6F00?style=for-the-badge)](docs/TECHNICAL_ANALYSIS.md)
[![License](https://img.shields.io/badge/License-Personal%20Non--Commercial-D32F2F?style=for-the-badge)](LICENSE)

*Built and hardware-verified on live Jio AirFiber 5G ODU connections across **OpenWrt Snapshot** and **Official OpenWrt 25.12.6**.*

[Firmware Build](#-step-1-build-firmware-on-openwrt-firmware-selector) •
[First-Boot Wi-Fi](#-step-2-enable-wi-fi-on-first-boot-uci-defaults) •
[One-Line Setup](#-step-3-run-the-universal-setup-script) •
[WAN LED States](#-wan-status-led-legend) •
[Verification](#-step-4-verify-your-connection) •
[Technical Analysis](docs/TECHNICAL_ANALYSIS.md)

</div>

---

## Why This Toolkit Exists

Jio AirFiber 5G Outdoor Units (ODU) deliver an **IPv6-only SLAAC transport without Prefix Delegation (`IA_PD`)** and translate IPv4 through Jio's carrier NAT64 gateway (`64:ff9b::/96`). Default OpenWrt configurations suffer from four silent failure modes on this link:

1. **TCP Stalls & Packet Drops:** Standard `464-clat` MTU settings trigger silent drops on Jio's 1280-byte NAT64 TCP path (`19s` for 10 MB vs. `3s` with Split-MTU).
2. **`allmulticast` Interface Flapping:** Enabling `odhcpd` NDP relay conflicts with `464xlat` Proxy NDP, toggling `wan` multicast mode every ~100 ms.
3. **Flow Offloading Breakage:** Both MediaTek Hardware PPE and Software Flow Offloading break `kmod-nat46` translation or bypass TCP MSS clamping.
4. **Official OpenWrt 25.12.6 `odhcp6c` Regression:** Stock `odhcp6c` on Official 25.12.6 fails to reliably bring up SLAAC on Jio 5G without the verified `mt7986` (`aarch64`) `files/` bundle.

---

## Key Features

| Feature | Implementation Details |
| :--- | :--- |
| **Universal Firmware Support** | Works seamlessly on both **OpenWrt Snapshot** and **Official OpenWrt 25.12.x** (`opkg` & `apk` aware). |
| **Dual WAN Topologies** | Supports both **Untagged `wan`** (bridge ODU) and **VLAN `1015` (`wan.1015`)** with optional MAC cloning. |
| **Zero-Drop 464XLAT Split-MTU** | Enforces `1280` device MTU, `1260` IPv4 route MTU, and `1220` TCP MSS clamping via `hotplug.d` + `fw4` (`nftables`). |
| **Built-In `mt7986` 25.12.6 Fix** | Auto-detects Official `25.12.x` on `aarch64`, backs up stock files, and installs the verified `files/` `odhcp6c` bundle. |
| **Flap-Free Multi-Core Routing** | Disables `odhcpd` NDP relay and `flow_offloading`, while enabling `packet_steering='1'` across all `mt7986` cores. |
| **ISP DNS Leak Prevention** | Locks `peerdns='0'` on all WAN interfaces and routes queries exclusively to Cloudflare + Google IPv4/IPv6 DNS. |
| **WAN Status LED Daemon** | Lightweight `procd` daemon (`jio-wan-led`) showing live dual-stack health **without touching Wi-Fi settings**. |
| **Sysupgrade Persistence** | Automatically registers hooks, LED services, and patched `odhcp6c` paths in `/etc/sysupgrade.conf`. |

---

## Repository Structure

```text
Jio-Airfiber-5G-WAN-For-OpenWrt/
├── README.md                              # Complete setup guide & documentation
├── LICENSE                                # Personal, non-commercial license (The DIY Daddy)
├── CREDITS.md                             # Project acknowledgments & attributions
├── .gitattributes                         # Enforces LF line endings on scripts & binary mode on odhcp6c
├── docs/
│   └── TECHNICAL_ANALYSIS.md              # Deep-dive packet analysis, benchmarks & repo comparison
├── files/                                 # Verified mt7986 (aarch64) odhcp6c fix bundle for 25.12.6
│   ├── odhcp6c
│   ├── dhcpv6.sh
│   └── dhcpv6.script
└── scripts/
    ├── uci-defaults-wifi.sh               # First-boot Wi-Fi + MT76 DHCP fix for Firmware Selector
    ├── jio-airfiber-5g-wan.sh             # Universal Jio 5G WAN installer (Snapshot & Official 25.12.x)
    ├── apply-mt7986-odhcp6c.sh            # Standalone mt7986 (aarch64) 25.12.6 odhcp6c patcher
    └── jio-wan-led.sh                     # Standalone WAN & 464XLAT status LED daemon
```

---

## Step 1: Build Firmware on OpenWrt Firmware Selector

1. Open [**firmware-selector.openwrt.org**](https://firmware-selector.openwrt.org/) and choose your MediaTek Filogic (`mt7986`) router model and version (**25.12.x** or **SNAPSHOT**).
2. Expand **Customize installed packages and/or first boot script**.
3. Append the following packages to **Installed Packages**:

```text
luci 464xlat kmod-nat46 ip-tiny luci-proto-ipv6 ca-bundle
```

| Package | Why It Is Required |
| :--- | :--- |
| `464xlat` | Userspace CLAT daemon translating IPv4 over Jio's IPv6-only 5G link via NAT64 (`64:ff9b::/96`). |
| `kmod-nat46` | Kernel stateless IPv4/IPv6 translation driver creating the `464-clat` interface. |
| `ip-tiny` | Full `iproute2` binary required for reliable `mtu 1260 advmss 1220` route replacement (BusyBox `ip` lacks full support). |
| `luci-proto-ipv6` | LuCI web interface protocol support for DHCPv6/SLAAC and IPv6 WAN management. |
| `luci` | Web UI (**essential on Snapshots**, which omit LuCI by default; safe to include on Official builds). |
| `ca-bundle` | TLS root certificates so `wget` can fetch HTTPS scripts/files from GitHub and query `https://api.ipify.org`. |

> **Tip:** Add `luci-ssl` if you want HTTPS access to LuCI.

---

## Step 2: Enable Wi-Fi on First Boot (`uci-defaults`)

OpenWrt ships with Wi-Fi disabled after a fresh flash. To bring up both **2.4 GHz** and **5 GHz** automatically on first boot—with the **MT76 DHCP `multicast_to_unicast='0'` fix**—paste [`scripts/uci-defaults-wifi.sh`](scripts/uci-defaults-wifi.sh) into **Script to run on first boot (uci-defaults)** on Firmware Selector before clicking **Request Build**:

<details>
<summary><strong>Click to expand First-Boot Wi-Fi Script (uci-defaults-wifi.sh)</strong></summary>

```sh
#!/bin/sh
# Jio Airfiber 5G WAN For OpenWrt — First-Boot Wi-Fi Setup (uci-defaults)
# Enables 2.4GHz & 5GHz Wi-Fi on boot with MT76 DHCP fix

WIFI_SSID="OpenWrt-Jio5G"
WIFI_KEY="12345678"

[ ! -f /etc/config/wireless ] && /sbin/wifi config 2>/dev/null || true

if [ -f /etc/config/wireless ]; then
    for radio in $(uci show wireless | grep "=wifi-device" | cut -d'.' -f2 | cut -d'=' -f1); do
        BAND=$(uci -q get wireless."$radio".band || echo "")
        HWMODE=$(uci -q get wireless."$radio".hwmode || echo "")
        uci set wireless."$radio".country='IN'
        uci set wireless."$radio".disabled='0'
        if [ "$BAND" = "5g" ] || echo "$HWMODE" | grep -q "11a"; then
            uci set wireless."$radio".htmode='HE80'
            uci set wireless."$radio".channel='36'
        else
            uci set wireless."$radio".htmode='HT20'
            uci set wireless."$radio".channel='auto'
        fi
    done

    for iface in $(uci show wireless | grep "=wifi-iface" | cut -d'.' -f2 | cut -d'=' -f1); do
        uci set wireless."$iface".disabled='0'
        uci set wireless."$iface".network='lan'
        uci set wireless."$iface".ssid="$WIFI_SSID"
        uci set wireless."$iface".encryption='psk2'
        uci set wireless."$iface".key="$WIFI_KEY"
        uci set wireless."$iface".multicast_to_unicast='0'
    done

    uci commit wireless
fi

exit 0
```

</details>

Flash your custom `sysupgrade.bin`, connect to **`OpenWrt-Jio5G`** (password: `12345678`), and SSH into `root@192.168.1.1`.

---

## Step 3: Run the Universal Setup Script

The main script works on both **Snapshot** and **Official 25.12.x** and **never modifies your Wi-Fi configuration**.

### Interactive One-Line Install (Router with Internet)
```sh
wget -O /tmp/jio-airfiber-5g-wan.sh https://raw.githubusercontent.com/the-diy-daddy/Jio-Airfiber-5G-WAN-For-OpenWrt/main/scripts/jio-airfiber-5g-wan.sh && chmod +x /tmp/jio-airfiber-5g-wan.sh && /tmp/jio-airfiber-5g-wan.sh
```

### Offline Install (Recommended for Fresh Official 25.12.6 Flash)
If your fresh Official 25.12.6 router does not have WAN connectivity yet, copy the repository (`scripts/` and `files/`) to `/tmp/jio5g` via SCP from your PC, then run:
```sh
chmod +x /tmp/jio5g/scripts/*.sh
/tmp/jio5g/scripts/jio-airfiber-5g-wan.sh
```

### Non-Interactive / Environment Variable Mode
```sh
# Untagged WAN (default / bridge ODU)
WAN_MODE="untagged" WAN_MAC="00:1A:79:B6:56:6C" ENABLE_WAN_LED="1" APPLY_ODHCP6C_FIX="auto" /tmp/jio-airfiber-5g-wan.sh

# VLAN 1015 WAN (standard Jio AirFiber ODU)
WAN_MODE="vlan1015" WAN_MAC="00:1A:79:B6:56:6C" ENABLE_WAN_LED="1" APPLY_ODHCP6C_FIX="auto" /tmp/jio-airfiber-5g-wan.sh
```

### Official 25.12.6 `mt7986` (`aarch64`) `odhcp6c` Fix Details
When running on **Official OpenWrt 25.12.x (`aarch64`)**, the installer automatically offers to apply `files/odhcp6c`, `files/dhcpv6.sh`, and `files/dhcpv6.script`:
- Original 25.12.6 files are safely backed up to `/root/odhcp6c-25.12.6-backup/`.
- All three paths are added to `/etc/sysupgrade.conf` automatically.
- You can also apply the patch standalone via [`scripts/apply-mt7986-odhcp6c.sh`](scripts/apply-mt7986-odhcp6c.sh).

> **Rollback:** To restore stock 25.12.6 files at any time:
> ```sh
> cp -f /root/odhcp6c-25.12.6-backup/odhcp6c /usr/sbin/odhcp6c
> cp -f /root/odhcp6c-25.12.6-backup/dhcpv6.sh /lib/netifd/proto/dhcpv6.sh
> cp -f /root/odhcp6c-25.12.6-backup/dhcpv6.script /lib/netifd/dhcpv6.script
> ifdown wan6; sleep 2; ifup wan6
> ```

---

## WAN Status LED Legend

When enabled, `jio-wan-led` runs as a lightweight `procd` daemon polling live IPv6 (`2606:4700:4700::1111`) and 464XLAT IPv4 (`1.1.1.1`) every 15 seconds while leaving Wi-Fi LEDs untouched:

| Connection State | WAN / Status LED Behavior | Meaning |
| :--- | :--- | :--- |
| **Dual-Stack Online** | **Solid Green / Blue** | Both native IPv6 (`wan6`) and 464XLAT IPv4 (`464-clat`) are online. |
| **IPv6 Only** | **Slow Blink (800 ms)** | IPv6 is up, but `464-clat` IPv4 translation is down or degraded. |
| **WAN Offline** | **Solid Red** *(or Fast Blink 150 ms)* | Neither IPv6 nor IPv4 is reachable. |

---

## Step 4: Verify Your Connection

Run these commands right after setup—and once more after a full `reboot`:

```sh
ifstatus wan6 | grep -E '"up"|"address"'
ip link show dev 464-clat | grep -o 'mtu [0-9]*'
ip route show dev 464-clat
nft list chain inet fw4 clat_mss_clamp
ping -6 -c 2 2606:4700:4700::1111
ping -4 -c 2 1.1.1.1
wget -qO- -T 5 https://api.ipify.org && echo ""
```

### Expected Healthy Output
- **`wan6`:** `"up": true` with a global `2409:...` address
- **`464-clat` device MTU:** `mtu 1280`
- **IPv4 default route:** `default scope link metric 2048 mtu 1260 advmss 1220`
- **`fw4` MSS clamp:** `maxseg size set 1220` on both `oifname "464-clat"` and `iifname "464-clat"`
- **Public IPv4 check:** `api.ipify.org` returns your public Jio IPv4 address with `0%` packet loss

---

## Documentation, Credits & License

- **Technical Deep-Dive:** Read [`docs/TECHNICAL_ANALYSIS.md`](docs/TECHNICAL_ANALYSIS.md) for the packet-level 20-byte `kmod-nat46` MTU proof, throughput benchmarks (`19s -> 3s`, 0 dropped packets), and architectural comparison against `marufagul/jio-airfiber-openwrt-5g-wan`.
- **Credits & Acknowledgments:** See [`CREDITS.md`](CREDITS.md) — special thanks to [**marufagul**](https://github.com/marufagul) and **Google Gemini**.
- **License:** Copyright © 2026 **The DIY Daddy** ([github.com/the-diy-daddy](https://github.com/the-diy-daddy)). Strictly for **personal, non-commercial use** with exclusive video creation rights reserved — see [`LICENSE`](LICENSE) for full terms.