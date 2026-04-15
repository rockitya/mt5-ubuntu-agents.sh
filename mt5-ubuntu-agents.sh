#!/bin/bash
set -e

# MT5 Ubuntu Cloud Agents — Full Setup Script
# Usage: bash mt5-ubuntu-agents.sh [CORES] [PASSWORD] [MQL5_LOGIN]
# Example: bash mt5-ubuntu-agents.sh 7 Prem@1996 rcktya
#
# CDN blocked? No problem — Cloudflare WARP is used automatically.
# Already have mt5setup.exe? SCP it once and it's reused forever:
#   scp mt5setup.exe root@SERVER:/opt/mt5setup.exe
#
# Password tip: echo 'YourPassword' > /root/.mt5pw && chmod 600 /root/.mt5pw

TOTAL_CORES=$(nproc)
if [ -z "$1" ]; then
    REQUESTED_CORES=$((TOTAL_CORES > 1 ? TOTAL_CORES - 1 : 1))
else
    REQUESTED_CORES=$1
    if [ "$REQUESTED_CORES" -ge "$TOTAL_CORES" ] && [ "$TOTAL_CORES" -gt 1 ]; then
        echo "WARNING: Reserving 1 core for OS stability."
        REQUESTED_CORES=$((TOTAL_CORES - 1))
    fi
fi

if [ -f /root/.mt5pw ]; then
    PW=$(cat /root/.mt5pw)
elif [ ! -z "$2" ]; then
    PW="$2"
else
    PW="MetaTester"
fi

MQL5_LOGIN=$3
export DEBIAN_FRONTEND=noninteractive

echo "============================================="
echo " MT5 Cloud Agent Setup"
echo " Cores: $REQUESTED_CORES | Login: ${MQL5_LOGIN:-none}"
echo "============================================="

# --- [1/8] WIPE ---
echo "==> [1/8] NUCLEAR WIPE..."
screen -ls 2>/dev/null | grep "\.mt5-" | awk '{print $1}' | xargs -I{} screen -X -S {} quit 2>/dev/null || true
screen -wipe 2>/dev/null || true
pkill -9 -f metatester64 2>/dev/null || true
pkill -9 -f wineserver 2>/dev/null || true
pkill -9 -f Xvfb 2>/dev/null || true
sleep 3
rm -rf /opt/mt5master /opt/mt5agent-* /opt/mt5 2>/dev/null || true
# NOTE: /opt/mt5setup.exe is intentionally preserved across reruns
apt-get remove --purge -y wine* winehq* 2>/dev/null || true
apt-get autoremove -y >/dev/null 2>&1 || true
crontab -l 2>/dev/null | grep -v mt5 | grep -v clear-ram | crontab - 2>/dev/null || true
rm -f /usr/local/bin/clear-ram-cache.sh 2>/dev/null || true
echo "    -> Done."

# --- [2/8] WINE DEVEL + CLOUDFLARE WARP ---
echo "==> [2/8] Installing WineHQ Devel + Cloudflare WARP..."
dpkg --add-architecture i386
mkdir -pm755 /etc/apt/keyrings

# WineHQ repo
wget -q -O /etc/apt/keyrings/winehq-archive.key https://dl.winehq.org/wine-builds/winehq.key
UBUNTU_VER=$(lsb_release -cs)
wget -q -NP /etc/apt/sources.list.d/ \
    "https://dl.winehq.org/wine-builds/ubuntu/dists/$UBUNTU_VER/winehq-$UBUNTU_VER.sources"

# Cloudflare WARP repo
curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | \
    gpg --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg 2>/dev/null
echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] \
    https://pkg.cloudflareclient.com/ ${UBUNTU_VER} main" | \
    tee /etc/apt/sources.list.d/cloudflare-client.list >/dev/null

apt-get update -y >/dev/null
apt-get install -y --install-recommends \
    winehq-devel xvfb screen wget net-tools cabextract curl rsync \
    cloudflare-warp >/dev/null 2>&1

echo "    -> $(wine --version)"

# Connect Cloudflare WARP — changes server exit IP, bypasses MetaQuotes CDN block
echo "    -> Connecting Cloudflare WARP..."
warp-cli --accept-tos register >/dev/null 2>&1 || true
warp-cli connect >/dev/null 2>&1 || true

WARP_READY=0
for i in {1..15}; do
    if warp-cli status 2>/dev/null | grep -qi "Connected"; then
        echo "    -> WARP connected after $((i*2))s."
        WARP_READY=1
        break
    fi
    printf "."
    sleep 2
done
echo ""

