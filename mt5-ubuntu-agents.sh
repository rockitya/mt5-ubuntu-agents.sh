#!/bin/bash
set -euo pipefail

# ============================================================
# MT5 TWO-PHASE CLOUD AGENT SETUP
# Phase 1: Install Wine, WARP, Swap, ZRAM, MetaTester
#          → Start agents in local-only mode
# Phase 2: Enable cloud selling separately
#          → /opt/mt5/cloud-on.sh YOUR_MQL5_LOGIN
#
# Usage:
#   bash mt5-ubuntu-agents.sh [AGENTS] [PASSWORD]
# Example:
#   bash mt5-ubuntu-agents.sh 7 Prem@1996
#
# After setup completes:
#   Enable cloud:  /opt/mt5/cloud-on.sh rcktya
#   Disable cloud: /opt/mt5/cloud-off.sh
#   Check ping:    /opt/mt5/show-ping.sh
#   Restart all:   /opt/mt5/start-all.sh
# ============================================================

export DEBIAN_FRONTEND=noninteractive

AGENTS="${1:-7}"
PW="${2:-MetaTester}"

TOTAL_CORES=$(nproc)
USABLE_CORES=$(( TOTAL_CORES > 1 ? TOTAL_CORES - 1 : 1 ))

[ "$AGENTS" -gt "$USABLE_CORES" ] && AGENTS="$USABLE_CORES"
[ "$AGENTS" -lt 1 ] && AGENTS=1

SP=3000
EP=$((SP + AGENTS - 1))

# ────────────────────────────────────────────────────────────
# HELPERS
# ────────────────────────────────────────────────────────────
cleanup_all() {
    pkill -9 -f metatester64 2>/dev/null || true
    pkill -9 -f wineserver   2>/dev/null || true
    pkill -9 -f Xvfb         2>/dev/null || true
    screen -ls 2>/dev/null | awk '/\.mt5-/{print $1}' \
        | xargs -r -I{} screen -S {} -X quit 2>/dev/null || true
    screen -wipe 2>/dev/null || true
    rm -f /tmp/.X*-lock /tmp/.X11-unix/X* 2>/dev/null || true
}

ensure_warp() {
    warp-cli --accept-tos registration new >/dev/null 2>&1 || true
    warp-cli --accept-tos register        >/dev/null 2>&1 || true
    warp-cli --accept-tos connect         >/dev/null 2>&1 \
        || warp-cli connect >/dev/null 2>&1 || true
    for i in {1..20}; do
        warp-cli status 2>/dev/null | grep -qi "Connected" && return 0
        sleep 2
    done
    return 1
}

echo "============================================="
echo " MT5 Two-Phase Agent Setup"
echo " Agents  : $AGENTS"
echo " Cores   : $TOTAL_CORES total / $USABLE_CORES usable"
echo " Ports   : $SP – $EP"
echo "============================================="

# ────────────────────────────────────────────────────────────
# [1/9] CLEANUP
# ────────────────────────────────────────────────────────────
echo "==> [1/9] Cleanup"
cleanup_all
rm -rf /opt/mt5master /opt/mt5agent-* /opt/mt5 2>/dev/null || true
rm -f /tmp/mt5setup.exe 2>/dev/null || true
mkdir -p /opt/mt5
printf '%s' "$PW" > /opt/mt5/agent-password
chmod 600 /opt/mt5/agent-password
echo "    -> Done"

# ────────────────────────────────────────────────────────────
# [2/9] WINE + WARP + TOOLS
# ────────────────────────────────────────────────────────────
echo "==> [2/9] Install WineHQ Devel + Cloudflare WARP + tools"
dpkg --add-architecture i386
mkdir -pm755 /etc/apt/keyrings /usr/share/keyrings
UBUNTU_VER="$(lsb_release -cs)"

wget -q -O /etc/apt/keyrings/winehq-archive.key \
    https://dl.winehq.org/wine-builds/winehq.key
