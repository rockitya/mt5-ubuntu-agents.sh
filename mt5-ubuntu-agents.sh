#!/bin/bash

# ============================================================
# MT5 COMPLETE SETUP SCRIPT
# ─────────────────────────────────────────────────────────
# IMPORTANT: Always run inside screen to survive disconnects:
#   screen -S mt5setup
#   bash mt5-ubuntu-agents.sh 7 Prem@1996
#   (reconnect anytime: screen -r mt5setup)
# ─────────────────────────────────────────────────────────
# Steps:
#  PRE. Clear apt locks
#  0.   Uninstall old Wine / MetaTester / packages (WARP last)
#  1.   Disable firewall (ufw + iptables)
#  2.   Install Wine + WARP + x11vnc + noVNC + tools
#  3.   Connect WARP (auto-accept TOS)
#  4.   Setup 64GB Swap + ZRAM
#  5.   Download mt5setup.exe (fresh via WARP)
#  6.   Install master MetaTester Wine prefix
#  7.   Clone agent prefixes + generate all helper scripts
#  8.   Start agents (local-only mode)
#  9.   Verify agents
# 10.   Launch noVNC for cloud registration
# 11.   Clean RAM
# ─────────────────────────────────────────────────────────
# Usage:
#   bash mt5-ubuntu-agents.sh [AGENTS] [PASSWORD]
# Example:
#   bash mt5-ubuntu-agents.sh 7 Prem@1996
# ─────────────────────────────────────────────────────────
# After setup:
#   Register cloud : https://YOUR_IP:6080/vnc.html (pw: mt5vnc)
#   Enable cloud   : /opt/mt5/cloud-on.sh YOUR_MQL5_LOGIN
#   Disable cloud  : /opt/mt5/cloud-off.sh
#   Status         : /opt/mt5/status.sh
#   Restart agents : /opt/mt5/start-all.sh
#   Reopen VNC     : /opt/mt5/open-for-cloud.sh
# ============================================================

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

AGENTS="${1:-7}"
PW="${2:-MetaTester}"
SP=3000
EP=$((SP + AGENTS - 1))
MT5_CDN="https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe"
NOVNC_PORT=6080
VNC_PORT=5900
VNC_PASS="mt5vnc"

TOTAL_CORES=$(nproc)
USABLE_CORES=$(( TOTAL_CORES > 1 ? TOTAL_CORES - 1 : 1 ))
SERVER_IP="$(hostname -I | awk '{print $1}')"

echo "============================================="
echo " MT5 Complete Setup"
echo " Agents  : $AGENTS | Ports: $SP-$EP"
echo " Cores   : $TOTAL_CORES total / $USABLE_CORES usable"
echo " Server  : $SERVER_IP"
echo " noVNC   : https://$SERVER_IP:$NOVNC_PORT/vnc.html"
echo "============================================="

# ────────────────────────────────────────────────────────────
# [PRE] CLEAR APT LOCKS
# ────────────────────────────────────────────────────────────
echo "==> [PRE] Clearing apt locks..."

pkill -9 -f apt-get 2>/dev/null || true
pkill -9 -f apt     2>/dev/null || true
pkill -9 -f dpkg    2>/dev/null || true
sleep 2

rm -f /var/lib/dpkg/lock-frontend  2>/dev/null || true
rm -f /var/lib/dpkg/lock           2>/dev/null || true
rm -f /var/lib/apt/lists/lock      2>/dev/null || true
rm -f /var/cache/apt/archives/lock 2>/dev/null || true

dpkg --configure -a 2>/dev/null || true

LOCK_WAIT=0
while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
    echo "    ...Waiting for apt lock ($LOCK_WAIT s)..."
    sleep 2
    LOCK_WAIT=$((LOCK_WAIT + 2))
    [ "$LOCK_WAIT" -ge 60 ] && break
done

echo "    -> apt lock cleared"

# ────────────────────────────────────────────────────────────
# [0/11] UNINSTALL OLD MT5 + WINE + PACKAGES
#        NOTE: WARP is stopped LAST to keep SSH alive
# ────────────────────────────────────────────────────────────
echo "==> [0/11] Uninstall old MetaTester + Wine + packages"

