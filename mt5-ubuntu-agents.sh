#!/bin/bash
export DEBIAN_FRONTEND=noninteractive

NOVNC_PORT=6080
VNC_PORT=5900
VNC_PASS="mt5vnc"
SERVER_IP="$(hostname -I | awk '{print $1}')"
WORKDIR="/root/mt5_experiment"
SETUP_FILE="$WORKDIR/mt5testersetup.exe"
SDE_DIR_BASE="/root/sde"
SDE_URL_DEFAULT="https://www.intel.com/content/www/us/en/download/684897/intel-software-development-emulator.html"
MT5_URL_DEFAULT="https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe"

echo "============================================="
echo " MetaTester + Intel SDE setup"
echo " Server : $SERVER_IP"
echo " noVNC  : https://$SERVER_IP:$NOVNC_PORT/vnc.html?autoconnect=1"
echo "============================================="

# ------------------------------------------------------------
# [1/7] REMOVE OLD SETUP
# ------------------------------------------------------------
echo "==> [1/7] Removing old setup"
pkill -9 -f metatester64 2>/dev/null || true
pkill -9 -f terminal64 2>/dev/null || true
pkill -9 -f wineserver 2>/dev/null || true
pkill -9 -f wine 2>/dev/null || true
pkill -9 -f Xvfb 2>/dev/null || true
pkill -9 -f x11vnc 2>/dev/null || true
pkill -9 -f websockify 2>/dev/null || true
pkill -9 -f openbox 2>/dev/null || true
pkill -9 -f xterm 2>/dev/null || true
screen -wipe 2>/dev/null || true
rm -rf /opt/mt5 /root/.wine "$WORKDIR" /tmp/.X11-unix /tmp/.X*-lock 2>/dev/null || true
apt-get remove --purge -y \
  winehq-devel winehq-stable winehq-staging wine wine64 wine32 libwine fonts-wine \
  x11vnc novnc python3-websockify openbox xterm x11-utils \
  zram-tools cloudflare-warp 2>/dev/null || true
apt-get autoremove -y >/dev/null 2>&1 || true
apt-get autoclean -y >/dev/null 2>&1 || true
rm -f /etc/apt/sources.list.d/winehq-*.sources /etc/apt/keyrings/winehq-archive.key /etc/sysctl.d/99-mt5.conf 2>/dev/null || true
mkdir -p "$WORKDIR"
echo "    -> done"

# ------------------------------------------------------------
# [2/7] DISABLE FIREWALL
# ------------------------------------------------------------
echo "==> [2/7] Disable firewall"
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
echo "    -> done"

# ------------------------------------------------------------
# [3/7] INSTALL WINE + VNC + TOOLS
# ------------------------------------------------------------
echo "==> [3/7] Install Wine + VNC + tools"
apt-get update -y >/dev/null
apt-get install -y \
  software-properties-common ca-certificates gnupg2 lsb-release \
  wget curl openssl python3 python3-pip xvfb screen cabextract x11-utils \
  x11vnc novnc python3-websockify openbox xterm net-tools util-linux procps \
  tar xz-utils >/dev/null 2>&1

dpkg --add-architecture i386
mkdir -pm755 /etc/apt/keyrings
UBUNTU_VER="$(lsb_release -cs)"
wget -q -O /etc/apt/keyrings/winehq-archive.key https://dl.winehq.org/wine-builds/winehq.key
wget -q -NP /etc/apt/sources.list.d/ "https://dl.winehq.org/wine-builds/ubuntu/dists/${UBUNTU_VER}/winehq-${UBUNTU_VER}.sources"
apt-get update -y >/dev/null
apt-get install -y --install-recommends winehq-devel >/dev/null 2>&1
echo "    -> $(wine --version)"

# ------------------------------------------------------------
# [4/7] DOWNLOAD MT5 TESTER SETUP + INTEL SDE PLACEHOLDER
# ------------------------------------------------------------
echo "==> [4/7] Download MetaTester setup"

wget -O "$SETUP_FILE" "$MT5_URL_DEFAULT" >/dev/null 2>&1 || curl -L -o "$SETUP_FILE" "$MT5_URL_DEFAULT" >/dev/null 2>&1 || true
FILESIZE=$(stat -c%s "$SETUP_FILE" 2>/dev/null || echo 0)
if [ "$FILESIZE" -lt 1000000 ]; then
  echo "ERROR: Could not download mt5 setup from official site"
  exit 1
fi
echo "    -> Saved to $SETUP_FILE"

mkdir -p "$SDE_DIR_BASE"
cat > "$WORKDIR/README-SDE.txt" <<EOF
Download Intel SDE Windows package manually from:
$SDE_URL_DEFAULT

Look for a file like:
  sde-external-*-win.tar.xz

