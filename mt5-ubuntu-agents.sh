#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

NOVNC_PORT=6080
VNC_PORT=5900
VNC_PASS="mt5vnc"
SERVER_IP="$(hostname -I | awk '{print $1}')"

echo "============================================="
echo " MT5 / MetaTester minimal setup"
echo " Server : $SERVER_IP"
echo " noVNC  : https://$SERVER_IP:$NOVNC_PORT/vnc.html"
echo "============================================="

# ------------------------------------------------------------
# [PRE] CLEAR APT LOCKS
# ------------------------------------------------------------
echo "==> [PRE] Clearing apt locks"

pkill -9 -f apt-get 2>/dev/null || true
pkill -9 -f apt 2>/dev/null || true
pkill -9 -f dpkg 2>/dev/null || true
sleep 2

rm -f /var/lib/dpkg/lock-frontend 2>/dev/null || true
rm -f /var/lib/dpkg/lock 2>/dev/null || true
rm -f /var/lib/apt/lists/lock 2>/dev/null || true
rm -f /var/cache/apt/archives/lock 2>/dev/null || true
dpkg --configure -a 2>/dev/null || true

# ------------------------------------------------------------
# [0/7] REMOVE OLD SETUP
# ------------------------------------------------------------
echo "==> [0/7] Removing old setup"

pkill -9 -f metatester64 2>/dev/null || true
pkill -9 -f terminal64 2>/dev/null || true
pkill -9 -f wineserver 2>/dev/null || true
pkill -9 -f wine 2>/dev/null || true
pkill -9 -f Xvfb 2>/dev/null || true
pkill -9 -f x11vnc 2>/dev/null || true
pkill -9 -f websockify 2>/dev/null || true
screen -wipe 2>/dev/null || true

rm -rf /opt/mt5 2>/dev/null || true
rm -rf /root/.wine 2>/dev/null || true
rm -f /tmp/.X*-lock 2>/dev/null || true
rm -rf /tmp/.X11-unix 2>/dev/null || true
rm -f /tmp/mt5linux.sh 2>/dev/null || true
rm -f /tmp/mt5setup.exe 2>/dev/null || true

apt-get remove --purge -y \
    winehq-devel winehq-stable winehq-staging \
    wine wine64 wine32 libwine fonts-wine \
    x11vnc novnc python3-websockify \
    zram-tools cloudflare-warp \
    2>/dev/null || true

swapoff /swapfile 2>/dev/null || true
swapoff -a 2>/dev/null || true
sed -i '\|/swapfile none swap sw 0 0|d' /etc/fstab 2>/dev/null || true
rm -f /swapfile 2>/dev/null || true

rm -f /etc/apt/sources.list.d/winehq-*.sources 2>/dev/null || true
rm -f /etc/apt/sources.list.d/cloudflare-*.list 2>/dev/null || true
rm -f /etc/apt/keyrings/winehq-archive.key 2>/dev/null || true
rm -f /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg 2>/dev/null || true
rm -f /etc/sysctl.d/99-mt5.conf 2>/dev/null || true
rm -f /etc/default/zramswap 2>/dev/null || true
rm -f /opt/mt5/novnc.pem 2>/dev/null || true

apt-get autoremove -y >/dev/null 2>&1 || true
apt-get autoclean -y >/dev/null 2>&1 || true

echo "    -> Old setup removed"

# ------------------------------------------------------------
# [1/7] DISABLE FIREWALL
# ------------------------------------------------------------
echo "==> [1/7] Disable firewall"

ufw disable 2>/dev/null || true
iptables -F 2>/dev/null || true
iptables -X 2>/dev/null || true
iptables -t nat -F 2>/dev/null || true
iptables -t mangle -F 2>/dev/null || true
iptables -P INPUT ACCEPT 2>/dev/null || true
iptables -P FORWARD ACCEPT 2>/dev/null || true
iptables -P OUTPUT ACCEPT 2>/dev/null || true
ip6tables -F 2>/dev/null || true
ip6tables -X 2>/dev/null || true
ip6tables -P INPUT ACCEPT 2>/dev/null || true
ip6tables -P FORWARD ACCEPT 2>/dev/null || true
ip6tables -P OUTPUT ACCEPT 2>/dev/null || true
systemctl stop firewalld 2>/dev/null || true
systemctl disable firewalld 2>/dev/null || true

echo "    -> Firewall disabled"

# ------------------------------------------------------------
# [2/7] INSTALL WINE + VNC + TOOLS
# ------------------------------------------------------------
echo "==> [2/7] Install Wine + VNC + tools"

dpkg --add-architecture i386
mkdir -pm755 /etc/apt/keyrings

UBUNTU_VER="$(lsb_release -cs)"

wget -q -O /etc/apt/keyrings/winehq-archive.key \
    https://dl.winehq.org/wine-builds/winehq.key
wget -q -NP /etc/apt/sources.list.d/ \
    "https://dl.winehq.org/wine-builds/ubuntu/dists/${UBUNTU_VER}/winehq-${UBUNTU_VER}.sources"

apt-get update -y >/dev/null
apt-get install -y --install-recommends \
    winehq-devel \
    xvfb screen wget curl cabextract \
    x11vnc novnc python3-websockify openssl \
    net-tools util-linux procps \
    >/dev/null

echo "    -> $(wine --version)"

# ------------------------------------------------------------
# [3/7] SETUP FIXED 64GB SWAP ONLY
# ------------------------------------------------------------
echo "==> [3/7] Setup fixed 64GB swap"

swapoff -a 2>/dev/null || true
sed -i '\|/swapfile none swap sw 0 0|d' /etc/fstab 2>/dev/null || true
rm -f /swapfile 2>/dev/null || true