echo "    -> Killing MT5/Wine/screen/VNC processes (NOT WARP yet)..."
pkill -9 -f metatester64 2>/dev/null || true
pkill -9 -f wineserver   2>/dev/null || true
pkill -9 -f wine         2>/dev/null || true
pkill -9 -f Xvfb         2>/dev/null || true
pkill -9 -f x11vnc       2>/dev/null || true
pkill -9 -f websockify   2>/dev/null || true
screen -ls 2>/dev/null | awk '/\.mt5-/{print $1}' \
    | xargs -r -I{} screen -S {} -X quit 2>/dev/null || true
screen -wipe 2>/dev/null || true
sleep 2

echo "    -> Removing /opt/mt5* directories..."
rm -rf /opt/mt5master   2>/dev/null || true
rm -rf /opt/mt5agent-*  2>/dev/null || true
rm -rf /opt/mt5         2>/dev/null || true
rm -rf /opt/mt5-docker  2>/dev/null || true
rm -f  /tmp/mt5setup.exe 2>/dev/null || true
rm -f  /tmp/.X*-lock     2>/dev/null || true
rm -rf /tmp/.X11-unix    2>/dev/null || true
rm -rf /root/.wine       2>/dev/null || true

echo "    -> Uninstalling Wine packages..."
apt-get remove --purge -y \
    winehq-devel winehq-stable winehq-staging \
    wine wine64 wine32 \
    wine-stable wine-devel wine-staging \
    libwine fonts-wine \
    2>/dev/null || true

echo "    -> Uninstalling VNC/noVNC packages..."
apt-get remove --purge -y \
    x11vnc novnc python3-websockify \
    2>/dev/null || true

echo "    -> Uninstalling ZRAM..."
systemctl stop    zramswap 2>/dev/null || true
systemctl disable zramswap 2>/dev/null || true
apt-get remove --purge -y zram-tools 2>/dev/null || true

echo "    -> Removing old swap..."
swapoff /swapfile 2>/dev/null || true
swapoff -a        2>/dev/null || true
sed -i '\|/swapfile none swap sw 0 0|d' /etc/fstab 2>/dev/null || true
rm -f /swapfile 2>/dev/null || true

echo "    -> Removing old repo + config files..."
rm -f /etc/apt/sources.list.d/winehq-*.sources   2>/dev/null || true
rm -f /etc/apt/sources.list.d/cloudflare-*.list  2>/dev/null || true
rm -f /etc/apt/sources.list.d/docker.list         2>/dev/null || true
rm -f /etc/apt/keyrings/winehq-archive.key        2>/dev/null || true
rm -f /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg 2>/dev/null || true
rm -f /etc/default/zramswap                       2>/dev/null || true
rm -f /etc/sysctl.d/99-mt5.conf                   2>/dev/null || true
rm -f /usr/local/bin/clear-ram-cache.sh           2>/dev/null || true

echo "    -> Cleaning old cron entries..."
(crontab -l 2>/dev/null \
    | grep -v 'start-all\|clear-ram-cache' \
    || true) | crontab - 2>/dev/null || true

apt-get autoremove -y >/dev/null 2>&1 || true
apt-get autoclean    -y >/dev/null 2>&1 || true

# WARP removed LAST — keeps SSH alive during all cleanup above
echo "    -> Stopping WARP last (keeps SSH alive)..."
systemctl stop    warp-svc 2>/dev/null || true
systemctl disable warp-svc 2>/dev/null || true
apt-get remove --purge -y cloudflare-warp 2>/dev/null || true
rm -rf /var/lib/cloudflare-warp 2>/dev/null || true
rm -rf /etc/cloudflare-warp     2>/dev/null || true
sleep 3

echo "    -> Uninstall complete"

# ────────────────────────────────────────────────────────────
# [1/11] DISABLE FIREWALL
# ────────────────────────────────────────────────────────────
echo "==> [1/11] Disable firewall"

if command -v ufw &>/dev/null; then
    ufw disable 2>/dev/null || true
    echo "    -> UFW disabled"
else
    echo "    -> UFW not installed"
