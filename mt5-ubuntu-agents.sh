#!/bin/bash
export DEBIAN_FRONTEND=noninteractive

NOVNC_PORT=6080
VNC_PORT=5900
VNC_PASS="mt5vnc"
SERVER_IP="$(hostname -I | awk '{print $1}')"
SETUP_FILE="/root/mt5setup.exe"
OFFICIAL_URL="https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe"
GDRIVE_ID="1XMi5YbCtyeiJFlSbflJjbUFV-sIQI4TC"
GDRIVE_URL="https://drive.usercontent.google.com/download?id=${GDRIVE_ID}&export=download&authuser=0"

echo "============================================="
echo " MT5 Clean Install"
echo " $SERVER_IP"
echo "============================================="

# ===========================================================
# [1] UNINSTALL ALL PREVIOUS METATESTER + MODULES
# ===========================================================
echo ""
echo "==> [1/6] Uninstall all previous MetaTester + modules"

# Kill everything
pkill -9 -f metatester64  2>/dev/null; pkill -9 -f terminal64  2>/dev/null
pkill -9 -f wineserver    2>/dev/null; pkill -9 -f wine        2>/dev/null
pkill -9 -f Xvfb          2>/dev/null; pkill -9 -f x11vnc      2>/dev/null
pkill -9 -f websockify    2>/dev/null; pkill -9 -f openbox     2>/dev/null
pkill -9 -f xterm         2>/dev/null
screen -wipe 2>/dev/null; sleep 2

# Remove all MT5 / Wine directories
rm -rf /opt/mt5 /opt/mt5master /opt/mt5agent-* 2>/dev/null
rm -rf /root/.wine /root/.local/share/applications 2>/dev/null
rm -f /tmp/.X*-lock 2>/dev/null; rm -rf /tmp/.X11-unix 2>/dev/null

# Clear apt locks first
pkill -9 -f apt-get 2>/dev/null; pkill -9 -f dpkg 2>/dev/null; sleep 2
rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock \
      /var/lib/apt/lists/lock /var/cache/apt/archives/lock 2>/dev/null
dpkg --configure -a 2>/dev/null

# Purge Wine + VNC + extras
apt-get remove --purge -y \
    winehq-devel winehq-stable winehq-staging \
    wine wine64 wine32 wine-stable wine-devel wine-staging \
    libwine fonts-wine \
    x11vnc novnc python3-websockify \
    openbox xterm x11-utils \
    zram-tools cloudflare-warp \
    2>/dev/null
apt-get autoremove -y >/dev/null 2>&1
apt-get autoclean  -y >/dev/null 2>&1

# Remove repo/key files
rm -f /etc/apt/sources.list.d/winehq-*.sources 2>/dev/null
rm -f /etc/apt/sources.list.d/cloudflare-*.list 2>/dev/null
rm -f /etc/apt/keyrings/winehq-archive.key 2>/dev/null
rm -f /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg 2>/dev/null
rm -f /etc/sysctl.d/99-mt5.conf /etc/default/zramswap 2>/dev/null
(crontab -l 2>/dev/null | grep -v 'mt5\|clear-ram' || true) | crontab - 2>/dev/null

echo "    -> done"

# ===========================================================
# [2] ADD 64GB SWAP
# ===========================================================
echo ""
echo "==> [2/6] Add 64GB swap"

swapoff -a 2>/dev/null
sed -i '\|/swapfile|d' /etc/fstab 2>/dev/null
rm -f /swapfile 2>/dev/null

if fallocate -l 64G /swapfile 2>/dev/null; then
    echo "    -> fallocate ok"
else
    dd if=/dev/zero of=/swapfile bs=1M count=65536 status=progress
fi

chmod 600 /swapfile
mkswap  /swapfile >/dev/null
swapon  /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab

cat > /etc/sysctl.d/99-mt5.conf <<'EOF'
vm.swappiness=10
vm.vfs_cache_pressure=80
EOF
sysctl -p /etc/sysctl.d/99-mt5.conf >/dev/null 2>&1

free -h | grep -E "Mem|Swap"
swapon --show
echo "    -> done"

