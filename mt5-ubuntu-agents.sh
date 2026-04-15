#!/bin/bash
set -euo pipefail

# Usage:
#   bash mt5-ubuntu-agents.sh [AGENTS] [PASSWORD] [MQL5_LOGIN]
# Example:
#   bash mt5-ubuntu-agents.sh 7 Prem@1996 rcktya

export DEBIAN_FRONTEND=noninteractive

TOTAL_CORES=$(nproc)
RESERVE_CORES=1
USABLE_CORES=$(( TOTAL_CORES > RESERVE_CORES ? TOTAL_CORES - RESERVE_CORES : 1 ))

if [ -n "${1:-}" ]; then
    REQUESTED_AGENTS="$1"
else
    REQUESTED_AGENTS="$USABLE_CORES"
fi

if [ "$REQUESTED_AGENTS" -gt "$USABLE_CORES" ]; then
    REQUESTED_AGENTS="$USABLE_CORES"
fi
if [ "$REQUESTED_AGENTS" -lt 1 ]; then
    REQUESTED_AGENTS=1
fi

if [ -f /root/.mt5pw ]; then
    PW="$(cat /root/.mt5pw)"
elif [ -n "${2:-}" ]; then
    PW="$2"
else
    PW="MetaTester"
fi

MQL5_LOGIN="${3:-}"

SP=3000
EP=$((SP + REQUESTED_AGENTS - 1))

echo "============================================="
echo " MT5 Cloud Agent Setup"
echo " Agents: $REQUESTED_AGENTS"
echo " Total cores: $TOTAL_CORES | Usable cores: $USABLE_CORES"
echo " Login: ${MQL5_LOGIN:-none}"
echo "============================================="

cleanup_runtime() {
    pkill -9 -f metatester64 2>/dev/null || true
    pkill -9 -f wineserver 2>/dev/null || true
    pkill -9 -f Xvfb 2>/dev/null || true
    screen -ls 2>/dev/null | awk '/\.mt5-/{print $1}' | xargs -r -I{} screen -S {} -X quit 2>/dev/null || true
    screen -wipe 2>/dev/null || true
    rm -f /tmp/.X*-lock /tmp/.X11-unix/X* 2>/dev/null || true
}

echo "==> [1/9] Cleanup"
cleanup_runtime
rm -rf /opt/mt5master /opt/mt5agent-* /opt/mt5 2>/dev/null || true
rm -f /tmp/mt5setup.exe 2>/dev/null || true
echo "    -> Done"

echo "==> [2/9] Install Wine + WARP + tools"
dpkg --add-architecture i386
mkdir -pm755 /etc/apt/keyrings /usr/share/keyrings

UBUNTU_VER="$(lsb_release -cs)"

wget -q -O /etc/apt/keyrings/winehq-archive.key https://dl.winehq.org/wine-builds/winehq.key
wget -q -NP /etc/apt/sources.list.d/ \
  "https://dl.winehq.org/wine-builds/ubuntu/dists/${UBUNTU_VER}/winehq-${UBUNTU_VER}.sources"

curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
  | gpg --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg

echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ ${UBUNTU_VER} main" \
  > /etc/apt/sources.list.d/cloudflare-client.list

apt-get update -y >/dev/null
apt-get install -y --install-recommends \
  winehq-devel xvfb screen wget net-tools cabextract curl rsync \
  util-linux cloudflare-warp zram-tools procps >/dev/null

echo "    -> $(wine --version)"

echo "==> [3/9] Connect Cloudflare WARP"
warp-cli --accept-tos registration new >/dev/null 2>&1 || true
warp-cli --accept-tos register >/dev/null 2>&1 || true
warp-cli --accept-tos connect >/dev/null 2>&1 || warp-cli connect >/dev/null 2>&1 || true

WARP_OK=0
for i in {1..20}; do
    if warp-cli status 2>/dev/null | grep -qi "Connected"; then
        WARP_OK=1
        echo "    -> WARP connected after $((i*2))s"
        break
    fi
    printf "."
    sleep 2