EXIT_IP=$(curl -s --max-time 10 https://cloudflare.com/cdn-cgi/trace 2>/dev/null | grep "^ip=" | cut -d= -f2 || echo "unknown")
echo "    -> Exit IP via WARP: $EXIT_IP"

# --- [3/8] SWAP 64GB PERSISTENT ---
echo "==> [3/8] Setting up 64GB Swap (persistent across reboots)..."

# Disable and remove any existing swap first
swapoff -a 2>/dev/null || true
rm -f /swapfile 2>/dev/null || true

# Check available disk space
AVAIL_GB=$(df -BG / | awk 'NR==2{print $4}' | tr -d 'G')
echo "    -> Available disk: ${AVAIL_GB}GB"

if [ "$AVAIL_GB" -lt 66 ]; then
    SWAP_GB=$((AVAIL_GB - 2))
    echo "    WARNING: Only ${AVAIL_GB}GB free. Using ${SWAP_GB}GB swap instead of 64GB."
else
    SWAP_GB=64
fi

SWAP_MB=$((SWAP_GB * 1024))
echo "    -> Allocating ${SWAP_GB}GB (${SWAP_MB}MB) swap..."

# Try fallocate first (instant), fall back to dd (slower but works on all filesystems)
if fallocate -l ${SWAP_GB}G /swapfile 2>/dev/null; then
    echo "    -> fallocate succeeded."
else
    echo "    -> fallocate failed (filesystem may not support it). Using dd..."
    dd if=/dev/zero of=/swapfile bs=1M count=$SWAP_MB status=progress
fi

# Verify file was actually created and has correct size
ACTUAL_SIZE=$(stat -c%s /swapfile 2>/dev/null || echo 0)
EXPECTED_SIZE=$((SWAP_MB * 1024 * 1024))
if [ "$ACTUAL_SIZE" -lt "$EXPECTED_SIZE" ]; then
    echo "    ERROR: Swap file is only $(du -sh /swapfile | cut -f1) — expected ${SWAP_GB}GB."
    echo "    Check disk space: df -h /"
    # Continue without swap rather than exit — agents can still run
else
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile

    # Persist in fstab
    grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab

    echo "    -> Swap successfully created and activated:"
    free -h | grep Swap
fi

# Kernel tuning
cat > /etc/sysctl.d/99-mt5.conf << 'EOF'
vm.swappiness=10
net.ipv4.tcp_keepalive_time=60
net.ipv4.tcp_keepalive_intvl=10
net.ipv4.tcp_keepalive_probes=6
net.ipv4.tcp_fin_timeout=30
net.core.somaxconn=1024
fs.file-max=1000000
EOF
sysctl -p /etc/sysctl.d/99-mt5.conf >/dev/null 2>&1 || true
echo "    -> Kernel tuning applied."

# --- [4/8] RAM CACHE SCRIPT (runs at end, not here) ---
echo "==> [4/8] Creating RAM cache script (will run after agents launch)..."
cat > /usr/local/bin/clear-ram-cache.sh << 'EOF'
#!/bin/bash
sync
# echo 1 = page cache only (safe); echo 3 = page+dentries+inodes (aggressive)
echo 1 > /proc/sys/vm/drop_caches
EOF
chmod +x /usr/local/bin/clear-ram-cache.sh

# Schedule cron — but DO NOT run now (agents not up yet)
(crontab -l 2>/dev/null | grep -v clear-ram-cache; echo "*/30 * * * * /usr/local/bin/clear-ram-cache.sh") | crontab -
echo "    -> RAM cache script created. Will run AFTER agents are up. Cron: every 30 min."

# --- [5/8] MT5 SETUP DOWNLOAD (FRESH EVERY RUN) ---
# mt5setup.exe is a WEB INSTALLER — it also pulls MT5 from CDN at install time.
# WARP covers both automatically (system-level IP change, no proxy wrapper needed).
echo "==> [5/8] Downloading mt5setup.exe (fresh every run)..."

SETUP_FILE="/tmp/mt5setup.exe"
MT5_CDN="https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe"

rm -f "$SETUP_FILE" 2>/dev/null || true

echo "    -> Downloading via Cloudflare WARP (full speed)..."
wget -q --show-progress "$MT5_CDN" -O "$SETUP_FILE" 2>&1 || \
    curl -L --progress-bar "$MT5_CDN" -o "$SETUP_FILE" || true

FILESIZE=$(stat -c%s "$SETUP_FILE" 2>/dev/null || echo 0)

if [ "$FILESIZE" -lt 1000000 ]; then
    echo ""
    echo "ERROR: Download failed (${FILESIZE} bytes)."
    echo "  WARP status:    warp-cli status"
    echo "  Reconnect WARP: warp-cli disconnect && warp-cli connect && sleep 10"
    echo "  Then retry:     bash $0 $*"
    echo ""
    echo "  OR manual SCP from LOCAL PC:"
    echo "  curl -o mt5setup.exe '${MT5_CDN}'"
    echo "  scp mt5setup.exe root@$(hostname -I | awk '{print $1}'):${SETUP_FILE}"
    rm -f "$SETUP_FILE"
    exit 1
fi
echo "    -> Downloaded: $(du -sh $SETUP_FILE | cut -f1)"
# No symlink needed — already at /tmp/mt5setup.exe

# --- [5b/8] WINE PREFIX INIT + MT5 INSTALL ---
echo "    -> Initializing Wine prefix..."
export WINEPREFIX=/opt/mt5master
export WINEARCH=win64
export WINEDLLOVERRIDES="mscoree,mshtml="
mkdir -p $WINEPREFIX

xvfb-run -a wineboot -u >/dev/null 2>&1
echo "    -> Wine prefix initialized."

echo "    -> Running silent MT5 install (WARP active — wait up to 5 minutes)..."
xvfb-run -a wine /tmp/mt5setup.exe /auto &
INSTALL_PID=$!

for i in {1..60}; do
    if find $WINEPREFIX -name "metatester64.exe" 2>/dev/null | grep -q .; then
        echo "    -> metatester64.exe found after $((i*5))s. Waiting 15s for installer to finish..."
        sleep 15
        break
    fi
    echo "    ...Installing ($((i*5))s / 300s)..."
    sleep 5
done

kill $INSTALL_PID 2>/dev/null || true
wait $INSTALL_PID 2>/dev/null || true
pkill -f mt5setup 2>/dev/null || true
sleep 3

MT5_DIR=$(find $WINEPREFIX -name "metatester64.exe" -exec dirname {} \; 2>/dev/null | head -1)
if [ -z "$MT5_DIR" ]; then
    echo "ERROR: MT5 installation failed. metatester64.exe not found."
    echo "  Check WARP: warp-cli status"
    echo "  Retry:      bash $0 $*"
    exit 1
fi
echo "    -> Installed at: $MT5_DIR"

# --- [6/8] CLEAR CLOUD.PING ---
echo "==> [6/8] Clearing Cloud.Ping cache for clean cloud connection..."
WINEPREFIX="$WINEPREFIX" WINEARCH=win64 wine reg delete \
    "HKCU\\Software\\MetaQuotes Software\\Cloud.Ping" \
    /f >/dev/null 2>&1 || true
echo "    -> Cloud.Ping cache cleared."

# --- [7/8] CLONE & LAUNCH AGENTS ---
echo "==> [7/8] Cloning master prefix and launching $REQUESTED_CORES agents..."
mkdir -p /opt/mt5

SP=3000
EP=$((SP + REQUESTED_CORES - 1))

cat > /opt/mt5/start-all.sh << 'STARTEOF'
#!/bin/bash
# Restart all MT5 cloud agents
screen -ls 2>/dev/null | grep "\.mt5-" | awk '{print $1}' | xargs -I{} screen -X -S {} quit 2>/dev/null || true
screen -wipe 2>/dev/null || true
pkill -9 -f metatester64 2>/dev/null || true
pkill -9 -f wineserver 2>/dev/null || true
sleep 5
ulimit -n 100000
warp-cli connect >/dev/null 2>&1 || true
sleep 3
STARTEOF

for P in $(seq $SP $EP); do
    echo "    -> Deploying agent on port $P..."
    AGENT_WP="/opt/mt5agent-$P"

    rsync -a --exclude='*.lock' "$WINEPREFIX/" "$AGENT_WP/"

    AGENT_EX=$(find $AGENT_WP -name "metatester64.exe" 2>/dev/null | head -1)
    AGENT_WIN_EX="$(echo "$AGENT_EX" | sed "s|$AGENT_WP/drive_c|C:|" | sed 's|/|\\|g')"

    WINEPREFIX="$AGENT_WP" WINEARCH=win64 wine reg delete \
        "HKCU\\Software\\MetaQuotes Software\\Cloud.Ping" \
        /f >/dev/null 2>&1 || true

    ACCOUNT_FLAG=""

    if [ ! -z "$MQL5_LOGIN" ]; then
        ACCOUNT_FLAG="/account:$MQL5_LOGIN"

        WINEPREFIX="$AGENT_WP" WINEARCH=win64 wine reg add \
            "HKCU\\Software\\MetaQuotes\\MetaTester" \
            /v "Login" /t REG_SZ /d "$MQL5_LOGIN" /f >/dev/null 2>&1 || true
        WINEPREFIX="$AGENT_WP" WINEARCH=win64 wine reg add \
            "HKCU\\Software\\MetaQuotes\\MetaTester" \
            /v "SellComputingResources" /t REG_DWORD /d "1" /f >/dev/null 2>&1 || true

        CONFIG_DIR="$AGENT_WP/drive_c/users/Public/AppData/Roaming/MetaQuotes/Tester"
        mkdir -p "$CONFIG_DIR"
        printf '[Tester]\nPort=%s\nPassword=%s\n[Cloud]\nLogin=%s\nSellComputingResources=1\n' \
            "$P" "$PW" "$MQL5_LOGIN" > "$CONFIG_DIR/metatester.ini"
        chmod 600 "$CONFIG_DIR/metatester.ini"
    fi

    AGENT_SCRIPT="/opt/mt5/run-agent-$P.sh"
    DISP=$((P - 2990))

    cat > "$AGENT_SCRIPT" << AGENTEOF
#!/bin/bash
export WINEPREFIX=$AGENT_WP
export WINEARCH=win64
export WINEDLLOVERRIDES='mscoree,mshtml='
ulimit -n 100000
Xvfb :${DISP} -screen 0 1024x768x24 &
XVFB_PID=\$!
sleep 1
DISPLAY=:${DISP} wine '$AGENT_WIN_EX' /address:0.0.0.0:$P /password:$PW $ACCOUNT_FLAG
kill \$XVFB_PID 2>/dev/null || true
AGENTEOF
    chmod +x "$AGENT_SCRIPT"

    screen -dmS "mt5-$P" bash "$AGENT_SCRIPT"
    echo "      -> Agent $P launched: screen -r mt5-$P"

    echo "screen -dmS mt5-$P bash '$AGENT_SCRIPT'" >> /opt/mt5/start-all.sh
done

chmod +x /opt/mt5/start-all.sh

# @reboot: WARP connect → RAM clear → agents
(crontab -l 2>/dev/null | grep -v mt5; \
    echo "@reboot sleep 45 && warp-cli connect && sleep 5 && /usr/local/bin/clear-ram-cache.sh && /opt/mt5/start-all.sh") | crontab -
echo "    -> @reboot cron added (45s boot delay + WARP reconnect)."

# --- [8/8] VERIFY ---
echo "==> [8/8] Waiting for agents to come online (up to 5 minutes)..."
for i in {1..60}; do
    COUNT=0
    for P in $(seq $SP $EP); do
        ss -tuln 2>/dev/null | grep -q ":$P " && COUNT=$((COUNT + 1)) || true
    done
    if [ "$COUNT" -ge 1 ]; then
        echo ""
        echo "============================================="
        echo "  SUCCESS: $COUNT / $REQUESTED_CORES agents online!"
        for P in $(seq $SP $EP); do
            if ss -tuln 2>/dev/null | grep -q ":$P "; then
                echo "    Port $P: UP"
            else
                echo "    Port $P: pending"
            fi
        done
        echo "============================================="
        [ ! -z "$MQL5_LOGIN" ] && echo "  Cloud: ENABLED for account '$MQL5_LOGIN'"
        echo ""
        echo "  WARP Status:  warp-cli status"
        echo "  Exit IP:      curl -s https://cloudflare.com/cdn-cgi/trace | grep ip="
        echo "  Swap:         free -h"
        echo ""
        echo "  Commands:"
        echo "    screen -ls                          (list all sessions)"
        echo "    screen -r mt5-3000                  (watch agent live)"
        echo "    Ctrl+A then D                       (detach from screen)"
        echo "    /opt/mt5/start-all.sh               (restart all agents)"
        echo "    /usr/local/bin/clear-ram-cache.sh   (clear RAM manually)"
        echo ""
        echo "  After 3 minutes, verify cloud ping:"
        echo "    screen -r mt5-3000"
        echo "    (look for: Network server agentX.mql5.net ping XX ms)"
        echo "    Also check: https://cloud.mql5.com"
        echo ""
        echo "  NOTE: mt5setup.exe is downloaded fresh on every run."
        echo "============================================="

        # --- RAM CACHE CLEAR — runs here, AFTER agents are confirmed online ---
        echo ""
        echo "  Clearing RAM cache now that all agents are up..."
        /usr/local/bin/clear-ram-cache.sh
        echo "  -> RAM cache cleared. Free memory:"
        free -h | grep -E "Mem|Swap"
        exit 0
    fi
    echo "    ...Waiting ($((i*5))s / 300s)..."
    sleep 5
done

echo ""
echo "TIMEOUT: Agents may still be starting up."
echo "  Attach to see live output: screen -r mt5-3000"
echo "  Check all sessions:        screen -ls"
echo ""
echo "  Clearing RAM cache anyway..."
/usr/local/bin/clear-ram-cache.sh
free -h | grep -E "Mem|Swap"
