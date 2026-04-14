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

echo "---------------------------------------------------------"
echo "Disabling UFW Firewall..."
sudo ufw disable > /dev/null 2>&1

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1

echo "Installing dependencies silently (Please wait 1-2 minutes)..."
sudo dpkg --add-architecture i386 > /dev/null 2>&1
sudo -E apt-get update -yqq > /dev/null 2>&1
sudo -E apt-get install -yqq wine64 wine32 xvfb tmux wget ufw > /dev/null 2>&1

echo "Downloading metatester64.exe..."
mkdir -p ~/mt5-agents
cd ~/mt5-agents
wget -q -nc -O metatester64.exe "https://raw.githubusercontent.com/rockitya/mt5-ubuntu-agents.sh/main/metatester64.exe"

START_PORT=3000
for i in $(seq 1 $CORES); do
    PORT=$((START_PORT + i - 1))
    DIR="$HOME/mt5-agents/node_$PORT"
    
    echo "Starting Agent on port $PORT in the background..."
    mkdir -p "$DIR"
    cp metatester64.exe "$DIR/"
    
    ACCOUNT_FLAG=""
    if [ ! -z "$MQL5_LOGIN" ]; then
        ACCOUNT_FLAG="/account:$MQL5_LOGIN"
        
        # Inject Registry key for "Sell computing resources" BEFORE starting the agent
        cat <<REG > "$DIR/cloud.reg"
Windows Registry Editor Version 5.00
[HKEY_CURRENT_USER\Software\MetaQuotes\MetaTester]
"Login"="$MQL5_LOGIN"
"SellComputingResources"=dword:00000001
REG
        WINEPREFIX="$DIR" WINEDEBUG=-all xvfb-run -a wine regedit "$DIR/cloud.reg" > /dev/null 2>&1
    fi
    
    # Kill any old crashed sessions on this port
    tmux kill-session -t "agent_$PORT" 2>/dev/null
    
    # FIX: Run the install/start command DIRECTLY inside the detached tmux session.
    # This prevents the script from pausing, and keeps the agent alive permanently.
    tmux new-session -d -s "agent_$PORT" "WINEPREFIX=\"$DIR\" WINEDEBUG=-all xvfb-run -a wine \"$DIR/metatester64.exe\" /install /address:0.0.0.0:$PORT /password:$PASSWORD $ACCOUNT_FLAG"
    
    sleep 2
    echo "✅ Agent running natively on port $PORT"
done

# Run RAM Cleanup AFTER everything is launched
echo "---------------------------------------------------------"
echo "Cleaning up RAM Cache..."
sudo sync; sudo sysctl -w vm.drop_caches=3 > /dev/null 2>&1

echo "========================================================="
echo "Setup Complete! $CORES Agents are running in the background."
echo "Firewall is OFF. Kernel popups bypassed. RAM is cleaned."
echo "========================================================="
