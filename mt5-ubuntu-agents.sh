#!/bin/bash
export DEBIAN_FRONTEND=noninteractive

# ============================================================
# MT5 / MetaTester VNC setup
# - Wine + noVNC + proper desktop (openbox + xterm + background)
# - Download mt5setup.exe once from Google Drive
# - Launch installer visibly inside VNC
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
pkill -9 -f websockify   2>/dev/null; pkill -9 -f openbox     2>/dev/null
screen -wipe 2>/dev/null

rm -rf /opt/mt5 /root/.wine 2>/dev/null
rm -f /tmp/.X*-lock 2>/dev/null; rm -rf /tmp/.X11-unix 2>/dev/null

apt-get remove --purge -y \
    winehq-devel winehq-stable winehq-staging wine wine64 wine32 libwine fonts-wine \
    x11vnc novnc python3-websockify openbox xterm \
    zram-tools cloudflare-warp \
    2>/dev/null
apt-get autoremove -y >/dev/null 2>&1
apt-get autoclean -y >/dev/null 2>&1

swapoff /swapfile 2>/dev/null; swapoff -a 2>/dev/null
sed -i '\|/swapfile none swap sw 0 0|d' /etc/fstab 2>/dev/null
rm -f /swapfile 2>/dev/null

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
# [2/6] INSTALL ALL TOOLS
# ------------------------------------------------------------
echo "==> [2/6] Install Wine + noVNC + desktop tools"

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

# ------------------------------------------------------------
# [3/6] FIXED 64GB SWAP
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
# [4/6] DOWNLOAD MT5SETUP.EXE ONCE
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
        echo "Upload manually from your local PC then re-run:"
        echo "  scp mt5setup.exe root@$SERVER_IP:/root/mt5setup.exe"
        exit 1
    fi
    echo "    -> Downloaded: $(du -sh "$SETUP_FILE" | cut -f1)"
fi

# ------------------------------------------------------------
# [5/6] START FULL VNC DESKTOP
# ------------------------------------------------------------
echo "==> [5/6] Start VNC desktop"

mkdir -p /opt/mt5
VNC_CERT="/opt/mt5/novnc.pem"

openssl req -x509 -nodes -newkey rsa:2048 \
    -keyout "$VNC_CERT" -out "$VNC_CERT" -days 3650 \
    -subj "/CN=$SERVER_IP" >/dev/null 2>&1

# Kill any leftovers
pkill -9 -f x11vnc 2>/dev/null; pkill -9 -f websockify 2>/dev/null
pkill -9 -f openbox 2>/dev/null; pkill -9 -f Xvfb 2>/dev/null
sleep 2
rm -f /tmp/.X10-lock /tmp/.X11-unix/X10 2>/dev/null

# 1. Start virtual display
Xvfb :10 -screen 0 1280x900x24 >/tmp/xvfb.log 2>&1 &
sleep 4

# 2. Set solid background so desktop is not black
DISPLAY=:10 xsetroot -solid '#1e2433'
sleep 1

# 3. Start openbox window manager
DISPLAY=:10 openbox &
sleep 3

# 4. Open xterm so there is always something visible on desktop
DISPLAY=:10 xterm -geometry 100x30+10+10 -bg '#0d1117' -fg '#00ff88' \
    -title "MT5 Terminal" -e "bash --norc" &
sleep 2

# 5. Start x11vnc
x11vnc -display :10 \
    -rfbport "$VNC_PORT" \
    -passwd "$VNC_PASS" \
    -forever -shared \
    -noxdamage -noxfixes \
    -bg -o /tmp/x11vnc.log 2>/dev/null
sleep 2

# 6. Start noVNC
websockify -D \
    --web=/usr/share/novnc/ \
    --cert="$VNC_CERT" \
    "$NOVNC_PORT" localhost:"$VNC_PORT" \
    >/tmp/websockify.log 2>&1
sleep 2

# Verify VNC is up
VNC_CHECK=$(ss -tuln 2>/dev/null | grep -c ":$VNC_PORT " || echo 0)
NOVNC_CHECK=$(ss -tuln 2>/dev/null | grep -c ":$NOVNC_PORT " || echo 0)
echo "    -> x11vnc port $VNC_PORT : $([ "$VNC_CHECK" -gt 0 ] && echo UP || echo FAILED)"
echo "    -> noVNC  port $NOVNC_PORT : $([ "$NOVNC_CHECK" -gt 0 ] && echo UP || echo FAILED)"

