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

echo "==> [1/9] NUCLEAR WIPE: Erasing all old installations and modules..."
# Disable Firewall
sudo ufw disable >/dev/null 2>&1 || true
sudo iptables -F >/dev/null 2>&1 || true

# Stop Auto-Updates to free dpkg
sudo systemctl stop apt-daily.timer 2>/dev/null || true
sudo systemctl stop apt-daily-upgrade.timer 2>/dev/null || true
sudo systemctl stop unattended-upgrades.service 2>/dev/null || true
while sudo fuser /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend /var/cache/apt/archives/lock >/dev/null 2>&1; do
    sleep 2
done
sudo dpkg --configure -a >/dev/null 2>&1 || true

# Stop and wipe all existing Docker containers and images
if command -v docker &> /dev/null; then
    sudo docker rm -f $(sudo docker ps -aq) >/dev/null 2>&1 || true
    sudo docker rmi -f mt5-cloud-agent >/dev/null 2>&1 || true
    sudo docker system prune -af --volumes >/dev/null 2>&1 || true
fi

# Erase all old SystemD services, Host Wine, and MT5 directories
for P in $(seq 3000 3100); do sudo systemctl stop mt5-agent-$P.service 2>/dev/null || true; sudo systemctl disable mt5-agent-$P.service 2>/dev/null || true; done
sudo apt-get remove --purge -y wine* xvfb winbind >/dev/null 2>&1 || true
sudo apt-get autoremove -y >/dev/null 2>&1 || true
sudo rm -rf /opt/mt5* /tmp/mt5* ~/.wine /root/.wine /etc/systemd/system/mt5-agent* >/dev/null 2>&1 || true

echo "==> [2/9] Installing fresh Docker Engine..."
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com | sudo sh >/dev/null 2>&1
fi
sudo systemctl enable docker >/dev/null 2>&1 || true
sudo systemctl start docker >/dev/null 2>&1 || true

echo "==> [3/9] Creating 64GB Swap File (Max RAM Protection)..."
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

echo "==> [4/9] Optimizing Host Network..."
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

echo "==> [5/9] Downloading Custom Agent from GitHub..."
mkdir -p /tmp/mt5-docker-build
cd /tmp/mt5-docker-build

wget -q -O metatester64.exe "https://raw.githubusercontent.com/rockitya/mt5-ubuntu-agents.sh/main/metatester64.exe"

echo "==> [6/9] Writing Container keep-alive script..."
# THE FIX: This wrapper script prevents the container from shutting down 
# when Wine pushes the agent into the background.
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
RUN xvfb-run -a wineboot -u

RUN echo '#!/bin/bash' > /mt5/run.sh && \
    echo 'touch /mt5/agent.log' >> /mt5/run.sh && \
    echo 'xvfb-run -a wine /mt5/metatester64.exe /config:Z:\\mt5\\config.ini > /mt5/agent.log 2>&1 &' >> /mt5/run.sh && \
    echo 'echo "Agent running in background. Streaming logs..."' >> /mt5/run.sh && \
    echo 'sleep 2' >> /mt5/run.sh && \
    echo 'tail -f /mt5/agent.log' >> /mt5/run.sh && \
    chmod +x /mt5/run.sh

ENTRYPOINT ["/mt5/run.sh"]
EOF

echo "==> [7/9] Building the Docker image..."
sudo docker build -t mt5-cloud-agent . >/dev/null 2>&1
cd ~

echo "==> [8/9] Deploying Containerized Cloud Agents..."
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

    # Launch Docker mapped directly to the Host network
    sudo docker run -d \
        --name mt5-agent-$P \
        --net=host \
        --restart=always \
        --memory="2g" \
        -v "$DIR/config.ini:/mt5/config.ini" \
        mt5-cloud-agent >/dev/null 2>&1
done

echo "==> [9/9] Finalizing..."
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
