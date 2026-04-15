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

echo "==> [1/7] NUCLEAR WIPE: Removing broken Wine & old installs..."
sudo killall -9 wine wineserver Xvfb xvfb-run metatester64.exe fluxbox 2>/dev/null || true
for P in $(seq 3000 3100); do
    sudo systemctl stop mt5-agent-$P.service 2>/dev/null || true
    sudo systemctl disable mt5-agent-$P.service 2>/dev/null || true
done
sudo rm -rf /opt/mt5* /tmp/mt5* ~/.wine /root/.wine /home/mt5user/.wine /etc/systemd/system/mt5-agent* 2>/dev/null || true
sudo systemctl daemon-reload

# Purge Ubuntu's broken Wine completely
sudo apt-get remove --purge -y wine* 2>/dev/null || true
sudo apt-get autoremove -y >/dev/null 2>&1 || true

echo "==> [2/7] Installing Official WineHQ Stable (Full COM/OLE Support)..."
sudo dpkg --add-architecture i386
sudo mkdir -pm755 /etc/apt/keyrings
sudo wget -O /etc/apt/keyrings/winehq-archive.key https://dl.winehq.org/wine-builds/winehq.key

# Detect Ubuntu version and add correct repo
UBUNTU_VER=$(lsb_release -cs)
sudo wget -NP /etc/apt/sources.list.d/ "https://dl.winehq.org/wine-builds/ubuntu/dists/$UBUNTU_VER/winehq-$UBUNTU_VER.sources"

sudo apt-get update -y >/dev/null
# THE FIX: Install winehq-stable - the ONLY Wine build with a working COM/OLE/RPC stack
sudo apt-get install -y --install-recommends winehq-stable xvfb wget fluxbox net-tools >/dev/null 2>&1

echo "    -> Confirming Wine version..."
wine --version

echo "==> [3/7] Setting up 64GB Swap & Network..."
if ! swapon --show | grep -q "/swapfile"; then
    sudo fallocate -l 64G /swapfile || sudo dd if=/dev/zero of=/swapfile bs=1M count=65536 status=progress || true
    sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile || true
fi

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

echo "==> [4/7] Creating 'mt5user' & Initializing Wine Environment..."
if ! id "mt5user" &>/dev/null; then
    sudo useradd -m -s /bin/bash mt5user
fi

MASTER_WP="/opt/mt5master"
sudo mkdir -p "$MASTER_WP"
sudo chown -R mt5user:mt5user "$MASTER_WP"

sudo -u mt5user env WINEPREFIX="$MASTER_WP" WINEARCH=win64 WINEDLLOVERRIDES="mscoree,mshtml=" xvfb-run -a wineboot -u >/dev/null 2>&1
echo "    -> Wine prefix created successfully."

echo "==> [5/7] Downloading metatester64.exe..."
MASTER_EX="$MASTER_WP/drive_c/Program Files/MetaTrader 5/metatester64.exe"
sudo -u mt5user mkdir -p "$(dirname "$MASTER_EX")"
sudo -u mt5user wget --show-progress -q -O "$MASTER_EX" \
    "https://github.com/rockitya/mt5-ubuntu-agents.sh/raw/main/metatester64.exe"
sudo -u mt5user chmod +x "$MASTER_EX"

echo "==> [6/7] Deploying Agents..."
SP=3000
EP=$((SP + REQUESTED_CORES - 1))

for P in $(seq $SP $EP); do
    echo "    -> Configuring Agent on port $P..."
    AGENT_WP="/opt/mt5agent-$P"
    sudo cp -r "$MASTER_WP" "$AGENT_WP"
    sudo chown -R mt5user:mt5user "$AGENT_WP"
    AGENT_EX="$AGENT_WP/drive_c/Program Files/MetaTrader 5/metatester64.exe"

    ACCOUNT_FLAG=""
    if [ ! -z "$MQL5_LOGIN" ]; then
        ACCOUNT_FLAG="/account:$MQL5_LOGIN"
        cat <<REG | sudo -u mt5user tee "$AGENT_WP/cloud.reg" >/dev/null
Windows Registry Editor Version 5.00
[HKEY_CURRENT_USER\Software\MetaQuotes\MetaTester]
"Login"="$MQL5_LOGIN"
"SellComputingResources"=dword:00000001
REG
        sudo -u mt5user env WINEPREFIX="$AGENT_WP" WINEARCH=win64 WINEDLLOVERRIDES="mscoree,mshtml=" \
            xvfb-run -a wine regedit "$AGENT_WP/cloud.reg" >/dev/null 2>&1

        CONFIG_DIR="$AGENT_WP/drive_c/users/mt5user/AppData/Roaming/MetaQuotes/Tester"
        sudo -u mt5user mkdir -p "$CONFIG_DIR"
        cat <<INI | sudo -u mt5user tee "$CONFIG_DIR/metatester.ini" >/dev/null
[Tester]
Port=$P
Password=$PW
[Cloud]
Login=$MQL5_LOGIN
SellComputingResources=1
INI
    fi

    # Launch script using Xvfb + fluxbox for stable OLE/COM binding
    LAUNCH_SCRIPT="/opt/mt5agent-$P/launch.sh"
    cat << EOF | sudo tee "$LAUNCH_SCRIPT" >/dev/null
#!/bin/bash
export WINEPREFIX="$AGENT_WP"
export WINEARCH=win64
export WINEDLLOVERRIDES="mscoree,mshtml="
fluxbox &
sleep 2
exec wine "$AGENT_EX" /address:0.0.0.0:$P /password:$PW $ACCOUNT_FLAG
EOF
    sudo chmod +x "$LAUNCH_SCRIPT"
    sudo chown mt5user:mt5user "$LAUNCH_SCRIPT"

    cat << EOF | sudo tee /etc/systemd/system/mt5-agent-$P.service >/dev/null
[Unit]
Description=MT5 Strategy Tester Agent on Port $P
After=network.target

[Service]
Type=simple
User=mt5user
Group=mt5user
LimitNOFILE=65536
ExecStart=/usr/bin/xvfb-run --auto-servernum --server-args="-screen 0 1024x768x24" $LAUNCH_SCRIPT
Restart=on-failure
RestartSec=15
StartLimitIntervalSec=120
StartLimitBurst=3

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable mt5-agent-$P.service >/dev/null 2>&1
    sudo systemctl reset-failed mt5-agent-$P.service 2>/dev/null || true
    sudo systemctl restart mt5-agent-$P.service
done

echo "==> [7/7] Verifying Agent Status (Waiting up to 90s)..."
for i in {1..18}; do
    if ss -tuln | grep -q ":3000"; then
        echo ""
        echo "========================================="
        echo "✓ SUCCESS! Agents are active!"
        ss -tuln | grep -E "30[0-9]{2}" | awk '{print $5}'
        echo "========================================="
        [ ! -z "$MQL5_LOGIN" ] && echo "Cloud Selling: ENABLED for '$MQL5_LOGIN'"
        echo "Watch logs: sudo journalctl -u mt5-agent-3000 -f"
        echo "========================================="
        exit 0
    fi
    echo "    ...Waiting ($((i*5))s)..."
    sleep 5
done

echo "❌ TIMEOUT. Last logs:"
sudo journalctl -u mt5-agent-3000 --no-pager -n 30