wget -q -NP /etc/apt/sources.list.d/ \
    "https://dl.winehq.org/wine-builds/ubuntu/dists/${UBUNTU_VER}/winehq-${UBUNTU_VER}.sources"

curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
    | gpg --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg

echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] \
https://pkg.cloudflareclient.com/ ${UBUNTU_VER} main" \
    > /etc/apt/sources.list.d/cloudflare-client.list

apt-get update -y >/dev/null
apt-get install -y --install-recommends \
    winehq-devel xvfb screen wget curl rsync cabextract \
    net-tools util-linux procps zram-tools cloudflare-warp >/dev/null

echo "    -> $(wine --version)"

# ────────────────────────────────────────────────────────────
# [3/9] CONNECT WARP
# ────────────────────────────────────────────────────────────
echo "==> [3/9] Connect Cloudflare WARP"
if ensure_warp; then
    EXIT_IP="$(curl -s --max-time 10 https://cloudflare.com/cdn-cgi/trace \
        2>/dev/null | awk -F= '/^ip=/{print $2}')"
    echo "    -> WARP connected | Exit IP: ${EXIT_IP:-unknown}"
else
    echo "    WARNING: WARP not confirmed – continuing anyway"
fi

# ────────────────────────────────────────────────────────────
# [4/9] 64GB SWAP + ZRAM
# ────────────────────────────────────────────────────────────
echo "==> [4/9] Setup 64GB Swap + ZRAM"
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

echo "    -> Free disk : ${AVAIL_GB}G"
echo "    -> Swap size : ${SWAP_GB}G"

if fallocate -l "${SWAP_GB}G" /swapfile 2>/dev/null; then
    echo "    -> fallocate ok"
else
    echo "    -> fallocate failed – using dd (slower)"
    dd if=/dev/zero of=/swapfile bs=1M count="$SWAP_MB" status=progress
fi

ACTUAL=$(stat -c%s /swapfile 2>/dev/null || echo 0)
EXPECTED=$(( SWAP_MB * 1024 * 1024 ))
if [ "$ACTUAL" -lt "$EXPECTED" ]; then
    echo "    ERROR: Swap file only $(du -sh /swapfile | cut -f1) – check df -h /"
else
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    echo "    -> Swap active:"
    free -h | grep Swap
fi

# ZRAM – compressed RAM from remaining memory
cat > /etc/default/zramswap <<'EOF'
ALGO=lz4
PERCENT=50
PRIORITY=100
EOF
systemctl enable zramswap >/dev/null 2>&1 || true
systemctl restart zramswap >/dev/null 2>&1 || true

# Kernel tuning
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

echo "    -> Full memory state:"
free -h   || true
swapon --show || true
zramctl   || true

# ────────────────────────────────────────────────────────────
# [5/9] RAM CLEANER (runs at end, cron every 30 min)
# ────────────────────────────────────────────────────────────
echo "==> [5/9] Create RAM cache cleaner"
cat > /usr/local/bin/clear-ram-cache.sh <<'EOF'
#!/bin/bash
sync
echo 1 > /proc/sys/vm/drop_caches
EOF
chmod +x /usr/local/bin/clear-ram-cache.sh
(crontab -l 2>/dev/null | grep -v clear-ram-cache || true; \
    echo "*/30 * * * * /usr/local/bin/clear-ram-cache.sh") | crontab -
echo "    -> Cron every 30 min (runs AFTER agents start)"

# ────────────────────────────────────────────────────────────
# [6/9] DOWNLOAD mt5setup.exe FRESH
# ────────────────────────────────────────────────────────────
echo "==> [6/9] Download mt5setup.exe (fresh every run via WARP)"
SETUP_FILE="/tmp/mt5setup.exe"
MT5_CDN="https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe"
rm -f "$SETUP_FILE" 2>/dev/null || true

wget -q --show-progress "$MT5_CDN" -O "$SETUP_FILE" 2>&1 \
    || curl -L --progress-bar "$MT5_CDN" -o "$SETUP_FILE"

