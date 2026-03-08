#!/usr/bin/env bash
# Fully automated update + deploy (no prompts)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_FILE="${HOME}/.autolab/logs/auto-update.log"

log() {
    echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" | tee -a "$LOG_FILE"
}

log "=== Starting automated update check ==="

# Phase 1: Check for updates
cd "$SCRIPT_DIR"
RESULT=$(./orchestrate.sh run 2>&1 | tee -a "$LOG_FILE") || {
    log "ERROR: orchestrate.sh failed"
    exit 1
}

# Check if new version available
if echo "$RESULT" | grep -q "No new releases found"; then
    log "System up to date"
    exit 0
fi

# Extract new version
NEW_VERSION=$(cat ~/.autolab/updates/state.json | python3 -c "import json,sys; print(json.load(sys.stdin)['pending_versions'][0])" 2>/dev/null || echo "")

if [[ -z "$NEW_VERSION" ]]; then
    log "No pending versions to deploy"
    exit 0
fi

log "New version available: $NEW_VERSION"

# Phase 2: Update & build in test environment
log "Running autolab-update.sh $NEW_VERSION..."
UPDATE_OUTPUT=$(./autolab-update.sh "$NEW_VERSION" 2>&1 | tee -a "$LOG_FILE")

# CRITICAL: Check if gateway test PASSED
if echo "$UPDATE_OUTPUT" | grep -q "Gateway test:.*FAIL"; then
    log "❌ ABORT: Gateway test FAILED in test environment"
    log "NOT deploying to production - test lab broken"
    log "Manual intervention required: cd ~/autolab-test && check logs"
    
    # Notify Dan immediately

Gateway test FAILED in test lab (~/autolab-test).
Update NOT deployed to production.

Check: ~/autolab-test/
Logs: ~/.autolab/logs/auto-update.log

System still running on current version." 2>&1 || true
    
    exit 1
fi

if ! echo "$UPDATE_OUTPUT" | grep -q "Gateway test:.*PASS"; then
    log "⚠️ WARNING: Could not verify gateway test status"
    log "NOT deploying without confirmed PASS"
    exit 1
fi

log "✅ Gateway test PASSED in test environment"

# Phase 3: Deploy to production (auto-yes)
log "Deploying to production..."
./autolab-deploy.sh --yes >> "$LOG_FILE" 2>&1 || {
    log "ERROR: autolab-deploy.sh failed"
    exit 1
}

# Phase 4: Health check after deployment
log "Running post-deployment health check..."
sleep 10  # Give gateway time to stabilize

GATEWAY_PID=$(launchctl list | grep ai.autolab.gateway | awk '{print $1}')
if [[ -z "$GATEWAY_PID" ]] || [[ "$GATEWAY_PID" == "-" ]]; then
    log "❌ CRITICAL: Gateway not running after deployment!"
    log "Attempting auto-rollback..."
    
    cd "$SCRIPT_DIR"
    ./autolab-deploy.sh --rollback >> "$LOG_FILE" 2>&1 || {
        log "❌ ROLLBACK FAILED - Manual intervention required!"

Update deployed but gateway failed to start.
AUTO-ROLLBACK FAILED.

URGENT: Manual recovery needed
SSH to machine and run:
cd ~/autolab-updater && ./autolab-deploy.sh --rollback" 2>&1 || true
        exit 1
    }
    
    log "✅ Rollback succeeded - system restored to previous version"

Gateway crashed after deploying $NEW_VERSION.
Auto-rollback succeeded.

System restored to previous version and running normally." 2>&1 || true
    exit 1
fi

log "✅ Gateway running (PID $GATEWAY_PID)"

# Test RPC health
if ! autolab gateway call status --json >/dev/null 2>&1; then
    log "❌ Gateway not responding to RPC calls"
    log "Attempting auto-rollback..."
    
    cd "$SCRIPT_DIR"
    ./autolab-deploy.sh --rollback >> "$LOG_FILE" 2>&1
    

Gateway started but not responding after $NEW_VERSION.
Auto-rollback succeeded.

System restored and healthy." 2>&1 || true
    exit 1
fi

log "✅ Gateway responding to RPC"
log "✅ Health check PASSED"

log "=== Update complete: $NEW_VERSION deployed ==="

# Notify Dan via telegram

🔒 Security: $(cat ~/.autolab/updates/latest-report.md | grep 'Security:' | head -1 || echo 'N/A')
🔧 Bugs: $(cat ~/.autolab/updates/latest-report.md | grep 'Bugs:' | head -1 || echo 'N/A')

Gateway restarted successfully." 2>&1 || log "Failed to send telegram notification"

exit 0
