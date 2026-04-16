#!/bin/bash
# ============================================================
# MT5 / MetaTester - ULTRA-REPAIR & AUTO-INSTALL
# This version force-clears dpkg locks before starting.
# ============================================================
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# ------------------------------------------------------------
# [CRITICAL] FORCE REPAIR DPKG/APT LOCKS
# ------------------------------------------------------------
echo "==> Clearing system locks and repairing package database..."

# 1. Kill any hung apt/dpkg processes
killall apt apt-get dpkg 2>/dev/null || true

# 2. Force remove lock files
rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock
rm -f /var/lib/apt/lists/lock /var/cache/apt/archives/lock

# 3. Run the repair command
dpkg --configure -a

# 4. Fix broken dependencies
apt-get install -f -y

echo "    -> System repaired. Starting MT5 Setup..."

# ------------------------------------------------------------
# SETTINGS & PATHS
# ------------------------------------------------------------
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
NOVNC_PORT=6080
VNC_PORT=5900
VNC_PASS="mt5vnc"
SERVER_IP="$(hostname -I | awk '{print $1}')"
SETUP_FILE="/root/mt5setup.exe"
GDRIVE_URL="https://drive.usercontent.google.com/download?id=1XMi5YbCtyeiJFlSbflJjbUFV-sIQI4TC&export=download&authuser=0"

# ------------------------------------------------------------
# [0/7] CLEAN OLD RUNTIME
# ------------------------------------------------------------
echo "==> [0/7] Cleaning old processes..."
pkill -9 -f "metatester|terminal|wine|Xvfb|x11vnc|websockify" 2>/dev/null || true
rm -rf /root/.wine /opt/mt5 /tmp/.X* 2>/dev/null || true

# ------------------------------------------------------------
# [1/7] FIREWALL
# ------------------------------------------------------------
echo "==> [1/7] Disabling Firewalls..."
ufw disable 2>/dev/null || true
systemctl stop firewalld 2>/dev/null || true

# ------------------------------------------------------------
# [2/7] INSTALL WINE + TOOLS
# ------------------------------------------------------------
echo "==> [2/7] Installing Wine & VNC Components..."
apt-get update -y
apt-get install -y software-properties-common wget curl xvfb x11vnc novnc python3-websockify python3-pip gnupg2 lsb-release

dpkg --add-architecture i386
mkdir -pm755 /etc/apt/keyrings
UBUNTU_VER="$(lsb_release -cs)"
wget -q -O /etc/apt/keyrings/winehq-archive.key https://dl.winehq.org/wine-builds/winehq.key
wget -q -NP /etc/apt/sources.list.d/ "https://dl.winehq.org/wine-builds/ubuntu/dists/${UBUNTU_VER}/winehq-${UBUNTU_VER}.sources"

apt-get update -y
apt-get install -y --install-recommends winehq-devel

# ------------------------------------------------------------
# [3/7] SWAP SETUP (64GB)
# ------------------------------------------------------------
echo "==> [3/7] Creating 64GB Swap file (This takes a moment)..."
swapoff -a 2>/dev/null || true
rm -f /swapfile
fallocate -l 64G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=65536
chmod 600 /swapfile
mkswap /swapfile && swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab

# ------------------------------------------------------------
# [4/7] DOWNLOAD MT5
# ------------------------------------------------------------
echo "==> [4/7] Downloading MT5 Setup..."
pip3 install gdown --break-system-packages || pip3 install gdown
gdown --fuzzy "$GDRIVE_URL" -O "$SETUP_FILE" || true

if [ ! -f "$SETUP_FILE" ] || [ $(stat -c%s "$SETUP_FILE") -lt 100000 ]; then
    echo "ERROR: Download failed. Using fallback web link..."
    wget -O "$SETUP_FILE" "https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe"
fi

# ------------------------------------------------------------
# [5/7] INSTALL MT5
# ------------------------------------------------------------
echo "==> [5/7] Installing MT5 into Wine..."
export WINEPREFIX=/root/.wine
export WINEARCH=win64
export WINEDEBUG=-all

Xvfb :99 -screen 0 1280x1024x24 &
sleep 3
DISPLAY=:99 wine "$SETUP_FILE" /auto &
sleep 60
pkill -9 wine 2>/dev/null || true

# ------------------------------------------------------------
# [6/7] START NOVNC SERVICE
# ------------------------------------------------------------
echo "==> [6/7] Starting GUI Services..."
mkdir -p /opt/mt5
VNC_CERT="/opt/mt5/novnc.pem"
openssl req -x509 -nodes -newkey rsa:2048 -keyout "$VNC_CERT" -out "$VNC_CERT" -days 365 -subj "/CN=MT5"

# Create the launch script
cat > /opt/mt5/start.sh <<EOF
#!/bin/bash
Xvfb :10 -screen 0 1280x900x24 &
sleep 2
x11vnc -display :10 -rfbport $VNC_PORT -passwd "$VNC_PASS" -forever -bg
websockify -D --web=/usr/share/novnc/ --cert="$VNC_CERT" $NOVNC_PORT localhost:$VNC_PORT
sleep 2
MTEST_EX=\$(find /root/.wine -iname 'metatester64.exe' | head -1)
DISPLAY=:10 wine "\$MTEST_EX"
EOF

chmod +x /opt/mt5/start.sh
nohup /opt/mt5/start.sh > /dev/null 2>&1 &

echo "===================================================="
echo " SETUP FINISHED"
echo " URL: https://$SERVER_IP:$NOVNC_PORT/vnc.html"
echo " Password: $VNC_PASS"
echo "===================================================="
