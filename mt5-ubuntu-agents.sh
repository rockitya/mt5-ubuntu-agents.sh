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
# [1] UNINSTALL ALL
# ===========================================================
echo ""
echo "==> [1/6] Uninstall all previous setup"

pkill -9 -f metatester64 2>/dev/null; pkill -9 -f terminal64  2>/dev/null
pkill -9 -f wineserver   2>/dev/null; pkill -9 -f wine        2>/dev/null
pkill -9 -f Xvfb         2>/dev/null; pkill -9 -f x11vnc      2>/dev/null
pkill -9 -f websockify   2>/dev/null; pkill -9 -f openbox     2>/dev/null
pkill -9 -f xterm        2>/dev/null
screen -wipe 2>/dev/null; sleep 2

rm -rf /opt/mt5 /root/.wine 2>/dev/null
rm -f /tmp/.X*-lock 2>/dev/null; rm -rf /tmp/.X11-unix 2>/dev/null

# Clear apt locks
pkill -9 -f apt-get 2>/dev/null; pkill -9 -f dpkg 2>/dev/null; sleep 2
rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock \
      /var/lib/apt/lists/lock /var/cache/apt/archives/lock 2>/dev/null
dpkg --configure -a 2>/dev/null

apt-get remove --purge -y \
    winehq-devel winehq-stable winehq-staging \
    wine wine64 wine32 wine-stable wine-devel \
    libwine fonts-wine \
    x11vnc novnc python3-websockify \
    openbox xterm x11-utils \
    zram-tools cloudflare-warp \
    2>/dev/null
apt-get autoremove -y >/dev/null 2>&1
apt-get autoclean  -y >/dev/null 2>&1

rm -f /etc/apt/sources.list.d/winehq-*.sources 2>/dev/null
rm -f /etc/apt/keyrings/winehq-archive.key 2>/dev/null
rm -f /etc/sysctl.d/99-mt5.conf 2>/dev/null
(crontab -l 2>/dev/null | grep -v 'mt5\|clear-ram' || true) | crontab - 2>/dev/null
echo "    -> done"

# ===========================================================
# [2] SWAP — check disk space, use dd (reliable on all FS)
# ===========================================================
echo ""
echo "==> [2/6] Setup swap"

swapoff -a 2>/dev/null
sed -i '\|/swapfile|d' /etc/fstab 2>/dev/null
rm -f /swapfile 2>/dev/null

# Check available disk space in GB
AVAIL_GB=$(df -BG / 2>/dev/null | awk 'NR==2{gsub("G","",$4); print $4+0}')
echo "    -> Disk available: ${AVAIL_GB}GB"

if   [ "$AVAIL_GB" -ge 68 ]; then SWAP_GB=64
elif [ "$AVAIL_GB" -ge 36 ]; then SWAP_GB=32
elif [ "$AVAIL_GB" -ge 20 ]; then SWAP_GB=16
elif [ "$AVAIL_GB" -ge 12 ]; then SWAP_GB=8
else
    echo "    WARNING: Only ${AVAIL_GB}GB free — skipping swap"
    SWAP_GB=0
fi

if [ "$SWAP_GB" -gt 0 ]; then
    echo "    -> Creating ${SWAP_GB}GB swapfile using dd (reliable on all filesystems)..."
    SWAP_MB=$((SWAP_GB * 1024))
    dd if=/dev/zero of=/swapfile bs=1M count="$SWAP_MB" status=progress 2>&1

    if [ $? -ne 0 ]; then
        echo "    ERROR: dd failed — trying smaller 4GB swap"
        rm -f /swapfile 2>/dev/null
        dd if=/dev/zero of=/swapfile bs=1M count=4096 status=none
    fi

    chmod 600 /swapfile
    mkswap /swapfile

    if swapon /swapfile; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
        echo "    -> Swap ACTIVE"
    else
        echo "    ERROR: swapon failed — check filesystem type"
        rm -f /swapfile
    fi