# ===========================================================
# [3] DISABLE FIREWALL
# ===========================================================
echo ""
echo "==> [3/6] Disable firewall"

ufw disable 2>/dev/null
iptables  -F 2>/dev/null; iptables  -X 2>/dev/null
iptables  -t nat    -F 2>/dev/null; iptables  -t mangle -F 2>/dev/null
iptables  -P INPUT   ACCEPT 2>/dev/null
iptables  -P FORWARD ACCEPT 2>/dev/null
iptables  -P OUTPUT  ACCEPT 2>/dev/null
ip6tables -F 2>/dev/null; ip6tables -X 2>/dev/null
ip6tables -P INPUT   ACCEPT 2>/dev/null
ip6tables -P FORWARD ACCEPT 2>/dev/null
ip6tables -P OUTPUT  ACCEPT 2>/dev/null
systemctl stop    firewalld 2>/dev/null
systemctl disable firewalld 2>/dev/null

echo "    -> done"

# ===========================================================
# [4] INSTALL WINE + TOOLS + DOWNLOAD MT5SETUP.EXE
# ===========================================================
echo ""
echo "==> [4/6] Install Wine + tools, download mt5setup.exe"

apt-get update -y >/dev/null
apt-get install -y \
    software-properties-common ca-certificates gnupg2 lsb-release \
    wget curl openssl python3 python3-pip \
    xvfb screen cabextract x11-utils \
    x11vnc novnc python3-websockify \
    openbox xterm \
    net-tools util-linux procps \
    >/dev/null 2>&1

dpkg --add-architecture i386
mkdir -pm755 /etc/apt/keyrings
UBUNTU_VER="$(lsb_release -cs)"

wget -q -O /etc/apt/keyrings/winehq-archive.key \
    https://dl.winehq.org/wine-builds/winehq.key
wget -q -NP /etc/apt/sources.list.d/ \
    "https://dl.winehq.org/wine-builds/ubuntu/dists/${UBUNTU_VER}/winehq-${UBUNTU_VER}.sources"

apt-get update -y >/dev/null
apt-get install -y --install-recommends winehq-devel >/dev/null 2>&1
echo "    -> $(wine --version)"

# --- Download mt5setup.exe ---
FILESIZE=$(stat -c%s "$SETUP_FILE" 2>/dev/null || echo 0)

if [ "$FILESIZE" -gt 1000000 ]; then
    echo "    -> Reusing cached mt5setup.exe ($(du -sh "$SETUP_FILE" | cut -f1))"
else
    rm -f "$SETUP_FILE" 2>/dev/null

    # Try 1: Official MetaQuotes CDN
    echo "    -> Trying official MetaQuotes CDN..."
    wget -q --timeout=30 --tries=2 "$OFFICIAL_URL" -O "$SETUP_FILE" 2>/dev/null || true
    FILESIZE=$(stat -c%s "$SETUP_FILE" 2>/dev/null || echo 0)

    if [ "$FILESIZE" -lt 1000000 ]; then
        echo "    -> Official CDN blocked, trying curl..."
        curl -L --max-time 30 --retry 2 --silent "$OFFICIAL_URL" -o "$SETUP_FILE" 2>/dev/null || true
        FILESIZE=$(stat -c%s "$SETUP_FILE" 2>/dev/null || echo 0)
    fi

    # Try 2: Google Drive fallback
    if [ "$FILESIZE" -lt 1000000 ]; then
        echo "    -> Official CDN failed, falling back to Google Drive..."
        python3 -m pip install -q --upgrade pip 2>/dev/null
        python3 -m pip install -q gdown 2>/dev/null
        rm -f "$SETUP_FILE" 2>/dev/null
        gdown --fuzzy "$GDRIVE_URL" -O "$SETUP_FILE" 2>&1 || \
        gdown "https://drive.google.com/uc?id=${GDRIVE_ID}" -O "$SETUP_FILE" 2>&1 || \
        gdown "$GDRIVE_ID" -O "$SETUP_FILE" 2>&1
        FILESIZE=$(stat -c%s "$SETUP_FILE" 2>/dev/null || echo 0)
    fi

    # Both failed
    if [ "$FILESIZE" -lt 1000000 ]; then
        echo ""
        echo "ERROR: Download failed from both sources (${FILESIZE} bytes)"
        echo ""
        echo "Upload manually from your local PC:"
        echo "  scp mt5setup.exe root@$SERVER_IP:/root/mt5setup.exe"
        echo "Then re-run this script."
        exit 1
    fi

    echo "    -> Downloaded: $(du -sh "$SETUP_FILE" | cut -f1)"
