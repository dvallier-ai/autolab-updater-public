#!/usr/bin/env bash
# ============================================================================
# autolab-cron-check.sh — Periodic check for upstream updates
# ============================================================================
#
# Lightweight script for cron/launchd/agent heartbeats to check if a new
# upstream OpenClaw version is available and optionally trigger the
# update + deploy pipeline.
#
# Modes:
#   ./autolab-cron-check.sh                # check only, print status
#   ./autolab-cron-check.sh --auto-update  # check + run autolab-update.sh
#   ./autolab-cron-check.sh --auto-deploy  # check + update + deploy
#   ./autolab-cron-check.sh --notify       # check + send notification
#   ./autolab-cron-check.sh --install-launchd  # install daily launchd job
#
# Exit codes:
#   0 = up to date (or update succeeded)
#   1 = new version available (check-only mode)
#   2 = update/deploy failed
#
# Designed for:
#   - crontab entries
#   - macOS LaunchAgent periodic jobs
#   - Agent heartbeat checks (HEARTBEAT.md)
#   - Manual one-off checks
#
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GIT="/usr/bin/git"
UPSTREAM_BARE="$HOME/.autolab/updates/upstream.git"
UPSTREAM_REPO="https://github.com/openclaw/openclaw.git"
STATE_FILE="$HOME/.autolab/updates/state.json"
PROD_DIR="$HOME/autolab"
LOG_DIR="$HOME/.autolab/logs"
LAUNCHD_LABEL="ai.autolab.cron-check"

mkdir -p "$LOG_DIR"

# ── Helpers ────────────────────────────────────────────────────────────────────
timestamp() { date -u +%Y-%m-%dT%H:%M:%S+00:00; }

log() {
    local msg="[$(date +%H:%M:%S)] $*"
    echo "$msg"
    echo "$msg" >> "$LOG_DIR/cron-check.log"
}

# ── Fetch latest upstream version ─────────────────────────────────────────────
get_latest_upstream() {
    if [[ ! -d "$UPSTREAM_BARE" ]]; then
        mkdir -p "$(dirname "$UPSTREAM_BARE")"
        $GIT clone --bare "$UPSTREAM_REPO" "$UPSTREAM_BARE" >/dev/null 2>&1
    else
        (cd "$UPSTREAM_BARE" && $GIT fetch --tags --force origin '+refs/heads/*:refs/heads/*' >/dev/null 2>&1) || true
    fi
    (cd "$UPSTREAM_BARE" && $GIT tag --sort=-v:refname | grep -v beta | head -1)
}

# ── Get current version ──────────────────────────────────────────────────────
get_current_version() {
    if [[ -f "$PROD_DIR/package.json" ]]; then
        local ver
        ver=$(grep '"version"' "$PROD_DIR/package.json" | head -1 | sed 's/.*"version": "\([^"]*\)".*/\1/')
        echo "v$ver"
    else
        echo "unknown"
    fi
}

# ── Update state file ─────────────────────────────────────────────────────────
update_state() {
    local latest="$1"
    local current="$2"

    mkdir -p "$(dirname "$STATE_FILE")"

    # Calculate pending versions
    local pending="[]"
    if [[ "$current" != "$latest" ]]; then
        pending=$(cd "$UPSTREAM_BARE" && $GIT tag --sort=-v:refname | grep -v beta | while read -r tag; do
            if [[ "$tag" > "$current" && "$tag" <= "$latest" ]]; then
                echo "\"$tag\""
            fi
        done | paste -sd, - | sed 's/^/[/;s/$/]/')
        [[ "$pending" == "[]" ]] || true
    fi

    cat > "$STATE_FILE" <<EOF
{
  "last_checked": "$(timestamp)",
  "last_seen_tag": "$latest",
  "base_version": "$current",
  "applied_versions": [],
  "skipped_versions": [],
  "pending_versions": $pending
}
EOF
}

