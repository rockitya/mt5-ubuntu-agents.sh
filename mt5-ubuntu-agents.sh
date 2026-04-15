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

echo "==> [1/6] Cleaning up old installations..."
for P in $(seq 3000 3100); do sudo systemctl stop mt5-agent-$P.service 2>/dev/null || true; sudo systemctl disable mt5-agent-$P.service 2>/dev/null || true; done
sudo apt-get remove --purge -y wine* xvfb >/dev/null 2>&1 || true
sudo apt-get autoremove -y >/dev/null 2>&1 || true
sudo rm -rf /opt/mt5agent-* /opt/mt5master >/dev/null 2>&1 || true

echo "==> [2/6] Installing Docker..."
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com | sudo sh >/dev/null 2>&1
fi
sudo systemctl enable docker >/dev/null 2>&1
sudo systemctl start docker >/dev/null 2>&1

echo "==> [3/6] Creating 64GB Swap File (Max RAM Protection)..."
if swapon --show | grep -q "/swapfile"; then
    echo "    Swap active. Skipping."
else
    echo "    Allocating 64GB of disk space..."
    sudo fallocate -l 64G /swapfile || sudo dd if=/dev/zero of=/swapfile bs=1M count=65536 status=progress || true
    sudo chmod 600 /swapfile || true
    sudo mkswap /swapfile || true
    sudo swapon /swapfile || true
    if ! grep -q "/swapfile none swap" /etc/fstab; then
        echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null || true
    fi
fi

echo "==> [4/6] Optimizing Host Network..."
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

echo "==> [5/6] Pulling Pre-Built Docker Image (No building required)..."
# We bypass the build hang by pulling the pre-made image directly
sudo docker pull gmag11/metatrader5-docker:latest >/dev/null 2>&1

echo "==> [6/6] Deploying Cloud Agents..."
SP=3000
EP=$((SP + REQUESTED_CORES - 1))

for P in $(seq $SP $EP); do
    echo "    -> Spinning up Agent Container on port $P..."
    DIR="/opt/mt5-configs/node_$P"
    sudo mkdir -p "$DIR"
    
    # Generate the absolute source-of-truth config file
    cat <<INI | sudo tee "$DIR/config.ini" >/dev/null
[Tester]
Port=$P
Password=$PW
[Cloud]
Login=$MQL5_LOGIN
SellComputingResources=1
INI

    # Stop any existing container on this port
    sudo docker rm -f mt5-agent-$P >/dev/null 2>&1 || true
    
    # Launch the agent using the pre-built image
    sudo docker run -d \
        --name mt5-agent-$P \
        --net=host \
        --restart=always \
        --memory="2g" \
        -v "$DIR/config.ini:/root/.wine/drive_c/users/root/AppData/Roaming/MetaQuotes/Tester/metatester.ini" \
        gmag11/metatrader5-docker:latest \
        /bin/bash -c "wine C:\\\\Program\\ Files\\\\MetaTrader\\ 5\\\\metatester64.exe /config:C:\\\\users\\\\root\\\\AppData\\\\Roaming\\\\MetaQuotes\\\\Tester\\\\metatester.ini" >/dev/null 2>&1
done

echo "==> Finalizing..."
sudo sync; sudo sysctl -w vm.drop_caches=3 > /dev/null 2>&1
sleep 6

echo ""
echo "========================================="
echo "✓ SUCCESS! Dockerized Agents are active!"
sudo docker ps --format "table {{.Names}}\t{{.Status}}"
echo "========================================="
echo "VPS IP  : $(hostname -I | awk '{print $1}')"
echo "Password: $PW"
if [ ! -z "$MQL5_LOGIN" ]; then
    echo "Cloud Selling: ENABLED for account '$MQL5_LOGIN'"
fi
echo "========================================="
echo "Wait 2 minutes, then view the cloud connection logs using:"
echo "sudo docker logs -f mt5-agent-3000"