FILESIZE="$(stat -c%s "$SETUP_FILE" 2>/dev/null || echo 0)"
if [ "$FILESIZE" -lt 100000 ]; then
    echo ""
    echo "ERROR: Download failed (${FILESIZE} bytes)"
    echo "  WARP status : warp-cli status"
    echo "  Reconnect   : warp-cli disconnect && warp-cli connect"
    echo "  Manual SCP  : scp mt5setup.exe root@$(hostname -I | awk '{print $1}'):/tmp/mt5setup.exe"
    exit 1
fi
echo "    -> Downloaded: $(du -sh "$SETUP_FILE" | cut -f1)"

# ────────────────────────────────────────────────────────────
# [7/9] INSTALL MASTER MT5 WINE PREFIX
# ────────────────────────────────────────────────────────────
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
ensure_warp || true

echo "    -> Running MetaTester installer (up to 10 min)..."
DISPLAY=:90 wine "$SETUP_FILE" /auto >/tmp/mt5-install.log 2>&1 &
INSTALL_PID=$!

FOUND=0
for i in {1..120}; do
    # Re-check WARP every 60s during install
    if [ $(( i % 12 )) -eq 0 ]; then
        if ! warp-cli status 2>/dev/null | grep -qi "Connected"; then
            echo "    WARNING: WARP dropped – reconnecting..."
            warp-cli disconnect >/dev/null 2>&1 || true
            sleep 2
            warp-cli connect   >/dev/null 2>&1 || true
            sleep 5
        fi
    fi

    if find "$WINEPREFIX" -name "metatester64.exe" 2>/dev/null | grep -q .; then
        FOUND=1
        echo "    -> metatester64.exe found after $((i*5))s – waiting 15s..."
        sleep 15
        break
    fi
    echo "    ...Installing ($((i*5))s / 600s)..."
    sleep 5
done

kill "$INSTALL_PID"      2>/dev/null || true
wait "$INSTALL_PID"      2>/dev/null || true
kill "$XVFB_MASTER_PID"  2>/dev/null || true
wait "$XVFB_MASTER_PID"  2>/dev/null || true
rm -f /tmp/.X90-lock /tmp/.X11-unix/X90 2>/dev/null || true

MT5_DIR="$(find "$WINEPREFIX" -name metatester64.exe -exec dirname {} \; 2>/dev/null | head -1 || true)"
if [ -z "$MT5_DIR" ] || [ "$FOUND" -ne 1 ]; then
    echo "ERROR: MetaTester install failed – metatester64.exe not found"
    echo "---- install log ----"
    tail -n 60 /tmp/mt5-install.log || true
    exit 1
fi
echo "    -> Installed at: $MT5_DIR"

# Clear Cloud.Ping cache on master
wine reg delete "HKCU\\Software\\MetaQuotes Software\\Cloud.Ping" \
    /f >/dev/null 2>&1 || true

# ────────────────────────────────────────────────────────────
# [8/9] CLONE AGENTS + GENERATE ALL HELPER SCRIPTS
# ────────────────────────────────────────────────────────────
echo "==> [8/9] Clone agent prefixes + generate helper scripts"
mkdir -p /opt/mt5
rm -f /opt/mt5/cloud-login /opt/mt5/cloud-enabled 2>/dev/null || true

# ── start-all.sh ───────────────────────────────────────────
cat > /opt/mt5/start-all.sh <<EOF
#!/bin/bash
pkill -9 -f metatester64 2>/dev/null || true
pkill -9 -f wineserver   2>/dev/null || true
pkill -9 -f Xvfb         2>/dev/null || true
screen -ls 2>/dev/null | awk '/\\.mt5-/{print \$1}' \\
    | xargs -r -I{} screen -S {} -X quit 2>/dev/null || true
