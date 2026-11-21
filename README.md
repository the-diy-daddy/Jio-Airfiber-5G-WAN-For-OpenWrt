<div align="center">

# Jio AirFiber 5G WAN for OpenWrt

**Production-tested SLAAC IPv6 + 464XLAT (`kmod-nat46`) automation toolkit for Jio AirFiber 5G ODUs on OpenWrt**

[![OpenWrt](https://img.shields.io/badge/OpenWrt-25.12.x%20%7C%20Snapshot-00B5E2?style=for-the-badge&logo=openwrt&logoColor=white)](https://openwrt.org/)
[![Target](https://img.shields.io/badge/Target-MediaTek%20Filogic%20MT7986-2B3137?style=for-the-badge)](https://openwrt.org/docs/techref/hardware/soc/soc.mediatek)
[![Protocol](https://img.shields.io/badge/Stack-IPv6%20SLAAC%20%2B%20464XLAT-10B981?style=for-the-badge)](#why-this-toolkit)
[![License](https://img.shields.io/badge/License-Personal%20Non--Commercial-E11D48?style=for-the-badge)](LICENSE)
[![YouTube](https://img.shields.io/badge/YouTube-The%20DIY%20Daddy-FF0000?style=for-the-badge&logo=youtube&logoColor=white)](https://www.youtube.com/@the_diy_daddy)

[Quick Start](#quick-start) •
[Firmware Build](#step-1-build-custom-firmware) •
[CLI Reference](#cli-options) •
[Verification](#step-6-switch-to-jio-5g-wan--verify) •
[Technical Report](docs/TECHNICAL_ANALYSIS.md) •
[Credits](CREDITS.md)

</div>

---

## Why This Toolkit?

Standard OpenWrt installs hit four separate failures on Jio AirFiber 5G links: **NAT64 TCP stalls**, **`odhcpd` `allmulticast` flapping**, **duplicate `464-wan6_4` interfaces**, and an **`odhcp6c` regression on Official OpenWrt 25.12.6**. This toolkit automates the empirically verified fix end-to-end without touching your AP Wi-Fi settings.

| Feature | What It Solves |
| :--- | :--- |
| **Zero-Drop Split-MTU Engine (`1280 / 1260 / 1220`)** | Sets `464-clat` device MTU to `1280`, IPv4 route MTU to `1260` (`advmss 1220`), and `fw4` forward-chain TCP MSS clamping to `1220` — cutting 10 MB IPv4 downloads from **19s → 3s** with **0 drops**. |
| **Auto Official 25.12.x `mt7986` `odhcp6c` Fix** | Automatically backs up stock files to `/root/odhcp6c-25.12.6-backup/`, atomically installs the working `aarch64` `odhcp6c`, `dhcpv6.sh`, and `dhcpv6.script` (`chmod 0755`), verifies protocol registration, and skips itself on Snapshots. |
| **Clean 464XLAT + Private DNS** | Locks `wan6.iface_464xlat='0'` and `clat.ip6prefix='64:ff9b::/96'` so a single `464-clat` interface starts cleanly while enforcing Cloudflare & Google IPv4/IPv6 DNS (`noresolv='1'`, `peerdns='0'`). |
| **Zero `allmulticast` Flapping & Safe Offload** | Disables conflicting `odhcpd` NDP relay on `wan`, disables `flow_offloading` (prevents MediaTek PPE / `kmod-nat46` stalls), and enables `packet_steering='1'`. |
| **SSH-Safe Execution & Rollback** | Ignores `SIGHUP`, commits and `sync`s 100% of configs to flash before triggering a detached background `netifd` restart (or skip restart completely with `--no-restart`). |
| **WAN Status LED Daemon & Sysupgrade Safe** | Optional `procd` LED monitor (`jio-wan-led`) showing live IPv6/IPv4 health (never touches Wi-Fi LEDs), with all hooks and binaries registered in `/etc/sysupgrade.conf`. |

---

## Measured Performance (Live `mt7986` Hardware)

| Test (10 MB Cloudflare File) | Default / Single MTU (`1380/1340`) | This Toolkit (`1280 / 1260 / 1220`) |
| :--- | :---: | :---: |
| **IPv4 over 464XLAT (`464-clat`)** | `19s` (TCP stalls & retransmissions) | **`3s`** (`13,589` pkts · **`0` errors · `0` drops**) |
| **Native IPv6 (`wan6`)** | `3s` | **`3–4s`** (`0%` packet loss) |
| **NAT64 / `allmulticast` Kernel Flaps** | Every ~100 ms (with `ndp='relay'`) | **`0`** |

> [!NOTE]
> Deep-dive packet analysis, kernel log traces, and architectural benchmarks are documented in **[`docs/TECHNICAL_ANALYSIS.md`](docs/TECHNICAL_ANALYSIS.md)**.

---

## Quick Start

### Step 1: Build Custom Firmware

Open **[OpenWrt Firmware Selector](https://firmware-selector.openwrt.org/)**, pick your router model and OpenWrt version (**25.12.x Official** or **SNAPSHOT**), expand **Customize installed packages and/or first boot script**, and append these packages:

```text
luci 464xlat kmod-nat46 ip-tiny luci-proto-ipv6 ca-bundle
```

<details>
<summary><strong>Why each package is required</strong> (click to expand)</summary>

| Package | Role |
| :--- | :--- |
| `464xlat` | Userspace CLAT daemon translating IPv4 traffic over Jio's IPv6-only 5G link (`64:ff9b::/96`). |
| `kmod-nat46` | Kernel module providing stateless IPv4 ↔ IPv6 translation (`464-clat` interface). |
| `ip-tiny` | Full `iproute2` binary required for `mtu` and `advmss` route flags (BusyBox `ip` ignores them). |
| `luci-proto-ipv6` | LuCI web UI support for DHCPv6/SLAAC and IPv6 interfaces. |
| `luci` | Web interface (required on Snapshot builds; safe to include on Official builds). |
| `ca-bundle` | TLS root certificates for HTTPS downloads from GitHub and `api.ipify.org`. |

*(Optional: append `luci-ssl` if you want HTTPS access to LuCI.)*

</details>

---

### Step 2: Enable First-Boot Wi-Fi (`uci-defaults`)

OpenWrt ships with Wi-Fi disabled after a fresh flash. Paste [`scripts/uci-defaults-wifi.sh`](scripts/uci-defaults-wifi.sh) into **Script to run on first boot (uci-defaults)** before clicking **Request Build**. It brings up 2.4 GHz & 5 GHz Wi-Fi (`OpenWrt-Jio5G` / `12345678`) with the MT76 `multicast_to_unicast='0'` DHCP fix.

<details>
<summary><strong>View <code>scripts/uci-defaults-wifi.sh</code></strong> (click to expand & copy)</summary>

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

---

### Step 3: Temporarily Connect to an External Wi-Fi Hotspot (`wwan`)

> [!TIP]
> On a freshly flashed router without Jio 5G internet yet, give the router temporary internet via your phone hotspot or existing Wi-Fi so it can fetch the toolkit cleanly into `/tmp`.

1. Flash your custom `sysupgrade.bin`, connect to `OpenWrt-Jio5G` (password `12345678`), and open LuCI at `http://192.168.1.1`.
2. Go to **Network → Wireless**, click **Scan** on either radio, and join your external Wi-Fi as a **Client** (`wwan`) assigned to the `wan` firewall zone.
3. Connect over SSH:
   ```sh
   ssh root@192.168.1.1
   ```

---

### Step 4: Download the Toolkit Once into `/tmp`

Run this single command to download and extract all scripts and `mt7986` `odhcp6c` files into `/tmp/jio-airfiber-5g-wan`:

```sh
rm -rf /tmp/Jio-Airfiber-5G-WAN-For-OpenWrt-main /tmp/jio-airfiber-5g-wan /tmp/jio5g.tar.gz && \
wget -4 -O /tmp/jio5g.tar.gz https://codeload.github.com/the-diy-daddy/Jio-Airfiber-5G-WAN-For-OpenWrt/tar.gz/refs/heads/main && \
tar -xzf /tmp/jio5g.tar.gz -C /tmp && \
mv /tmp/Jio-Airfiber-5G-WAN-For-OpenWrt-main /tmp/jio-airfiber-5g-wan && \
chmod +x /tmp/jio-airfiber-5g-wan/scripts/*.sh
```

> [!NOTE]
> Using `wget -4` with `codeload.github.com` bypasses Jio DNS64 (`64:ff9b::`) hangs and `github.com` redirect timeouts on fresh flashes.

---

### Step 5: Run the Setup Script

Pick **one** command below that matches your setup *(replace the MAC address with your Jio router's WAN MAC, or omit `--mac` to keep your factory MAC)*:

#### Option A — Recommended: Untagged `wan` (One-Command Non-Interactive)
Works for most Jio AirFiber 5G ODUs & bridge-mode setups. Automatically applies the Official 25.12.x `mt7986` `odhcp6c` fix, configures `wan6` + `clat` + split-MTU + `fw4` MSS clamping, and installs the WAN LED monitor:

```sh
/tmp/jio-airfiber-5g-wan/scripts/jio-airfiber-5g-wan.sh --untagged --mac "00:1A:79:b6:56:6c" --led -y
```

#### Option B — Installing Over Temporary `wwan` (No SSH Drop Until You Reboot)
Same as Option A, but skips the immediate `netifd` restart so your SSH/LuCI session stays up while you remove `wwan` and plug in the Jio ODU:

```sh
/tmp/jio-airfiber-5g-wan/scripts/jio-airfiber-5g-wan.sh --untagged --mac "00:1A:79:b6:56:6c" --led --no-restart -y
```

#### Option C — VLAN `1015` Mode (`wan.1015`)
Use **only** if your specific Jio AirFiber ODU requires 802.1Q VLAN `1015` tagging on the Ethernet port:

```sh
/tmp/jio-airfiber-5g-wan/scripts/jio-airfiber-5g-wan.sh --vlan1015 --mac "00:1A:79:b6:56:6c" --led -y
```

#### Option D — Interactive Mode (Guided Prompts)

```sh
/tmp/jio-airfiber-5g-wan/scripts/jio-airfiber-5g-wan.sh --mac "00:1A:79:b6:56:6c"
```

> [!IMPORTANT]
> You **do not** need to run `apply-mt7986-odhcp6c.sh` separately — `jio-airfiber-5g-wan.sh` detects Official 25.12.x on `aarch64` and applies the `files/` patch automatically.

---

### Step 6: Switch to Jio 5G WAN & Verify

1. In LuCI (**Network → Wireless** and **Network → Interfaces**), delete or disable your temporary `wwan` Wi-Fi client so all IPv4 traffic routes through Jio `464-clat`.
2. Plug the Jio AirFiber 5G ODU Ethernet cable into the router's **WAN** port and reboot:
   ```sh
   reboot
   ```
3. Wait **1–2 minutes** for the first Jio Router Advertisement, then verify via SSH:

```sh
ifstatus wan6 | grep -E '"up"|"proto"|"device"|"address"'
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
"device": "wan",
"address": "2409:xxxx:xxxx:xxxx::xxxx",
mtu 1280
default scope link metric 2048 mtu 1260 advmss 1220
... maxseg size set 1220
2 packets transmitted, 2 packets received, 0% packet loss
2 packets transmitted, 2 packets received, 0% packet loss
152.58.xxx.xxx
```

---

## CLI Options

<details>
<summary><strong>Full <code>jio-airfiber-5g-wan.sh</code> CLI Reference & Standalone Rollback</strong> (click to expand)</summary>

| Flag | Description |
| :--- | :--- |
| `--untagged` | Use untagged `wan` device (**recommended default**). |
| `--vlan1015` | Create and use `802.1Q` VLAN `1015` (`wan.1015`). |
| `--mac "<MAC>"` | Clone a specific WAN MAC address (e.g., `"00:1A:79:b6:56:6c"`). |
| `--nat64-prefix "<CIDR>"` | Override Jio NAT64 IPv6 prefix (default: `64:ff9b::/96`). |
| `--led` / `--no-led` | Enable (default) or skip installing the `jio-wan-led` status daemon. |
| `--odhcp6c-fix` / `--no-odhcp6c-fix` | Force or skip the Official 25.12.x `mt7986` `odhcp6c` patch (auto-detected by default). |
| `--no-restart` | Write & commit everything to flash without triggering `network restart` (apply via `reboot`). |
| `-y`, `--yes` | Non-interactive mode — accept defaults for any omitted options. |

#### Standalone `mt7986` `odhcp6c` Patch & Rollback
```sh
# Apply standalone (Official firmware only)
/tmp/jio-airfiber-5g-wan/scripts/apply-mt7986-odhcp6c.sh
```

```sh
# Restore stock Official 25.12.6 odhcp6c files from /root/odhcp6c-25.12.6-backup/
/tmp/jio-airfiber-5g-wan/scripts/apply-mt7986-odhcp6c.sh --rollback
```

#### Inspect Setup & Restart Logs
```sh
cat /tmp/jio-5g-setup.log
cat /tmp/jio-network-restart.log
```

</details>

<details>
<summary><strong>Quick Troubleshooting</strong> (click to expand)</summary>

- **`wan6` stays `"up": false` after reboot:** Check whether your ODU expects untagged `wan` vs VLAN `1015`. Switch instantly with:
  ```sh
  uci set network.wan6.device='wan' && uci -q delete network.wan_1015 || true && uci commit network && /etc/init.d/network reload
  ```
- **First connection takes 1–2 minutes:** Jio 5G ODUs send periodic Router Advertisements; wait up to 120 seconds after plugging in the WAN cable or rebooting before assuming a failure.
- **IPv4 still routing via phone hotspot:** Make sure you deleted or disabled your temporary `wwan` interface in LuCI (`ip -4 route` should show only `464-clat` as the default route).

</details>

---

## Repository Layout

```text
Jio-Airfiber-5G-WAN-For-OpenWrt/
├── README.md                           # Main guide & quick start
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
    ├── jio-airfiber-5g-wan.sh          # Universal all-in-one setup script
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