done
echo

EXIT_IP="$(curl -s --max-time 10 https://cloudflare.com/cdn-cgi/trace 2>/dev/null | awk -F= '/^ip=/{print $2}' || true)"
echo "    -> Exit IP: ${EXIT_IP:-unknown}"

echo "==> [4/9] Setup 64G swap + ZRAM"
swapoff -a 2>/dev/null || true
sed -i '\|/swapfile none swap sw 0 0|d' /etc/fstab 2>/dev/null || true
rm -f /swapfile 2>/dev/null || true

AVAIL_GB="$(df -BG / | awk 'NR==2{gsub("G","",$4); print $4}')"
if [ "$AVAIL_GB" -ge 68 ]; then
    SWAP_GB=64
else
    SWAP_GB=$(( AVAIL_GB > 6 ? AVAIL_GB - 4 : 2 ))
fi
SWAP_MB=$((SWAP_GB * 1024))

echo "    -> Disk free: ${AVAIL_GB}G"
echo "    -> Swap target: ${SWAP_GB}G"

if fallocate -l "${SWAP_GB}G" /swapfile 2>/dev/null; then
    echo "    -> fallocate ok"
else
    echo "    -> fallocate unavailable, using dd"
    dd if=/dev/zero of=/swapfile bs=1M count="$SWAP_MB" status=progress
fi

chmod 600 /swapfile
mkswap /swapfile >/dev/null
swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab

cat > /etc/default/zramswap <<'EOF'
ALGO=lz4
PERCENT=50
PRIORITY=100
EOF

systemctl enable zramswap >/dev/null 2>&1 || true
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
free -h || true
swapon --show || true
zramctl || true

echo "==> [5/9] Create RAM cache cleaner (run at end)"
cat > /usr/local/bin/clear-ram-cache.sh <<'EOF'
#!/bin/bash
sync
echo 1 > /proc/sys/vm/drop_caches
EOF
chmod +x /usr/local/bin/clear-ram-cache.sh
(crontab -l 2>/dev/null | grep -v clear-ram-cache || true; echo "*/30 * * * * /usr/local/bin/clear-ram-cache.sh") | crontab -

echo "==> [6/9] Download mt5setup.exe fresh"
SETUP_FILE="/tmp/mt5setup.exe"
MT5_CDN="https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe"
rm -f "$SETUP_FILE" 2>/dev/null || true

wget -q --show-progress "$MT5_CDN" -O "$SETUP_FILE" 2>&1 || \
curl -L --progress-bar "$MT5_CDN" -o "$SETUP_FILE"

FILESIZE="$(stat -c%s "$SETUP_FILE" 2>/dev/null || echo 0)"
if [ "$FILESIZE" -lt 100000 ]; then
    echo "ERROR: mt5setup.exe download failed (${FILESIZE} bytes)"
    echo "Check: warp-cli status"
    exit 1
fi
echo "    -> Downloaded: $(du -sh "$SETUP_FILE" | cut -f1)"

echo "==> [7/9] Install master MetaTester prefix"
export WINEPREFIX=/opt/mt5master
export WINEARCH=win64
export WINEDLLOVERRIDES="mscoree,mshtml="
export WINEDEBUG=-all
mkdir -p "$WINEPREFIX"

rm -f /tmp/.X90-lock /tmp/.X11-unix/X90 2>/dev/null || true
Xvfb :90 -screen 0 1024x768x24 >/tmp/xvfb-master.log 2>&1 &
XVFB_MASTER_PID=$!
sleep 2
DISPLAY=:90 wineboot -u >/dev/null 2>&1

warp-cli connect >/dev/null 2>&1 || true
sleep 3

DISPLAY=:90 wine "$SETUP_FILE" /auto >/tmp/mt5-install.log 2>&1 &
INSTALL_PID=$!

