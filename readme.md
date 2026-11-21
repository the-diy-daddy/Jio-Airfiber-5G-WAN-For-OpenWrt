<div align="center">

# Jio Airfiber 5G WAN For OpenWrt

**Production-Tested SLAAC IPv6 + 464XLAT (`kmod-nat46`) Automation for MediaTek Filogic (`mt7986`) Routers**

[![OpenWrt](https://img.shields.io/badge/OpenWrt-25.12.x%20%7C%20Snapshot-00B5E2?style=for-the-badge&logo=openwrt&logoColor=white)](https://openwrt.org/)
[![Platform](https://img.shields.io/badge/Platform-MediaTek%20Filogic%20mt7986-2E7D32?style=for-the-badge)](https://openwrt.org/docs/techref/hardware/soc/soc.mediatek.filogic)
[![IPv4 over IPv6](https://img.shields.io/badge/Transport-464XLAT%20Split--MTU-FF6F00?style=for-the-badge)](docs/TECHNICAL_ANALYSIS.md)
[![License](https://img.shields.io/badge/License-Personal%20Non--Commercial-D32F2F?style=for-the-badge)](LICENSE)

*Built and hardware-verified on live Jio AirFiber 5G ODU connections across **OpenWrt Snapshot** and **Official OpenWrt 25.12.6**.*

[Firmware Build](#step-1-build-firmware-on-openwrt-firmware-selector) •
[First-Boot Wi-Fi](#step-2-enable-wi-fi-on-first-boot-uci-defaults) •
[Download to /tmp](#step-4-download-everything-to-tmp-at-once) •
[Run Scripts](#step-5-apply-configuration--official-odhcp6c-fix) •
[WAN LED States](#wan-status-led-legend) •
[Verification](#step-7-verify-your-connection) •
[Technical Analysis](docs/TECHNICAL_ANALYSIS.md)

</div>

---

## Why This Toolkit Exists

Jio AirFiber 5G Outdoor Units (ODU) deliver an **IPv6-only SLAAC transport without Prefix Delegation (`IA_PD`)** and translate IPv4 through Jio's carrier NAT64 gateway (`64:ff9b::/96`). Stock OpenWrt configurations suffer from four silent failure modes on this link:

1. **TCP Stalls & Packet Drops:** Default `464-clat` MTU settings trigger silent drops on Jio's 1280-byte NAT64 TCP path (`19s` for 10 MB vs. `3s` with Split-MTU).
2. **`allmulticast` Interface Flapping:** Enabling `odhcpd` NDP relay conflicts with `464xlat` Proxy NDP, toggling `wan` multicast mode every ~100 ms.
3. **Flow Offloading Breakage:** Both MediaTek Hardware PPE and Software Flow Offloading break `kmod-nat46` translation or bypass TCP MSS clamping.
4. **Official OpenWrt 25.12.6 `odhcp6c` Regression:** Stock `odhcp6c` on Official 25.12.6 fails to reliably bring up SLAAC on Jio 5G without the verified `mt7986` (`aarch64`) `files/odhcp6c/` bundle.

---

## Key Features

| Feature | Implementation Details |
| :--- | :--- |
| **Universal Firmware Support** | Works seamlessly on both **OpenWrt Snapshot** and **Official OpenWrt 25.12.x** (`opkg` & `apk` aware). |
| **One-Shot `/tmp` Staging** | Pull the entire repo into `/tmp/5g-wan-jio-airfiber-for-openwrt` over temporary external Wi-Fi (`wwan`), then apply offline. |
| **Automatic Official `odhcp6c` Fix** | Detects Official `aarch64` (`mt7986`) firmware, backs up stock files to `/root/odhcp6c-25.12.6-backup/`, and applies `files/odhcp6c/`. |
| **Dual WAN Topologies** | Supports both **Untagged `wan`** (bridge ODU) and **VLAN `1015` (`wan.1015`)** with `--mac` cloning. |
| **Zero-Drop 464XLAT Split-MTU** | Enforces `1280` device MTU, `1260` IPv4 route MTU, and `1220` TCP MSS clamping via `hotplug.d` + `fw4` (`nftables`). |
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
├── files/
│   └── odhcp6c/                           # Verified mt7986 (aarch64) odhcp6c fix bundle for Official FW
│       ├── odhcp6c
│       ├── dhcpv6.sh
│       └── dhcpv6.script
└── scripts/
    ├── uci-defaults-wifi.sh               # First-boot Wi-Fi + MT76 DHCP fix for Firmware Selector
    ├── jio-airfiber-5g-wan.sh             # Universal Jio 5G WAN installer (Snapshot & Official 25.12.x)
    ├── apply_mt7986_odhcp6c.sh            # Standalone mt7986 (aarch64) Official firmware odhcp6c patcher
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
| `ca-bundle` | TLS root certificates so `wget` can download the repository archive and query HTTPS endpoints like `https://api.ipify.org`. |

> **Tip:** Add `luci-ssl` if you want HTTPS access to LuCI.

---

## Step 2: Enable Wi-Fi on First Boot (`uci-defaults`)

OpenWrt ships with Wi-Fi disabled after a fresh flash. To bring up both **2.4 GHz** and **5 GHz** automatically on first boot—with the **MT76 DHCP `multicast_to_unicast='0'` fix**—paste [`scripts/uci-defaults-wifi.sh`](scripts/uci-defaults-wifi.sh) into **Script to run on first boot (uci-defaults)** on Firmware Selector before clicking **Request Build**:

<details>
<summary><strong>Click to expand First-Boot Wi-Fi Script (scripts/uci-defaults-wifi.sh)</strong></summary>

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

Flash your custom `sysupgrade.bin`, connect to **`OpenWrt-Jio5G`** (password: `12345678`), and log in to LuCI (`http://192.168.1.1`) or SSH (`root@192.168.1.1`).

---

## Step 3: Give the Router Temporary Internet via External Wi-Fi Client (`wwan`)

Before connecting your Jio AirFiber 5G ODU, temporarily connect the OpenWrt router to an existing Wi-Fi network (such as your phone hotspot or home router) as a **Wi-Fi Client**:

1. Open LuCI at **`http://192.168.1.1`**.
2. Go to **Network → Wireless** and click **Scan** on one of the radios (e.g., 2.4 GHz or 5 GHz).
3. Click **Join Network** next to your external Wi-Fi / mobile hotspot.
4. Enter the Wi-Fi passphrase, keep the default firewall zone (**`wan`**) and interface name (**`wwan`**), then click **Submit** → **Save & Apply**.
5. SSH into `root@192.168.1.1` and verify internet access:
   ```sh
   ping -c 2 github.com
   ```

---

## Step 4: Download Everything to `/tmp` at Once

Run this single command over SSH to download the entire repository (all scripts + the `files/odhcp6c/` bundle) straight into `/tmp/5g-wan-jio-airfiber-for-openwrt`:

```sh
rm -rf /tmp/Jio-Airfiber-5G-WAN-For-OpenWrt-main /tmp/5g-wan-jio-airfiber-for-openwrt /tmp/jio5g.tar.gz && \
wget -4 -O /tmp/jio5g.tar.gz https://codeload.github.com/the-diy-daddy/Jio-Airfiber-5G-WAN-For-OpenWrt/tar.gz/refs/heads/main && \
tar -xzf /tmp/jio5g.tar.gz -C /tmp && \
mv /tmp/Jio-Airfiber-5G-WAN-For-OpenWrt-main /tmp/5g-wan-jio-airfiber-for-openwrt && \
chmod +x /tmp/5g-wan-jio-airfiber-for-openwrt/scripts/*.sh
```

> Everything is now staged locally in `/tmp/5g-wan-jio-airfiber-for-openwrt`—you can run the scripts below immediately or offline without touching your Wi-Fi AP settings.

---

## Step 5: Apply Configuration & Official `odhcp6c` Fix

### 1. Run the Main Jio 5G WAN Setup Script
Pass your Jio ODU / old router MAC address with `--mac` (or omit `--mac` to keep the hardware MAC):

```sh
# Standard interactive run with MAC clone (auto-detects Official FW and applies odhcp6c fix)
/tmp/5g-wan-jio-airfiber-for-openwrt/scripts/jio_airfiber_5g_wan.sh --mac "00:1A:79:b6:56:6c"
```

#### Unattended / Advanced Examples
```sh
# Untagged WAN (bridge ODU) + MAC clone + WAN LED, no prompts
/tmp/5g-wan-jio-airfiber-for-openwrt/scripts/jio_airfiber_5g_wan.sh --untagged --mac "00:1A:79:b6:56:6c" --led

# VLAN 1015 WAN (standard Jio AirFiber ODU) + MAC clone + WAN LED, no prompts
/tmp/5g-wan-jio-airfiber-for-openwrt/scripts/jio_airfiber_5g_wan.sh --vlan1015 --mac "00:1A:79:b6:56:6c" --led
```

| Flag | Description |
| :--- | :--- |
| `--mac "XX:XX:XX:XX:XX:XX"` | Clones the specified MAC address on `wan` (and `wan.1015` in VLAN mode). |
| `--untagged` / `--vlan1015` | Selects Untagged `wan` or VLAN `1015` (`wan.1015`) without prompting. |
| `--led` / `--no-led` | Enables or skips the `jio-wan-led` status LED daemon. |
| `--odhcp6c-fix` / `--no-odhcp6c-fix` | Forces or skips the Official `mt7986` `odhcp6c` patch (default: **auto** on Official `aarch64` builds). |
| `-y`, `--yes` | Non-interactive mode using defaults (`untagged`, WAN LED on, auto `odhcp6c` fix). |

### 2. Standalone Official Firmware `odhcp6c` Fix (`mt7986` / `aarch64`)
`jio-airfiber-5g-wan.sh` **automatically** applies the `files/odhcp6c/` bundle whenever Official OpenWrt firmware is detected on `aarch64` (`mt7986`). If you ever want to apply it standalone (or re-apply after testing), run:

```sh
/tmp/5g-wan-jio-airfiber-for-openwrt/scripts/apply_mt7986_odhcp6c.sh
```

- Automatically backs up your stock Official files once to `/root/odhcp6c-25.12.6-backup/`.
- Registers `/usr/sbin/odhcp6c`, `/lib/netifd/proto/dhcpv6.sh`, and `/lib/netifd/dhcpv6.script` in `/etc/sysupgrade.conf`.
- Automatically skips on OpenWrt Snapshot builds (use `--force` to override).

#### Rollback to Stock Official `odhcp6c` Files
Run `/tmp/5g-wan-jio-airfiber-for-openwrt/scripts/apply_mt7986_odhcp6c.sh --rollback` or restore manually:

```sh
cp -f /root/odhcp6c-25.12.6-backup/odhcp6c /usr/sbin/odhcp6c
cp -f /root/odhcp6c-25.12.6-backup/dhcpv6.sh /lib/netifd/proto/dhcpv6.sh
cp -f /root/odhcp6c-25.12.6-backup/dhcpv6.script /lib/netifd/dhcpv6.script
ifdown wan6; sleep 2; ifup wan6
```

---

## Step 6: Switch to Jio AirFiber 5G ODU & Reboot

Once the scripts finish:

1. In LuCI (**Network → Wireless**), **Remove** or **Disable** your temporary external Wi-Fi client (`wwan`) and delete the `wwan` interface under **Network → Interfaces** (so it doesn't compete for the default route).
2. Plug the Ethernet cable from your **Jio AirFiber 5G ODU** into the router's **WAN** port.
3. Reboot the router:
   ```sh
   reboot
   ```

---

## WAN Status LED Legend

When enabled, `jio-wan-led` runs as a lightweight `procd` daemon polling live IPv6 (`2606:4700:4700::1111`) and 464XLAT IPv4 (`1.1.1.1`) every 15 seconds while leaving Wi-Fi LEDs untouched:

| Connection State | WAN / Status LED Behavior | Meaning |
| :--- | :--- | :--- |
| **Dual-Stack Online** | **Solid Green / Blue** | Both native IPv6 (`wan6`) and 464XLAT IPv4 (`464-clat`) are online. |
| **IPv6 Only** | **Slow Blink (800 ms)** | IPv6 is up, but `464-clat` IPv4 translation is down or degraded. |
| **WAN Offline** | **Solid Red** *(or Fast Blink 150 ms)* | Neither IPv6 nor IPv4 is reachable. |

---

## Step 7: Verify Your Connection

Wait ~45 seconds after reboot, SSH back into `root@192.168.1.1`, and run:

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