fi

# ===========================================================
# [5] OPEN METATESTER IN NOVNC
# ===========================================================
echo ""
echo "==> [5/6] Open MetaTester in noVNC"

mkdir -p /opt/mt5
VNC_CERT="/opt/mt5/novnc.pem"

openssl req -x509 -nodes -newkey rsa:2048 \
    -keyout "$VNC_CERT" -out "$VNC_CERT" -days 3650 \
    -subj "/CN=$SERVER_IP" >/dev/null 2>&1

# Kill leftovers
pkill -9 -f x11vnc    2>/dev/null; pkill -9 -f websockify 2>/dev/null
pkill -9 -f openbox   2>/dev/null; pkill -9 -f Xvfb       2>/dev/null
sleep 2
rm -f /tmp/.X10-lock /tmp/.X11-unix/X10 2>/dev/null

# Start virtual display
Xvfb :10 -screen 0 1280x900x24 >/tmp/xvfb.log 2>&1 &
sleep 4

# Dark background so desktop is visible
DISPLAY=:10 xsetroot -solid '#1a1f2e'

# Start openbox window manager
DISPLAY=:10 openbox &
sleep 3

# Open xterm so there is always something to interact with
DISPLAY=:10 xterm \
    -geometry 110x35+20+20 \
    -bg '#0d1117' -fg '#00ff88' \
    -fa 'Monospace' -fs 11 \
    -title "MT5 Shell" \
    &
sleep 2

# Start x11vnc
x11vnc \
    -display :10 \
    -rfbport "$VNC_PORT" \
    -passwd  "$VNC_PASS" \
    -forever -shared \
    -noxdamage -noxfixes \
    -bg -o /tmp/x11vnc.log 2>/dev/null
sleep 2

# Start noVNC
websockify -D \
    --web=/usr/share/novnc/ \
    --cert="$VNC_CERT" \
    "$NOVNC_PORT" localhost:"$VNC_PORT" \
    >/tmp/websockify.log 2>&1
sleep 2

# Verify ports are open
VNC_UP=$(ss -tuln 2>/dev/null | grep -c ":${VNC_PORT} " || echo 0)
NOVNC_UP=$(ss -tuln 2>/dev/null | grep -c ":${NOVNC_PORT} " || echo 0)
echo "    -> VNC  port $VNC_PORT  : $([ "$VNC_UP"   -gt 0 ] && echo UP || echo FAILED)"
echo "    -> noVNC port $NOVNC_PORT : $([ "$NOVNC_UP" -gt 0 ] && echo UP || echo FAILED)"

# Init Wine prefix
export WINEPREFIX=/root/.wine
export WINEARCH=win64
export WINEDLLOVERRIDES="mscoree,mshtml="
export WINEDEBUG=-all

echo "    -> Initialising Wine prefix..."
DISPLAY=:10 wineboot --init >/tmp/wineboot.log 2>&1
sleep 12

# Launch installer inside VNC
echo "    -> Launching mt5setup.exe inside VNC..."
DISPLAY=:10 \
    WINEPREFIX=/root/.wine \
    WINEARCH=win64 \
    WINEDLLOVERRIDES="mscoree,mshtml=" \
    WINEDEBUG=-all \
    wine "$SETUP_FILE" >/tmp/mt5-install.log 2>&1 &
INSTALL_PID=$!
sleep 5

if kill -0 "$INSTALL_PID" 2>/dev/null; then
    echo "    -> Installer running (PID $INSTALL_PID)"
else
    echo "    -> WARNING: Installer exited. Check /tmp/mt5-install.log"
    echo "    -> Use the xterm in VNC to run manually:"
    echo "       WINEPREFIX=/root/.wine wine /root/mt5setup.exe"
