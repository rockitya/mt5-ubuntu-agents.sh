#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

NOVNC_PORT=6080
VNC_PORT=5900
VNC_PASS="mt5vnc"
SERVER_IP="$(hostname -I | awk '{print $1}')"

FILE_ID="1XMi5YbCtyeiJFlSbflJjbUFV-sIQI4TC"
SETUP_FILE="/root/mt5setup.exe"

echo "============================================="
echo " MT5 / MetaTester setup"
echo " Server : $SERVER_IP"
echo " noVNC  : https://$SERVER_IP:$NOVNC_PORT/vnc.html"
echo "============================================="

echo "==> [0/6] Cleaning MT5 runtime only"
pkill -9 -f metatester64 2>/dev/null || true
pkill -9 -f terminal64 2>/dev/null || true
pkill -9 -f wineserver 2>/dev/null || true
pkill -9 -f wine 2>/dev/null || true
pkill -9 -f Xvfb 2>/dev/null || true
pkill -9 -f x11vnc 2>/dev/null || true
pkill -9 -f websockify 2>/dev/null || true
rm -rf /opt/mt5 2>/dev/null || true
rm -rf /root/.wine 2>/dev/null || true
rm -f /tmp/.X*-lock 2>/dev/null || true
rm -rf /tmp/.X11-unix 2>/dev/null || true

echo "==> [1/6] Install required packages"
apt-get update -y
apt-get install -y \
    wget \
    curl \
    python3 \
    python3-pip \
    xvfb \
    screen \
    cabextract \
    x11vnc \
    novnc \
    python3-websockify \
    net-tools \
    util-linux \
    procps \
    wine64

echo "    -> $(wine --version)"

echo "==> [2/6] Setup fixed 64GB swap"
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

echo "==> [3/6] Download mt5setup.exe"
FILESIZE=$(stat -c%s "$SETUP_FILE" 2>/dev/null || echo 0)

if [ "$FILESIZE" -gt 1000000 ]; then
    echo "    -> Reusing cached mt5setup.exe ($(du -sh "$SETUP_FILE" | cut -f1))"
else
    python3 -m pip install --upgrade pip >/dev/null 2>&1 || true
    python3 -m pip install gdown >/dev/null 2>&1 || true
    rm -f "$SETUP_FILE" 2>/dev/null || true
    gdown "${FILE_ID}" -O "$SETUP_FILE"
fi

echo "==> [4/6] Install MetaTester"
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

DISPLAY=:90 wine "$SETUP_FILE" /auto >/tmp/mt5-install.log 2>&1 &
INSTALL_PID=$!

FOUND=0
for i in {1..120}; do
    MTEST_EX="$(find /root/.wine -iname 'metatester64.exe' 2>/dev/null | head -1 || true)"
    MT5_EX="$(find /root/.wine -iname 'terminal64.exe' 2>/dev/null | head -1 || true)"
    if [ -n "$MTEST_EX" ] || [ -n "$MT5_EX" ]; then
        FOUND=1
        sleep 10
        break
    fi
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
    tail -n 100 /tmp/mt5-install.log || true
    exit 1
fi

echo "==> [5/6] Open in noVNC"
mkdir -p /opt/mt5

cat > /opt/mt5/open-vnc.sh <<EOF
#!/bin/bash
set -euo pipefail
pkill -9 -f x11vnc 2>/dev/null || true
pkill -9 -f websockify 2>/dev/null || true
rm -f /tmp/.X10-lock /tmp/.X11-unix/X10 2>/dev/null || true
Xvfb :10 -screen 0 1280x900x24 >/tmp/xvfb-vnc.log 2>&1 &
sleep 3
x11vnc -display :10 -rfbport $VNC_PORT -passwd "$VNC_PASS" -forever -shared -noxdamage -noxfixes -bg -o /tmp/x11vnc.log 2>/dev/null || true
sleep 2
websockify -D --web=/usr/share/novnc/ $NOVNC_PORT localhost:$VNC_PORT >/tmp/websockify.log 2>&1
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
echo "https://$SERVER_IP:$NOVNC_PORT/vnc.html"
echo "Password: $VNC_PASS"
EOF

chmod +x /opt/mt5/open-vnc.sh
/opt/mt5/open-vnc.sh

echo "==> [6/6] Optional SDE launcher"
cat > /opt/mt5/run-sde-metatester.sh <<EOF
#!/bin/bash
set -euo pipefail
SDE_DIR="/root/sde"
MTEST_EX="\$(find /root/.wine -iname 'metatester64.exe' 2>/dev/null | head -1 || true)"
if [ ! -f "\$SDE_DIR/sde.exe" ]; then
    echo "ERROR: Intel SDE not found at \$SDE_DIR/sde.exe"
    exit 1
fi
if [ -z "\$MTEST_EX" ]; then
    echo "ERROR: metatester64.exe not found"
    exit 1
fi
pkill -9 -f x11vnc 2>/dev/null || true
pkill -9 -f websockify 2>/dev/null || true
rm -f /tmp/.X10-lock /tmp/.X11-unix/X10 2>/dev/null || true
Xvfb :10 -screen 0 1280x900x24 >/tmp/xvfb-sde.log 2>&1 &
sleep 3
x11vnc -display :10 -rfbport $VNC_PORT -passwd "$VNC_PASS" -forever -shared -noxdamage -noxfixes -bg -o /tmp/x11vnc-sde.log 2>/dev/null || true
sleep 2
websockify -D --web=/usr/share/novnc/ $NOVNC_PORT localhost:$VNC_PORT >/tmp/websockify-sde.log 2>&1
sleep 2
DISPLAY=:10 WINEPREFIX=/root/.wine WINEARCH=win64 WINEDEBUG=-all wine "\$SDE_DIR/sde.exe" -hsw -- "\$MTEST_EX" >/tmp/sde-metatester.log 2>&1 &
echo "https://$SERVER_IP:$NOVNC_PORT/vnc.html?autoconnect=1"
echo "Password: $VNC_PASS"
EOF

chmod +x /opt/mt5/run-sde-metatester.sh

cat <<DONE

=====================================================
 SETUP COMPLETE
=====================================================
 noVNC:
   https://$SERVER_IP:$NOVNC_PORT/vnc.html
   Password: $VNC_PASS

 Reopen later:
   /opt/mt5/open-vnc.sh

 Optional SDE launcher:
   /opt/mt5/run-sde-metatester.sh
=====================================================
DONE