FOUND=0
for i in {1..120}; do
    if ! warp-cli status 2>/dev/null | grep -qi "Connected"; then
        echo "    WARNING: WARP dropped, reconnecting..."
        warp-cli disconnect >/dev/null 2>&1 || true
        sleep 2
        warp-cli connect >/dev/null 2>&1 || true
        sleep 5
    fi

    if find "$WINEPREFIX" -name "metatester64.exe" 2>/dev/null | grep -q .; then
        FOUND=1
        echo "    -> metatester64.exe found after $((i*5))s"
        sleep 15
        break
    fi

    echo "    ...Installing ($((i*5))s / 600s)..."
    sleep 5
done

kill "$INSTALL_PID" 2>/dev/null || true
wait "$INSTALL_PID" 2>/dev/null || true
kill "$XVFB_MASTER_PID" 2>/dev/null || true
wait "$XVFB_MASTER_PID" 2>/dev/null || true
rm -f /tmp/.X90-lock /tmp/.X11-unix/X90 2>/dev/null || true

MT5_DIR="$(find "$WINEPREFIX" -name metatester64.exe -exec dirname {} \; 2>/dev/null | head -1 || true)"
if [ -z "$MT5_DIR" ] || [ "$FOUND" -ne 1 ]; then
    echo "ERROR: MetaTester install failed"
    echo "---- tail /tmp/mt5-install.log ----"
    tail -n 60 /tmp/mt5-install.log || true
    exit 1
fi
echo "    -> Installed at: $MT5_DIR"

wine reg delete "HKCU\\Software\\MetaQuotes Software\\Cloud.Ping" /f >/dev/null 2>&1 || true

echo "==> [8/9] Clone prefixes and launch agents"
mkdir -p /opt/mt5

cat > /opt/mt5/start-all.sh <<EOF
#!/bin/bash
set -e
pkill -9 -f metatester64 2>/dev/null || true
pkill -9 -f wineserver 2>/dev/null || true
pkill -9 -f Xvfb 2>/dev/null || true
screen -ls 2>/dev/null | awk '/\\.mt5-/{print \$1}' | xargs -r -I{} screen -S {} -X quit 2>/dev/null || true
screen -wipe 2>/dev/null || true
rm -f /tmp/.X*-lock /tmp/.X11-unix/X* 2>/dev/null || true
warp-cli connect >/dev/null 2>&1 || true
sleep 5
ulimit -n 100000
EOF

for P in $(seq "$SP" "$EP"); do
    IDX=$((P - SP))
    CORE=$((IDX % USABLE_CORES))
    DISP=$((100 + IDX))

    AGENT_WP="/opt/mt5agent-$P"
    rsync -a --exclude='*.lock' "$WINEPREFIX/" "$AGENT_WP/"

    AGENT_EX="$(find "$AGENT_WP" -name metatester64.exe 2>/dev/null | head -1)"
    if [ -z "$AGENT_EX" ]; then
        echo "ERROR: metatester64.exe missing in $AGENT_WP"
        exit 1
    fi

    AGENT_WIN_EX="$(echo "$AGENT_EX" | sed "s|$AGENT_WP/drive_c|C:|" | sed 's|/|\\|g')"

    WINEPREFIX="$AGENT_WP" WINEARCH=win64 wine reg delete \
      "HKCU\\Software\\MetaQuotes Software\\Cloud.Ping" /f >/dev/null 2>&1 || true

    if [ -n "$MQL5_LOGIN" ]; then
        WINEPREFIX="$AGENT_WP" WINEARCH=win64 wine reg add \
          "HKCU\\Software\\MetaQuotes\\MetaTester" \
          /v "Login" /t REG_SZ /d "$MQL5_LOGIN" /f >/dev/null 2>&1 || true

        WINEPREFIX="$AGENT_WP" WINEARCH=win64 wine reg add \
          "HKCU\\Software\\MetaQuotes\\MetaTester" \
          /v "SellComputingResources" /t REG_DWORD /d "1" /f >/dev/null 2>&1 || true

        CFG_DIR="$AGENT_WP/drive_c/users/Public/AppData/Roaming/MetaQuotes/Tester"
        mkdir -p "$CFG_DIR"
        cat > "$CFG_DIR/metatester.ini" <<CFGEOF