# ------------------------------------------------------------
# [6/6] INIT WINE PREFIX + LAUNCH INSTALLER IN VNC
# ------------------------------------------------------------
echo "==> [6/6] Init Wine + launch installer inside VNC"

export WINEPREFIX=/root/.wine
export WINEARCH=win64
export WINEDLLOVERRIDES="mscoree,mshtml="
export WINEDEBUG=-all

# Init wine prefix visibly in the xterm
echo "    -> Initialising Wine prefix (30s)..."
DISPLAY=:10 wineboot --init >/tmp/wineboot.log 2>&1
sleep 10

echo "    -> Launching mt5setup.exe inside VNC..."
DISPLAY=:10 \
    WINEPREFIX=/root/.wine \
    WINEARCH=win64 \
    WINEDLLOVERRIDES="mscoree,mshtml=" \
    wine "$SETUP_FILE" >/tmp/mt5-install.log 2>&1 &

INSTALL_PID=$!
echo "    -> Installer PID: $INSTALL_PID"

sleep 5
if kill -0 "$INSTALL_PID" 2>/dev/null; then
    echo "    -> Installer is running — open VNC to see it"
else
    echo ""
    echo "    WARNING: Installer exited immediately"
    echo "    ---- install log ----"
    cat /tmp/mt5-install.log 2>/dev/null || true
    echo ""
    echo "    You can still use the xterm in VNC to run it manually:"
    echo "      WINEPREFIX=/root/.wine wine /root/mt5setup.exe"
fi

# Write reopen script
cat > /opt/mt5/open-vnc.sh <<OPENVNC
#!/bin/bash
pkill -9 -f x11vnc   2>/dev/null
pkill -9 -f websockify 2>/dev/null
pkill -9 -f openbox  2>/dev/null
pkill -9 -f Xvfb     2>/dev/null
sleep 2

rm -f /tmp/.X10-lock /tmp/.X11-unix/X10 2>/dev/null
Xvfb :10 -screen 0 1280x900x24 >/tmp/xvfb.log 2>&1 &
sleep 4

DISPLAY=:10 xsetroot -solid '#1e2433'
DISPLAY=:10 openbox &
sleep 3

DISPLAY=:10 xterm -geometry 100x30+10+10 -bg '#0d1117' -fg '#00ff88' \
    -title "MT5 Terminal" -e "bash --norc" &
sleep 2

x11vnc -display :10 -rfbport 5900 -passwd "${VNC_PASS}" \\
    -forever -shared -noxdamage -noxfixes \\
    -bg -o /tmp/x11vnc.log 2>/dev/null
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
    DISPLAY=:10 WINEPREFIX=/root/.wine WINEARCH=win64 WINEDEBUG=-all \\
        wine "\$MTEST" >/tmp/metatester.log 2>&1 &
    echo "-> Launched metatester64.exe"
elif [ -n "\$MT5" ]; then
    DISPLAY=:10 WINEPREFIX=/root/.wine WINEARCH=win64 WINEDEBUG=-all \\
        wine "\$MT5" >/tmp/terminal.log 2>&1 &
    echo "-> Launched terminal64.exe"
else
    echo "-> MetaTester not installed yet"
    echo "   Run from the xterm in VNC:"
    echo "   WINEPREFIX=/root/.wine wine /root/mt5setup.exe"
fi

SIP="\$(hostname -I | awk '{print \$1}')"
echo ""
echo "=============================="
echo " https://\${SIP}:6080/vnc.html?autoconnect=1"
echo " Password: ${VNC_PASS}"
echo "=============================="
OPENVNC
chmod +x /opt/mt5/open-vnc.sh

# RAM cleanup
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
 Open this in your browser NOW (click Connect):
   https://$SERVER_IP:$NOVNC_PORT/vnc.html?autoconnect=1
   Password: $VNC_PASS

 You will see:
   - Dark blue desktop (openbox)
   - Green terminal (xterm) in top-left corner
   - MT5 installer window (should appear in ~10s)

 If installer not visible, type in the xterm:
   WINEPREFIX=/root/.wine wine /root/mt5setup.exe

 Reopen VNC later:
   /opt/mt5/open-vnc.sh
=====================================================
DONE
