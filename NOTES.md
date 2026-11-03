# VPN Tether Router — Catatan Setup & Troubleshooting

Catatan hasil debugging session untuk Redmi `kunzite_id` + SukiSU + HMA VPN + USB tether ke Kali Linux laptop.

---

## TL;DR — Resep sukses

1. **Reboot HP** (clear BPF tether offload maps + conntrack)
2. **HMA app** → Protocol: **WireGuard**, Server: **Singapore (manual, bukan Fastest)**
3. **USB tether ON** di HP
4. **Open WebUI module** → tap **TOGGLE ROUTE** → ONLINE
5. Laptop auto-dapat Singapore IP, speed ~65 Mbps

**Urutan matiin:** module OFF → VPN OFF → tether OFF (bukan kebalik, bikin leak sementara)

---

## Chain-of-fix (v2.2.1 → v2.3.1)

| Versi | Bug yang kefix | Dampak |
|-------|----------------|--------|
| v2.2.2 | `grep 'state UP'` ga match tun yang state-nya UNKNOWN | VPN kedetect |
| v2.2.3 | Deteksi `/sys/class/net/<if>/flags` bit 0 | Robust lintas kernel |
| v2.2.3 | vtable salah ambil `local_network` dari Android rules | Routing bener ke table tun0 |
| v2.2.3 | `grep "priority 9000"` ga match format Android `9000:` | OFF cleanup jalan, no duplicate rules |
| v2.2.4 | `disable_ipv6=1` di tether iface | IPv6 leak via BPF offload fastpath di-tutup |
| v2.2.5 | Order helper functions sebelum --state mode | No `_has_our_rule: not found` error |
| v2.2.6 | Bridge async callback API (`ksu.exec(cmd, '{}', cb)`) | Toggle gerak di SukiSU modern |
| v2.2.7 | visibility API (pause polling pas hidden) | WebUI zero-cost di background |
| v2.2.8 | MSS clamp (TCPMSS set 1200) | Browser bulk download ga drop |
| v2.2.9 | DNAT port 53 → 1.1.1.1 | Bypass carrier DNS hijack SafeSearch |
| v2.3.0 | Revert MTU rndis0 (biarin 1500), MSS clamp only | Fix asymmetric MTU drop |
| v2.3.1 | `settings put global tether_offload_disabled 1` | **Core fix** — matiin Android BPF tether offload |

---

## Hal yang penting dipahami

### 1. Modul vs WebUI itu DUA LAPIS BEDA

| Komponen | Jalan di mana | Pengaruh WebUI |
|----------|---------------|----------------|
| **Routing** (iptables, ip rule, NAT, MASQUERADE) | **Kernel Linux** | **NOL** |
| **WebUI** (polling, animasi, display) | WebView di SukiSU manager | Berenti pas ditutup/background |

Tutup WebUI → modul tetap jalan. Tutup SukiSU manager → modul tetap jalan. Yang matiin cuma: tap TOGGLE OFF, atau reboot (auto-OFF by design).

### 2. Android BPF Tether Offload

`/sys/fs/bpf/tethering/` — kernel BPF yang fast-path map rndis0 ↔ rmnet_data2 **bypass iptables + ip rule**. Ini penyebab paket laptop ke destination tertentu keluar via carrier langsung bypass VPN tunnel (confirmed via tcpdump: paket `rmnet_data2 In [R.]` seq 1).

Fix: `settings put global tether_offload_disabled 1` + `cmd netd tether offload stop`.

**Catatan:** setting ini **habis reboot bisa reset**. Modul v2.3.1 auto-apply ulang pas toggle ON, dan simpan state asli ke `$MODDIR/state/offload_orig` untuk di-restore pas OFF.

### 3. Carrier Indonesia DNS Hijack

Carrier (XL/Telkomsel/Three/dll) nge-hijack UDP port 53, paksa return `forcesafesearch.google.com` dengan IP `216.239.38.120`. Browser nunggu DNS timeout → feel "internet lambat".

Fix: `iptables -t nat -I PREROUTING 1 -i rndis0 -p udp --dport 53 -j DNAT --to 1.1.1.1:53` (plus TCP version). Semua query DNS dari laptop paksa ke Cloudflare lewat VPN.

### 4. IPv6 Carrier Share /64 ke rndis0

Carrier assign `/64` IPv6 publik ke rndis0 → laptop auto-SLAAC dapat IPv6 global dari prefix yang sama → paket IPv6 laptop keluar via fast-path BPF, **bypass iptables FORWARD DROP policy**.

Confirmed earlier: `ip6tables -L FORWARD -n -v` → DROP rule counter 0, tapi `curl -6` dari laptop return carrier IPv6 publik.

Fix definitif: `sysctl -w net.ipv6.conf.rndis0.disable_ipv6=1` + policy DROP sebagai lapis-2.

### 5. HMA Server Selection

