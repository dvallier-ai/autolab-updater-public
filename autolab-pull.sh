#!/usr/bin/env bash
# ============================================================================
# autolab-pull.sh — Pull latest AutoLab from fork and restart gateway
# ============================================================================
#
# For secondary machines that don't run the full
# update pipeline. After MacB pushes to the fork, these machines just
# pull, build, and restart.
#
# First-time setup (converts from npm/openclaw to git/autolab):
#   ./autolab-pull.sh --init
#
# Normal update:
#   ./autolab-pull.sh              # interactive
#   ./autolab-pull.sh --yes        # auto-confirm (for cron/agents)
#
# Rollback:
#   ./autolab-pull.sh --rollback
#
# Can be run locally on each machine, or remotely via SSH:
#   ssh maca "bash ~/autolab/scripts/smart-update/autolab-pull.sh --yes"
#
# ============================================================================

set -euo pipefail

GIT="/usr/bin/git"
FORK_REPO="https://github.com/your-username/autolab.git"
INSTALL_DIR="$HOME/autolab"
BACKUP_DIR="$HOME/.autolab/backups"
LOG_DIR="$HOME/.autolab/logs"
LAUNCHD_LABEL=""  # auto-detected
GATEWAY_PORT=""   # auto-detected

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $*"; }
ok()   { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*" >&2; }
step() { echo -e "\n${CYAN}━━━ $* ━━━${NC}"; }
die()  { err "$*"; exit 1; }

# ── Detect gateway setup ──────────────────────────────────────────────────────
detect_gateway() {
    # Check for autolab gateway first, then openclaw
    if launchctl list 2>/dev/null | grep -q "ai.autolab.gateway"; then
        LAUNCHD_LABEL="ai.autolab.gateway"
    elif launchctl list 2>/dev/null | grep -q "ai.openclaw.gateway"; then
        LAUNCHD_LABEL="ai.openclaw.gateway"
    fi

    if [[ -n "$LAUNCHD_LABEL" ]]; then
        local plist="$HOME/Library/LaunchAgents/$LAUNCHD_LABEL.plist"
        if [[ -f "$plist" ]]; then
            GATEWAY_PORT=$(grep -A1 'GATEWAY_PORT' "$plist" | grep '<string>' | sed 's/.*<string>\(.*\)<\/string>.*/\1/' | head -1)
        fi
    fi

    log "Detected gateway: ${LAUNCHD_LABEL:-none} on port ${GATEWAY_PORT:-unknown}"
}

# ── First-time init ───────────────────────────────────────────────────────────
init() {
    step "First-time setup"

    if [[ -d "$INSTALL_DIR/.git" ]]; then
        ok "Git repo already exists at $INSTALL_DIR"
        return 0
    fi

    if [[ -d "$INSTALL_DIR" ]]; then
        warn "$INSTALL_DIR exists but is not a git repo. Backing up..."
        mv "$INSTALL_DIR" "${INSTALL_DIR}.bak.$(date +%Y%m%d)"
    fi

    log "Cloning from fork..."
    $GIT clone "$FORK_REPO" "$INSTALL_DIR" 2>&1 | tail -3
    ok "Cloned to $INSTALL_DIR"

    log "Installing dependencies..."
    (cd "$INSTALL_DIR" && pnpm install) 2>&1 | tail -3
    ok "Dependencies installed"

    log "Building..."
    (cd "$INSTALL_DIR" && pnpm build) 2>&1 | tail -5
    ok "Built"

    # Copy a2ui bundle from npm install if it exists
    local npm_bundle="/opt/homebrew/lib/node_modules/openclaw/src/canvas-host/a2ui/a2ui.bundle.js"
    if [[ -f "$npm_bundle" ]]; then
        mkdir -p "$INSTALL_DIR/src/canvas-host/a2ui"
        cp "$npm_bundle" "$INSTALL_DIR/src/canvas-host/a2ui/"
        ok "Copied a2ui.bundle.js from npm install"
    fi

    # Create/update LaunchAgent
    create_launchagent

    ok "Init complete. Restart gateway with: $0 --restart"
}

# ── Create autolab LaunchAgent ────────────────────────────────────────────────
create_launchagent() {
    step "Setting up LaunchAgent"

    local port="${GATEWAY_PORT:-18791}"
    local plist_path="$HOME/Library/LaunchAgents/ai.autolab.gateway.plist"

    # Detect existing token
    local token=""
    if [[ -n "$LAUNCHD_LABEL" ]]; then
        local old_plist="$HOME/Library/LaunchAgents/$LAUNCHD_LABEL.plist"
        if [[ -f "$old_plist" ]]; then
            token=$(grep -A1 'GATEWAY_TOKEN' "$old_plist" | grep '<string>' | sed 's/.*<string>\(.*\)<\/string>.*/\1/' | head -1)
            port=$(grep -A1 'GATEWAY_PORT' "$old_plist" | grep '<string>' | sed 's/.*<string>\(.*\)<\/string>.*/\1/' | head -1)
        fi
    fi

    if [[ -z "$token" ]]; then
        token=$(openssl rand -hex 24)
        warn "Generated new gateway token: $token"
    fi

    local version
    version=$(grep '"version"' "$INSTALL_DIR/package.json" | head -1 | sed 's/.*"version": "\([^"]*\)".*/\1/')

    mkdir -p "$(dirname "$plist_path")"
    cat > "$plist_path" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
        <key>Comment</key>
        <string>AutoLab Gateway (v$version)</string>
        <key>EnvironmentVariables</key>
        <dict>
                <key>AUTOLAB_GATEWAY_PORT</key>
                <string>$port</string>
                <key>AUTOLAB_GATEWAY_TOKEN</key>
                <string>$token</string>
                <key>AUTOLAB_LAUNCHD_LABEL</key>
                <string>ai.autolab.gateway</string>
                <key>AUTOLAB_SERVICE_KIND</key>
                <string>gateway</string>
                <key>AUTOLAB_SERVICE_MARKER</key>
                <string>autolab</string>
                <key>AUTOLAB_SERVICE_VERSION</key>
                <string>$version</string>
                <key>AUTOLAB_SYSTEMD_UNIT</key>
                <string>autolab-gateway.service</string>
                <key>HOME</key>
                <string>$HOME</string>
                <key>PATH</key>
                <string>$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
        </dict>
        <key>KeepAlive</key>
        <true/>
        <key>Label</key>
        <string>ai.autolab.gateway</string>
        <key>ProgramArguments</key>
        <array>
                <string>/opt/homebrew/bin/node</string>
                <string>$INSTALL_DIR/dist/index.js</string>
                <string>gateway</string>
                <string>--port</string>
                <string>$port</string>
        </array>
        <key>RunAtLoad</key>
        <true/>
        <key>StandardErrorPath</key>
        <string>$HOME/.autolab/logs/gateway.err.log</string>
        <key>StandardOutPath</key>
        <string>$HOME/.autolab/logs/gateway.log</string>
</dict>
</plist>
EOF

    mkdir -p "$HOME/.autolab/logs"
    ok "Created $plist_path (port $port)"
    LAUNCHD_LABEL="ai.autolab.gateway"
    GATEWAY_PORT="$port"
}

# ── Pull & Build ──────────────────────────────────────────────────────────────
pull_and_build() {
    step "Pulling latest from fork"

    cd "$INSTALL_DIR"

    # Record current ref for rollback
    local old_ref
    old_ref=$($GIT rev-parse HEAD)
    local old_ver
    old_ver=$(grep '"version"' package.json | head -1 | sed 's/.*"version": "\([^"]*\)".*/\1/')

    # Pull
    log "Fetching..."
    $GIT fetch origin main 2>&1 | tail -3

    # Check if there are changes
    local behind
    behind=$($GIT rev-list HEAD..origin/main --count)
    if (( behind == 0 )); then
        ok "Already up to date (v$old_ver)"
        return 1  # signal: no changes
    fi
    log "$behind commits behind origin/main"

    # Save backup ref
    mkdir -p "$BACKUP_DIR"
    local backup_path="$BACKUP_DIR/autolab-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$backup_path"
    echo "$old_ref" > "$backup_path/git-ref"
    echo "$old_ver" > "$backup_path/version"
    ln -sf "$backup_path" "$BACKUP_DIR/latest"

    # Pull
    $GIT reset --hard origin/main 2>&1 | tail -1
    local new_ver
    new_ver=$(grep '"version"' package.json | head -1 | sed 's/.*"version": "\([^"]*\)".*/\1/')
    ok "Updated: v$old_ver → v$new_ver"

    # Install & build
    log "Installing dependencies..."
    pnpm install 2>"$LOG_DIR/pull-pnpm.err.log" | tail -3
    ok "Dependencies installed"

    log "Building..."
    pnpm build 2>"$LOG_DIR/pull-build.err.log" | tail -5
    ok "Build complete"

    return 0  # signal: changes applied
}

# ── Restart Gateway ───────────────────────────────────────────────────────────
restart_gateway() {
    step "Restarting gateway"

    if [[ -z "$LAUNCHD_LABEL" ]]; then
        warn "No gateway LaunchAgent detected. Start manually."
        return 0
    fi

    # Stop old gateway (handle both old openclaw and new autolab labels)
    for label in "ai.openclaw.gateway" "ai.autolab.gateway"; do
        if launchctl list 2>/dev/null | grep -q "$label"; then
            log "Stopping $label..."
            launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
        fi
    done
    sleep 3

    # Start new gateway
    local plist="$HOME/Library/LaunchAgents/ai.autolab.gateway.plist"
    if [[ -f "$plist" ]]; then
        log "Starting ai.autolab.gateway..."
        launchctl bootstrap "gui/$(id -u)" "$plist" 2>/dev/null || \
        launchctl load "$plist" 2>/dev/null || true
        ok "Gateway restart initiated"
    else
        warn "No LaunchAgent plist found at $plist"
        warn "Run: $0 --init to create one"
    fi

    # Health check
    local port="${GATEWAY_PORT:-18791}"
    log "Health check on port $port..."
    local i=0
    while (( i < 60 )); do
        if curl -sf "http://127.0.0.1:$port/health" >/dev/null 2>&1; then
            ok "Gateway HEALTHY on port $port"
            return 0
        fi
        sleep 2
        i=$((i + 2))
    done
    err "Gateway not healthy after 60s"
    return 1
}

# ── Rollback ──────────────────────────────────────────────────────────────────
rollback() {
    step "Rolling back"

    local latest="$BACKUP_DIR/latest"
    if [[ ! -L "$latest" ]]; then
        die "No backup found"
    fi

    local ref
    ref=$(cat "$(readlink "$latest")/git-ref")
    local ver
    ver=$(cat "$(readlink "$latest")/version")

    warn "Rolling back to v$ver (${ref:0:8})"
    cd "$INSTALL_DIR"
    $GIT reset --hard "$ref" 2>&1 | tail -1
    pnpm install 2>/dev/null | tail -2
    pnpm build 2>/dev/null | tail -3
    restart_gateway
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    echo -e "\n${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║              AutoLab Pull — Secondary Machine            ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}\n"

    mkdir -p "$LOG_DIR"
    detect_gateway

    local auto_yes=false
    local action="pull"

    for arg in "$@"; do
        case "$arg" in
            --yes|-y) auto_yes=true ;;
            --init) action="init" ;;
            --rollback) action="rollback" ;;
            --restart) action="restart" ;;
        esac
    done

    case "$action" in
        init)
            init
            return
            ;;
        rollback)
            rollback
            return
            ;;
        restart)
            restart_gateway
            return
            ;;
    esac

    # Normal pull flow
    [[ -d "$INSTALL_DIR/.git" ]] || die "$INSTALL_DIR is not a git repo. Run: $0 --init"

    if pull_and_build; then
        # Changes were pulled
        if ! $auto_yes; then
            echo ""
            read -rp "  Restart gateway now? [y/N] " confirm
            if [[ "$confirm" != [yY] ]]; then
                log "Skipped restart. Run: $0 --restart"
                return
            fi
        fi
        restart_gateway
    fi
}

# ── Entry Point ────────────────────────────────────────────────────────────────
case "${1:-}" in
    -h|--help)
        echo "AutoLab Pull — Update secondary machines from fork"
        echo ""
        echo "Usage:"
        echo "  $0              Pull latest, build, restart (interactive)"
        echo "  $0 --yes        Auto-confirm (for cron/agents)"
        echo "  $0 --init       First-time setup (clone + LaunchAgent)"
        echo "  $0 --rollback   Rollback to previous version"
        echo "  $0 --restart    Just restart the gateway"
        echo ""
        echo "For MacA (via SSH from MacB):"
        echo "  ssh maca 'bash ~/autolab/scripts/smart-update/autolab-pull.sh --yes'"
        ;;
    *)
        main "$@"
        ;;
esac
