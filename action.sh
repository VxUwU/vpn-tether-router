#!/system/bin/sh
# ============================================================
# vpn_tether_router v2.2.1 — Safe Toggle + WebUI + Cek IP Publik
#
# Mode:
#   (tanpa argumen) : toggle ON/OFF
#   --state         : state singkat untuk WebUI (ON / VPN / TETHER / UPLINK)
#   --checkip       : cek IP publik (uplink vs VPN) + jalur client via conntrack
#
# Prinsip aman:
#   - Tidak pernah flush chain bawaan netd.
#   - Semua rule milik module bertag "vtr2" dan dihapus satu per satu saat OFF.
#   - Tidak ada kill netd; netd dibiarkan bekerja normal.
#   - Kalau VPN belum aktif saat ON -> batal total, tidak ada perubahan.
# ============================================================

TAG="vtr2"
CHAIN="vtr_fwd"
NAT_CHAIN="vtr_nat"
RULE_PRIO=9000
MODDIR="${MODDIR:-/data/adb/modules/vpn_tether_router}"
LOGF="/data/local/tmp/vtr2.log"

# log ke stdout (buat WebUI) + file (buat debug offline).
log() {
    echo "[$TAG] $*"
    echo "$(date '+%H:%M:%S') [$TAG] $*" >> "$LOGF" 2>/dev/null
}

# ---------- Deteksi interface (mksh/toybox safe) ----------

# Cek interface "aktif" via /sys. IFF_UP = 0x1 pada /sys/class/net/<if>/flags.
# Flags file isi contoh "0x1003". Pakai printf+%d utk convert, hindari arithmetic hex quirks.
if_is_up() {
    [ -r "/sys/class/net/$1/flags" ] || return 1
    _f=$(cat "/sys/class/net/$1/flags" 2>/dev/null)
    [ -n "$_f" ] || return 1
    _n=$(printf '%d' "$_f" 2>/dev/null)
    [ -z "$_n" ] && return 1
    [ $(( _n & 1 )) -eq 1 ]
}

if_exists() { [ -e "/sys/class/net/$1" ]; }

# List semua iface sekaligus (sekali baca /sys), lebih reliable dari globbing shell.
_all_ifs() { ls /sys/class/net/ 2>/dev/null; }

detect_uplink() {
    for i in rmnet_data2 rmnet_data1 rmnet_data0 rmnet0 ccmni0 ccmni1 wlan0; do
        if_is_up "$i" && { echo "$i"; return; }
    done
    echo ""
}

detect_vpn_if() {
    # Scan semua iface, filter nama tun*/ppp*/wg*/tap*/warp*, ambil yg UP.
    for i in $(_all_ifs); do
        case "$i" in
            tun*|ppp*|wg*|tap*|warp*|proton*|mullvad*)
                if_is_up "$i" && { echo "$i"; return; }
                ;;
        esac
    done
    echo ""
}

detect_tether_ifs() {
    upl="$(detect_uplink)"
    for i in rndis0 usb0 wlan2 wlan1 ap0 softap0 swlan0; do
        [ "$i" = "$upl" ] && continue
        if_is_up "$i" && echo "$i"
    done
}

# Match rule kita di output `ip rule show`.
# Android cetak "9000:\tfrom all iif rndis0 lookup <table>" (BUKAN "priority 9000").
_our_rules_v4() { ip rule show    2>/dev/null | awk -v p="$RULE_PRIO" '$1==p":"'; }
_our_rules_v6() { ip -6 rule show 2>/dev/null | awk -v p="$RULE_PRIO" '$1==p":"'; }
_has_our_rule() { [ -n "$(_our_rules_v4)" ] || [ -n "$(_our_rules_v6)" ]; }