fi

iptables  -F                2>/dev/null || true
iptables  -X                2>/dev/null || true
iptables  -t nat    -F      2>/dev/null || true
iptables  -t mangle -F      2>/dev/null || true
iptables  -P INPUT   ACCEPT 2>/dev/null || true
iptables  -P FORWARD ACCEPT 2>/dev/null || true
iptables  -P OUTPUT  ACCEPT 2>/dev/null || true

ip6tables -F                2>/dev/null || true
ip6tables -X                2>/dev/null || true
ip6tables -P INPUT   ACCEPT 2>/dev/null || true
ip6tables -P FORWARD ACCEPT 2>/dev/null || true
ip6tables -P OUTPUT  ACCEPT 2>/dev/null || true

if systemctl is-active --quiet firewalld 2>/dev/null; then
    systemctl stop    firewalld 2>/dev/null || true
    systemctl disable firewalld 2>/dev/null || true
    echo "    -> firewalld disabled"
fi

echo "    -> All firewall rules cleared"

# ────────────────────────────────────────────────────────────
# [2/11] INSTALL WINE + WARP + VNC + TOOLS
# ────────────────────────────────────────────────────────────
echo "==> [2/11] Install Wine + WARP + x11vnc + noVNC + tools"
dpkg --add-architecture i386
mkdir -pm755 /etc/apt/keyrings /usr/share/keyrings
UBUNTU_VER="$(lsb_release -cs)"

wget -q -O /etc/apt/keyrings/winehq-archive.key \
    https://dl.winehq.org/wine-builds/winehq.key
wget -q -NP /etc/apt/sources.list.d/ \
    "https://dl.winehq.org/wine-builds/ubuntu/dists/${UBUNTU_VER}/winehq-${UBUNTU_VER}.sources"

curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
    | gpg --dearmor \
    -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg

echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] \
https://pkg.cloudflareclient.com/ ${UBUNTU_VER} main" \
    > /etc/apt/sources.list.d/cloudflare-client.list

apt-get update -y >/dev/null
apt-get install -y --install-recommends \
    winehq-devel \
    xvfb screen wget curl rsync cabextract \
    net-tools util-linux procps \
    zram-tools \
    cloudflare-warp \
    x11vnc novnc python3-websockify openssl \
    >/dev/null

echo "    -> $(wine --version)"
echo "    -> noVNC: $(dpkg -s novnc 2>/dev/null | grep Version: || echo ok)"

# ────────────────────────────────────────────────────────────
# [3/11] CONNECT WARP (auto-accept TOS via yes |)
# ────────────────────────────────────────────────────────────
echo "==> [3/11] Connect Cloudflare WARP (auto TOS)"

systemctl enable  warp-svc >/dev/null 2>&1 || true
systemctl restart warp-svc >/dev/null 2>&1 || true
sleep 3

# yes | silently answers the TOS prompt with y
yes | warp-cli registration new >/dev/null 2>&1 || true
yes | warp-cli register         >/dev/null 2>&1 || true
sleep 2

warp-cli connect >/dev/null 2>&1 || true

WARP_OK=0
for i in {1..20}; do
    warp-cli status 2>/dev/null | grep -qi "Connected" \
        && WARP_OK=1 && break
    sleep 2
done

if [ "$WARP_OK" -eq 1 ]; then
    EXIT_IP="$(curl -s --max-time 8 \
        https://cloudflare.com/cdn-cgi/trace \
        2>/dev/null | awk -F= '/^ip=/{print $2}' || echo unknown)"
    echo "    -> WARP connected | Exit IP: $EXIT_IP"
else
    echo "    WARNING: WARP not confirmed – continuing"
fi

# ────────────────────────────────────────────────────────────
# [4/11] 64GB SWAP + ZRAM
# ────────────────────────────────────────────────────────────
echo "==> [4/11] Setup 64GB Swap + ZRAM"

AVAIL_GB="$(df -BG / | awk 'NR==2{gsub("G","",$4); print $4}')"
SWAP_GB=$(( AVAIL_GB >= 68 ? 64 : (AVAIL_GB > 6 ? AVAIL_GB - 4 : 2) ))
SWAP_MB=$((SWAP_GB * 1024))
echo "    -> Free disk: ${AVAIL_GB}G | Swap: ${SWAP_GB}G"