fi

cat > /etc/sysctl.d/99-mt5.conf <<'EOF'
vm.swappiness=60
vm.vfs_cache_pressure=80
EOF
sysctl -p /etc/sysctl.d/99-mt5.conf >/dev/null 2>&1

echo ""
echo "    --- Memory status ---"
free -h
echo ""
swapon --show 2>/dev/null || echo "    (no swap active)"
echo "    -> done"

# ===========================================================
# [3] DISABLE FIREWALL
# ===========================================================
echo ""
echo "==> [3/6] Disable firewall"

ufw disable 2>/dev/null
iptables  -F 2>/dev/null; iptables  -X 2>/dev/null
iptables  -t nat -F 2>/dev/null; iptables -t mangle -F 2>/dev/null
iptables  -P INPUT ACCEPT 2>/dev/null
iptables  -P FORWARD ACCEPT 2>/dev/null
iptables  -P OUTPUT ACCEPT 2>/dev/null
ip6tables -F 2>/dev/null; ip6tables -X 2>/dev/null
ip6tables -P INPUT ACCEPT 2>/dev/null
ip6tables -P FORWARD ACCEPT 2>/dev/null
ip6tables -P OUTPUT ACCEPT 2>/dev/null
systemctl stop firewalld 2>/dev/null
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
        echo "    -> CDN blocked, trying curl..."
        curl -L --max-time 30 --retry 2 -s "$OFFICIAL_URL" -o "$SETUP_FILE" 2>/dev/null || true
        FILESIZE=$(stat -c%s "$SETUP_FILE" 2>/dev/null || echo 0)
    fi

    # Try 2: Google Drive fallback
    if [ "$FILESIZE" -lt 1000000 ]; then
        echo "    -> Falling back to Google Drive..."
        python3 -m pip install -q --upgrade pip 2>/dev/null
        python3 -m pip install -q gdown 2>/dev/null
        rm -f "$SETUP_FILE" 2>/dev/null
        gdown --fuzzy "$GDRIVE_URL" -O "$SETUP_FILE" 2>&1 || \
        gdown "https://drive.google.com/uc?id=${GDRIVE_ID}" -O "$SETUP_FILE" 2>&1 || \
        gdown "$GDRIVE_ID" -O "$SETUP_FILE" 2>&1
        FILESIZE=$(stat -c%s "$SETUP_FILE" 2>/dev/null || echo 0)
    fi

    if [ "$FILESIZE" -lt 1000000 ]; then
        echo ""
        echo "ERROR: Download failed from all sources (${FILESIZE} bytes)"
        echo "Upload manually from your local PC:"
        echo "  scp mt5setup.exe root@$SERVER_IP:/root/mt5setup.exe"
        echo "Then re-run this script."
        exit 1
    fi
    echo "    -> Downloaded: $(du -sh "$SETUP_FILE" | cut -f1)"
fi

# ===========================================================
# [5] START NOVNC DESKTOP + INSTALL + OPEN METATESTER
# ===========================================================
echo ""
echo "==> [5/6] Start VNC desktop + launch installer"

mkdir -p /opt/mt5
VNC_CERT="/opt/mt5/novnc.pem"

openssl req -x509 -nodes -newkey rsa:2048 \
    -keyout "$VNC_CERT" -out "$VNC_CERT" -days 3650 \
    -subj "/CN=$SERVER_IP" >/dev/null 2>&1

# Kill all old display processes
pkill -9 -f x11vnc    2>/dev/null; pkill -9 -f websockify  2>/dev/null
pkill -9 -f openbox   2>/dev/null; pkill -9 -f Xvfb        2>/dev/null
pkill -9 -f xterm     2>/dev/null
sleep 2
rm -f /tmp/.X10-lock /tmp/.X11-unix/X10 2>/dev/null

# Start display
Xvfb :10 -screen 0 1280x900x24 >/tmp/xvfb.log 2>&1 &
sleep 4