# ── Main check ────────────────────────────────────────────────────────────────
check() {
    local latest current
    latest=$(get_latest_upstream)
    current=$(get_current_version)

    log "Current: $current | Latest upstream: $latest"
    update_state "$latest" "$current"

    if [[ "$current" == "$latest" ]]; then
        log "Up to date."
        echo "UP_TO_DATE"
        return 0
    else
        log "UPDATE AVAILABLE: $current → $latest"
        echo "UPDATE_AVAILABLE:$current:$latest"
        return 1
    fi
}

# ── Auto-update ───────────────────────────────────────────────────────────────
auto_update() {
    local result
    result=$(check) || true

    if [[ "$result" == UP_TO_DATE ]]; then
        return 0
    fi

    local target
    target=$(echo "$result" | cut -d: -f3)
    log "Auto-updating to $target..."

    if bash "$SCRIPT_DIR/autolab-update.sh" "$target" >> "$LOG_DIR/cron-update.log" 2>&1; then
        log "Update pipeline completed for $target"
        return 0
    else
        log "Update pipeline FAILED for $target"
        return 2
    fi
}

# ── Auto-deploy ───────────────────────────────────────────────────────────────
auto_deploy() {
    auto_update || return $?

    # Only deploy if update created a test environment
    if [[ ! -f "$HOME/autolab-test/dist/index.js" ]]; then
        log "No test build found — skipping deploy"
        return 0
    fi

    log "Auto-deploying..."
    if bash "$SCRIPT_DIR/autolab-deploy.sh" --yes >> "$LOG_DIR/cron-deploy.log" 2>&1; then
        log "Deploy completed successfully"
        return 0
    else
        log "Deploy FAILED — check $LOG_DIR/cron-deploy.log"
        return 2
    fi
}

# ── Install launchd periodic job ──────────────────────────────────────────────
install_launchd() {
    local plist="$HOME/Library/LaunchAgents/$LAUNCHD_LABEL.plist"

    cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LAUNCHD_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$SCRIPT_DIR/autolab-cron-check.sh</string>
        <string>--auto-update</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key>
        <integer>6</integer>
        <key>Minute</key>
        <integer>0</integer>
    </dict>
    <key>StandardOutPath</key>
    <string>$LOG_DIR/cron-check.log</string>
    <key>StandardErrorPath</key>
    <string>$LOG_DIR/cron-check.err.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key>
        <string>$HOME</string>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    </dict>
</dict>
</plist>
EOF

    launchctl bootstrap "gui/$(id -u)" "$plist" 2>/dev/null || \
    launchctl load "$plist" 2>/dev/null || true

    echo "Installed daily check at 6:00 AM"
    echo "Plist: $plist"
    echo "Logs:  $LOG_DIR/cron-check.log"
    echo ""
    echo "To change schedule, edit the plist and reload:"
    echo "  launchctl bootout gui/\$(id -u)/$LAUNCHD_LABEL"
    echo "  launchctl bootstrap gui/\$(id -u) $plist"
}

# ── Entry Point ────────────────────────────────────────────────────────────────
case "${1:-}" in
    --auto-update)
        auto_update
        ;;
    --auto-deploy)
        auto_deploy
        ;;
    --notify)
        # Check and output result for agents/scripts to parse
        check || true
        ;;
    --install-launchd)
        install_launchd
        ;;
    -h|--help)
        echo "AutoLab Cron Check — Periodic upstream update checker"
        echo ""
        echo "Usage:"
        echo "  $0                    Check for updates (exit 1 if available)"
        echo "  $0 --auto-update      Check + run update pipeline"
        echo "  $0 --auto-deploy      Check + update + deploy to production"
        echo "  $0 --notify           Check + output machine-readable status"
        echo "  $0 --install-launchd  Install daily launchd job"
        echo ""
        echo "Exit codes:"
        echo "  0 = up to date (or action succeeded)"
        echo "  1 = new version available (check-only)"
        echo "  2 = update/deploy failed"
        echo ""
        echo "Cron example (check daily at 6 AM):"
        echo "  0 6 * * * $SCRIPT_DIR/autolab-cron-check.sh --auto-update >> $LOG_DIR/cron-check.log 2>&1"
        ;;
    *)
        check
        ;;
esac