fi

# Write reopen script
cat > /opt/mt5/open-vnc.sh <<OPENVNC
#!/bin/bash
pkill -9 -f x11vnc 2>/dev/null; pkill -9 -f websockify 2>/dev/null
pkill -9 -f openbox 2>/dev/null; pkill -9 -f Xvfb 2>/dev/null; sleep 2
rm -f /tmp/.X10-lock /tmp/.X11-unix/X10 2>/dev/null

Xvfb :10 -screen 0 1280x900x24 >/tmp/xvfb.log 2>&1 &; sleep 4
DISPLAY=:10 xsetroot -solid '#1a1f2e'
DISPLAY=:10 openbox &; sleep 3
DISPLAY=:10 xterm -geometry 110x35+20+20 -bg '#0d1117' -fg '#00ff88' \
    -fa 'Monospace' -fs 11 -title "MT5 Shell" &; sleep 2

x11vnc -display :10 -rfbport 5900 -passwd "${VNC_PASS}" \\
    -forever -shared -noxdamage -noxfixes -bg -o /tmp/x11vnc.log 2>/dev/null; sleep 2

websockify -D --web=/usr/share/novnc/ --cert="/opt/mt5/novnc.pem" \\
    6080 localhost:5900 >/tmp/websockify.log 2>&1; sleep 2

MTEST="\$(find /root/.wine -iname 'metatester64.exe' 2>/dev/null | head -1)"
MT5="\$(find /root/.wine -iname 'terminal64.exe' 2>/dev/null | head -1)"

if [ -n "\$MTEST" ]; then
    DISPLAY=:10 WINEPREFIX=/root/.wine WINEARCH=win64 WINEDEBUG=-all \\
        wine "\$MTEST" >/tmp/metatester.log 2>&1 &
    echo "-> Launched metatester64.exe"
elif [ -n "\$MT5" ]; then
    DISPLAY=:10 WINEPREFIX=/root/.wine WINEARCH=win64 WINEDEBUG=-all \\
        wine "\$MT5" >/tmp/terminal.log 2>&1 &
    echo "-> Launched terminal64.exe"
else
    echo "-> Not installed yet. Use xterm in VNC to run:"
    echo "   WINEPREFIX=/root/.wine wine /root/mt5setup.exe"
fi

SIP="\$(hostname -I | awk '{print \$1}')"
echo "https://\${SIP}:6080/vnc.html?autoconnect=1  |  pw: ${VNC_PASS}"
OPENVNC
chmod +x /opt/mt5/open-vnc.sh

# ===========================================================
# [6] CLEAR RAM CACHE
# ===========================================================
echo ""
echo "==> [6/6] Clear RAM cache"
sync
echo 1 > /proc/sys/vm/drop_caches
echo 2 > /proc/sys/vm/drop_caches
echo 3 > /proc/sys/vm/drop_caches

cat > /usr/local/bin/clear-ram.sh <<'RAMCLEAN'
#!/bin/bash
sync
echo 3 > /proc/sys/vm/drop_caches
echo "RAM cache cleared"
free -h
RAMCLEAN
chmod +x /usr/local/bin/clear-ram.sh
free -h | grep -E "Mem|Swap"
echo "    -> done"

# ===========================================================
# DONE
# ===========================================================
cat <<DONE

=====================================================
 ALL DONE
=====================================================

 OPEN VNC IN BROWSER:
   https://$SERVER_IP:$NOVNC_PORT/vnc.html?autoconnect=1
   Password : $VNC_PASS

 YOU WILL SEE:
   - Dark desktop (openbox running)
   - Green xterm terminal (top-left)
   - MT5 installer window (opens in ~10s)

 IF INSTALLER DOES NOT APPEAR:
   Type this in the green xterm inside VNC:
   WINEPREFIX=/root/.wine wine /root/mt5setup.exe

 REOPEN VNC LATER:
   /opt/mt5/open-vnc.sh

 CLEAR RAM ANYTIME:
   /usr/local/bin/clear-ram.sh
=====================================================
DONE
