#!/bin/bash
set -e

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

PW=${2:-"MetaTester"}
MQL5_LOGIN=$3

export DEBIAN_FRONTEND=noninteractive

echo "==> [1/8] NUCLEAR WIPE: Uninstalling all old MetaTester instances..."
# 1. Stop all Docker processes to free up files
if command -v docker &> /dev/null; then
    sudo docker rm -f $(sudo docker ps -aq) >/dev/null 2>&1 || true
    sudo docker rmi -f mt5-cloud-agent >/dev/null 2>&1 || true
    sudo docker system prune -af --volumes >/dev/null 2>&1 || true
fi

# 2. Stop all lingering Linux background services
for P in $(seq 3000 3100); do sudo systemctl stop mt5-agent-$P.service 2>/dev/null || true; sudo systemctl disable mt5-agent-$P.service 2>/dev/null || true; done

# 3. Explicitly hunt down and kill any rogue metatester64.exe processes
sudo killall -9 wineserver metatester64.exe wine xvfb-run >/dev/null 2>&1 || true

# 4. Physically delete all MetaTrader installation folders and Wine prefixes across the system
sudo rm -rf /opt/mt5* /tmp/mt5* ~/.wine /root/.wine /etc/systemd/system/mt5-agent* >/dev/null 2>&1 || true
sudo rm -rf "/opt/mt5master" "/opt/mt5agent-"* "/root/mt5-agents" >/dev/null 2>&1 || true

# 5. Uninstall Wine to guarantee a blank slate
sudo apt-get remove --purge -y wine* xvfb winbind >/dev/null 2>&1 || true
sudo apt-get autoremove -y >/dev/null 2>&1 || true

echo "==> [2/8] Installing fresh Docker Engine..."
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com | sudo sh >/dev/null 2>&1
fi
sudo systemctl enable docker >/dev/null 2>&1 || true
sudo systemctl start docker >/dev/null 2>&1 || true

echo "==> [3/8] Creating 64GB Swap File (Max RAM Protection)..."
if swapon --show | grep -q "/swapfile"; then
    echo "    Swap active. Skipping."
else
    echo "    Allocating 64GB of disk space (This may take a few minutes)..."
    sudo fallocate -l 64G /swapfile || sudo dd if=/dev/zero of=/swapfile bs=1M count=65536 status=progress || true
    sudo chmod 600 /swapfile || true
    sudo mkswap /swapfile || true
    sudo swapon /swapfile || true
    if ! grep -q "/swapfile none swap" /etc/fstab; then
        echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null || true
    fi
fi

echo "==> [4/8] Optimizing Host Network..."
cat <<EOF | sudo tee /etc/sysctl.d/99-mt5-network.conf >/dev/null
net.ipv4.tcp_keepalive_time=60
net.ipv4.tcp_keepalive_intvl=10
net.ipv4.tcp_keepalive_probes=6
net.ipv4.tcp_fin_timeout=30
net.core.somaxconn=1024
fs.file-max=1000000
vm.swappiness=60
EOF
sudo sysctl -p /etc/sysctl.d/99-mt5-network.conf >/dev/null 2>&1 || true

echo "==> [5/8] Downloading Custom Agent from GitHub..."
mkdir -p /tmp/mt5-docker-build
cd /tmp/mt5-docker-build

wget -q -O metatester64.exe "https://raw.githubusercontent.com/rockitya/mt5-ubuntu-agents.sh/main/metatester64.exe"

echo "==> [6/8] Writing Strict Foreground Container..."
# THE FIX: Removed the buggy 'run.sh' bash loop. 
# We now tell Docker to execute metatester64.exe directly as its main, blocking PID 1 process.
cat << 'EOF' > Dockerfile
FROM ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive
ENV WINEARCH=win64
ENV WINEDEBUG=-all
RUN dpkg --add-architecture i386 && \
    apt-get update -yqq && \
    apt-get install -yqq wine64 wine32 xvfb winbind net-tools && \
    rm -rf /var/lib/apt/lists/*

RUN mkdir -p /mt5
COPY metatester64.exe /mt5/metatester64.exe
RUN chmod +x /mt5/metatester64.exe

# Execute natively in the foreground so the container never exits
ENTRYPOINT ["xvfb-run", "-a", "wine", "/mt5/metatester64.exe", "/config:Z:\\mt5\\config.ini"]
EOF

echo "==> [7/8] Building the Docker image (Logs enabled)..."
sudo docker build --network=host -t mt5-cloud-agent .
cd ~

echo "==> [8/8] Deploying Containerized Cloud Agents..."
SP=3000
EP=$((SP + REQUESTED_CORES - 1))

for P in $(seq $SP $EP); do
    echo "    -> Spinning up Agent Container on port $P..."
    DIR="/opt/mt5-configs/node_$P"
    sudo mkdir -p "$DIR"
    
    cat <<INI | sudo tee "$DIR/config.ini" >/dev/null
[Tester]
Port=$P
Password=$PW
[Cloud]
Login=$MQL5_LOGIN
SellComputingResources=1
INI

    # Docker runs it safely in the background (-d), but INSIDE the container it runs in the foreground.
    sudo docker run -d \
        --name mt5-agent-$P \
        --net=host \
        --restart=always \
        --memory="2g" \
        -v "$DIR/config.ini:/mt5/config.ini" \
        mt5-cloud-agent >/dev/null 2>&1
done

sudo sync; sudo sysctl -w vm.drop_caches=3 > /dev/null 2>&1
sleep 6

echo ""
echo "========================================="
echo "✓ SUCCESS! Dockerized Agents are ACTIVE AND RUNNING!"
sudo docker ps --format "table {{.Names}}\t{{.Status}}"
echo "========================================="
echo "VPS IP  : $(hostname -I | awk '{print $1}')"
echo "Password: $PW"
if [ ! -z "$MQL5_LOGIN" ]; then
    echo "Cloud Selling: ENABLED for account '$MQL5_LOGIN'"
fi
echo "========================================="
echo "To watch the live cloud connection logs, type:"
echo "sudo docker logs -f mt5-agent-3000"