[Tester]
Port=$P
Password=$PW

[Cloud]
Login=$MQL5_LOGIN
SellComputingResources=1
CFGEOF
        chmod 600 "$CFG_DIR/metatester.ini"
    fi

    AGENT_SCRIPT="/opt/mt5/run-agent-$P.sh"
    cat > "$AGENT_SCRIPT" <<AGENTEOF
#!/bin/bash
set -e
export WINEPREFIX="$AGENT_WP"
export WINEARCH=win64
export WINEDLLOVERRIDES="mscoree,mshtml="
export WINEDEBUG=-all
export NUMBER_OF_PROCESSORS=1
ulimit -n 100000

rm -f /tmp/.X${DISP}-lock /tmp/.X11-unix/X${DISP} 2>/dev/null || true
Xvfb :${DISP} -screen 0 1024x768x24 >/tmp/xvfb-${P}.log 2>&1 &
XVFB_PID=\$!
sleep 2

warp-cli connect >/dev/null 2>&1 || true
sleep 2

# CPU-affinity trick:
# - taskset pins this Wine process to a single Linux CPU
# - NUMBER_OF_PROCESSORS=1 reduces the visible processor hint for Windows apps
taskset -c ${CORE} env DISPLAY=:${DISP} NUMBER_OF_PROCESSORS=1 \
    wine '${AGENT_WIN_EX}' /address:0.0.0.0:${P} /password:'${PW}' ${MQL5_LOGIN:+/account:${MQL5_LOGIN}}

kill \$XVFB_PID 2>/dev/null || true
wait \$XVFB_PID 2>/dev/null || true
AGENTEOF
    chmod +x "$AGENT_SCRIPT"

    screen -dmS "mt5-$P" bash "$AGENT_SCRIPT"
    echo "screen -dmS mt5-$P bash '$AGENT_SCRIPT'" >> /opt/mt5/start-all.sh

    echo "    -> Agent $P on CPU core $CORE via display :$DISP"
done

chmod +x /opt/mt5/start-all.sh

(crontab -l 2>/dev/null | grep -v '@reboot .*mt5' || true; \
 echo "@reboot sleep 45 && warp-cli connect && sleep 5 && /opt/mt5/start-all.sh") | crontab -

echo "==> [9/9] Verify"
ONLINE=0
for i in {1..60}; do
    COUNT=0
    for P in $(seq "$SP" "$EP"); do
        if ss -tuln 2>/dev/null | grep -q ":$P "; then
            COUNT=$((COUNT + 1))
        fi
    done
    if [ "$COUNT" -ge 1 ]; then
        ONLINE="$COUNT"
        break
    fi
    echo "    ...Waiting ($((i*5))s / 300s)..."
    sleep 5
done

echo "============================================="
echo " Requested agents: $REQUESTED_AGENTS"
echo " Online agents:    $ONLINE"
echo " Ports:            $SP-$EP"
echo " WARP:             $(warp-cli status 2>/dev/null | tr '\n' ' ' | sed 's/  */ /g')"
echo "============================================="

for P in $(seq "$SP" "$EP"); do
    if ss -tuln 2>/dev/null | grep -q ":$P "; then
        echo " Port $P: UP"
    else
        echo " Port $P: DOWN"
    fi
done

echo
echo "Final memory state:"
free -h || true
swapon --show || true
zramctl || true

echo
echo "Clearing RAM cache now..."
/usr/local/bin/clear-ram-cache.sh || true
free -h || true

echo
echo "Commands:"
echo "  screen -ls"
echo "  screen -r mt5-3000"
echo "  /opt/mt5/start-all.sh"
echo "  warp-cli status"
echo "  tail -n 60 /tmp/mt5-install.log"