if fallocate -l "${SWAP_GB}G" /swapfile 2>/dev/null; then
    echo "    -> fallocate ok"
else
    echo "    -> using dd fallback..."
    dd if=/dev/zero of=/swapfile bs=1M count="$SWAP_MB" status=progress
fi

ACTUAL=$(stat -c%s /swapfile 2>/dev/null || echo 0)
EXPECTED=$(( SWAP_MB * 1024 * 1024 ))
if [ "$ACTUAL" -ge "$EXPECTED" ]; then
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    echo "    -> Swap active: $(free -h | awk '/Swap/{print $2}')"
else
    echo "    WARNING: Swap smaller than expected – check df -h /"
fi

cat > /etc/default/zramswap <<'EOF'
ALGO=lz4
PERCENT=50
PRIORITY=100
EOF
systemctl enable  zramswap >/dev/null 2>&1 || true
systemctl restart zramswap >/dev/null 2>&1 || true

cat > /etc/sysctl.d/99-mt5.conf <<'EOF'
vm.swappiness=10
vm.vfs_cache_pressure=80
net.ipv4.tcp_keepalive_time=60
net.ipv4.tcp_keepalive_intvl=10
net.ipv4.tcp_keepalive_probes=6
net.ipv4.tcp_fin_timeout=30
net.core.somaxconn=1024
fs.file-max=1000000
EOF
sysctl -p /etc/sysctl.d/99-mt5.conf >/dev/null 2>&1 || true

echo "    -> Memory status:"
free -h       || true
swapon --show || true
zramctl       || true

# ────────────────────────────────────────────────────────────
# [5/11] DOWNLOAD mt5setup.exe FRESH VIA WARP
# ────────────────────────────────────────────────────────────
echo "==> [5/11] Download mt5setup.exe (fresh via WARP)"
SETUP_FILE="/tmp/mt5setup.exe"
rm -f "$SETUP_FILE" 2>/dev/null || true

wget -q --show-progress "$MT5_CDN" -O "$SETUP_FILE" 2>&1 || \
    curl -L --progress-bar "$MT5_CDN" -o "$SETUP_FILE"

FILESIZE="$(stat -c%s "$SETUP_FILE" 2>/dev/null || echo 0)"
if [ "$FILESIZE" -lt 100000 ]; then
    echo ""
    echo "ERROR: Download failed (${FILESIZE} bytes)"
    echo "  Reconnect WARP : warp-cli disconnect && warp-cli connect"
    echo "  Manual SCP     : scp mt5setup.exe root@$SERVER_IP:/tmp/mt5setup.exe"
    exit 1
fi
echo "    -> Downloaded: $(du -sh "$SETUP_FILE" | cut -f1)"

# ────────────────────────────────────────────────────────────
# [6/11] INSTALL MASTER WINE PREFIX
# ────────────────────────────────────────────────────────────
echo "==> [6/11] Install master MetaTester Wine prefix"
export WINEPREFIX=/opt/mt5master
export WINEARCH=win64
export WINEDLLOVERRIDES="mscoree,mshtml="
export WINEDEBUG=-all
mkdir -p "$WINEPREFIX"
mkdir -p /opt/mt5
printf '%s' "$PW" > /opt/mt5/agent-password
chmod 600 /opt/mt5/agent-password

rm -f /tmp/.X90-lock /tmp/.X11-unix/X90 2>/dev/null || true
Xvfb :90 -screen 0 1280x900x24 >/tmp/xvfb-master.log 2>&1 &
XVFB_MASTER_PID=$!
sleep 3

DISPLAY=:90 wineboot -u >/dev/null 2>&1
sleep 2

echo "    -> Running installer (up to 10 min)..."
DISPLAY=:90 wine "$SETUP_FILE" /auto >/tmp/mt5-install.log 2>&1 &
INSTALL_PID=$!

