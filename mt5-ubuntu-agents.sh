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
echo "============================================="

log(){ echo "$1"; }

log "==> [1/8] Remove old setup"
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
mkdir -p "$WORKDIR"

log "==> [2/8] Disable firewall"
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

log "==> [3/8] Install base VNC + tools first"
pkill -9 -f apt-get 2>/dev/null || true
pkill -9 -f apt 2>/dev/null || true
pkill -9 -f dpkg 2>/dev/null || true
sleep 2
rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock /var/cache/apt/archives/lock 2>/dev/null || true
dpkg --configure -a 2>/dev/null || true

apt-get update -y
apt-get install -y \
  ca-certificates gnupg2 lsb-release wget curl openssl \
  python3 python3-pip xvfb screen cabextract x11-utils \
  x11vnc novnc python3-websockify openbox xterm net-tools util-linux procps \
  tar xz-utils software-properties-common

log "    -> base tools installed"

log "==> [4/8] Install Wine with fallback method"
dpkg --add-architecture i386
mkdir -pm755 /etc/apt/keyrings
UBUNTU_VER="$(lsb_release -cs)"

rm -f /etc/apt/sources.list.d/winehq-*.sources 2>/dev/null || true
rm -f /etc/apt/keyrings/winehq-archive.key 2>/dev/null || true

wget -q -O /etc/apt/keyrings/winehq-archive.key https://dl.winehq.org/wine-builds/winehq.key
wget -q -NP /etc/apt/sources.list.d/ "https://dl.winehq.org/wine-builds/ubuntu/dists/${UBUNTU_VER}/winehq-${UBUNTU_VER}.sources"
apt-get update -y || true

# Try official winehq-devel first
if apt-get install -y --install-recommends winehq-devel; then
  log "    -> winehq-devel installed"
else
  log "    -> winehq-devel failed, using distro fallback"
  apt-get -f install -y || true
  apt-get install -y wine64 wine32 libwine fonts-wine || {
    log "ERROR: Both Wine methods failed"
    exit 1
  }
fi

wine --version || { log "ERROR: wine command not available"; exit 1; }
log "    -> $(wine --version)"

log "==> [5/8] Download MetaTester setup"
wget -O "$SETUP_FILE" "$MT5_URL_DEFAULT" >/dev/null 2>&1 || curl -L -o "$SETUP_FILE" "$MT5_URL_DEFAULT" >/dev/null 2>&1 || true
FILESIZE=$(stat -c%s "$SETUP_FILE" 2>/dev/null || echo 0)
if [ "$FILESIZE" -lt 1000000 ]; then
  log "ERROR: Could not download mt5 setup from official site"
  exit 1
fi
log "    -> saved to $SETUP_FILE"

mkdir -p "$SDE_DIR_BASE"
cat > "$WORKDIR/README-SDE.txt" <<EOF
Download Intel SDE Windows package manually from:
$SDE_URL_DEFAULT

Look for:
  sde-external-...-win.tar.xz

Upload it to server:
  scp sde-external-...-win.tar.xz root@$SERVER_IP:/root/

Extract it:
  cd /root
  tar -xf sde-external-...-win.tar.xz
  mv sde-external-* $SDE_DIR_BASE

Then run:
  /opt/mt5/run-sde-metatester.sh
EOF

log "==> [6/8] Start noVNC desktop"
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

log "==> [7/8] Init Wine + helper"
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

log "==> [8/8] Done"
cat <<DONE

If it paused earlier, the likely cause was winehq-devel install hanging/failing.
This version installs base packages first, then tries winehq-devel, and falls back to distro wine64/wine32. WineHQ packages can fail or hang on some Ubuntu releases due to repo/dependency issues. [web:391][web:395][web:398]

Open noVNC:
  https://$SERVER_IP:$NOVNC_PORT/vnc.html?autoconnect=1
Password:
  $VNC_PASS

MetaTester setup path:
  $SETUP_FILE

After you upload and extract Intel SDE:
  /opt/mt5/run-sde-metatester.sh
DONE