# ---------- Mode: diagnostik lengkap ----------
if [ "$1" = "--diag" ]; then
    echo "=== vtr2 diag ==="
    echo "date  : $(date 2>/dev/null)"
    echo "sh    : $0"
    echo "whoami: $(id 2>/dev/null)"
    echo
    echo "--- /sys/class/net ---"
    ls /sys/class/net/ 2>&1
    echo
    echo "--- iface flags (hex / UP?) ---"
    for i in $(ls /sys/class/net/ 2>/dev/null); do
        f=$(cat "/sys/class/net/$i/flags" 2>/dev/null)
        n=$(printf '%d' "$f" 2>/dev/null)
        up=0; [ -n "$n" ] && [ $(( n & 1 )) -eq 1 ] && up=1
        printf '  %-16s flags=%s up=%s\n' "$i" "$f" "$up"
    done
    echo
    echo "--- detect ---"
    echo "VPN_IF  : $(detect_vpn_if)"
    echo "UPLINK  : $(detect_uplink)"
    echo "TETHER  : $(detect_tether_ifs | tr '\n' ' ')"
    echo
    echo "--- ip rule (top 20) ---"
    ip rule show 2>&1 | head -20
    echo
    echo "--- rule prio $RULE_PRIO ---"
    r4=$(_our_rules_v4); r6=$(_our_rules_v6)
    if [ -n "$r4" ] || [ -n "$r6" ]; then
        [ -n "$r4" ] && echo "$r4"
        [ -n "$r6" ] && echo "(v6) $r6"
    else
        echo "(none)"
    fi
    echo
    echo "--- iptables vtr_fwd ---"
    iptables -L "$CHAIN" -n -v 2>&1 | head -8
    echo "--- iptables -t nat vtr_nat ---"
    iptables -t nat -L "$NAT_CHAIN" -n -v 2>&1 | head -8
    echo
    echo "--- route table (vpn_if name) ---"
    v=$(detect_vpn_if)
    [ -n "$v" ] && ip route show table "$v" 2>&1 | head -10 || echo "(no vpn iface)"
    echo
    echo "--- log tail ---"
    tail -40 "$LOGF" 2>/dev/null || echo "(no log)"
    exit 0
fi

# ---------- Mode: state untuk WebUI ----------
if [ "$1" = "--state" ]; then
    on=0
    _has_our_rule && on=1
    vif=$(detect_vpn_if)
    tifs=$(detect_tether_ifs | tr '\n' ' ')
    upl=$(detect_uplink)
    echo "ON=$on"
    echo "VPN=${vif:-none}"
    echo "TETHER=${tifs:-none}"
    echo "UPLINK=${upl:-unknown}"
    exit 0
fi

# ---------- Mode: cek IP publik ----------
if [ "$1" = "--checkip" ]; then
    upl=$(detect_uplink)
    vif=$(detect_vpn_if)
    tifs=$(detect_tether_ifs)

    # Cari IP client tether yang sedang terhubung.
    cip=""
    for t in $tifs; do
        cip=$(ip neigh show dev "$t" 2>/dev/null | awk '$3=="REACHABLE"||$3=="STALE"||$3=="DELAY"||$3=="PERMANENT"{print $1; exit}')
        [ -n "$cip" ] && break
    done

    # IP publik HP dilihat dari masing-masing jalur.
    upl_ip=""; [ -n "$upl" ] && upl_ip=$(curl -s --max-time 4 --interface "$upl" ifconfig.me 2>/dev/null)
    vpn_ip=""; [ -n "$vif" ] && vpn_ip=$(curl -s --max-time 4 --interface "$vif" ifconfig.me 2>/dev/null)

    echo "UPLINK=$upl"
    echo "IP_UPLINK=${upl_ip:-GAGAL}"
    echo "VPN=${vif:-none}"
    echo "IP_VPN=${vpn_ip:-GAGAL}"
    echo "CLIENT=${cip:-none}"

    # Bukti jalur client: cek conntrack, NAT reply diarahkan ke IP tun atau uplink.
    if [ -n "$cip" ] && [ -n "$vif" ] && [ -n "$upl" ]; then
        tip=$(ip -4 addr show "$vif" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)
        uip=$(ip -4 addr show "$upl" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)
        vv=$(grep -c "src=$cip .*dst=$tip " /proc/net/nf_conntrack 2>/dev/null)
        vu=$(grep -c "src=$cip .*dst=$uip " /proc/net/nf_conntrack 2>/dev/null)
        echo "CLIENT_VIA_VPN=${vv:-0}"
        echo "CLIENT_VIA_UPLINK=${vu:-0}"
        echo "NOTE=Untuk hasil akurat: dari client jalankan 'curl ifconfig.me' dulu, baru tekan Cek lagi (conntrack aktif 1-2 menit)."
    fi
    exit 0
