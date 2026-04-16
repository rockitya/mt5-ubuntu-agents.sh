#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

NOVNC_PORT=6080
VNC_PORT=5900
VNC_PASS="mt5vnc"
SERVER_IP="$(hostname -I | awk '{print $1}')"
WORKDIR="/root/mt5_experiment"
SETUP_FILE="$WORKDIR/mt5setup.exe"
SDE_DIR="/root/sde"
SWAP_SIZE="64G"

log(){ echo "==> [$STEP/$TOTAL] $1"; let STEP++; }

STEP=1
TOTAL=6

log "Uninstall all — Wine, MetaTester, VNC, ZRAM, WARP, cron jobs"
pkill -9 -f metatester64 2>/dev/null || true
pkill -9 -f wineserver 2>/dev/null || true
pkill -9 -f wine 2>/dev/null || true
pkill -9 -f Xvfb 2>/dev/null || true
pkill -9 -f x11vnc 2>/dev/null || true
pkill -9 -f websockify 2>/dev/null || true
rm -rf /opt/mt5 /root/.wine "$WORKDIR" /tmp/.X11-unix /tmp/.X*-lock /root/sde
apt-get remove --purge -y wine* x11vnc novnc python3-websockify openbox xterm zram-tools cloudflare-warp 2>/dev/null || true
apt-get autoremove -y 2>/dev/null || true
crontab -r 2>/dev/null || true
rm -f /etc/cron.*/*mt5* 2>/dev/null || true
swapoff /swapfile 2>/dev/null || true
rm -f /swapfile 2>/dev/null || true
mkdir -p "$WORKDIR" "$SDE_DIR"

log "Add fixed 64GB swap only"
fallocate -l $SWAP_SIZE /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=65536
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab
free -h | grep Swap

log "Disable firewall (UFW + iptables + ip6tables)"
ufw disable 2>/dev/null || true
iptables -F; iptables -X; iptables -t nat -F; iptables -t mangle -F
iptables -P INPUT ACCEPT; iptables -P FORWARD ACCEPT; iptables -P OUTPUT ACCEPT
ip6tables -F; ip6tables -X; ip6tables -P INPUT ACCEPT; ip6tables -P FORWARD ACCEPT; ip6tables -P OUTPUT ACCEPT
systemctl stop firewalld 2>/dev/null || true; systemctl disable firewalld 2>/dev/null || true

log "Install Wine, download mt5setup.exe"
apt-get update
apt-get install -y software-properties-common
dpkg --add-architecture i386
wget -qO- https://dl.winehq.org/wine-builds/winehq.key | apt-key add -
wget -NP /etc/apt/sources.list.d/ https://dl.winehq.org/wine-builds/ubuntu/dists/$(lsb_release -cs)/winehq-$(lsb_release -cs).sources
apt-get update
apt-get install -y wine64 wine32 libwine fonts-wine
wget -O "$SETUP_FILE" "https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe" || \
  (apt-get install -y gdown && gdown "https://drive.google.com/uc?id=YOUR_GOOGLE_DRIVE_ID" -O "$SETUP_FILE") || \
  { echo "SCP: scp mt5setup.exe root@$SERVER_IP:$SETUP_FILE"; exit 1; }

log "Start noVNC + Wine + MetaTester through emulator"
mkdir -p /opt/mt5
openssl req -x509 -nodes -newkey rsa:2048 -keyout /opt/mt5/novnc.pem -out /opt/mt5/novnc.pem -days 3650 -subj "/CN=$SERVER_IP" >/dev/null 2>&1
Xvfb :10 -screen 0 1280x900x24 >/tmp/xvfb.log 2>&1 &
sleep 3
DISPLAY=:10 openbox >/tmp/openbox.log 2>&1 &
sleep 2
DISPLAY=:10 xsetroot -solid '#1a1f2e'
DISPLAY=:10 xterm -geometry 110x35+20+20 -bg '#0d1117' -fg '#00ff88' -fa 'Monospace' -fs 11 -title 'MT5 Shell' &
export WINEPREFIX=/root/.wine WINEARCH=win64 WINEDLLOVERRIDES="mscoree,mshtml=" WINEDEBUG=-all
DISPLAY=:10 wineboot --init >/tmp/wineboot.log 2>&1 &
sleep 10
x11vnc -display :10 -rfbport $VNC_PORT -passwd $VNC_PASS -forever -shared -noxdamage -noxfixes -bg -o /tmp/x11vnc.log &
websockify --web=/usr/share/novnc/ --cert=/opt/mt5/novnc.pem $NOVNC_PORT localhost:$VNC_PORT >/tmp/websockify.log 2>&1 &

cat > /opt/mt5/run-emulator-metatester.sh <<EOF
#!/bin/bash
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export WINEPREFIX=/root/.wine WINEARCH=win64 WINEDLLOVERRIDES="mscoree,mshtml=" WINEDEBUG=-all
DISPLAY=:10 wine "$SDE_DIR/sde.exe" -hsw -- "$SETUP_FILE" &
EOF
chmod +x /opt/mt5/run-emulator-metatester.sh

log "Clear RAM cache (drop_caches 1,2,3)"
for i in 1 2 3; do sync; echo \$i > /proc/sys/vm/drop_caches; done
echo "RAM cache cleared"; free -h

echo "
=============================================
SETUP COMPLETE
=============================================
noVNC: https://$SERVER_IP:$NOVNC_PORT/vnc.html?autoconnect=1
Password: $VNC_PASS

Upload Intel SDE windows package to /root/, extract to $SDE_DIR, then:
DISPLAY=:10 /opt/mt5/run-emulator-metatester.sh

Swap: $SWAP_SIZE active
Firewall: disabled
Wine: ready
=============================================
"
