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
echo "      MetaTester 5 Setup (Final Fixed Architecture)      "
echo "========================================================="
echo "Cores: $CORES | MQL5 Login: ${MQL5_LOGIN:-None}"

echo "---------------------------------------------------------"
echo "Disabling UFW Firewall..."
sudo ufw disable > /dev/null 2>&1

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1

echo "Installing Wine and Networking packages (winbind, net-tools, tmux)..."
sudo dpkg --add-architecture i386 > /dev/null 2>&1
sudo -E apt-get update -yqq > /dev/null 2>&1
sudo -E apt-get install -yqq wine wine64 wine32 xvfb wget winbind net-tools tmux > /dev/null 2>&1

echo "Downloading official metatester64.exe..."
mkdir -p ~/mt5-agents
cd ~/mt5-agents
wget -q -nc -O metatester64.exe "https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/metatester64.exe"

START_PORT=3000

for i in $(seq 1 $CORES); do
    PORT=$((START_PORT + i - 1))
    DIR="$HOME/mt5-agents/node_$PORT"
    export WINEPREFIX="$DIR"
    export WINEDEBUG=-all
    
    echo "Configuring Agent on port $PORT..."
    
    # 1. Wipe old corrupted attempts and setup a fresh environment
    wineserver -k > /dev/null 2>&1
    rm -rf "$DIR"
    mkdir -p "$DIR"
    cp metatester64.exe "$DIR/"
    
    # Initialize the fresh Wine prefix
    xvfb-run -a wineboot -u > /dev/null 2>&1
    sleep 2
    
    ACCOUNT_FLAG=""
    if [ ! -z "$MQL5_LOGIN" ]; then
        ACCOUNT_FLAG="/account:$MQL5_LOGIN"
    fi
    
    # 2. INSTALL the agent (Timeout is required because Wine holds the terminal open)
    timeout 10 xvfb-run -a wine "$DIR/metatester64.exe" /install /address:0.0.0.0:$PORT /password:$PASSWORD $ACCOUNT_FLAG > /dev/null 2>&1
    
    # 3. Inject Cloud Network Registry
    if [ ! -z "$MQL5_LOGIN" ]; then
        cat <<REG > "$DIR/cloud.reg"
Windows Registry Editor Version 5.00
[HKEY_CURRENT_USER\Software\MetaQuotes\MetaTester]
"Login"="$MQL5_LOGIN"
"SellComputingResources"=dword:00000001
REG
        xvfb-run -a wine regedit "$DIR/cloud.reg" > /dev/null 2>&1
    fi
    
    # Safely kill the installation process
    wineserver -k > /dev/null 2>&1
    sleep 2
    
    # 4. START the agent
    # 'wineboot' turns the Windows Services on. 'wineserver -w' keeps the container permanently alive.
    tmux kill-session -t "agent_$PORT" 2>/dev/null
    tmux new-session -d -s "agent_$PORT" "WINEPREFIX=\"$DIR\" xvfb-run -a bash -c 'wineboot && wineserver -w'"
    
    echo "✅ Agent is fully installed and STARTED on port $PORT"
done

echo "---------------------------------------------------------"
echo "Cleaning up RAM Cache..."
sudo sync; sudo sysctl -w vm.drop_caches=3 > /dev/null 2>&1

echo "========================================================="
echo "Setup Complete!"
echo "Run this command to prove they are actively listening:"
echo "sudo netstat -tulnp | grep wineserver"
echo "========================================================="
