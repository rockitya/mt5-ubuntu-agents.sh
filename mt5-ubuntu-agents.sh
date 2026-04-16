#!/bin/bash
# NO set -e on purpose — we handle errors manually
export DEBIAN_FRONTEND=noninteractive

# ============================================================
# MT5 / MetaTester VNC setup
# - Install Wine + openbox window manager + noVNC
# - Download mt5setup.exe once from Google Drive (cached)
# - Start full desktop in noVNC (not headless)
# - Launch installer INSIDE VNC so you can see and control it
# - No agents, no WARP, no ZRAM
# ============================================================

NOVNC_PORT=6080
VNC_PORT=5900
VNC_PASS="mt5vnc"
SERVER_IP="$(hostname -I | awk '{print $1}')"
FILE_ID="1XMi5YbCtyeiJFlSbflJjbUFV-sIQI4TC"
GDRIVE_URL="https://drive.usercontent.google.com/download?id=${FILE_ID}&export=download&authuser=0"
SETUP_FILE="/root/mt5setup.exe"

echo "============================================="
echo " MT5 / MetaTester VNC setup"
echo " Server : $SERVER_IP"
echo " noVNC  : https://$SERVER_IP:$NOVNC_PORT/vnc.html"
echo " Pass   : $VNC_PASS"
echo "============================================="

# ------------------------------------------------------------
# [PRE] CLEAR APT LOCKS
# ------------------------------------------------------------
echo "==> [PRE] Clearing apt locks"
pkill -9 -f apt-get 2>/dev/null; pkill -9 -f apt 2>/dev/null; pkill -9 -f dpkg 2>/dev/null
sleep 2
rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock /var/cache/apt/archives/lock 2>/dev/null
dpkg --configure -a 2>/dev/null
echo "    -> done"

# ------------------------------------------------------------
# [0/6] REMOVE OLD SETUP
# ------------------------------------------------------------
echo "==> [0/6] Removing old setup"
pkill -9 -f metatester64 2>/dev/null; pkill -9 -f terminal64 2>/dev/null
pkill -9 -f wineserver   2>/dev/null; pkill -9 -f wine        2>/dev/null
pkill -9 -f Xvfb         2>/dev/null; pkill -9 -f x11vnc      2>/dev/null
pkill -9 -f websockify   2>/dev/null
screen -wipe 2>/dev/null

rm -rf /opt/mt5 /root/.wine 2>/dev/null
rm -f /tmp/.X*-lock 2>/dev/null; rm -rf /tmp/.X11-unix 2>/dev/null

apt-get remove --purge -y \
    winehq-devel winehq-stable winehq-staging wine wine64 wine32 libwine fonts-wine \
    x11vnc novnc python3-websockify \
    openbox xterm \
    zram-tools cloudflare-warp \
    2>/dev/null
apt-get autoremove -y >/dev/null 2>&1
apt-get autoclean -y >/dev/null 2>&1

swapoff /swapfile 2>/dev/null; swapoff -a 2>/dev/null
sed -i '\|/swapfile none swap sw 0 0|d' /etc/fstab 2>/dev/null; rm -f /swapfile 2>/dev/null

rm -f /etc/apt/sources.list.d/winehq-*.sources 2>/dev/null
rm -f /etc/apt/keyrings/winehq-archive.key 2>/dev/null
rm -f /etc/sysctl.d/99-mt5.conf /etc/default/zramswap 2>/dev/null
echo "    -> done"

# ------------------------------------------------------------
# [1/6] DISABLE FIREWALL
# ------------------------------------------------------------
echo "==> [1/6] Disable firewall"
ufw disable 2>/dev/null
iptables -F 2>/dev/null; iptables -X 2>/dev/null
iptables -t nat -F 2>/dev/null; iptables -t mangle -F 2>/dev/null
iptables -P INPUT ACCEPT 2>/dev/null; iptables -P FORWARD ACCEPT 2>/dev/null; iptables -P OUTPUT ACCEPT 2>/dev/null
ip6tables -F 2>/dev/null; ip6tables -X 2>/dev/null
ip6tables -P INPUT ACCEPT 2>/dev/null; ip6tables -P FORWARD ACCEPT 2>/dev/null; ip6tables -P OUTPUT ACCEPT 2>/dev/null
systemctl stop firewalld 2>/dev/null; systemctl disable firewalld 2>/dev/null
echo "    -> done"

# ------------------------------------------------------------
# [2/6] INSTALL WINE + NOVNC + WINDOW MANAGER
# ------------------------------------------------------------
echo "==> [2/6] Install Wine + noVNC + openbox window manager"