FOUND=0
for i in {1..120}; do
    if [ $(( i % 12 )) -eq 0 ]; then
        if ! warp-cli status 2>/dev/null | grep -qi "Connected"; then
            echo "    WARNING: WARP dropped – reconnecting..."
            yes | warp-cli register >/dev/null 2>&1 || true
            warp-cli connect        >/dev/null 2>&1 || true
            sleep 5
        fi
    fi

    if find "$WINEPREFIX" -name "metatester64.exe" \
            2>/dev/null | grep -q .; then
        FOUND=1
        echo "    -> metatester64.exe found after $((i*5))s – settling 15s..."
        sleep 15
        break
    fi
    echo "    ...Installing ($((i*5))s / 600s)..."
    sleep 5
done

kill "$INSTALL_PID"     2>/dev/null || true
wait "$INSTALL_PID"     2>/dev/null || true
kill "$XVFB_MASTER_PID" 2>/dev/null || true
wait "$XVFB_MASTER_PID" 2>/dev/null || true
rm -f /tmp/.X90-lock /tmp/.X11-unix/X90 2>/dev/null || true

MT5_DIR="$(find "$WINEPREFIX" -name metatester64.exe \
    -exec dirname {} \; 2>/dev/null | head -1 || true)"
if [ -z "$MT5_DIR" ] || [ "$FOUND" -ne 1 ]; then
    echo "ERROR: MetaTester install failed"
    echo "---- install log ----"
    tail -n 60 /tmp/mt5-install.log || true
    exit 1
fi
echo "    -> Installed at: $MT5_DIR"

wine reg delete \
    "HKCU\\Software\\MetaQuotes Software\\Cloud.Ping" \
    /f >/dev/null 2>&1 || true

# ────────────────────────────────────────────────────────────
# [7/11] CLONE AGENT PREFIXES + GENERATE ALL SCRIPTS
# ────────────────────────────────────────────────────────────
echo "==> [7/11] Clone agent prefixes + generate all helper scripts"
rm -f /opt/mt5/cloud-enabled /opt/mt5/cloud-login 2>/dev/null || true

# ── start-all.sh ─────────────────────────────────────────
cat > /opt/mt5/start-all.sh <<EOF
#!/bin/bash
pkill -9 -f metatester64 2>/dev/null || true
pkill -9 -f wineserver   2>/dev/null || true
pkill -9 -f Xvfb         2>/dev/null || true
screen -ls 2>/dev/null | awk '/\\.mt5-/{print \$1}' \\
    | xargs -r -I{} screen -S {} -X quit 2>/dev/null || true
screen -wipe 2>/dev/null || true
rm -f /tmp/.X*-lock /tmp/.X11-unix/X* 2>/dev/null || true
yes | warp-cli register >/dev/null 2>&1 || true
warp-cli connect        >/dev/null 2>&1 || true
sleep 5
ulimit -n 100000
for P in \$(seq $SP $EP); do
    screen -dmS "mt5-\$P" bash "/opt/mt5/run-agent-\$P.sh"
    echo "  -> Agent \$P started"
done
EOF
chmod +x /opt/mt5/start-all.sh

# ── cloud-on.sh ──────────────────────────────────────────
cat > /opt/mt5/cloud-on.sh <<'CLOUDON'
#!/bin/bash
LOGIN="${1:-}"
if [ -z "$LOGIN" ]; then
    echo "Usage: /opt/mt5/cloud-on.sh MQL5_LOGIN"
    exit 1
fi
echo "$LOGIN" > /opt/mt5/cloud-login
touch /opt/mt5/cloud-enabled
chmod 600 /opt/mt5/cloud-login /opt/mt5/cloud-enabled
/opt/mt5/start-all.sh
sleep 20
echo ""
echo "============================================"
echo " Cloud ENABLED for: $LOGIN"
echo "============================================"
echo " Watch  : screen -r mt5-3000"
echo " Status : /opt/mt5/status.sh"
echo " Web    : https://cloud.mql5.com/en/agents"
CLOUDON
chmod +x /opt/mt5/cloud-on.sh