fi

# ---------- OFF: hapus semua rule prio $RULE_PRIO (loop sampai bersih, buat duplikat) ----------
off() {
    log "OFF — membersihkan rule $TAG ..."

    # Loop hapus — kernel bolehin multiple rules prio sama, kita buang semua.
    # Break kalo del gagal (hindari infinite loop).
    _n=0
    while _has_our_rule && [ $_n -lt 32 ]; do
        _before=$(_our_rules_v4; _our_rules_v6)
        ip rule del priority "$RULE_PRIO" 2>/dev/null
        ip -6 rule del priority "$RULE_PRIO" 2>/dev/null
        _after=$(_our_rules_v4; _our_rules_v6)
        # Kalo nggak ada perubahan, loop ga progress — abort.
        [ "$_before" = "$_after" ] && break
        _n=$(( _n + 1 ))
    done
    if _has_our_rule; then
        log "  WARN — $_n rule dihapus, tapi masih ada sisa (butuh root/manual)"
    elif [ $_n -gt 0 ]; then
        log "  hapus $_n rule prio $RULE_PRIO"
    fi

    # Restore BPF tether offload ke nilai asli.
    if [ -f "$MODDIR/state/offload_orig" ]; then
        orig=$(cat "$MODDIR/state/offload_orig" 2>/dev/null)
        [ -z "$orig" ] && orig=0
        settings put global tether_offload_disabled "$orig" >/dev/null 2>&1
        rm -f "$MODDIR/state/offload_orig"
    else
        settings put global tether_offload_disabled 0 >/dev/null 2>&1
    fi

    # Legacy: kalau versi lama pernah ubah MTU, restore ke 1500 default.
    if [ -f "$MODDIR/state/mtu_touched" ]; then
        while read -r t orig; do
            [ -n "$t" ] || continue
            [ -n "$orig" ] || continue
            ip link set "$t" mtu "$orig" 2>/dev/null
        done < "$MODDIR/state/mtu_touched"
        rm -f "$MODDIR/state/mtu_touched"
    fi

    # Hapus DNS redirect rule kita.
    for t in rndis0 usb0 wlan2 wlan1 ap0 softap0; do
        while iptables -t nat -D PREROUTING -i "$t" -p udp --dport 53 -j DNAT --to-destination 1.1.1.1:53 -m comment --comment "$TAG" 2>/dev/null; do :; done
        while iptables -t nat -D PREROUTING -i "$t" -p tcp --dport 53 -j DNAT --to-destination 1.1.1.1:53 -m comment --comment "$TAG" 2>/dev/null; do :; done
    done

    # Hapus MSS clamp rule kita — iterate RULE NUMBER di mangle FORWARD yang punya comment "vtr2".
    # Lebih reliable dari hardcoding MSS values (yang beda-beda per VPN provider / MTU).
    _mss_cleaned=0
    while :; do
        line=$(iptables -t mangle -L FORWARD --line-numbers -n 2>/dev/null | awk -v tag="/* $TAG */" '$0 ~ "TCPMSS" && index($0, tag) {print $1; exit}')
        [ -z "$line" ] && break
        iptables -t mangle -D FORWARD "$line" 2>/dev/null || break
        _mss_cleaned=$(( _mss_cleaned + 1 ))
        [ $_mss_cleaned -gt 16 ] && break
    done
    # Fallback: hapus pakai --clamp-mss-to-pmtu format (versi legacy).
    while iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu -m comment --comment "$TAG" 2>/dev/null; do :; done

    # Restore disable_ipv6 ke nilai asli (sebelum kita touch).
    if [ -f "$MODDIR/state/v6_touched" ]; then
        while read -r t orig; do
            [ -n "$t" ] || continue
            [ -n "$orig" ] || orig=0
            sysctl -w "net.ipv6.conf.$t.disable_ipv6=$orig" >/dev/null 2>&1
            sysctl -w "net.ipv6.conf.$t.forwarding=1" >/dev/null 2>&1
        done < "$MODDIR/state/v6_touched"
        rm -f "$MODDIR/state/v6_touched"
    fi

    # Hapus DROP eksplisit IPv6 per tether iface (yg kita pasang di on).
    for t in rndis0 usb0 wlan2 wlan1 ap0 softap0; do
        _n=0
        while ip6tables -D FORWARD -i "$t" -j DROP -m comment --comment "$TAG" 2>/dev/null; do
            _n=$(( _n+1 )); [ $_n -gt 8 ] && break
        done
    done

    # Lepas chain kita dari FORWARD / POSTROUTING, lalu hapus chain-nya.
    iptables -t filter -D FORWARD -j "$CHAIN" 2>/dev/null
    ip6tables -t filter -D FORWARD -j "$CHAIN" 2>/dev/null
    iptables -t nat -D POSTROUTING -j "$NAT_CHAIN" 2>/dev/null
    iptables -t filter -F "$CHAIN" 2>/dev/null;  iptables -t filter -X "$CHAIN" 2>/dev/null
    ip6tables -t filter -F "$CHAIN" 2>/dev/null;  ip6tables -t filter -X "$CHAIN" 2>/dev/null
    iptables -t nat -F "$NAT_CHAIN" 2>/dev/null;  iptables -t nat -X "$NAT_CHAIN" 2>/dev/null

    # Kembalikan policy IPv6 FORWARD.
    ip6tables -P FORWARD ACCEPT 2>/dev/null

    log "OFF selesai — tethering kembali ke jalur bawaan."
}

