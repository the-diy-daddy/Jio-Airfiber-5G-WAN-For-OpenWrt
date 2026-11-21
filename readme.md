# Jio Airfiber 5G WAN For OpenWrt

A production-tested OpenWrt configuration and automated deployment toolkit for **Jio AirFiber 5G Outdoor Units (ODU)** using native **SLAAC IPv6 + 464XLAT (`kmod-nat46`) IPv4**.

Tested on **MediaTek Filogic (`mt7986`)** routers running both **OpenWrt Snapshot** and **Official OpenWrt 25.12.6**.

### Key Features

* **Universal Compatibility:** Works on both **Snapshot** and **Official 25.12.x** firmware, supporting both **Untagged `wan`** and **VLAN `1015` (`wan.1015`)** ODU topologies.
* **Zero-Drop 464XLAT Split-MTU Engine:** Enforces the empirically verified `1280` device MTU / `1260` IPv4 route MTU / `1220` TCP MSS clamp via `hotplug.d` and `nftables` (`fw4`), eliminating Jio NAT64 TCP stalls.
* **No `allmulticast` Flapping:** Disables conflicting `odhcpd` NDP relay on `wan` so `464xlat` maintains uninterrupted Proxy NDP.
* **Multi-Core Throughput:** Enables `packet_steering` while keeping `flow_offloading` disabled to prevent MediaTek PPE / `kmod-nat46` breakage.
* **ISP DNS Leak Prevention:** Forces Cloudflare & Google IPv4/IPv6 DNS via `dnsmasq` (`noresolv='1'`, `peerdns='0'`).
* **WAN Status LED Daemon:** Lightweight `procd` service (`5g-wan-led`) that reflects live IPv6 & 464XLAT health on router LEDs without touching Wi-Fi settings.
* **Sysupgrade Persistence:** Automatically registers hooks and critical files in `/etc/sysupgrade.conf`.

## Repository Structure

```text
5g-wan-jio-airfiber-for-openwrt/
├── README.md
├── CREDITS.md
├── LICENSE
├── docs/
│   └── TECHNICAL_ANALYSIS.md
└── scripts/
    ├── uci-defaults-wifi.sh
    ├── 5g-wan-jio-airfiber-for-openwrt.sh
    └── 5g-wan-led.sh
```

## Step 1: Build Custom Firmware on OpenWrt Firmware Selector

1. Open [firmware-selector.openwrt.org](https://firmware-selector.openwrt.org/) and select your exact router model and OpenWrt version (**25.12.x** or **SNAPSHOT**).
2. Expand **Customize installed packages and/or first boot script**.
3. In **Installed Packages**, append the following packages to the existing list:

```text
luci 464xlat kmod-nat46 ip-tiny luci-proto-ipv6 ca-bundle
```

### Why Each Package Is Required

| Package | Purpose |
| :--- | :--- |
| `464xlat` | Userspace CLAT daemon that translates IPv4 traffic over Jio's IPv6-only 5G network via NAT64 (`64:ff9b::/96`). |
| `kmod-nat46` | Kernel module providing stateless IPv4-to-IPv6 packet translation (`464-clat` interface). |
| `ip-tiny` | Full `iproute2` utility (BusyBox `ip` lacks reliable `mtu`/`advmss` route replacement flags needed by our hotplug hook). |
| `luci-proto-ipv6` | LuCI web UI support for managing DHCPv6/SLAAC and IPv6 interfaces. |
| `luci` | Web interface (**required on Snapshots**, which ship without LuCI; harmless to include on Official builds). |
| `ca-bundle` | Root TLS certificates so `wget` / `uclient-fetch` can verify HTTPS endpoints (such as `https://api.ipify.org`) from SSH. |

*(Optional: Add `luci-ssl` if you want HTTPS access to LuCI.)*

## Step 2: Enable Wi-Fi on First Boot (`uci-defaults`)

OpenWrt disables Wi-Fi by default after a fresh flash. To ensure both 2.4 GHz and 5 GHz Wi-Fi start automatically—including the **MT76 DHCP `multicast_to_unicast='0'` fix**—paste the following into **Script to run on first boot (uci-defaults)** on Firmware Selector before clicking **Request Build**:

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

Flash the generated `sysupgrade.bin` image, connect to `OpenWrt-Jio5G` (password `12345678`), and SSH into `root@192.168.1.1`.

## Step 3: Run the Universal Setup Script

Copy `scripts/5g-wan-jio-airfiber-for-openwrt.sh` to your router and run it. It works on both **Snapshot** and **Official 25.12.x** and **never modifies your Wi-Fi configuration**.

```sh
chmod +x /tmp/5g-wan-jio-airfiber-for-openwrt.sh
/tmp/5g-wan-jio-airfiber-for-openwrt.sh
```

### Non-Interactive / CLI Options

You can also pass environment variables directly:

```sh
# Untagged WAN (default) with MAC clone and WAN LED enabled
WAN_MODE="untagged" WAN_MAC="00:1A:79:B6:56:6C" ENABLE_WAN_LED="1" /tmp/5g-wan-jio-airfiber-for-openwrt.sh

# VLAN 1015 mode for standard Jio AirFiber ODU
WAN_MODE="vlan1015" WAN_MAC="00:1A:79:B6:56:6C" ENABLE_WAN_LED="1" /tmp/5g-wan-jio-airfiber-for-openwrt.sh
```

> **Note for Official OpenWrt 25.12.6:** If `wan6` fails to receive a Router Advertisement on Official 25.12.6 due to the `odhcp6c` regression, replace `/usr/sbin/odhcp6c`, `/lib/netifd/proto/dhcpv6.sh`, and `/lib/netifd/dhcpv6.script` with the working snapshot copies. This script automatically preserves those paths in `/etc/sysupgrade.conf` when detected.

## Step 4: Verify Your Connection

Run these commands after the script completes (and again after a `reboot`):

```sh
ifstatus wan6 | grep -E '"up"|"address"'
ip link show dev 464-clat | grep -o 'mtu [0-9]*'
ip route show dev 464-clat
nft list chain inet fw4 clat_mss_clamp
ping -6 -c 2 2606:4700:4700::1111
ping -4 -c 2 1.1.1.1
wget -qO- -T 5 https://api.ipify.org && echo ""
```

Expected output:

* `wan6`: `"up": true` with a global `2409:...` address
* `464-clat`: `mtu 1280`
* IPv4 route: `default scope link metric 2048 mtu 1260 advmss 1220`
* `fw4` MSS clamp: `maxseg size set 1220` on both `oifname` and `iifname`
* `api.ipify.org`: prints your public Jio IPv4 address

## Documentation, Credits & License

* Read the full [Technical Analysis Report](docs/TECHNICAL_ANALYSIS.md) for packet-level root cause analysis, benchmarks, and architectural comparisons.
* See [CREDITS.md](CREDITS.md) for full acknowledgments (including [**marufagul**](https://github.com/marufagul) and **Google Gemini**).
* Copyright © 2026 **The DIY Daddy**. Strictly for personal, non-commercial use — see [LICENSE](LICENSE) for full terms and video creation restrictions.