# ── cloud-off.sh ─────────────────────────────────────────
cat > /opt/mt5/cloud-off.sh <<'CLOUDOFF'
#!/bin/bash
rm -f /opt/mt5/cloud-login /opt/mt5/cloud-enabled 2>/dev/null || true
/opt/mt5/start-all.sh
echo "Cloud DISABLED – agents restarted in local-only mode."
CLOUDOFF
chmod +x /opt/mt5/cloud-off.sh

# ── status.sh ────────────────────────────────────────────
cat > /opt/mt5/status.sh <<EOF
#!/bin/bash
echo "=== Agent Status ==="
for P in \$(seq $SP $EP); do
    PORT_UP=\$(ss -tuln 2>/dev/null | grep -c ":\$P " || echo 0)
    SCR=\$(screen -ls 2>/dev/null | grep "mt5-\$P" | awk '{print \$1}' || echo none)
    echo "  Agent \$P | port: \$([ \$PORT_UP -gt 0 ] && echo UP || echo DOWN) | screen: \${SCR:-none}"
done
echo ""
echo "=== Cloud Mode ==="
if [ -f /opt/mt5/cloud-enabled ]; then
    echo "  ENABLED  | Login: \$(cat /opt/mt5/cloud-login)"
else
    echo "  DISABLED | run: /opt/mt5/cloud-on.sh YOUR_MQL5_LOGIN"
fi
echo ""
echo "=== Memory ==="
free -h | grep -E "Mem|Swap"
zramctl 2>/dev/null | head -4 || true
echo ""
echo "=== WARP ==="
warp-cli status 2>/dev/null || echo "  not running"
echo ""
echo "=== Firewall ==="
ufw status 2>/dev/null || echo "  UFW not installed"
echo ""
echo "=== noVNC ==="
pgrep -a websockify 2>/dev/null || echo "  not running"
EOF
chmod +x /opt/mt5/status.sh

# ── SSL cert for noVNC ───────────────────────────────────
VNC_CERT="/opt/mt5/novnc.pem"
openssl req -x509 -nodes -newkey rsa:2048 \
    -keyout "$VNC_CERT" -out "$VNC_CERT" -days 3650 \
    -subj "/CN=$SERVER_IP" >/dev/null 2>&1

# ── open-for-cloud.sh (noVNC + MetaTester GUI) ───────────
cat > /opt/mt5/open-for-cloud.sh <<EOF
#!/bin/bash
pkill -9 -f x11vnc    2>/dev/null || true
pkill -9 -f websockify 2>/dev/null || true
sleep 2

rm -f /tmp/.X10-lock /tmp/.X11-unix/X10 2>/dev/null || true
Xvfb :10 -screen 0 1280x900x24 >/tmp/xvfb-vnc.log 2>&1 &
sleep 3

x11vnc -display :10 \\
    -rfbport $VNC_PORT \\
    -passwd "$VNC_PASS" \\
    -forever -noxdamage -noxfixes -bg \\
    -o /tmp/x11vnc.log 2>/dev/null || true
sleep 2

websockify -D \\
    --web=/usr/share/novnc/ \\
    --cert=/opt/mt5/novnc.pem \\
    $NOVNC_PORT localhost:$VNC_PORT \\
    >/tmp/websockify.log 2>&1
sleep 2

MT5_EX="\$(find /opt/mt5master -name metatester64.exe 2>/dev/null | head -1)"
[ -z "\$MT5_EX" ] && \\
    MT5_EX="\$(find /opt/mt5agent-3000 -name metatester64.exe 2>/dev/null | head -1)"

WINEPREFIX=/opt/mt5master WINEARCH=win64 WINEDEBUG=-all \\
    DISPLAY=:10 wine "\$MT5_EX" >/tmp/mt5-vnc.log 2>&1 &

echo ""
echo "============================================"
echo " noVNC Running!"
echo "============================================"
echo " Browser  : https://$SERVER_IP:$NOVNC_PORT/vnc.html"
echo " Password : $VNC_PASS"
echo ""
echo " IN MetaTester window:"
echo "   -> Tab: MQL5 Cloud Network"
echo "   -> Tick: Allow public use of agents"
echo "   -> Login: your MQL5 username"
echo "   -> Password: your MQL5 account password"
echo "   -> Click: Apply"
echo ""
echo " After clicking Apply run:"
echo "   /opt/mt5/cloud-on.sh YOUR_MQL5_LOGIN"
echo "============================================"
EOF
chmod +x /opt/mt5/open-for-cloud.sh

