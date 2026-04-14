#!/bin/bash

# Read inputs directly from the command line arguments
CORES=$1
PASSWORD=$2
MQL5_LOGIN=$3

if [ -z "$CORES" ] || [ -z "$PASSWORD" ]; then
    echo "Error: Missing required arguments."
    echo "Usage: curl -sSL <github_raw_url> | bash -s <CORES> <PASSWORD> [MQL5_LOGIN]"
    exit 1
fi

echo "========================================================="
echo "      MetaTester 5 Setup (Fully Automatic & Headless)    "
echo "========================================================="
echo "Cores: $CORES | MQL5 Login: ${MQL5_LOGIN:-None}"

# 1. Disable the Firewall completely
echo "---------------------------------------------------------"
echo "Disabling UFW Firewall..."
sudo ufw disable

# 2. Block all interactive popups (Kernel Upgrades/Restarts)
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1

# 3. One-Time RAM Cleanup
echo "---------------------------------------------------------"
echo "Cleaning up RAM Cache..."
sudo sync; sudo sysctl -w vm.drop_caches=3

# 4. Install Dependencies (Silently)
echo "---------------------------------------------------------"
echo "Installing Wine and dependencies (This may take a minute)..."
sudo dpkg --add-architecture i386
sudo -E apt-get update -yq
sudo -E apt-get install -yq wine64 wine32 xvfb tmux wget ufw

# 5. Download metatester64.exe
echo "---------------------------------------------------------"
mkdir -p ~/mt5-agents
cd ~/mt5-agents
echo "Downloading metatester64.exe..."
wget -q -nc -O metatester64.exe "https://raw.githubusercontent.com/rockitya/mt5-ubuntu-agents.sh/main/metatester64.exe"

# 6. Build Agent Nodes
echo "---------------------------------------------------------"
START_PORT=3000
for i in $(seq 1 $CORES); do
    PORT=$((START_PORT + i - 1))
    DIR="$HOME/mt5-agents/node_$PORT"
    
    echo "Configuring Agent on port $PORT..."
    mkdir -p "$DIR"
    cp metatester64.exe "$DIR/"
    
    ACCOUNT_FLAG=""
    if [ ! -z "$MQL5_LOGIN" ]; then
        ACCOUNT_FLAG="/account:$MQL5_LOGIN"
    fi
    
    WINEPREFIX="$DIR" WINEDEBUG=-all xvfb-run -a wine "$DIR/metatester64.exe" /install /address:0.0.0.0:$PORT /password:$PASSWORD $ACCOUNT_FLAG > /dev/null 2>&1
    
    # Inject Registry key for "Sell computing resources"
    if [ ! -z "$MQL5_LOGIN" ]; then
        cat <<REG > "$DIR/cloud.reg"
Windows Registry Editor Version 5.00
[HKEY_CURRENT_USER\Software\MetaQuotes\MetaTester]
"Login"="$MQL5_LOGIN"
"SellComputingResources"=dword:00000001
REG
        WINEPREFIX="$DIR" WINEDEBUG=-all xvfb-run -a wine regedit "$DIR/cloud.reg" > /dev/null 2>&1
    fi
    
    WINEPREFIX="$DIR" wineserver -k > /dev/null 2>&1
    sleep 2
    
    tmux new-session -d -s "agent_$PORT" "WINEPREFIX=\"$DIR\" WINEDEBUG=-all xvfb-run -a wineboot && WINEPREFIX=\"$DIR\" wineserver -w"
    
    echo "✅ Agent running natively on port $PORT"
done

echo "========================================================="
echo "Setup Complete! $CORES Agents are running in the background."
echo "Firewall is OFF. Kernel popups were bypassed."
echo "========================================================="
