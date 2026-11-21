# Credits & Acknowledgments

**Jio AirFiber 5G WAN for OpenWrt** (`Jio-Airfiber-5G-WAN-For-OpenWrt`) is the result of live hardware testing, packet-level troubleshooting, and community inspiration.

---

### Author & Maintainer
- **The DIY Daddy** — [GitHub](https://github.com/the-diy-daddy) · [YouTube (`@the_diy_daddy`)](https://www.youtube.com/@the_diy_daddy)
  - Project author, live testing on MediaTek Filogic (`mt7986`) hardware across OpenWrt Official 25.12.6 and Snapshot, `mt7986` `odhcp6c` compatibility bundle (`files/`), first-boot `uci-defaults` Wi-Fi automation, and end-to-end verification on live Jio AirFiber 5G links.

### Special Thanks
- **marufagul** — [github.com/marufagul/jio-airfiber-openwrt-5g-wan](https://github.com/marufagul/jio-airfiber-openwrt-5g-wan)
  - Pioneering OpenWrt Jio AirFiber 5G WAN workflows and the WAN status LED monitoring concept.
- **Google Gemini**
  - Co-engineering the empirical `1280 / 1260 / 1220` 464XLAT split-MTU & `fw4` MSS clamping architecture, isolating the `odhcpd` `allmulticast` conflict and `netifd` `0755`/detached-restart fixes, developing the universal deployment scripts, and authoring the technical analysis report.

### Upstream Open-Source Projects
- **The OpenWrt Project & Contributors** — For OpenWrt, `464xlat`, `kmod-nat46`, `fw4` (`nftables`), `odhcp6c`, and the OpenWrt Firmware Selector.

---

*For usage rights, attribution requirements, and video restrictions, see [LICENSE](LICENSE).*