# ── start-novnc.sh (VNC only, no MetaTester) ─────────────
cat > /opt/mt5/start-novnc.sh <<EOF
#!/bin/bash
pkill -9 -f x11vnc    2>/dev/null || true
pkill -9 -f websockify 2>/dev/null || true
sleep 2
rm -f /tmp/.X10-lock /tmp/.X11-unix/X10 2>/dev/null || true
Xvfb :10 -screen 0 1280x900x24 >/tmp/xvfb-vnc.log 2>&1 &
sleep 3
x11vnc -display :10 -rfbport $VNC_PORT -passwd "$VNC_PASS" \\
    -forever -noxdamage -noxfixes -bg \\
    -o /tmp/x11vnc.log 2>/dev/null || true
sleep 2
websockify -D \\
    --web=/usr/share/novnc/ \\
    --cert=/opt/mt5/novnc.pem \\
    $NOVNC_PORT localhost:$VNC_PORT \\
    >/tmp/websockify.log 2>&1
echo "noVNC: https://$SERVER_IP:$NOVNC_PORT/vnc.html (pw: $VNC_PASS)"
EOF
chmod +x /opt/mt5/start-novnc.sh

# ── Per-agent run scripts ─────────────────────────────────
for P in $(seq "$SP" "$EP"); do
    IDX=$((P - SP))
    CORE=$((IDX % USABLE_CORES))
    DISP=$((100 + IDX))
    AGENT_WP="/opt/mt5agent-$P"

    echo "    -> Cloning prefix for agent $P (core $CORE, display :$DISP)..."
    rsync -a --exclude='*.lock' "$WINEPREFIX/" "$AGENT_WP/" >/dev/null

    AGENT_EX="$(find "$AGENT_WP" -name metatester64.exe \
        2>/dev/null | head -1)"
    if [ -z "$AGENT_EX" ]; then
        echo "ERROR: metatester64.exe missing in $AGENT_WP"
        exit 1
    fi
    AGENT_WIN_EX="$(echo "$AGENT_EX" \
        | sed "s|$AGENT_WP/drive_c|C:|" \
        | sed 's|/|\\|g')"

    cat > "/opt/mt5/run-agent-$P.sh" <<AGENTEOF
#!/bin/bash
export WINEPREFIX="$AGENT_WP"
export WINEARCH=win64
export WINEDLLOVERRIDES="mscoree,mshtml="
export WINEDEBUG=-all
export NUMBER_OF_PROCESSORS=1
ulimit -n 100000

PW="\$(cat /opt/mt5/agent-password)"
ACCOUNT_ARG=""
if [ -f /opt/mt5/cloud-enabled ] && [ -s /opt/mt5/cloud-login ]; then
    LOGIN="\$(cat /opt/mt5/cloud-login)"
    ACCOUNT_ARG="/account:\${LOGIN}"
fi

rm -f /tmp/.X${DISP}-lock /tmp/.X11-unix/X${DISP} 2>/dev/null || true
Xvfb :${DISP} -screen 0 1024x768x24 >/tmp/xvfb-${P}.log 2>&1 &
XVFB_PID=\$!
sleep 3

yes | warp-cli register >/dev/null 2>&1 || true
warp-cli connect        >/dev/null 2>&1 || true
sleep 2

taskset -c ${CORE} env DISPLAY=:${DISP} NUMBER_OF_PROCESSORS=1 \
    wine '${AGENT_WIN_EX}' \
    "/address:0.0.0.0:${P}" \
    "/password:\${PW}" \
    \${ACCOUNT_ARG}

kill \$XVFB_PID 2>/dev/null || true
wait \$XVFB_PID 2>/dev/null || true
AGENTEOF
    chmod +x "/opt/mt5/run-agent-$P.sh"
done

# @reboot cron
(crontab -l 2>/dev/null | grep -v '@reboot .*start-all' || true; \
 echo "@reboot sleep 45 && warp-cli connect && sleep 5 && /opt/mt5/start-all.sh") \
    | crontab -
