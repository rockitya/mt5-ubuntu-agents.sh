#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

NOVNC_PORT=6080
VNC_PORT=5900
VNC_PASS="mt5vnc"
SERVER_IP="$(hostname -I | awk '{print $1}')"

SETUP_EXE="/root/mt5setup.exe"
LINUX_SCRIPT="/root/mt5linux.sh"

echo "============================================="
echo " MT5 / MetaTester offline installer"
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
# [0/6] CHECK OFFLINE INSTALLER
# ------------------------------------------------------------
echo "==> [0/6] Check offline installer"

if [ -f "$SETUP_EXE" ]; then
    echo "    -> Found Windows installer: $SETUP_EXE"
elif [ -f "$LINUX_SCRIPT" ]; then
    echo "    -> Found Linux installer script: $LINUX_SCRIPT"
else
    echo ""
    echo "ERROR: No offline installer found."
    echo ""
    echo "Upload one of these from your local PC:"
    echo "  /root/mt5setup.exe"
    echo "  /root/mt5linux.sh"
    echo ""
    echo "Example from local PC:"
    echo "  scp mt5setup.exe root@$SERVER_IP:/root/mt5setup.exe"
    echo ""
    exit 1
fi

# ------------------------------------------------------------
# [1/6] REMOVE OLD SETUP
# ------------------------------------------------------------
echo "==> [1/6] Removing old setup"

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
rm -f /etc/apt/keyrings/winehq-archive.key 2>/dev/null || true
rm -f /etc/sysctl.d/99-mt5.conf 2>/dev/null || true
rm -f /etc/default/zramswap 2>/dev/null || true

apt-get autoremove -y >/dev/null 2>&1 || true
apt-get autoclean -y >/dev/null 2>&1 || true

echo "    -> Old setup removed"

# ------------------------------------------------------------
# [2/6] DISABLE FIREWALL
# ------------------------------------------------------------
echo "==> [2/6] Disable firewall"

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
# [3/6] INSTALL WINE + VNC + TOOLS
# ------------------------------------------------------------
echo "==> [3/6] Install Wine + VNC + tools"

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
# [4/6] SETUP FIXED 64GB SWAP
# ------------------------------------------------------------
echo "==> [4/6] Setup fixed 64GB swap"

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
# [5/6] INSTALL METATRADER / METATESTER FROM OFFLINE FILE
# ------------------------------------------------------------
echo "==> [5/6] Install MetaTrader / MetaTester from offline file"

mkdir -p /opt/mt5

export WINEPREFIX=/root/.wine
export WINEARCH=win64
export WINEDLLOVERRIDES="mscoree,mshtml="
export WINEDEBUG=-all

rm -f /tmp/.X90-lock /tmp/.X11-unix/X90 2>/dev/null || true
Xvfb :90 -screen 0 1280x900x24 >/tmp/xvfb-install.log 2>&1 &
XVFB_PID=$!
sleep 3

DISPLAY=:90 wineboot -u >/dev/null 2>&1
sleep 3

if [ -f "$SETUP_EXE" ]; then
    echo "    -> Installing from mt5setup.exe"
    DISPLAY=:90 wine "$SETUP_EXE" /auto >/tmp/mt5-install.log 2>&1 || true
elif [ -f "$LINUX_SCRIPT" ]; then
    echo "    -> Installing from mt5linux.sh"
    bash "$LINUX_SCRIPT" >/tmp/mt5-install.log 2>&1 || true
fi

sleep 20

kill "$XVFB_PID" 2>/dev/null || true
wait "$XVFB_PID" 2>/dev/null || true
rm -f /tmp/.X90-lock /tmp/.X11-unix/X90 2>/dev/null || true

MT5_EX="$(find /root/.wine -iname 'terminal64.exe' 2>/dev/null | head -1 || true)"
MTEST_EX="$(find /root/.wine -iname 'metatester64.exe' 2>/dev/null | head -1 || true)"

if [ -z "$MT5_EX" ] && [ -z "$MTEST_EX" ]; then
    echo "ERROR: Installation not found"
    echo "---- install log ----"
    tail -n 100 /tmp/mt5-install.log || true
    exit 1
fi

[ -n "$MT5_EX" ] && echo "    -> terminal64.exe found"
[ -n "$MTEST_EX" ] && echo "    -> metatester64.exe found"

# ------------------------------------------------------------
# [6/6] OPEN IN NOVNC
# ------------------------------------------------------------
echo "==> [6/6] Open MetaTrader / MetaTester in noVNC"

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
else
    echo "Nothing to open"
    exit 1
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

cat <<DONE

=====================================================
 OFFLINE INSTALL COMPLETE
=====================================================
 noVNC:
   https://$SERVER_IP:$NOVNC_PORT/vnc.html
   Password: $VNC_PASS

 Reopen later:
   /opt/mt5/open-vnc.sh
=====================================================
DONE
