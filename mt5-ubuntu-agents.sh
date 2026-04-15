# Run installer
bash mt5-ubuntu-agents.sh 7 Prem@1996

# Verify ports
ss -tuln | grep -E "300[0-9]"

# ──── When ready to sell ────
/opt/mt5/cloud-on.sh rcktya

# Watch for cloud connection
screen -r mt5-3000
# Look for: "Network server agent14.mql5.net ping 45 ms"

# Check all agents
/opt/mt5/show-ping.sh

# Verify on website
# https://cloud.mql5.com/en/agents