screen -wipe 2>/dev/null || true
rm -f /tmp/.X*-lock /tmp/.X11-unix/X* 2>/dev/null || true
warp-cli connect >/dev/null 2>&1 || true
sleep 5
ulimit -n 100000
for P in \$(seq $SP $EP); do
    screen -dmS "mt5-\$P" bash "/opt/mt5/run-agent-\$P.sh"
    echo "  -> Started agent \$P"
done
EOF
chmod +x /opt/mt5/start-all.sh

# ── cloud-on.sh ────────────────────────────────────────────
cat > /opt/mt5/cloud-on.sh <<'CLOUDON'
#!/bin/bash
set -euo pipefail
LOGIN="${1:-}"
if [ -z "$LOGIN" ]; then
    echo "Usage: /opt/mt5/cloud-on.sh MQL5_LOGIN"
    echo "Example: /opt/mt5/cloud-on.sh rcktya"
    exit 1
fi

echo "$LOGIN" > /opt/mt5/cloud-login
touch /opt/mt5/cloud-enabled
chmod 600 /opt/mt5/cloud-login /opt/mt5/cloud-enabled

PW="$(cat /opt/mt5/agent-password)"

for AGENT_WP in /opt/mt5agent-*; do
    P="$(basename "$AGENT_WP" | sed 's/mt5agent-//')"
    CFG_DIR="$AGENT_WP/drive_c/users/Public/AppData/Roaming/MetaQuotes/Tester"
    mkdir -p "$CFG_DIR"

    WINEPREFIX="$AGENT_WP" WINEARCH=win64 WINEDEBUG=-all \
    wine reg add "HKCU\\Software\\MetaQuotes\\MetaTester" \
        /v "Login" /t REG_SZ /d "$LOGIN" /f >/dev/null 2>&1 || true

    WINEPREFIX="$AGENT_WP" WINEARCH=win64 WINEDEBUG=-all \
    wine reg add "HKCU\\Software\\MetaQuotes\\MetaTester" \
        /v "SellComputingResources" /t REG_DWORD /d "1" /f >/dev/null 2>&1 || true

    cat > "$CFG_DIR/metatester.ini" <<CFGEOF
[Tester]
Port=$P
Password=$PW

[Cloud]
Login=$LOGIN
SellComputingResources=1
CFGEOF
    chmod 600 "$CFG_DIR/metatester.ini"

    WINEPREFIX="$AGENT_WP" WINEARCH=win64 WINEDEBUG=-all \
    wine reg delete "HKCU\\Software\\MetaQuotes Software\\Cloud.Ping" \
        /f >/dev/null 2>&1 || true

    echo "  -> Agent $P configured for cloud (login: $LOGIN)"
done

/opt/mt5/start-all.sh
sleep 20

echo ""
echo "Cloud mode enabled for: $LOGIN"
echo "Check:   /opt/mt5/show-ping.sh"
echo "Watch:   screen -r mt5-3000"
echo "Website: https://cloud.mql5.com/en/agents"
CLOUDON
chmod +x /opt/mt5/cloud-on.sh

# ── cloud-off.sh ───────────────────────────────────────────
cat > /opt/mt5/cloud-off.sh <<'CLOUDOFF'
#!/bin/bash
rm -f /opt/mt5/cloud-login /opt/mt5/cloud-enabled 2>/dev/null || true
/opt/mt5/start-all.sh
echo "Cloud mode disabled – agents restarted in local-only mode."
CLOUDOFF
chmod +x /opt/mt5/cloud-off.sh

# ── show-ping.sh ───────────────────────────────────────────
cat > /opt/mt5/show-ping.sh <<EOF
#!/bin/bash
for P in \$(seq $SP $EP); do
    echo "=== Agent \$P ==="
    screen -S mt5-\$P -X hardcopy /tmp/mt5-\$P.txt 2>/dev/null || true
    grep -iv "fixme\\|stub\\|warn\\|0x" /tmp/mt5-\$P.txt 2>/dev/null \
        | grep -i "ping\\|cloud\\|connect\\|server\\|login\\|start\\|network" \
        | tail -8 || echo "  (no output yet)"
    echo ""