apt-get update -y >/dev/null
apt-get install -y \
    software-properties-common ca-certificates gnupg2 lsb-release \
    wget curl openssl python3 python3-pip \
    xvfb screen cabextract \
    x11vnc novnc python3-websockify \
    openbox xterm \
    net-tools util-linux procps \
    >/dev/null 2>&1

dpkg --add-architecture i386
mkdir -pm755 /etc/apt/keyrings
UBUNTU_VER="$(lsb_release -cs)"

wget -q -O /etc/apt/keyrings/winehq-archive.key https://dl.winehq.org/wine-builds/winehq.key
wget -q -NP /etc/apt/sources.list.d/ \
    "https://dl.winehq.org/wine-builds/ubuntu/dists/${UBUNTU_VER}/winehq-${UBUNTU_VER}.sources"

apt-get update -y >/dev/null
apt-get install -y --install-recommends winehq-devel >/dev/null 2>&1

echo "    -> $(wine --version)"

# ------------------------------------------------------------
# [3/6] FIXED 64GB SWAP ONLY
# ------------------------------------------------------------
echo "==> [3/6] Setup fixed 64GB swap"

swapoff -a 2>/dev/null
sed -i '\|/swapfile none swap sw 0 0|d' /etc/fstab 2>/dev/null
rm -f /swapfile 2>/dev/null

if fallocate -l 64G /swapfile 2>/dev/null; then
    echo "    -> fallocate ok"
else
    dd if=/dev/zero of=/swapfile bs=1M count=65536 status=progress
fi

chmod 600 /swapfile; mkswap /swapfile >/dev/null; swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab

cat > /etc/sysctl.d/99-mt5.conf <<'SYSCTL'
vm.swappiness=10
vm.vfs_cache_pressure=80
SYSCTL
sysctl -p /etc/sysctl.d/99-mt5.conf >/dev/null 2>&1

free -h | grep -E "Mem|Swap"
swapon --show

# ------------------------------------------------------------
# [4/6] DOWNLOAD MT5SETUP.EXE ONCE FROM GOOGLE DRIVE
# ------------------------------------------------------------
echo "==> [4/6] Download mt5setup.exe from Google Drive"

FILESIZE=$(stat -c%s "$SETUP_FILE" 2>/dev/null || echo 0)

if [ "$FILESIZE" -gt 1000000 ]; then
    echo "    -> Reusing cached mt5setup.exe ($(du -sh "$SETUP_FILE" | cut -f1))"
else
    echo "    -> Installing gdown"
    python3 -m pip install -q --upgrade pip 2>/dev/null
    python3 -m pip install -q gdown 2>/dev/null
    rm -f "$SETUP_FILE" 2>/dev/null

    echo "    -> Downloading from Google Drive..."
    gdown --fuzzy "$GDRIVE_URL" -O "$SETUP_FILE" 2>&1 || \
    gdown "https://drive.google.com/uc?id=${FILE_ID}" -O "$SETUP_FILE" 2>&1 || \
    gdown "$FILE_ID" -O "$SETUP_FILE" 2>&1

    FILESIZE=$(stat -c%s "$SETUP_FILE" 2>/dev/null || echo 0)
    if [ "$FILESIZE" -lt 1000000 ]; then
        echo ""
        echo "ERROR: Google Drive download failed (${FILESIZE} bytes)"
        echo "Manually upload from your local PC then re-run:"
        echo "  scp mt5setup.exe root@$SERVER_IP:/root/mt5setup.exe"
        exit 1
    fi
    echo "    -> Downloaded: $(du -sh "$SETUP_FILE" | cut -f1)"
fi

# ------------------------------------------------------------
# [5/6] START NOVNC WITH FULL DESKTOP
# ------------------------------------------------------------
echo "==> [5/6] Start noVNC desktop"

mkdir -p /opt/mt5
VNC_CERT="/opt/mt5/novnc.pem"

openssl req -x509 -nodes -newkey rsa:2048 \
    -keyout "$VNC_CERT" -out "$VNC_CERT" -days 3650 \
    -subj "/CN=$SERVER_IP" >/dev/null 2>&1

# Kill any leftover VNC/display processes
pkill -9 -f x11vnc 2>/dev/null; pkill -9 -f websockify 2>/dev/null
sleep 1
rm -f /tmp/.X10-lock /tmp/.X11-unix/X10 2>/dev/null

# Start virtual display
Xvfb :10 -screen 0 1280x900x24 >/tmp/xvfb-vnc.log 2>&1 &
sleep 3