# ---------- ON: arahkan traffic tether ke VPN ----------
on() {
    local vif tifs uplink vtable

    vif=$(detect_vpn_if)
    if [ -z "$vif" ]; then
        log "GAGAL — tidak ada interface VPN (tun*) yang aktif. Nyalakan VPN dulu."
        return 1
    fi

    tifs=$(detect_tether_ifs)
    [ -z "$tifs" ] && log "PERINGATAN — belum ada interface tether yang aktif. Rule tetap dipasang dan aktif otomatis saat tethering dinyalakan."
    uplink=$(detect_uplink)

    log "VPN interface : $vif"
    log "Tether        : ${tifs:-rndis0 / wlan2 / ap0 (saat aktif)}"
    log "Uplink HP     : ${uplink:-<tidak terdeteksi>}"

    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
    sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1

    # ---------- Disable BPF tether offload ----------
    # Android native BPF (/sys/fs/bpf/tethering/) direct-fastpath map rndis0 <-> rmnet,
    # bypass iptables + ip rule kita. Hasilnya: paket laptop ke destination tertentu
    # (reddit/twitter/dll) keluar via carrier langsung bypass VPN tunnel → connection RST.
    # Simpan state asli biar bisa dibalikin di OFF.
    if command -v settings >/dev/null 2>&1; then
        orig_off=$(settings get global tether_offload_disabled 2>/dev/null)
        [ -z "$orig_off" ] && orig_off=0
        mkdir -p "$MODDIR/state" 2>/dev/null
        echo "$orig_off" > "$MODDIR/state/offload_orig" 2>/dev/null
        settings put global tether_offload_disabled 1 >/dev/null 2>&1
        log "BPF offload disabled (was: $orig_off)"
    else
        log "WARN — 'settings' tidak ditemukan, skip disable BPF offload"
    fi
    cmd netd tether offload stop >/dev/null 2>&1 || true

    # Tabel VPN: pakai nama interface langsung (standar Android VpnService).
    # Verifikasi tabel ada routenya; kalau kosong, coba cari rule dengan 'oif $vif' atau 'iif $vif'.
    vtable="$vif"
    if ! ip route show table "$vtable" 2>/dev/null | grep -q .; then
        alt=$(ip rule show 2>/dev/null | awk -v v="$vif" '$0 ~ ("(iif|oif) "v" ") {print}' | \
              grep -oE "lookup [^ ]+" | awk '{print $2}' | grep -v '^local_network$' | head -1)
        [ -n "$alt" ] && vtable="$alt"
    fi
    log "VPN table     : $vtable"

    # Buat chain milik kita (kalau belum ada), pasang di awal FORWARD / POSTROUTING.
    iptables -t filter -N "$CHAIN" 2>/dev/null
    ip6tables -t filter -N "$CHAIN" 2>/dev/null
    iptables -t nat -N "$NAT_CHAIN" 2>/dev/null
    iptables  -t filter -C FORWARD -j "$CHAIN"     2>/dev/null || iptables  -t filter -I FORWARD 1 -j "$CHAIN"     2>/dev/null
    ip6tables -t filter -C FORWARD -j "$CHAIN"     2>/dev/null || ip6tables -t filter -I FORWARD 1 -j "$CHAIN"     2>/dev/null
    iptables  -t nat    -C POSTROUTING -j "$NAT_CHAIN" 2>/dev/null || iptables  -t nat    -I POSTROUTING 1 -j "$NAT_CHAIN" 2>/dev/null

    # Isi chain: terima traffic tether -> VPN, terima reply, NAT via VPN.
    iptables -t filter -F "$CHAIN"; ip6tables -t filter -F "$CHAIN"; iptables -t nat -F "$NAT_CHAIN"
    for t in $tifs; do
        iptables -t filter -A "$CHAIN" -i "$t" -o "$vif" -j ACCEPT -m comment --comment "$TAG"
        ip6tables -t filter -A "$CHAIN" -i "$t" -o "$vif" -j ACCEPT -m comment --comment "$TAG"
        ip rule add from all iif "$t" priority $RULE_PRIO lookup "$vtable" 2>/dev/null
        ip -6 rule add from all iif "$t" priority $RULE_PRIO lookup "$vtable" 2>/dev/null
    done
    # Kalau belum ada tether yang aktif, pasang rule hanya untuk interface yg EXIST (biar ga silent-fail).
    if [ -z "$tifs" ]; then
        for t in rndis0 usb0 wlan2 wlan1 ap0 softap0; do
            [ "$t" = "$uplink" ] && continue
            if_exists "$t" || continue
            ip rule add from all iif "$t" priority $RULE_PRIO lookup "$vtable" 2>/dev/null
            ip -6 rule add from all iif "$t" priority $RULE_PRIO lookup "$vtable" 2>/dev/null
        done
        # Fallback jaring: kalau SATUPUN rule gagal/kosong, pasang mark-based rule yang pasti ada.
        if ! ip rule show 2>/dev/null | grep -q "priority $RULE_PRIO"; then
            log "PERINGATAN — tidak ada iface tether yang bisa dipasangi rule. Nyalakan tether/hotspot dulu, lalu toggle ulang."
        fi
    fi
    iptables -t filter -A "$CHAIN" -m state --state ESTABLISHED,RELATED -j ACCEPT -m comment --comment "$TAG"
    ip6tables -t filter -A "$CHAIN" -m state --state ESTABLISHED,RELATED -j ACCEPT -m comment --comment "$TAG"

    # ---------- MSS clamping (biar laptop ga ngirim paket lebih besar dari tun MTU) ----------
    # JANGAN ubah MTU rndis0/tether iface — bikin asymmetric MTU dgn laptop → paket drop.
    # Cukup MSS clamp: pas TCP handshake, HP overwrite nilai MSS yg di-advertise ke laptop
    # supaya laptop sejak awal kirim paket size yg muat utuh di tunnel VPN.
    vmtu=$(cat "/sys/class/net/$vif/mtu" 2>/dev/null)
    [ -z "$vmtu" ] && vmtu=1280
    [ "$vmtu" -lt 1280 ] && vmtu=1280
    [ "$vmtu" -gt 1500 ] && vmtu=1500
    # Safety margin 80 (vs standar 40) buat tunnel yg nested-encap atau provider yg
    # bikin tunnel header gede (WG+pq, OpenVPN+DCO). Ngorbanin 1% throughput buat stabilitas.
    tcp_mss=$(( vmtu - 80 ))
    [ "$tcp_mss" -lt 1200 ] && tcp_mss=1200

    log "MTU tun       : $vmtu  (MSS clamp = $tcp_mss)"

    # Hapus rule lama + clamp pakai --clamp-mss-to-pmtu (lebih adaptif + fallback ke --set-mss).
    iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null
    while iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$tcp_mss" -m comment --comment "$TAG" 2>/dev/null; do :; done
    iptables -t mangle -I FORWARD 1 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$tcp_mss" -m comment --comment "$TAG" 2>/dev/null

    # NAT keluar lewat VPN.
    iptables -t nat -A "$NAT_CHAIN" -o "$vif" -j MASQUERADE -m comment --comment "$TAG"

    # ---------- Anti DNS-hijack ----------
    # Carrier ISP sering intercept DNS (port 53) dan paksa SafeSearch / log-everything.
    # Kita paksa semua DNS dari tether client di-rewrite ke resolver publik (Cloudflare 1.1.1.1),
    # lalu paket keluar lewat VPN tunnel — DNS pun jadi private.
    for t in $tifs; do
        iptables -t nat -I PREROUTING 1 -i "$t" -p udp --dport 53 -j DNAT --to-destination 1.1.1.1:53 -m comment --comment "$TAG" 2>/dev/null
        iptables -t nat -I PREROUTING 1 -i "$t" -p tcp --dport 53 -j DNAT --to-destination 1.1.1.1:53 -m comment --comment "$TAG" 2>/dev/null
    done

    # ---------- Anti-leak IPv6 ----------
    # Modern Android (BPF tether offload) bikin iptables FORWARD ga dilewatin paket IPv6
    # tether, dan carrier sering share /64 publik langsung ke rndis0 — laptop auto-config
    # IPv6 global dan paket keluar via fast-path, bypass netfilter.
    # Solusi paling andal: disable IPv6 di tether iface + policy FORWARD DROP sbg lapis 2.
    ip6tables -P FORWARD DROP 2>/dev/null
    mkdir -p "$MODDIR/state" 2>/dev/null
    : > "$MODDIR/state/v6_touched"
    for t in $tifs rndis0 usb0 wlan2 wlan1 ap0 softap0; do
        if_exists "$t" || continue
        # Simpan state asli biar bisa dibalikin di OFF.
        orig=$(cat "/proc/sys/net/ipv6/conf/$t/disable_ipv6" 2>/dev/null)
        [ -n "$orig" ] && echo "$t $orig" >> "$MODDIR/state/v6_touched"
        sysctl -w "net.ipv6.conf.$t.disable_ipv6=1" >/dev/null 2>&1
        sysctl -w "net.ipv6.conf.$t.forwarding=0" >/dev/null 2>&1
        # Lapis defense-in-depth untuk kernel yang ga offload: DROP eksplisit.
        ip6tables -C FORWARD -i "$t" -j DROP -m comment --comment "$TAG" 2>/dev/null || \
            ip6tables -I FORWARD 1 -i "$t" -j DROP -m comment --comment "$TAG" 2>/dev/null
    done

    # Verifikasi: pastikan ip rule kita benar-benar terpasang.
    nrule=$(_our_rules_v4 | wc -l)
    if [ "${nrule:-0}" -eq 0 ]; then
        log "PERINGATAN — ip rule gagal dipasang (tabel '$vtable' mungkin tidak ada). Cek: ip rule show"
    else
        log "OK — $nrule rule prio $RULE_PRIO terpasang di tabel $vtable."
    fi

    log "ON selesai — tether diarahkan ke $vif (table $vtable). HP tetap internet normal via uplink."
}

# ---------- Toggle utama ----------
if _has_our_rule; then
    off
else
    on
fi
exit 0
