#!/bin/bash
# ============================================================
# MT5 DOCKER-BASED CLOUD AGENT SETUP
# Each agent runs in its own isolated Docker container
# No Xvfb lock conflicts, no Wine prefix clashes
#
# Usage:
#   bash mt5-docker-agents.sh [AGENTS] [PASSWORD]
# Example:
#   bash mt5-docker-agents.sh 7 Prem@1996
#
# After setup:
#   Enable cloud:  /opt/mt5/cloud-on.sh rcktya
#   Disable cloud: /opt/mt5/cloud-off.sh
#   Status:        /opt/mt5/status.sh
#   Logs:          docker logs mt5-agent-3000 -f
# ============================================================

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

AGENTS="${1:-7}"
PW="${2:-MetaTester}"
SP=3000
EP=$((SP + AGENTS - 1))
MT5_CDN="https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe"
IMAGE_NAME="mt5-agent"

echo "============================================="
echo " MT5 Docker Agent Setup"
echo " Agents : $AGENTS | Ports: $SP-$EP"
echo "============================================="

# ── [1/7] INSTALL DOCKER + WARP ──────────────────────────
echo "==> [1/7] Install Docker + Cloudflare WARP"

if ! command -v docker &>/dev/null; then
    curl -fsSL https://get.docker.com | bash
    systemctl enable docker
    systemctl start docker
    echo "    -> Docker installed: $(docker --version)"
else
    echo "    -> Docker already installed: $(docker --version)"
fi

UBUNTU_VER="$(lsb_release -cs)"
mkdir -pm755 /usr/share/keyrings

curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
    | gpg --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg

echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] \
https://pkg.cloudflareclient.com/ ${UBUNTU_VER} main" \
    > /etc/apt/sources.list.d/cloudflare-client.list

apt-get update -y >/dev/null
apt-get install -y cloudflare-warp >/dev/null

warp-cli --accept-tos registration new >/dev/null 2>&1 || true
warp-cli --accept-tos register        >/dev/null 2>&1 || true
warp-cli connect                       >/dev/null 2>&1 || true
sleep 5

EXIT_IP="$(curl -s --max-time 10 https://cloudflare.com/cdn-cgi/trace \
    2>/dev/null | awk -F= '/^ip=/{print $2}' || echo unknown)"
echo "    -> WARP exit IP: $EXIT_IP"

# ── [2/7] SETUP 64GB SWAP + ZRAM ─────────────────────────
echo "==> [2/7] Setup 64GB Swap + ZRAM"
swapoff -a 2>/dev/null || true
sed -i '\|/swapfile none swap sw 0 0|d' /etc/fstab 2>/dev/null || true
rm -f /swapfile 2>/dev/null || true

AVAIL_GB="$(df -BG / | awk 'NR==2{gsub("G","",$4); print $4}')"
SWAP_GB=$(( AVAIL_GB >= 68 ? 64 : (AVAIL_GB > 6 ? AVAIL_GB - 4 : 2) ))
SWAP_MB=$((SWAP_GB * 1024))

echo "    -> Free disk: ${AVAIL_GB}G | Swap: ${SWAP_GB}G"

if fallocate -l "${SWAP_GB}G" /swapfile 2>/dev/null; then
    echo "    -> fallocate ok"
else
    dd if=/dev/zero of=/swapfile bs=1M count="$SWAP_MB" status=progress
fi

ACTUAL=$(stat -c%s /swapfile 2>/dev/null || echo 0)
EXPECTED=$(( SWAP_MB * 1024 * 1024 ))
if [ "$ACTUAL" -ge "$EXPECTED" ]; then
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

apt-get install -y zram-tools >/dev/null 2>&1 || true
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
net.ipv4.tcp_fin_timeout=30
net.core.somaxconn=1024
fs.file-max=1000000
EOF
sysctl -p /etc/sysctl.d/99-mt5.conf >/dev/null 2>&1 || true

echo "    -> Memory:"
free -h | grep -E "Mem|Swap"
zramctl 2>/dev/null || true

# ── [3/7] BUILD DOCKER IMAGE ──────────────────────────────
echo "==> [3/7] Build Docker image (Wine + MT5 base)"
mkdir -p /opt/mt5-docker
printf '%s' "$PW" > /opt/mt5-docker/agent-password
chmod 600 /opt/mt5-docker/agent-password

cat > /opt/mt5-docker/Dockerfile <<'DOCKERFILE'
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV WINEARCH=win64
ENV WINEDEBUG=-all
ENV WINEDLLOVERRIDES=mscoree,mshtml=
ENV NUMBER_OF_PROCESSORS=1

# Base packages + WineHQ
RUN dpkg --add-architecture i386 && \
    apt-get update -y && \
    apt-get install -y wget curl gnupg2 xvfb procps net-tools \
        ca-certificates software-properties-common && \
    mkdir -pm755 /etc/apt/keyrings && \
    wget -q -O /etc/apt/keyrings/winehq-archive.key \
        https://dl.winehq.org/wine-builds/winehq.key && \
    wget -q -NP /etc/apt/sources.list.d/ \
        "https://dl.winehq.org/wine-builds/ubuntu/dists/jammy/winehq-jammy.sources" && \
    apt-get update -y && \
    apt-get install -y --install-recommends winehq-devel && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Init Wine prefix (64-bit)