- **Fastest Server** di HMA cenderung arahin ke AWS Jakarta `ap-southeast-3` — hop extra dalam 1 kota, kadang quirky NAT handling, kena carrier Indonesia routing kacau
- **Manual Singapore** → AWS `ap-southeast-1` → routing bersih, 15ms extra tapi worth it
- **Protocol WireGuard** > OpenVPN untuk tether+NAT (overhead kecil, kernel-level, less conntrack bugs)

### 6. MTU/MSS

- tun0 MTU biasanya **1280** (HMA conservative)
- rndis0 **jangan** diubah MTU-nya — asymmetric MTU dengan laptop (yang stay 1500) bikin paket drop
- Pakai **TCPMSS clamp set 1200** di FORWARD (bukan `--clamp-mss-to-pmtu`, PMTUD sering broken di mobile)
- Rumus: `tun_mtu - 80` margin untuk encap overhead

### 7. TTL Fix 64 — Compatible, Bukan Conflict

| Komponen TTL Fix | Overlap VTR | Verdict |
|------------------|-------------|---------|
| BPF TTL rewrite egress rmnet | Beda chain | ✅ Compatible |
| MSS clamp | Redundant (VTR duluan) | ✅ Compatible |
| DSCP reset POSTROUTING | VTR ga pakai DSCP | ✅ Compatible |
| nfqttl userspace daemon | NFQUEUE processing | ⚠️ Potensi latency spike |

Confirmed: pakai sama-sama, speed lebih tinggi dari HP langsung via tun0 (TTL fix BPF fast-path actually membantu throughput tether).

---

## Perintah debug yang berguna

```bash
# Diagnostik lengkap
su -c 'sh /data/adb/modules/vpn_tether_router/action.sh --diag'

# State singkat (buat WebUI)
su -c 'sh /data/adb/modules/vpn_tether_router/action.sh --state'

# Toggle manual
su -c 'sh /data/adb/modules/vpn_tether_router/action.sh'

# Cek IP publik via uplink vs VPN
su -c 'sh /data/adb/modules/vpn_tether_router/action.sh --checkip'

# Monitor paket dari laptop via tether
su -c 'tcpdump -i any -nn port 443 and host 10.157.177.2'

# Verify BPF offload disabled
su -c 'settings get global tether_offload_disabled'   # should be 1

# Log file persistent
su -c 'tail -40 /data/local/tmp/vtr2.log'
```

---

## Flow yang terbukti sukses (post-reboot)

```
┌────────────────────────────────────────────────┐
│  Laptop → USB tether (rndis0) → HP (MASQ) →    │
│  → tun0 (WireGuard HMA) → Singapore AWS →      │
│  → Internet                                     │
│                                                  │
│  Speed: 67 Mbps │ Latency: ~170ms              │
│  All sites: OK │ IPv6: blocked │ DNS: 1.1.1.1  │
└────────────────────────────────────────────────┘
```

Hasil akhir: 10/10 site tested OK (google/reddit/github/twitter/stackoverflow/youtube/cloudflare/wikipedia/amazon/netflix), 10MB download **67.7 Mbps** — **lebih tinggi dari raw carrier 4G 45 Mbps** karena WG efficient + TTL Fix bypass carrier throttle.

---

## Troubleshooting cepat

| Gejala | Fix |
|--------|-----|
| WebUI "BRIDGE NIL" | Close SukiSU manager full, re-open |
| Toggle ga gerak | Pastiin bridge async callback API (v2.2.6+) |
| VPN TUNNEL "none" padahal VPN udah ON | Cek `/sys/class/net/` ada tun*/wg*/ppp*; kalau nama beda, lapor |
| Browser timeout random site | **Reboot HP** — BPF offload cache stuck |
| Download kenceng tapi browser lambat | DNS carrier hijack — pastiin DNAT 53 → 1.1.1.1 jalan |
| Laptop dapat IP Jakarta walau VPN SG | HMA pilih Jakarta AWS; ganti ke Singapore **manual** |
| Speed anjlok tiba-tiba | 4G sinyal jelek (jitter > 50ms); pindah lokasi atau tunggu |
| Semua gagal | 1. Reboot HP 2. Pakai WireGuard 3. Server SG manual |

---

## File penting

- `/data/adb/modules/vpn_tether_router/action.sh` — core logic (toggle, state, checkip, diag)
- `/data/adb/modules/vpn_tether_router/webroot/index.html` — WebUI (async bridge, visibility-aware polling)
- `/data/adb/modules/vpn_tether_router/state/offload_orig` — original BPF offload setting (restored on OFF)
- `/data/adb/modules/vpn_tether_router/state/v6_touched` — list iface yang disable_ipv6-nya di-touch
- `/data/local/tmp/vtr2.log` — log persistent action.sh

---

Last updated: 2026-11-03 — v2.3.1