echo "    -> @reboot cron added"

# ────────────────────────────────────────────────────────────
# [8/11] START AGENTS (LOCAL-ONLY)
# ────────────────────────────────────────────────────────────
echo "==> [8/11] Start agents in local-only mode"
rm -f /opt/mt5/cloud-enabled /opt/mt5/cloud-login 2>/dev/null || true
/opt/mt5/start-all.sh

# ────────────────────────────────────────────────────────────
# [9/11] VERIFY AGENTS
# ────────────────────────────────────────────────────────────
echo "==> [9/11] Verify agents"
ONLINE=0
for i in {1..60}; do
    COUNT=0
    for P in $(seq "$SP" "$EP"); do
        ss -tuln 2>/dev/null | grep -q ":$P " \
            && COUNT=$((COUNT+1)) || true
    done
    if [ "$COUNT" -ge 1 ]; then
        ONLINE="$COUNT"
        break
    fi
    echo "    ...Waiting ($((i*5))s / 300s)..."
    sleep 5
done

echo "    -> Agents online: $ONLINE / $AGENTS"
for P in $(seq "$SP" "$EP"); do
    ss -tuln 2>/dev/null | grep -q ":$P " \
        && echo "    Port $P: UP" || echo "    Port $P: DOWN"
done

# ────────────────────────────────────────────────────────────
# [10/11] LAUNCH NOVNC FOR CLOUD REGISTRATION
# ────────────────────────────────────────────────────────────
echo "==> [10/11] Launch noVNC for cloud registration"
/opt/mt5/open-for-cloud.sh

# ────────────────────────────────────────────────────────────
# [11/11] CLEAN RAM
# ────────────────────────────────────────────────────────────
echo "==> [11/11] Clean RAM"

cat > /usr/local/bin/clear-ram-cache.sh <<'EOF'
#!/bin/bash
sync
echo 1 > /proc/sys/vm/drop_caches
EOF
chmod +x /usr/local/bin/clear-ram-cache.sh

(crontab -l 2>/dev/null | grep -v clear-ram-cache || true; \
    echo "*/30 * * * * /usr/local/bin/clear-ram-cache.sh") | crontab -

echo "    -> Memory before clean:"
free -h | grep -E "Mem|Swap"
/usr/local/bin/clear-ram-cache.sh
echo "    -> Memory after clean:"
free -h | grep -E "Mem|Swap"

# ────────────────────────────────────────────────────────────
# DONE
# ────────────────────────────────────────────────────────────
cat <<DONE

=====================================================
 SETUP COMPLETE
=====================================================
 Agents   : $ONLINE / $AGENTS running (local-only)
 Swap     : ${SWAP_GB}GB on /swapfile
 ZRAM     : 50% compressed RAM (lz4)
 WARP     : auto TOS + connected
 Firewall : disabled (ufw + iptables flushed)
 CPU trick: taskset + NUMBER_OF_PROCESSORS=1

 ─────────────────────────────────────────────────
 STEP 1 — Register cloud (ONE TIME via browser):
   https://$SERVER_IP:$NOVNC_PORT/vnc.html
   VNC Password: $VNC_PASS

   In MetaTester window:
   -> Tab: MQL5 Cloud Network
   -> Tick: Allow public use of agents
   -> Login: your MQL5 username
   -> Password: your MQL5 account password
   -> Click: Apply

 STEP 2 — After clicking Apply:
   /opt/mt5/cloud-on.sh rcktya

 ─────────────────────────────────────────────────
 COMMANDS:
   screen -ls                    All agent sessions
   screen -r mt5-3000            Watch agent live
   /opt/mt5/status.sh            Full status
   /opt/mt5/open-for-cloud.sh    Reopen VNC anytime
   /opt/mt5/cloud-on.sh LOGIN    Enable cloud
   /opt/mt5/cloud-off.sh         Disable cloud
   /opt/mt5/start-all.sh         Restart all agents

 WEBSITE:
   https://cloud.mql5.com/en/agents
=====================================================
DONE