RUN Xvfb :99 -screen 0 1024x768x24 & \
    sleep 2 && \
    DISPLAY=:99 WINEPREFIX=/root/.wine wineboot -u && \
    sleep 3 && \
    kill %1 2>/dev/null || true

WORKDIR /opt/mt5

# Entrypoint script written at container launch
CMD ["/opt/mt5/run.sh"]
DOCKERFILE

echo "    -> Building Docker image (this takes ~5 min)..."
docker build -t "$IMAGE_NAME" /opt/mt5-docker/ 2>&1 | tail -5

echo "    -> Image built: $(docker images $IMAGE_NAME --format '{{.Size}}')"

# ── [4/7] DOWNLOAD mt5setup.exe ──────────────────────────
echo "==> [4/7] Download mt5setup.exe (via WARP)"
rm -f /opt/mt5-docker/mt5setup.exe 2>/dev/null || true

wget -q --show-progress "$MT5_CDN" -O /opt/mt5-docker/mt5setup.exe 2>&1 || \
    curl -L --progress-bar "$MT5_CDN" -o /opt/mt5-docker/mt5setup.exe

FILESIZE="$(stat -c%s /opt/mt5-docker/mt5setup.exe 2>/dev/null || echo 0)"
if [ "$FILESIZE" -lt 100000 ]; then
    echo "ERROR: Download failed (${FILESIZE} bytes)"
    echo "Check: warp-cli status"
    exit 1
fi
echo "    -> Downloaded: $(du -sh /opt/mt5-docker/mt5setup.exe | cut -f1)"

# ── [5/7] INSTALL MT5 INSIDE BASE CONTAINER ─────────────
echo "==> [5/7] Install MetaTester inside base container"
docker rm -f mt5-installer 2>/dev/null || true

docker run -d --name mt5-installer \
    -v /opt/mt5-docker/mt5setup.exe:/tmp/mt5setup.exe:ro \
    -e DISPLAY=:99 \
    "$IMAGE_NAME" bash -c "
        Xvfb :99 -screen 0 1024x768x24 &
        sleep 2
        wine /tmp/mt5setup.exe /auto
        sleep 120
        find /root/.wine -name metatester64.exe 2>/dev/null
    "

echo "    -> Waiting for MetaTester install inside container (up to 10 min)..."
FOUND=0
for i in {1..120}; do
    if docker exec mt5-installer \
        find /root/.wine -name "metatester64.exe" 2>/dev/null | grep -q .; then
        FOUND=1
        echo "    -> metatester64.exe found after $((i*5))s"
        sleep 15
        break
    fi
    echo "    ...Installing ($((i*5))s / 600s)..."
    sleep 5
done

if [ "$FOUND" -ne 1 ]; then
    echo "ERROR: MetaTester install failed inside container"
    echo "---- container logs ----"
    docker logs mt5-installer 2>&1 | grep -iv "fixme\|stub" | tail -30
    exit 1
fi

# Commit the installed state as a new image
echo "    -> Committing installed MT5 as docker image..."
docker commit mt5-installer "${IMAGE_NAME}-installed"
docker rm -f mt5-installer

MT5_EX="$(docker run --rm "${IMAGE_NAME}-installed" \
    find /root/.wine -name metatester64.exe 2>/dev/null | head -1)"
MT5_WIN_EX="$(echo "$MT5_EX" | sed 's|/root/.wine/drive_c|C:|' | sed 's|/|\\|g')"
echo "    -> MT5 binary: $MT5_WIN_EX"

# ── [6/7] LAUNCH AGENT CONTAINERS ───────────────────────
echo "==> [6/7] Launch $AGENTS agent containers (local-only mode)"
mkdir -p /opt/mt5

# Save for cloud-on.sh
echo "$MT5_WIN_EX" > /opt/mt5/mt5-win-path
printf '%s' "$PW" > /opt/mt5/agent-password
chmod 600 /opt/mt5/agent-password /opt/mt5/mt5-win-path

TOTAL_CORES=$(nproc)
USABLE_CORES=$(( TOTAL_CORES > 1 ? TOTAL_CORES - 1 : 1 ))

# start-all.sh
cat > /opt/mt5/start-all.sh <<EOF
#!/bin/bash
PW="\$(cat /opt/mt5/agent-password)"
MT5_EX="\$(cat /opt/mt5/mt5-win-path)"
CLOUD_ARG=""
if [ -f /opt/mt5/cloud-enabled ] && [ -s /opt/mt5/cloud-login ]; then
    LOGIN="\$(cat /opt/mt5/cloud-login)"
    CLOUD_ARG="/account:\$LOGIN"
fi
warp-cli connect >/dev/null 2>&1 || true