if fallocate -l 64G /swapfile 2>/dev/null; then
    echo "    -> fallocate ok"
else
    dd if=/dev/zero of=/swapfile bs=1M count=65536 status=progress
fi

chmod 600 /swapfile
mkswap /swapfile >/dev/null
swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab

cat > /etc/sysctl.d/99-mt5.conf <<'EOF'
vm.swappiness=10
vm.vfs_cache_pressure=80
EOF
sysctl -p /etc/sysctl.d/99-mt5.conf >/dev/null 2>&1 || true

free -h | grep -E "Mem|Swap"
swapon --show || true

# ------------------------------------------------------------
# [4/7] DOWNLOAD OFFICIAL LINUX INSTALLER
# ------------------------------------------------------------
echo "==> [4/7] Download official MetaTrader Linux installer"

cd /tmp
rm -f /tmp/mt5linux.sh 2>/dev/null || true

wget -O /tmp/mt5linux.sh https://download.terminal.free/cdn/web/metaquotes.software.corp/mt5/mt5linux.sh || \
curl -L https://download.terminal.free/cdn/web/metaquotes.software.corp/mt5/mt5linux.sh -o /tmp/mt5linux.sh

chmod +x /tmp/mt5linux.sh

if [ ! -s /tmp/mt5linux.sh ]; then
    echo "ERROR: Failed to download mt5linux.sh"
    exit 1
fi

echo "    -> Downloaded Linux installer"

# ------------------------------------------------------------
# [5/7] INSTALL METATRADER / METATESTER
# ------------------------------------------------------------
echo "==> [5/7] Install MetaTrader using official Linux installer"

mkdir -p /opt/mt5
cd /opt/mt5

# The official MetaQuotes Linux installer handles Wine setup/install flow
bash /tmp/mt5linux.sh >/tmp/mt5linux-install.log 2>&1 || true

sleep 10

MT5_EX="$(find /root/.wine -iname 'terminal64.exe' 2>/dev/null | head -1 || true)"
MTEST_EX="$(find /root/.wine -iname 'metatester64.exe' 2>/dev/null | head -1 || true)"

if [ -z "$MT5_EX" ] && [ -z "$MTEST_EX" ]; then
    echo "ERROR: MetaTrader installation not found"
    echo "---- installer log ----"
    tail -n 100 /tmp/mt5linux-install.log || true
    exit 1
fi

echo "    -> Installation completed"
[ -n "$MT5_EX" ] && echo "    -> terminal64.exe found"
[ -n "$MTEST_EX" ] && echo "    -> metatester64.exe found"

# ------------------------------------------------------------
# [6/7] START NOVNC
# ------------------------------------------------------------
echo "==> [6/7] Start noVNC"

mkdir -p /opt/mt5
VNC_CERT="/opt/mt5/novnc.pem"

openssl req -x509 -nodes -newkey rsa:2048 \
    -keyout "$VNC_CERT" -out "$VNC_CERT" -days 3650 \
    -subj "/CN=$SERVER_IP" >/dev/null 2>&1

cat > /opt/mt5/open-vnc.sh <<EOF
#!/bin/bash
pkill -9 -f x11vnc 2>/dev/null || true
pkill -9 -f websockify 2>/dev/null || true
sleep 2

rm -f /tmp/.X10-lock /tmp/.X11-unix/X10 2>/dev/null || true
Xvfb :10 -screen 0 1280x900x24 >/tmp/xvfb-vnc.log 2>&1 &
sleep 3

x11vnc -display :10 -rfbport $VNC_PORT -passwd "$VNC_PASS" \
    -forever -noxdamage -noxfixes -bg \
    -o /tmp/x11vnc.log 2>/dev/null || true
sleep 2

websockify -D \
    --web=/usr/share/novnc/ \
    --cert="$VNC_CERT" \
    $NOVNC_PORT localhost:$VNC_PORT \
    >/tmp/websockify.log 2>&1
sleep 2

MT5_EX="\$(find /root/.wine -iname 'terminal64.exe' 2>/dev/null | head -1 || true)"
MTEST_EX="\$(find /root/.wine -iname 'metatester64.exe' 2>/dev/null | head -1 || true)"

if [ -n "\$MTEST_EX" ]; then
    DISPLAY=:10 WINEDEBUG=-all wine "\$MTEST_EX" >/tmp/metatester-vnc.log 2>&1 &
elif [ -n "\$MT5_EX" ]; then
    DISPLAY=:10 WINEDEBUG=-all wine "\$MT5_EX" >/tmp/terminal-vnc.log 2>&1 &
fi

echo ""
echo "============================================"
echo " noVNC running"
echo "============================================"
echo " Browser  : https://$SERVER_IP:$NOVNC_PORT/vnc.html"
echo " Password : $VNC_PASS"
echo "============================================"
EOF

chmod +x /opt/mt5/open-vnc.sh
/opt/mt5/open-vnc.sh

# ------------------------------------------------------------
# [7/7] CLEAN RAM
# ------------------------------------------------------------
echo "==> [7/7] Clean RAM"

cat > /usr/local/bin/clear-ram-cache.sh <<'EOF'
#!/bin/bash
sync
echo 1 > /proc/sys/vm/drop_caches
EOF
chmod +x /usr/local/bin/clear-ram-cache.sh
/usr/local/bin/clear-ram-cache.sh || true

cat <<DONE

=====================================================
 SETUP COMPLETE
=====================================================
 Installed:
   MetaTrader / MetaTester only

 Not done:
   No agents created
   No agents started
   No WARP
   No ZRAM

 noVNC:
   https://$SERVER_IP:$NOVNC_PORT/vnc.html
   Password: $VNC_PASS

 Reopen VNC later:
   /opt/mt5/open-vnc.sh
=====================================================
DONE