# Dark desktop background
DISPLAY=:10 xsetroot -solid '#1a1f2e'

# Start openbox
DISPLAY=:10 openbox &
sleep 3

# Open xterm on the desktop (always visible)
DISPLAY=:10 xterm \
    -geometry 110x35+20+20 \
    -bg '#0d1117' -fg '#00ff88' \
    -fa 'Monospace' -fs 11 \
    -title "MT5 Shell" &
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

# Verify ports
VNC_UP=$(ss   -tuln 2>/dev/null | grep -c ":${VNC_PORT} "   || echo 0)
NOVNC_UP=$(ss -tuln 2>/dev/null | grep -c ":${NOVNC_PORT} " || echo 0)
echo "    -> VNC  :$VNC_PORT   $([ "$VNC_UP"   -gt 0 ] && echo UP || echo FAILED)"
echo "    -> noVNC :$NOVNC_PORT $([ "$NOVNC_UP" -gt 0 ] && echo UP || echo FAILED)"

# Init Wine
export WINEPREFIX=/root/.wine
export WINEARCH=win64
export WINEDLLOVERRIDES="mscoree,mshtml="
export WINEDEBUG=-all

echo "    -> Init Wine prefix (wait ~15s)..."
DISPLAY=:10 wineboot --init >/tmp/wineboot.log 2>&1
sleep 15

# Launch mt5setup.exe in VNC
echo "    -> Launching mt5setup.exe in VNC (complete install in browser)..."
DISPLAY=:10 WINEPREFIX=/root/.wine WINEARCH=win64 \
    WINEDLLOVERRIDES="mscoree,mshtml=" WINEDEBUG=-all \
    wine "$SETUP_FILE" >/tmp/mt5-install.log 2>&1 &
INSTALL_PID=$!
sleep 5

if kill -0 "$INSTALL_PID" 2>/dev/null; then
    echo "    -> Installer running PID=$INSTALL_PID — complete in browser"
else
    echo "    -> Installer exited. Log: /tmp/mt5-install.log"
fi

# ===========================================================
# [6] CLEAR RAM CACHE + WRITE HELPER SCRIPTS
# ===========================================================
echo ""
echo "==> [6/6] Clear RAM cache + write helpers"

sync
echo 3 > /proc/sys/vm/drop_caches

# open-metatester.sh — opens METATESTER64.EXE specifically
cat > /opt/mt5/open-metatester.sh <<'METASCRIPT'
#!/bin/bash
echo "==> Searching for metatester64.exe..."
MTEST="$(find /root/.wine -iname 'metatester64.exe' 2>/dev/null | head -1)"

if [ -z "$MTEST" ]; then
    echo "ERROR: metatester64.exe not found"
    echo "Is MetaTrader 5 installed? Run /opt/mt5/open-vnc.sh and install first."
    find /root/.wine -iname '*.exe' 2>/dev/null | grep -i 'meta\|trade\|tester' || true
    exit 1
fi

echo "-> Found: $MTEST"

# Ensure display is running
if ! pgrep -x Xvfb >/dev/null 2>&1; then
    echo "-> Starting display..."
    rm -f /tmp/.X10-lock /tmp/.X11-unix/X10 2>/dev/null
    Xvfb :10 -screen 0 1280x900x24 >/tmp/xvfb.log 2>&1 &
    sleep 4
    DISPLAY=:10 xsetroot -solid '#1a1f2e'
    DISPLAY=:10 openbox &
    sleep 3
fi

# Kill old VNC
pkill -9 -f x11vnc    2>/dev/null
pkill -9 -f websockify 2>/dev/null
sleep 2

# Start VNC
x11vnc -display :10 -rfbport 5900 -passwd "mt5vnc" \
    -forever -shared -noxdamage -noxfixes \
    -bg -o /tmp/x11vnc.log 2>/dev/null
