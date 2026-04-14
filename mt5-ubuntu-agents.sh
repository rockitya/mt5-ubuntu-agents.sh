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
echo "      MetaTester 5 Setup (Final Application Mode)        "
echo "========================================================="
echo "Cores: $CORES | MQL5 Login: ${MQL5_LOGIN:-None}"

echo "---------------------------------------------------------"
echo "Disabling UFW Firewall..."
sudo ufw disable > /dev/null 2>&1

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1

echo "Installing required packages (wine, xvfb, winbind, tmux)..."
sudo dpkg --add-architecture i386 > /dev/null 2>&1
sudo -E apt-get update -yqq > /dev/null 2>&1
sudo -E apt-get install -yqq wine wine64 wine32 xvfb wget winbind net-tools tmux > /dev/null 2>&1

echo "Downloading official metatester64.exe..."
mkdir -p ~/mt5-agents
cd ~/mt5-agents
wget -q -nc -O metatester64.exe "https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/metatester64.exe"

# Stop all old processes and clear out old tmux sessions
killall -9 wineserver metatester64.exe wine 2>/dev/null
for i in $(tmux ls | awk -F: '{print $1}'); do tmux kill-session -t "$i"; done
sleep 2

START_PORT=3000

for i in $(seq 1 $CORES); do
    PORT=$((START_PORT + i - 1))
    DIR="$HOME/mt5-agents/node_$PORT"
    export WINEPREFIX="$DIR"
    
    echo "Configuring and starting Agent Application on port $PORT..."
    
    # Rebuild fresh directories for each agent
    rm -rf "$DIR"
    mkdir -p "$DIR"
    cp metatester64.exe "$DIR/"
    
    # Pre-boot the Wine environment so it generates standard folders
    xvfb-run -a wineboot -u > /dev/null 2>&1
    sleep 2
    
    ACCOUNT_FLAG=""
    if [ ! -z "$MQL5_LOGIN" ]; then
        ACCOUNT_FLAG="/account:$MQL5_LOGIN"
        
        # Inject Cloud Network Registry BEFORE starting the application to force the "Sell" feature
        cat <<REG > "$DIR/cloud.reg"
Windows Registry Editor Version 5.00
[HKEY_CURRENT_USER\Software\MetaQuotes\MetaTester]
"Login"="$MQL5_LOGIN"
"SellComputingResources"=dword:00000001
REG
        xvfb-run -a wine regedit "$DIR/cloud.reg" > /dev/null 2>&1
    fi
    
    # Run the application directly inside tmux
    tmux new-session -d -s "agent_$PORT" "WINEPREFIX=\"$DIR\" WINEDEBUG=-all xvfb-run -a wine \"$DIR/metatester64.exe\" /install /address:0.0.0.0:$PORT /password:$PASSWORD $ACCOUNT_FLAG"
    
    echo "✅ Application running safely in background (tmux session: agent_$PORT)"
    sleep 2
done

echo "---------------------------------------------------------"
echo "Cleaning up RAM Cache..."
sudo sync; sudo sysctl -w vm.drop_caches=3 > /dev/null 2>&1

echo "========================================================="
echo "Setup Complete!"
echo "Check your ports using: sudo netstat -tulnp | grep wineserver"
if [ ! -z "$MQL5_LOGIN" ]; then
    echo "Note: It can take 15-20 minutes for new agents to appear on your MQL5 Cloud profile."
fi
echo "========================================================="
