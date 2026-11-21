# Jio Airfiber 5G WAN For OpenWrt

A production-tested OpenWrt configuration and automated deployment toolkit for **Jio AirFiber 5G Outdoor Units (ODU)** using native **SLAAC IPv6 + 464XLAT (`kmod-nat46`) IPv4**.

Tested on **MediaTek Filogic (`mt7986`)** routers running both **Official OpenWrt 25.12.6** and **OpenWrt Snapshot**.

### Key Features
- **Zero-Troubleshooting Fresh-Reset Setup:** Download the repository once into `/tmp/jio-airfiber-5g-wan` over a temporary Wi-Fi client (`wwan`) and run one command—works cleanly right after a factory reset.
- **Automated Official 25.12.x `mt7986` `odhcp6c` Fix:** Automatically backs up stock files to `/root/odhcp6c-25.12.6-backup/`, applies the working `mt7986` (`aarch64`) `odhcp6c`, `dhcpv6.sh`, and `dhcpv6.script` with proper `0755` permissions, and restarts `netifd` so `dhcpv6` registers cleanly in LuCI.
- **Reliable 464XLAT Bring-Up:** Disables duplicate auto-spawned `464-wan6_4` (`iface_464xlat='0'`) and explicitly sets Jio's NAT64 prefix (`64:ff9b::/96`), allowing `464-clat` to start even with private non-DNS64 resolvers.
- **Zero-Drop 464XLAT Split-MTU Engine:** Enforces `1280` device MTU / `1260` IPv4 route MTU / `1220` TCP MSS clamp via `hotplug.d` and `nftables` (`fw4`), eliminating Jio NAT64 TCP stalls.
- **No `allmulticast` Flapping:** Disables conflicting `odhcpd` NDP relay on `wan` so `464xlat` maintains uninterrupted Proxy NDP.
- **Multi-Core Throughput:** Enables `packet_steering` while keeping `flow_offloading` disabled to prevent MediaTek PPE / `kmod-nat46` breakage.
- **ISP DNS Leak Prevention:** Forces Cloudflare & Google IPv4/IPv6 DNS via `dnsmasq` (`noresolv='1'`, `peerdns='0'`).
- **WAN Status LED Daemon:** Lightweight `procd` service (`jio-wan-led`) that reflects live IPv6 & 464XLAT health on router LEDs without touching AP Wi-Fi settings.
- **Sysupgrade Persistence:** Automatically registers hooks, LED daemons, and patched binaries in `/etc/sysupgrade.conf`.

---

## Repository Structure

```text
Jio-Airfiber-5G-WAN-For-OpenWrt/
├── README.md
├── LICENSE
├── CREDITS.md
├── .gitattributes
├── docs/
│   └── TECHNICAL_ANALYSIS.md
├── files/
│   ├── dhcpv6.script
│   ├── dhcpv6.sh
│   └── odhcp6c
└── scripts/
    ├── uci-defaults-wifi.sh
    ├── jio-airfiber-5g-wan.sh
    ├── apply-mt7986-odhcp6c.sh
    └── jio-wan-led.sh
```

*(Note: Both `files/` and `files/odhcp6c/` paths are auto-detected by the scripts.)*

---

## Step 1: Build Custom Firmware on OpenWrt Firmware Selector

