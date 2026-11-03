# VPN Tether Router

Android module (KernelSU/SukiSU) yang arahkan traffic USB tether & WiFi hotspot lewat VPN interface (`tunX`), dengan WebUI toggle & IP verification.

**Fitur:**
- Policy-based routing: tether client (laptop/HP lain) keluar via VPN exit, HP tetap internet normal via uplink
- WebUI terminal-style (interface matrix, packet flow topology, live stats)
- Auto-detect VPN interface (`tun*`, `wg*`, `ppp*`, `tap*`, `warp*`, `proton*`, `mullvad*`)
- Anti IPv6 leak (disable_ipv6 di tether iface + FORWARD DROP policy)
- Anti DNS hijack (DNAT port 53 → 1.1.1.1 via tunnel)
- Anti BPF tether offload bypass (settings `tether_offload_disabled`)
- MSS clamping adaptif (based on tun MTU)
- Auto-OFF saat reboot (no persistence surprise)
- Compatible dengan TTL Fix 64 (synergy, bukan conflict)

**Install:** flash `vpn-tether-router-vX.Y.Z.zip` via KernelSU/SukiSU manager, buka WebUI dari module card.

**Dokumentasi:** lihat [NOTES.md](NOTES.md) untuk troubleshooting & arsitektur.

**Testing:** v2.3.3, verified di Redmi `kunzite_id` + SukiSU + HMA WireGuard + USB tether ke Kali Linux. Capai 67 Mbps native (10 Mbps carrier overhead) dengan 10/10 major sites accessible.
