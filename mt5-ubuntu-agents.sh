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
echo "      MetaTester 5 Setup (tmux headless + MQL5 Cloud)    "
echo "========================================================="
echo "Cores: $CORES | MQL5 Login: ${MQL5_LOGIN:-None}"

# 1. One-Time RAM Cleanup
echo "---------------------------------------------------------"
echo "Cleaning up RAM Cache..."
sudo sync; sudo sysctl -w vm.drop_caches=3

# 2. Install Dependencies
echo "---------------------------------------------------------"
echo "Installing Wine and dependencies..."
sudo dpkg --add-architecture i386
sudo apt update
sudo apt install -y wine64 wine32 xvfb tmux wget ufw

START_PORT=3000
END_PORT=$((START_PORT + CORES - 1))
sudo ufw allow $START_PORT:$END_PORT/tcp

# 3. Download metatester64.exe
echo "---------------------------------------------------------"
mkdir -p ~/mt5-agents
cd ~/mt5-agents
echo "Downloading metatester64.exe from github.com/rockitya..."
wget -nc -O metatester64.exe "https://raw.githubusercontent.com/rockitya/mt5-ubuntu-agents.sh/main/metatester64.exe"

# 4. Build Agent Nodes
echo "---------------------------------------------------------"
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
    
    WINEPREFIX="$DIR" WINEDEBUG=-all xvfb-run -a wine "$DIR/metatester64.exe" /install /address:0.0.0.0:$PORT /password:$PASSWORD $ACCOUNT_FLAG
    
    # Inject Registry key for "Sell computing resources"
    if [ ! -z "$MQL5_LOGIN" ]; then
        cat <<REG > "$DIR/cloud.reg"
Windows Registry Editor Version 5.00
[HKEY_CURRENT_USER\Software\MetaQuotes\MetaTester]
"Login"="$MQL5_LOGIN"
"SellComputingResources"=dword:00000001
REG
        WINEPREFIX="$DIR" WINEDEBUG=-all xvfb-run -a wine regedit "$DIR/cloud.reg"
    fi
    
    WINEPREFIX="$DIR" wineserver -k
    sleep 2
    
    tmux new-session -d -s "agent_$PORT" "WINEPREFIX=\"$DIR\" WINEDEBUG=-all xvfb-run -a wineboot && WINEPREFIX=\"$DIR\" wineserver -w"
    
    echo "✅ Agent running natively on port $PORT (tmux session: agent_$PORT)"
done

echo "========================================================="
echo "Setup Complete! $CORES Agents are running in the background."
echo "========================================================="