sleep 2

websockify -D --web=/usr/share/novnc/ \
    --cert="/opt/mt5/novnc.pem" \
    6080 localhost:5900 \
    >/tmp/websockify.log 2>&1
sleep 2

# Clear RAM
sync; echo 3 > /proc/sys/vm/drop_caches

# Launch MetaTester64
echo "-> Launching metatester64.exe..."
DISPLAY=:10 \
    WINEPREFIX=/root/.wine \
    WINEARCH=win64 \
    WINEDEBUG=-all \
    wine "$MTEST" >/tmp/metatester.log 2>&1 &

echo ""
echo "================================================"
SIP="$(hostname -I | awk '{print $1}')"
echo "  https://${SIP}:6080/vnc.html?autoconnect=1"
echo "  Password: mt5vnc"
echo "================================================"
METASCRIPT
chmod +x /opt/mt5/open-metatester.sh

# open-vnc.sh — reopen VNC with installer if not installed yet
cat > /opt/mt5/open-vnc.sh <<'VNCSCRIPT'
#!/bin/bash
pkill -9 -f x11vnc 2>/dev/null; pkill -9 -f websockify 2>/dev/null
pkill -9 -f openbox 2>/dev/null; pkill -9 -f Xvfb 2>/dev/null; sleep 2
rm -f /tmp/.X10-lock /tmp/.X11-unix/X10 2>/dev/null

Xvfb :10 -screen 0 1280x900x24 >/tmp/xvfb.log 2>&1 & sleep 4
DISPLAY=:10 xsetroot -solid '#1a1f2e'
DISPLAY=:10 openbox & sleep 3
DISPLAY=:10 xterm -geometry 110x35+20+20 -bg '#0d1117' -fg '#00ff88' \
    -fa 'Monospace' -fs 11 -title "MT5 Shell" & sleep 2

x11vnc -display :10 -rfbport 5900 -passwd "mt5vnc" \
    -forever -shared -noxdamage -noxfixes \
    -bg -o /tmp/x11vnc.log 2>/dev/null; sleep 2

websockify -D --web=/usr/share/novnc/ --cert="/opt/mt5/novnc.pem" \
    6080 localhost:5900 >/tmp/websockify.log 2>&1; sleep 2

sync; echo 3 > /proc/sys/vm/drop_caches

SIP="$(hostname -I | awk '{print $1}')"
echo ""
echo "=========================================="
echo " https://${SIP}:6080/vnc.html?autoconnect=1"
echo " Password: mt5vnc"
echo "=========================================="
VNCSCRIPT
chmod +x /opt/mt5/open-vnc.sh

# clear-ram.sh
cat > /usr/local/bin/clear-ram.sh <<'RAMSCRIPT'
#!/bin/bash
echo "Before:"
free -h | grep -E "Mem|Swap"
sync
echo 1 > /proc/sys/vm/drop_caches
echo 2 > /proc/sys/vm/drop_caches
echo 3 > /proc/sys/vm/drop_caches
echo "After:"
free -h | grep -E "Mem|Swap"
echo "Swap:"
swapon --show 2>/dev/null || echo "(none)"
RAMSCRIPT
chmod +x /usr/local/bin/clear-ram.sh
/usr/local/bin/clear-ram.sh

cat <<DONE

=====================================================
 ALL DONE
=====================================================

 STEP 1 — Install MetaTester in browser:
   https://$SERVER_IP:$NOVNC_PORT/vnc.html?autoconnect=1
   Password : $VNC_PASS
   Complete the mt5setup.exe installer in the window.

 STEP 2 — After install, open MetaTester:
   /opt/mt5/open-metatester.sh

 REOPEN VNC ONLY (no app):
   /opt/mt5/open-vnc.sh

 CLEAR RAM ANYTIME:
   /usr/local/bin/clear-ram.sh

 CHECK SWAP:
   swapon --show && free -h
=====================================================
DONE
