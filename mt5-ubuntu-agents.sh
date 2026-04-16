#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# ============================================================
# MT5 / MetaTester minimal setup
# - No agents
# - No WARP
# - No ZRAM
# - Fixed 64GB swap
# - Download mt5setup.exe once from Google Drive
# - Install MetaTester
# - Open MetaTester in noVNC
# - PATH-safe
# - Galaxy-safe
# - NO dpkg --configure -a
# - No iptables flush
# - No broad Wine purge
# ============================================================

NOVNC_PORT=6080
VNC_PORT=5900
VNC_PASS="mt5vnc"
SERVER_IP="$(hostname -I | awk '{print $1}')"

FILE_ID="1XMi5YbCtyeiJFlSbflJjbUFV-sIQI4TC"
GDRIVE_URL="https://drive.usercontent.google.com/download?id=1XMi5YbCtyeiJFlSbflJjbUFV-sIQI4TC&export=download&authuser=0"
SETUP_FILE="/root/mt5setup.exe"

echo "============================================="
echo " MT5 / MetaTester setup"
echo " Server : $SERVER_IP"
echo " noVNC  : https://$SERVER_IP:$NOVNC_PORT/vnc.html"
echo "============================================="

# ------------------------------------------------------------
# [0/7] CLEAN OLD RUNTIME ONLY
# ------------------------------------------------------------
echo "==> [0/7] Cleaning old runtime only"

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
rm -f /opt/mt5/novnc.pem 2>/dev/null || true
rm -f /etc/sysctl.d/99-mt5.conf 2>/dev/null || true

echo "    -> Runtime cleanup done"

# ------------------------------------------------------------
# [1/7] DISABLE HIGH-LEVEL FIREWALL ONLY
# ------------------------------------------------------------
echo "==> [1/7] Disable high-level firewall only"

ufw disable 2>/dev/null || true
systemctl stop firewalld 2>/dev/null || true
systemctl disable firewalld 2>/dev/null || true

echo "    -> ufw/firewalld disabled (iptables untouched)"

# ------------------------------------------------------------
# [2/7] INSTALL WINE + VNC + TOOLS
# ------------------------------------------------------------
echo "==> [2/7] Install Wine + VNC + tools"

apt-get update -y >/dev/null
apt-get install -y \
    software-properties-common \
    ca-certificates \
    gnupg2 \
    lsb-release \
    wget curl openssl \
    python3 python3-pip \
    xvfb screen cabextract \
    x11vnc novnc python3-websockify \
    net-tools util-linux procps \
    >/dev/null

dpkg --add-architecture i386
mkdir -pm755 /etc/apt/keyrings
UBUNTU_VER="$(lsb_release -cs)"

wget -q -O /etc/apt/keyrings/winehq-archive.key \
    https://dl.winehq.org/wine-builds/winehq.key

wget -q -NP /etc/apt/sources.list.d/ \
    "https://dl.winehq.org/wine-builds/ubuntu/dists/${UBUNTU_VER}/winehq-${UBUNTU_VER}.sources"

apt-get update -y >/dev/null
apt-get install -y --install-recommends winehq-devel >/dev/null

echo "    -> $(wine --version)"

# ------------------------------------------------------------
# [3/7] SETUP FIXED 64GB SWAP
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

echo "    -> Memory status"
free -h | grep -E "Mem|Swap"
swapon --show || true

# ------------------------------------------------------------
# [4/7] DOWNLOAD MT5SETUP.EXE ONCE FROM GOOGLE DRIVE
# ------------------------------------------------------------
echo "==> [4/7] Download mt5setup.exe from Google Drive"

FILESIZE=$(stat -c%s "$SETUP_FILE" 2>/dev/null || echo 0)

if [ "$FILESIZE" -gt 1000000 ]; then
    echo "    -> Reusing cached mt5setup.exe ($(du -sh "$SETUP_FILE" | cut -f1))"