1. Open [firmware-selector.openwrt.org](https://firmware-selector.openwrt.org/) and select your exact router model and OpenWrt version (**25.12.x** or **SNAPSHOT**).
2. Expand **Customize installed packages and/or first boot script**.
3. In **Installed Packages**, append the following packages to the existing list:

```text
luci 464xlat kmod-nat46 ip-tiny luci-proto-ipv6 ca-bundle
```

| Package | Purpose |
| :--- | :--- |
| `464xlat` | Userspace CLAT daemon translating IPv4 over Jio's IPv6-only 5G link via NAT64 (`64:ff9b::/96`). |
| `kmod-nat46` | Kernel module providing stateless IPv4-to-IPv6 packet translation (`464-clat` interface). |
| `ip-tiny` | Full `iproute2` utility supporting `mtu` and `advmss` route flags required by the hotplug hook. |
| `luci-proto-ipv6` | LuCI web UI support for managing DHCPv6/SLAAC and IPv6 interfaces. |
| `luci` | Web interface (required on Snapshot builds; safe to include on Official builds). |
| `ca-bundle` | Root TLS certificates so `wget` can download directly over HTTPS from GitHub. |

---

## Step 2: Enable Wi-Fi on First Boot (`uci-defaults`)

Paste the contents of `scripts/uci-defaults-wifi.sh` into **Script to run on first boot (uci-defaults)** on Firmware Selector before clicking **Request Build**. This enables 2.4 GHz & 5 GHz Wi-Fi (`OpenWrt-Jio5G` / `12345678`) with the MT76 `multicast_to_unicast='0'` DHCP fix.

---

## Step 3: Temporarily Connect to an External Wi-Fi Hotspot (`wwan`)

Because a fresh Official 25.12.6 router does not have Jio 5G internet yet:
1. Open LuCI (`http://192.168.1.1`) → **Network → Wireless**.
2. Click **Scan** on either radio and join your phone hotspot or existing Wi-Fi as a **Client** (`wwan`) in the `wan` firewall zone.
3. SSH into your router (`ssh root@192.168.1.1`).

---

## Step 4: Download Everything Once into `/tmp`

Run this single command to fetch the full repository (scripts + `mt7986` `odhcp6c` files) into `/tmp/jio-airfiber-5g-wan`:

```sh
rm -rf /tmp/Jio-Airfiber-5G-WAN-For-OpenWrt-main /tmp/jio-airfiber-5g-wan /tmp/jio5g.tar.gz && \
wget -4 -O /tmp/jio5g.tar.gz https://codeload.github.com/the-diy-daddy/Jio-Airfiber-5G-WAN-For-OpenWrt/tar.gz/refs/heads/main && \
tar -xzf /tmp/jio5g.tar.gz -C /tmp && \
mv /tmp/Jio-Airfiber-5G-WAN-For-OpenWrt-main /tmp/jio-airfiber-5g-wan && \
chmod +x /tmp/jio-airfiber-5g-wan/scripts/*.sh
```

*(Using `wget -4` with `codeload.github.com` bypasses DNS64 `64:ff9b::` hangs and redirect timeouts on fresh flashes.)*

---

## Step 5: Run the Universal Setup Script

Run the main script with your WAN MAC address (it automatically applies the `mt7986` `odhcp6c` fix on Official firmware, configures `wan6` + `clat`, installs split-MTU & `fw4` MSS clamping, and restarts `netifd`):

```sh
# Untagged WAN (default / bridge ODU) — interactive prompts for remaining options
/tmp/jio-airfiber-5g-wan/scripts/jio-airfiber-5g-wan.sh --mac "00:1A:79:b6:56:6c"

# Fully non-interactive Untagged WAN
/tmp/jio-airfiber-5g-wan/scripts/jio-airfiber-5g-wan.sh --untagged --mac "00:1A:79:b6:56:6c" --led -y

# Fully non-interactive VLAN 1015 (standard Jio AirFiber ODU)
/tmp/jio-airfiber-5g-wan/scripts/jio-airfiber-5g-wan.sh --vlan1015 --mac "00:1A:79:b6:56:6c" --led -y
```

### Standalone `mt7986` `odhcp6c` Fix / Rollback
If you ever want to apply or roll back only the Official 25.12.6 `odhcp6c` fix:

```sh
# Apply standalone
/tmp/jio-airfiber-5g-wan/scripts/apply-mt7986-odhcp6c.sh

# Roll back to stock Official 25.12.6 files
/tmp/jio-airfiber-5g-wan/scripts/apply-mt7986-odhcp6c.sh --rollback
```

---

## Step 6: Switch from Temporary `wwan` to Jio 5G WAN & Verify

1. In LuCI (**Network → Wireless** and **Network → Interfaces**), remove or disable your temporary `wwan` Wi-Fi client.
2. Plug the Jio AirFiber 5G ODU Ethernet cable into the router's **WAN** port and reboot (`reboot`).
3. Wait 1–2 minutes for the first Jio Router Advertisement, then verify via SSH:

```sh
ifstatus wan6 | grep -E '"up"|"proto"|"device"|"address"'
ip link show dev 464-clat | grep -o 'mtu [0-9]*'
ip route show dev 464-clat
nft list chain inet fw4 clat_mss_clamp
ping -6 -c 2 2606:4700:4700::1111
ping -4 -c 2 1.1.1.1
wget -4 -qO- -T 5 https://api.ipify.org && echo ""
```

Expected output:
- `wan6`: `"up": true`, `"proto": "dhcpv6"`, global `2409:...` address
- `464-clat`: `mtu 1280`
- IPv4 route: `default scope link metric 2048 mtu 1260 advmss 1220`
- `fw4` MSS clamp: `maxseg size set 1220` on both `oifname` and `iifname`
- `api.ipify.org`: prints your public Jio IPv4 address

---

## Documentation, Credits & License

- Read the full [Technical Analysis Report](docs/TECHNICAL_ANALYSIS.md) for packet-level root cause analysis, benchmarks, and architectural comparisons.
- See [CREDITS.md](CREDITS.md) for full acknowledgments (including **[marufagul](https://github.com/marufagul)** and **Google Gemini**).
- Copyright © 2026 **The DIY Daddy** (`https://github.com/the-diy-daddy`). Strictly for personal, non-commercial use — see [LICENSE](LICENSE) for full terms and video creation restrictions.