done
EOF
chmod +x /opt/mt5/show-ping.sh

# ── Per-agent run scripts ───────────────────────────────────
for P in $(seq "$SP" "$EP"); do
    IDX=$((P - SP))
    CORE=$((IDX % USABLE_CORES))
    DISP=$((100 + IDX))
    AGENT_WP="/opt/mt5agent-$P"

    echo "    -> Cloning prefix for agent $P (core $CORE, display :$DISP)..."
    rsync -a --exclude='*.lock' "$WINEPREFIX/" "$AGENT_WP/"

    AGENT_EX="$(find "$AGENT_WP" -name metatester64.exe 2>/dev/null | head -1)"
    if [ -z "$AGENT_EX" ]; then
        echo "ERROR: metatester64.exe missing in $AGENT_WP"
        exit 1
    fi
    AGENT_WIN_EX="$(echo "$AGENT_EX" | sed "s|$AGENT_WP/drive_c|C:|" | sed 's|/|\\|g')"

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
sleep 2

warp-cli connect >/dev/null 2>&1 || true
sleep 2

# CPU-affinity trick — pins to 1 core, hides extra cores from Wine
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
 echo "@reboot sleep 45 && warp-cli connect && sleep 5 && /opt/mt5/start-all.sh") | crontab -
echo "    -> @reboot cron added"

# ────────────────────────────────────────────────────────────
# [9/9] START AGENTS (LOCAL-ONLY MODE)
# ────────────────────────────────────────────────────────────
echo "==> [9/9] Starting agents in LOCAL-ONLY mode"
rm -f /opt/mt5/cloud-enabled /opt/mt5/cloud-login 2>/dev/null || true
/opt/mt5/start-all.sh

ONLINE=0
for i in {1..60}; do
    COUNT=0
    for P in $(seq "$SP" "$EP"); do
        ss -tuln 2>/dev/null | grep -q ":$P " && COUNT=$((COUNT+1)) || true
    done
    if [ "$COUNT" -ge 1 ]; then
        ONLINE="$COUNT"
        break
    fi
    echo "    ...Waiting ($((i*5))s / 300s)..."
    sleep 5
done

echo "============================================="
echo " LOCAL-ONLY AGENTS ONLINE: $ONLINE / $AGENTS"
for P in $(seq "$SP" "$EP"); do
    if ss -tuln 2>/dev/null | grep -q ":$P "; then
        echo "   Port $P: UP"
    else
        echo "   Port $P: DOWN"
    fi
done
echo "============================================="

echo
echo "Memory state after launch:"
free -h || true
swapon --show || true
zramctl || true

echo
echo "Clearing RAM cache now that agents are up..."
/usr/local/bin/clear-ram-cache.sh || true
free -h || true

echo
cat <<DONE
============================================
 SETUP COMPLETE — PHASE 1 DONE
============================================

 Agents are running in local-only mode.
 Verify they are healthy BEFORE enabling cloud.

 COMMANDS:
   screen -ls                          List all agent sessions
   screen -r mt5-3000                  Watch agent live (Ctrl+A D to detach)
   ss -tuln | grep -E "300[0-9]"       Port status
   /opt/mt5/show-ping.sh               Cloud ping check

 PHASE 2 — Enable cloud selling:
   /opt/mt5/cloud-on.sh rcktya         Enable cloud with your MQL5 login
   /opt/mt5/cloud-off.sh               Disable cloud (local-only again)

 After cloud-on.sh, check:
   https://cloud.mql5.com/en/agents    Verify agents online (green)

 NOTES:
   - Swap    : ${SWAP_GB}GB active on /swapfile
   - ZRAM    : 50% compressed RAM via lz4
   - WARP    : Cloudflare IP bypass active
   - CPU     : taskset + NUMBER_OF_PROCESSORS=1 per agent
   - @reboot : /opt/mt5/start-all.sh auto-runs on reboot
============================================
DONE