else
    echo "    -> Installing gdown"
    python3 -m pip install --upgrade pip >/dev/null 2>&1 || true
    python3 -m pip install gdown >/dev/null 2>&1 || true

    rm -f "$SETUP_FILE" 2>/dev/null || true

    echo "    -> Downloading from Google Drive"
    gdown --fuzzy "$GDRIVE_URL" -O "$SETUP_FILE" || \
    gdown "https://drive.google.com/uc?id=${FILE_ID}" -O "$SETUP_FILE" || \
    gdown "${FILE_ID}" -O "$SETUP_FILE"

    FILESIZE=$(stat -c%s "$SETUP_FILE" 2>/dev/null || echo 0)

    if [ "$FILESIZE" -lt 1000000 ]; then
        echo "ERROR: Download failed (${FILESIZE} bytes)"
        exit 1
    fi

    echo "    -> Downloaded: $(du -sh "$SETUP_FILE" | cut -f1)"
fi

# ------------------------------------------------------------
# [5/7] INSTALL METATRADER / METATESTER
# ------------------------------------------------------------
echo "==> [5/7] Install MetaTester"

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
sleep 5

echo "    -> Running installer"
DISPLAY=:90 wine "$SETUP_FILE" /auto >/tmp/mt5-install.log 2>&1 &
INSTALL_PID=$!

FOUND=0
for i in {1..120}; do
    MTEST_EX="$(find /root/.wine -iname 'metatester64.exe' 2>/dev/null | head -1 || true)"
    MT5_EX="$(find /root/.wine -iname 'terminal64.exe' 2>/dev/null | head -1 || true)"

    if [ -n "$MTEST_EX" ] || [ -n "$MT5_EX" ]; then
        FOUND=1
        echo "    -> Installation files detected after $((i*5))s"
        sleep 10
        break
    fi

    echo "    ...Installing ($((i*5))s / 600s)"
    sleep 5
done

kill "$INSTALL_PID" 2>/dev/null || true
wait "$INSTALL_PID" 2>/dev/null || true
kill "$XVFB_PID" 2>/dev/null || true
wait "$XVFB_PID" 2>/dev/null || true
rm -f /tmp/.X90-lock /tmp/.X11-unix/X90 2>/dev/null || true

MTEST_EX="$(find /root/.wine -iname 'metatester64.exe' 2>/dev/null | head -1 || true)"
MT5_EX="$(find /root/.wine -iname 'terminal64.exe' 2>/dev/null | head -1 || true)"

if [ "$FOUND" -ne 1 ] && [ -z "$MTEST_EX" ] && [ -z "$MT5_EX" ]; then
    echo "ERROR: Installation not found"
    echo "---- install log ----"
    tail -n 100 /tmp/mt5-install.log || true
    exit 1
fi

[ -n "$MTEST_EX" ] && echo "    -> metatester64.exe found"
[ -n "$MT5_EX" ] && echo "    -> terminal64.exe found"

# ------------------------------------------------------------
# [6/7] OPEN IN NOVNC
# ------------------------------------------------------------
echo "==> [6/7] Open MetaTester in noVNC"

mkdir -p /opt/mt5
VNC_CERT="/opt/mt5/novnc.pem"

openssl req -x509 -nodes -newkey rsa:2048 \
    -keyout "$VNC_CERT" -out "$VNC_CERT" -days 3650 \
    -subj "/CN=$SERVER_IP" >/dev/null 2>&1

cat > /opt/mt5/open-vnc.sh <<EOF
#!/bin/bash
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

pkill -9 -f x11vnc 2>/dev/null || true
pkill -9 -f websockify 2>/dev/null || true
sleep 2

rm -f /tmp/.X10-lock /tmp/.X11-unix/X10 2>/dev/null || true
Xvfb :10 -screen 0 1280x900x24 >/tmp/xvfb-vnc.log 2>&1 &
sleep 3

x11vnc -display :10 -rfbport $VNC_PORT -passwd "$VNC_PASS" \
    -forever -shared -noxdamage -noxfixes -bg \
    -o /tmp/x11vnc.log 2>/dev/null || true
sleep 2

websockify -D \
    --web=/usr/share/novnc/ \
    --cert="$VNC_CERT" \
    $NOVNC_PORT localhost:$VNC_PORT \
    >/tmp/websockify.log 2>&1
sleep 2

MTEST_EX="\$(find /root/.wine -iname 'metatester64.exe' 2>/dev/null | head -1 || true)"
MT5_EX="\$(find /root/.wine -iname 'terminal64.exe' 2>/dev/null | head -1 || true)"