Then upload it to this server, for example:
  scp sde-external-*-win.tar.xz root@$SERVER_IP:/root/

After upload, run:
  cd /root
  tar -xf sde-external-*-win.tar.xz
  mv sde-external-* $SDE_DIR_BASE

Then inside noVNC terminal run:
  wine $SDE_DIR_BASE/sde.exe -hsw -- $SETUP_FILE
EOF

echo "    -> Wrote SDE instructions to $WORKDIR/README-SDE.txt"

# ------------------------------------------------------------
# [5/7] START NOVNC DESKTOP
# ------------------------------------------------------------
echo "==> [5/7] Start noVNC desktop"
mkdir -p /opt/mt5
VNC_CERT="/opt/mt5/novnc.pem"
openssl req -x509 -nodes -newkey rsa:2048 -keyout "$VNC_CERT" -out "$VNC_CERT" -days 3650 -subj "/CN=$SERVER_IP" >/dev/null 2>&1
rm -f /tmp/.X10-lock /tmp/.X11-unix/X10 2>/dev/null || true
Xvfb :10 -screen 0 1280x900x24 >/tmp/xvfb.log 2>&1 &
sleep 4
DISPLAY=:10 xsetroot -solid '#1a1f2e'
DISPLAY=:10 openbox &
sleep 2
DISPLAY=:10 xterm -geometry 110x35+20+20 -bg '#0d1117' -fg '#00ff88' -fa 'Monospace' -fs 11 -title 'MT5 Shell' &
sleep 2
x11vnc -display :10 -rfbport "$VNC_PORT" -passwd "$VNC_PASS" -forever -shared -noxdamage -noxfixes -bg -o /tmp/x11vnc.log 2>/dev/null
sleep 2
websockify -D --web=/usr/share/novnc/ --cert="$VNC_CERT" "$NOVNC_PORT" localhost:"$VNC_PORT" >/tmp/websockify.log 2>&1
sleep 2
echo "    -> noVNC ready"

# ------------------------------------------------------------
# [6/7] INIT WINE PREFIX + WRITE HELPER SCRIPTS
# ------------------------------------------------------------
echo "==> [6/7] Initialize Wine and write helpers"
export WINEPREFIX=/root/.wine
export WINEARCH=win64
export WINEDLLOVERRIDES="mscoree,mshtml="
export WINEDEBUG=-all
DISPLAY=:10 wineboot --init >/tmp/wineboot.log 2>&1 || true
sleep 10

cat > /opt/mt5/run-sde-metatester.sh <<EOF
#!/bin/bash
export WINEPREFIX=/root/.wine
export WINEARCH=win64
export WINEDEBUG=-all

SDE_EXE="$SDE_DIR_BASE/sde.exe"
SETUP_EXE="$SETUP_FILE"

if [ ! -f "\$SDE_EXE" ]; then
  echo "ERROR: SDE not found at \$SDE_EXE"
  echo "Read: $WORKDIR/README-SDE.txt"
  exit 1
fi

DISPLAY=:10 wine "\$SDE_EXE" -hsw -- "\$SETUP_EXE" >/tmp/sde-metatester.log 2>&1 &
echo "Started SDE + MetaTester setup"
echo "Log: /tmp/sde-metatester.log"
EOF
chmod +x /opt/mt5/run-sde-metatester.sh

cat > /usr/local/bin/clear-ram.sh <<'EOF'
#!/bin/bash
sync
echo 3 > /proc/sys/vm/drop_caches
echo "RAM cache cleared"
free -h
EOF
chmod +x /usr/local/bin/clear-ram.sh

# ------------------------------------------------------------
# [7/7] FINAL INSTRUCTIONS
# ------------------------------------------------------------
cat <<DONE

=====================================================
 SETUP COMPLETE
=====================================================

Open in browser:
  https://$SERVER_IP:$NOVNC_PORT/vnc.html?autoconnect=1
Password:
  $VNC_PASS

What is already done:
- Firewall disabled
- Wine installed
- noVNC desktop started
- MT5 tester setup downloaded to:
  $SETUP_FILE

Next steps:
1. Download Intel SDE Windows package manually from:
   $SDE_URL_DEFAULT
2. Upload the file ending in: sde-external-...-win.tar.xz
3. Extract it on the server:
   cd /root
   tar -xf sde-external-*-win.tar.xz
   mv sde-external-* $SDE_DIR_BASE
4. In the VNC terminal run:
   /opt/mt5/run-sde-metatester.sh

Equivalent direct command:
   wine $SDE_DIR_BASE/sde.exe -hsw -- $SETUP_FILE

SDE instructions file:
  $WORKDIR/README-SDE.txt

Clear RAM anytime:
  /usr/local/bin/clear-ram.sh
=====================================================
DONE
