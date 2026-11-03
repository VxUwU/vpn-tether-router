#!/system/bin/sh
# Tidak ada aksi saat boot: toggle hanya manual lewat WebUI.
# ip rule dan iptables tidak persist saat reboot, jadi tidak perlu restore apa pun.
MODDIR=/data/adb/modules/vpn_tether_router
chmod 755 "$MODDIR/action.sh" 2>/dev/null
exit 0