# Start openbox window manager (so the desktop is usable, not black)
DISPLAY=:10 openbox-session >/tmp/openbox.log 2>&1 &
sleep 2

# Start x11vnc
x11vnc -display :10 -rfbport "$VNC_PORT" -passwd "$VNC_PASS" \
    -forever -shared -noxdamage -noxfixes -bg \
    -o /tmp/x11vnc.log 2>/dev/null
sleep 2

# Start noVNC websocket proxy
websockify -D \
    --web=/usr/share/novnc/ \
    --cert="$VNC_CERT" \
    "$NOVNC_PORT" localhost:"$VNC_PORT" \
    >/tmp/websockify.log 2>&1
sleep 2

echo "    -> noVNC desktop running"

# ------------------------------------------------------------
# [6/6] LAUNCH INSTALLER INSIDE VNC
# ------------------------------------------------------------
echo "==> [6/6] Launch installer inside VNC"

export WINEPREFIX=/root/.wine
export WINEARCH=win64
export WINEDLLOVERRIDES="mscoree,mshtml="
export WINEDEBUG=-all

# Init wine prefix first
DISPLAY=:10 wineboot -u >/dev/null 2>&1 &
sleep 8

# Launch installer VISIBLY inside VNC — no /auto flag so you can see it
DISPLAY=:10 wine "$SETUP_FILE" >/tmp/mt5-install.log 2>&1 &

echo "    -> Installer launched inside VNC"
echo "    -> Open your browser to complete setup"

# Write reopen helper
cat > /opt/mt5/open-vnc.sh <<OPENVNC
#!/bin/bash
pkill -9 -f x11vnc 2>/dev/null
pkill -9 -f websockify 2>/dev/null
sleep 2

rm -f /tmp/.X10-lock /tmp/.X11-unix/X10 2>/dev/null
Xvfb :10 -screen 0 1280x900x24 >/tmp/xvfb-vnc.log 2>&1 &
sleep 3
DISPLAY=:10 openbox-session >/tmp/openbox.log 2>&1 &
sleep 2

x11vnc -display :10 -rfbport 5900 -passwd "$VNC_PASS" \\
    -forever -shared -noxdamage -noxfixes -bg \\
    -o /tmp/x11vnc.log 2>/dev/null
sleep 2

websockify -D \\
    --web=/usr/share/novnc/ \\
    --cert="/opt/mt5/novnc.pem" \\
    6080 localhost:5900 \\
    >/tmp/websockify.log 2>&1
sleep 2

MTEST="\$(find /root/.wine -iname 'metatester64.exe' 2>/dev/null | head -1)"
MT5="\$(find /root/.wine -iname 'terminal64.exe' 2>/dev/null | head -1)"

if [ -n "\$MTEST" ]; then
    DISPLAY=:10 WINEPREFIX=/root/.wine WINEARCH=win64 WINEDEBUG=-all wine "\$MTEST" >/tmp/metatester-vnc.log 2>&1 &
    echo "-> Launched metatester64.exe"
elif [ -n "\$MT5" ]; then
    DISPLAY=:10 WINEPREFIX=/root/.wine WINEARCH=win64 WINEDEBUG=-all wine "\$MT5" >/tmp/terminal-vnc.log 2>&1 &
    echo "-> Launched terminal64.exe"
else
    echo "-> MetaTester not found. Install it from the VNC desktop."
fi

echo ""
echo "=============================="
echo " https://\$(hostname -I | awk '{print \$1}'):6080/vnc.html"
echo " Password: $VNC_PASS"
echo "=============================="
OPENVNC
chmod +x /opt/mt5/open-vnc.sh

# RAM cleanup helper
cat > /usr/local/bin/clear-ram.sh <<'RAMCLEAN'
#!/bin/bash
sync; echo 1 > /proc/sys/vm/drop_caches
RAMCLEAN
chmod +x /usr/local/bin/clear-ram.sh
/usr/local/bin/clear-ram.sh

cat <<DONE

=====================================================
 SETUP COMPLETE
=====================================================
 Open this in your browser NOW:
   https://$SERVER_IP:$NOVNC_PORT/vnc.html
   Password: $VNC_PASS

 The mt5setup.exe installer is running inside VNC.
 Complete the installation from your browser window.
 You have full mouse + keyboard control.

 After installation finishes, reopen MetaTester anytime:
   /opt/mt5/open-vnc.sh

 RAM cleanup:
   /usr/local/bin/clear-ram.sh
=====================================================
DONE