for P in \$(seq $SP $EP); do
    IDX=\$((P - $SP))
    CORE=\$((IDX % $USABLE_CORES))
    docker rm -f "mt5-agent-\$P" 2>/dev/null || true
    docker run -d \\
        --name "mt5-agent-\$P" \\
        --cpuset-cpus="\$CORE" \\
        -p "\$P:\$P" \\
        --restart unless-stopped \\
        -e WINEDEBUG=-all \\
        -e WINEDLLOVERRIDES="mscoree,mshtml=" \\
        -e NUMBER_OF_PROCESSORS=1 \\
        "${IMAGE_NAME}-installed" bash -c "
            Xvfb :1 -screen 0 1024x768x24 &
            sleep 2
            wine '\$MT5_EX' /address:0.0.0.0:\$P /password:'\$PW' \$CLOUD_ARG
        "
    echo "  -> Container mt5-agent-\$P started on CPU core \$CORE"
done
EOF
chmod +x /opt/mt5/start-all.sh

# cloud-on.sh
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
echo "Cloud login set: $LOGIN"
echo "Restarting all agents with cloud mode..."
/opt/mt5/start-all.sh
sleep 20
echo ""
echo "Done. Check logs: docker logs mt5-agent-3000 -f"
echo "Website: https://cloud.mql5.com/en/agents"
CLOUDON
chmod +x /opt/mt5/cloud-on.sh

# cloud-off.sh
cat > /opt/mt5/cloud-off.sh <<'CLOUDOFF'
#!/bin/bash
rm -f /opt/mt5/cloud-login /opt/mt5/cloud-enabled 2>/dev/null || true
/opt/mt5/start-all.sh
echo "Cloud mode disabled."
CLOUDOFF
chmod +x /opt/mt5/cloud-off.sh

# status.sh
cat > /opt/mt5/status.sh <<EOF
#!/bin/bash
echo "=== Docker Agent Status ==="
for P in \$(seq $SP $EP); do
    STATE=\$(docker inspect --format='{{.State.Status}}' "mt5-agent-\$P" 2>/dev/null || echo "missing")
    PORT_OK=\$(ss -tuln 2>/dev/null | grep -c ":\$P " || echo 0)
    echo "  mt5-agent-\$P : state=\$STATE | port=\$([ \$PORT_OK -gt 0 ] && echo UP || echo DOWN)"
done
echo ""
echo "=== Cloud Status ==="
[ -f /opt/mt5/cloud-enabled ] && echo "  Cloud: ENABLED for \$(cat /opt/mt5/cloud-login)" || echo "  Cloud: DISABLED"
echo ""
echo "=== Memory ==="
free -h | grep -E "Mem|Swap"
echo ""
echo "=== WARP ==="
warp-cli status 2>/dev/null || echo "  warp-cli not found"
EOF
chmod +x /opt/mt5/status.sh

# @reboot cron
(crontab -l 2>/dev/null | grep -v '@reboot .*start-all' || true; \
 echo "@reboot sleep 45 && warp-cli connect && sleep 5 && /opt/mt5/start-all.sh") | crontab -

# Start agents now
rm -f /opt/mt5/cloud-enabled /opt/mt5/cloud-login 2>/dev/null || true
/opt/mt5/start-all.sh

# ── [7/7] RAM CLEAN + VERIFY ──────────────────────────────
echo "==> [7/7] Verify + RAM cleanup"

ONLINE=0
for i in {1..60}; do
    COUNT=0
    for P in $(seq "$SP" "$EP"); do
        if ss -tuln 2>/dev/null | grep -q ":$P "; then
            COUNT=$((COUNT+1))
        fi
    done
    if [ "$COUNT" -ge 1 ]; then
        ONLINE="$COUNT"
        break
    fi
    echo "    ...Waiting ($((i*5))s / 300s)..."
    sleep 5
done

cat > /usr/local/bin/clear-ram-cache.sh <<'EOF'
#!/bin/bash
sync
echo 1 > /proc/sys/vm/drop_caches
EOF
chmod +x /usr/local/bin/clear-ram-cache.sh
(crontab -l 2>/dev/null | grep -v clear-ram-cache || true; \
    echo "*/30 * * * * /usr/local/bin/clear-ram-cache.sh") | crontab -
/usr/local/bin/clear-ram-cache.sh

echo "============================================="
echo " DOCKER AGENTS ONLINE: $ONLINE / $AGENTS"
echo "============================================="
for P in $(seq "$SP" "$EP"); do
    if ss -tuln 2>/dev/null | grep -q ":$P "; then
        echo "  mt5-agent-$P: UP"
    else
        echo "  mt5-agent-$P: DOWN"
    fi
done
echo ""
free -h | grep -E "Mem|Swap"
echo ""
cat <<DONE
 COMMANDS:
   docker ps                           List containers
   docker logs mt5-agent-3000 -f       Live logs for agent 3000
   /opt/mt5/status.sh                  All agents status
   /opt/mt5/cloud-on.sh rcktya         Enable cloud selling
   /opt/mt5/cloud-off.sh               Disable cloud
   /opt/mt5/start-all.sh               Restart all agents
   https://cloud.mql5.com/en/agents    Verify on website
============================================
DONE
