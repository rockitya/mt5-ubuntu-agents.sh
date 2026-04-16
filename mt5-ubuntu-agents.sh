#!/bin/bash
set -e
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

log(){ echo -e "$1"; }

log "============================================="
log " MetaTester + Intel SDE minimal setup"
log " Server : $SERVER_IP"
log "============================================="

log "==> [1/8] Clean old processes"
pkill -9 -f wineserver 2>/dev/null || true
pkill -9 -f wine 2>/dev/null || true
pkill -9 -f Xvfb 2>/dev/null || true
pkill -9 -f x11vnc 2>/dev/null || true
pkill -9 -f websockify 2>/dev/null || true
pkill -9 -f openbox 2>/dev/null || true
pkill -9 -f xterm 2>/dev/null || true
screen -wipe 2>/dev/null || true
mkdir -p "$WORKDIR" /opt/mt5 "$SDE_DIR_BASE"

log "==> [2/8] Force apt to IPv4"
cat >/etc/apt/apt.conf.d/99force-ipv4 <<'EOF'
Acquire::ForceIPv4 "true";
EOF

log "==> [3/8] Disable firewall"
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

log "==> [4/8] Fix apt locks and update"
pkill -9 -f apt-get 2>/dev/null || true
pkill -9 -f apt 2>/dev/null || true
pkill -9 -f dpkg 2>/dev/null || true
sleep 2
rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock /var/cache/apt/archives/lock 2>/dev/null || true
dpkg --configure -a || true
apt-get -o Acquire::ForceIPv4=true update

log "==> [5/8] Install minimal packages"
apt-get -o Acquire::ForceIPv4=true install -y \
  ca-certificates gnupg2 lsb-release wget curl openssl \
  python3 python3-pip xvfb screen cabextract x11-utils \
  x11vnc novnc python3-websockify openbox xterm net-tools util-linux procps \
  tar xz-utils software-properties-common

dpkg --add-architecture i386
apt-get -o Acquire::ForceIPv4=true update
apt-get -o Acquire::ForceIPv4=true install -y \
  wine64 wine32 libwine fonts-wine

log "    -> $(wine --version)"

log "==> [6/8] Download MT5 tester setup"
wget -O "$SETUP_FILE" "$MT5_URL_DEFAULT" >/dev/null 2>&1 || curl -L -o "$SETUP_FILE" "$MT5_URL_DEFAULT" >/dev/null 2>&1
FILESIZE=$(stat -c%s "$SETUP_FILE" 2>/dev/null || echo 0)
if [ "$FILESIZE" -lt 1000000 ]; then
  echo "ERROR: MT5 setup download failed"
  exit 1
fi
log "    -> saved to $SETUP_FILE"

cat > "$WORKDIR/README-SDE.txt" <<EOF
Download Intel SDE Windows package manually from:
$SDE_URL_DEFAULT

You need a file like:
  sde-external-...-win.tar.xz

Upload it to the server:
  scp sde-external-...-win.tar.xz root@$SERVER_IP:/root/

Extract it:
  cd /root
  tar -xf sde-external-...-win.tar.xz
  rm -rf $SDE_DIR_BASE
  mv sde-external-* $SDE_DIR_BASE

Then run:
  /opt/mt5/run-sde-metatester.sh
EOF

log "==> [7/8] Start noVNC desktop"
VNC_CERT="/opt/mt5/novnc.pem"
openssl req -x509 -nodes -newkey rsa:2048 -keyout "$VNC_CERT" -out "$VNC_CERT" -days 3650 -subj "/CN=$SERVER_IP" >/dev/null 2>&1
rm -f /tmp/.X10-lock /tmp/.X11-unix/X10 2>/dev/null || true
Xvfb :10 -screen 0 1280x900x24 >/tmp/xvfb.log 2>&1 &
sleep 4
DISPLAY=:10 openbox >/tmp/openbox.log 2>&1 &
sleep 2
DISPLAY=:10 xsetroot -solid '#1a1f2e'
DISPLAY=:10 xterm -geometry 110x35+20+20 -bg '#0d1117' -fg '#00ff88' -fa 'Monospace' -fs 11 -title 'MT5 Shell' >/tmp/xterm.log 2>&1 &
sleep 2
x11vnc -display :10 -rfbport "$VNC_PORT" -passwd "$VNC_PASS" -forever -shared -noxdamage -noxfixes -bg -o /tmp/x11vnc.log
sleep 2
websockify -D --web=/usr/share/novnc/ --cert="$VNC_CERT" "$NOVNC_PORT" localhost:"$VNC_PORT" >/tmp/websockify.log 2>&1
sleep 2

log "==> [8/8] Init Wine + helper launcher"
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

log ""
log "============================================="
log " SETUP COMPLETE"
log "============================================="
log "Open noVNC: https://$SERVER_IP:$NOVNC_PORT/vnc.html?autoconnect=1"
log "Password : $VNC_PASS"
log ""
log "MT5 setup downloaded to: $SETUP_FILE"
log "SDE instructions file   : $WORKDIR/README-SDE.txt"
log ""
log "After uploading and extracting Intel SDE, run:"
log "  /opt/mt5/run-sde-metatester.sh"
log ""
log "Clear RAM anytime:"
log "  /usr/local/bin/clear-ram.sh"
log "============================================="