if [ -n "\$MTEST_EX" ]; then
    DISPLAY=:10 WINEPREFIX=/root/.wine WINEARCH=win64 WINEDEBUG=-all wine "\$MTEST_EX" >/tmp/metatester-vnc.log 2>&1 &
elif [ -n "\$MT5_EX" ]; then
    DISPLAY=:10 WINEPREFIX=/root/.wine WINEARCH=win64 WINEDEBUG=-all wine "\$MT5_EX" >/tmp/terminal-vnc.log 2>&1 &
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

# ------------------------------------------------------------
# [7/7] CLEAN RAM + SDE LAUNCHER
# ------------------------------------------------------------
echo "==> [7/7] Clean RAM + SDE launcher"

cat > /usr/local/bin/clear-ram-cache.sh <<'EOF'
#!/bin/bash
sync
echo 1 > /proc/sys/vm/drop_caches
EOF

chmod +x /usr/local/bin/clear-ram-cache.sh
/usr/local/bin/clear-ram-cache.sh || true

cat > /opt/mt5/run-sde-metatester.sh <<EOF
#!/bin/bash
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

SDE_DIR="/root/sde"
MTEST_EX="\$(find /root/.wine -iname 'metatester64.exe' 2>/dev/null | head -1 || true)"
VNC_CERT="/opt/mt5/novnc.pem"

echo "Checking SDE installation..."
if [ ! -f "\$SDE_DIR/sde.exe" ]; then
    echo "ERROR: Intel SDE not found at \$SDE_DIR/sde.exe"
    echo ""
    echo "=== INSTRUCTIONS ==="
    echo "1. Download: https://www.intel.com/content/www/us/en/download/684897/intel-software-development-emulator.html"
    echo "2. Get the Windows package with sde.exe"
    echo "3. Upload it to the server"
    echo "4. Extract into: \$SDE_DIR"
    exit 1
fi

if [ -z "\$MTEST_EX" ]; then
    echo "ERROR: metatester64.exe not found"
    exit 1
fi

echo "SDE found, starting emulator..."
pkill -9 -f x11vnc 2>/dev/null || true
pkill -9 -f websockify 2>/dev/null || true
sleep 2

rm -f /tmp/.X10-lock /tmp/.X11-unix/X10 2>/dev/null || true
Xvfb :10 -screen 0 1280x900x24 >/tmp/xvfb-sde.log 2>&1 &
sleep 3

x11vnc -display :10 -rfbport $VNC_PORT -passwd "$VNC_PASS" -forever -shared -noxdamage -noxfixes -bg -o /tmp/x11vnc-sde.log 2>/dev/null || true
sleep 2

websockify -D --web=/usr/share/novnc/ --cert="\$VNC_CERT" $NOVNC_PORT localhost:$VNC_PORT >/tmp/websockify-sde.log 2>&1
sleep 2

export WINEPREFIX=/root/.wine
export WINEARCH=win64
export WINEDLLOVERRIDES="mscoree,mshtml="
export WINEDEBUG=-all

DISPLAY=:10 wine "\$SDE_DIR/sde.exe" -hsw -- "\$MTEST_EX" >/tmp/sde-metatester.log 2>&1 &

echo ""
echo "============================================"
echo " SDE + MetaTester running"
echo "============================================"
echo " Browser  : https://$SERVER_IP:$NOVNC_PORT/vnc.html?autoconnect=1"
echo " Password : $VNC_PASS"
echo " Log      : /tmp/sde-metatester.log"
echo "============================================"
EOF

chmod +x /opt/mt5/run-sde-metatester.sh

cat <<DONE

=====================================================
 SETUP COMPLETE
=====================================================
 Installed:
   MetaTester / MetaTrader only

 Not done:
   No agents created
   No agents started
   No WARP
   No ZRAM

 noVNC:
   https://$SERVER_IP:$NOVNC_PORT/vnc.html
   Password: $VNC_PASS

 Reopen later:
   /opt/mt5/open-vnc.sh

 Optional SDE launcher:
   /opt/mt5/run-sde-metatester.sh
=====================================================
DONE
