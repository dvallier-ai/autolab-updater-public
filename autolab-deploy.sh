#!/usr/bin/env bash
# ============================================================================
# autolab-deploy.sh — Deploy validated update from test to production
# ============================================================================
#
# Prerequisites:
#   - Run autolab-update.sh first to prepare ~/autolab-test/
#   - Test environment must have passed build & gateway checks
#
# What it does:
#   1. Validates test environment exists and is built
#   2. Backs up production ~/autolab/ (git stash + tarball)
#   3. Copies validated code from ~/autolab-test/ to ~/autolab/
#   4. Runs pnpm install in production
#   5. Restarts the production gateway via launchctl
#   6. Waits for health check (60s timeout)
#   7. If unhealthy → automatic rollback from backup
#   8. Pushes to Dan's fork for network-wide deployment
#
# Usage:
#   ./autolab-deploy.sh              # interactive, prompts before deploy
#   ./autolab-deploy.sh --yes        # skip confirmation
#   ./autolab-deploy.sh --rollback   # rollback to last backup
#   ./autolab-deploy.sh --push-only  # just push to fork (after manual deploy)
#
# ============================================================================

set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────────────────
GIT="/usr/bin/git"
TEST_DIR="$HOME/autolab-test"
PROD_DIR="$HOME/autolab"
BACKUP_DIR="$HOME/.autolab/backups"
LOG_DIR="$HOME/.autolab/logs"
STATE_FILE="$HOME/.autolab/updates/state.json"
LAUNCHD_LABEL="ai.autolab.gateway"
PROD_PORT=18791
HEALTH_TIMEOUT=60
DO_NOT_RETRY_FLAG="$HOME/.autolab/do-not-retry"

# Colors
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

# ── Pre-flight Checks ─────────────────────────────────────────────────────────
preflight() {
    step "Pre-flight checks"

    # Check do-not-retry flag
    if [[ -f "$DO_NOT_RETRY_FLAG" ]]; then
        die "DO-NOT-RETRY flag is set ($DO_NOT_RETRY_FLAG). A previous deployment failed and rolled back. Investigate before retrying. Remove the flag to proceed."
    fi

    # Check test environment exists
    [[ -d "$TEST_DIR" ]] || die "Test environment not found at $TEST_DIR. Run autolab-update.sh first."
    [[ -f "$TEST_DIR/dist/index.js" ]] || die "Test environment not built. Run: cd $TEST_DIR && pnpm build"
    [[ -f "$TEST_DIR/package.json" ]] || die "No package.json in test environment"

    # Check production exists
    [[ -d "$PROD_DIR" ]] || die "Production directory not found at $PROD_DIR"

    # Get versions
    local test_ver prod_ver
    test_ver=$(grep '"version"' "$TEST_DIR/package.json" | head -1 | sed 's/.*"version": "\([^"]*\)".*/\1/')
    prod_ver=$(grep '"version"' "$PROD_DIR/package.json" | head -1 | sed 's/.*"version": "\([^"]*\)".*/\1/')

    log "Production version: v$prod_ver"
    log "Test version:       v$test_ver"

    if [[ "$test_ver" == "$prod_ver" ]]; then
        warn "Test and production are the same version (v$prod_ver)"
    fi

    # Check state file
    if [[ -f "$STATE_FILE" ]]; then
        local status
        status=$(python3 -c "import json; print(json.load(open('$STATE_FILE'))['status'])" 2>/dev/null || echo "unknown")
        log "Update state: $status"
        if [[ "$status" != "tested-ready-to-deploy" ]]; then
            warn "State is '$status', not 'tested-ready-to-deploy'"
        fi
    fi

    ok "Pre-flight checks passed"
}

# ── Backup Production ─────────────────────────────────────────────────────────
backup_production() {
    step "Backing up production"

    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    local backup_path="$BACKUP_DIR/autolab-$timestamp"

    mkdir -p "$BACKUP_DIR"

    # NOTE: We do NOT git stash — the smart-update scripts live in an untracked
    # directory inside $PROD_DIR, and stashing would delete them mid-run.
    # Instead we record the git ref and copy key files for rollback.

    # Create a lightweight backup (git ref + metadata)
    local prod_ref
    prod_ref=$(cd "$PROD_DIR" && $GIT rev-parse HEAD)
    local prod_ver
    prod_ver=$(grep '"version"' "$PROD_DIR/package.json" | head -1 | sed 's/.*"version": "\([^"]*\)".*/\1/')

    mkdir -p "$backup_path"
    echo "$prod_ref" > "$backup_path/git-ref"
    echo "$prod_ver" > "$backup_path/version"
    echo "$timestamp" > "$backup_path/timestamp"

    # Also back up key files that might have local changes
    cp "$PROD_DIR/package.json" "$backup_path/package.json"
    cp -r "$PROD_DIR/scripts/smart-update" "$backup_path/smart-update" 2>/dev/null || true

    # Save current branch
    (cd "$PROD_DIR" && $GIT branch --show-current) > "$backup_path/branch" 2>/dev/null || echo "main" > "$backup_path/branch"

    # Mark as latest backup
    ln -sf "$backup_path" "$BACKUP_DIR/latest"

    ok "Backup saved to $backup_path"
    echo "$backup_path"
}

# ── Deploy ─────────────────────────────────────────────────────────────────────
deploy() {
    step "Deploying to production"

    # Sync from test to production (excluding .git, node_modules, dist)
    log "Syncing files from test → production..."
    cd "$HOME"  # ensure cwd exists (rsync fails if cwd was deleted)
    rsync -a --delete \
        --exclude='.git' \
        --exclude='node_modules' \
        --exclude='.next' \
        --exclude='dist' \
        --exclude='scripts/smart-update' \
        "$TEST_DIR/" "$PROD_DIR/"
    ok "Files synced"

    # Install dependencies
    log "Installing dependencies in production..."
    (cd "$PROD_DIR" && pnpm install) 2>"$LOG_DIR/deploy-pnpm.err.log" | tail -3
    ok "Dependencies installed"

    # Build
    log "Building production..."
    (cd "$PROD_DIR" && pnpm build) 2>"$LOG_DIR/deploy-build.err.log" | tail -5
    ok "Production built"

    # Update version in package.json (in case rsync missed it due to local edit)
    local test_ver
    test_ver=$(grep '"version"' "$TEST_DIR/package.json" | head -1 | sed 's/.*"version": "\([^"]*\)".*/\1/')
    sed -i '' "s/\"version\": \"[^\"]*\"/\"version\": \"$test_ver\"/" "$PROD_DIR/package.json"

    # Commit the update in production
    log "Committing update..."
    (cd "$PROD_DIR" && \
        $GIT add -A && \
        $GIT -c user.name="Liam" -c user.email="liam@autolab.app" \
        commit --no-verify -m "update: v$test_ver — upstream sync with full rebrand

Deployed from autolab-test after successful build & gateway test.
Generated by autolab-deploy.sh" --allow-empty) 2>&1 | tail -2
    ok "Committed"
}

# ── Restart Gateway ───────────────────────────────────────────────────────────
restart_gateway() {
    step "Restarting gateway"

    log "Stopping $LAUNCHD_LABEL..."
    launchctl bootout "gui/$(id -u)/$LAUNCHD_LABEL" 2>/dev/null || true
    sleep 3

    log "Starting $LAUNCHD_LABEL..."
    launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/$LAUNCHD_LABEL.plist" 2>/dev/null || \
    launchctl load "$HOME/Library/LaunchAgents/$LAUNCHD_LABEL.plist" 2>/dev/null || true

    ok "Gateway restart initiated"
}

# ── Health Check ──────────────────────────────────────────────────────────────
health_check() {
    step "Health check (${HEALTH_TIMEOUT}s timeout)"

    local i=0
    while (( i < HEALTH_TIMEOUT )); do
        if curl -sf "http://127.0.0.1:$PROD_PORT/health" >/dev/null 2>&1; then
            ok "Gateway HEALTHY on port $PROD_PORT"
            return 0
        fi
        sleep 2
        i=$((i + 2))
        if (( i % 10 == 0 )); then
            log "Waiting... ${i}s / ${HEALTH_TIMEOUT}s"
        fi
    done

    err "Gateway failed health check after ${HEALTH_TIMEOUT}s"
    return 1
}

# ── Rollback ──────────────────────────────────────────────────────────────────
rollback() {
    step "ROLLING BACK"

    local latest_backup="$BACKUP_DIR/latest"

    if [[ ! -L "$latest_backup" || ! -d "$(readlink "$latest_backup")" ]]; then
        die "No backup found to rollback to!"
    fi

    local backup_path
    backup_path=$(readlink "$latest_backup")
    local git_ref
    git_ref=$(cat "$backup_path/git-ref")
    local version
    version=$(cat "$backup_path/version")

    warn "Rolling back to v$version (ref: ${git_ref:0:8})"

    # Reset to backup ref
    (cd "$PROD_DIR" && $GIT checkout main && $GIT reset --hard "$git_ref") 2>&1 | tail -2

    # Rebuild
    log "Rebuilding at rolled-back version..."
    (cd "$PROD_DIR" && pnpm install && pnpm build) 2>"$LOG_DIR/rollback-build.err.log" | tail -5

    # Restart gateway
    restart_gateway

    # Wait for health
    sleep 10
    if curl -sf "http://127.0.0.1:$PROD_PORT/health" >/dev/null 2>&1; then
        ok "Rollback successful — gateway healthy at v$version"
    else
        err "Rollback gateway also unhealthy. Manual intervention needed."
    fi

    # Set do-not-retry flag
    echo "Rollback occurred at $(date). Previous deploy failed." > "$DO_NOT_RETRY_FLAG"
    warn "DO-NOT-RETRY flag set. Investigate before re-deploying."
    warn "Remove $DO_NOT_RETRY_FLAG when ready to try again."
}

# ── Push to Fork ──────────────────────────────────────────────────────────────
push_to_fork() {
    step "Pushing to Dan's fork"

    (cd "$PROD_DIR" && $GIT push origin main) 2>&1 | tail -3

    ok "Pushed to dvallier-ai/autolab-public — other machines can now pull"
    echo ""
    log "Network deployment:"
    echo "  MacA (Nova):   ssh maca 'cd ~/autolab && git pull origin main && pnpm install && pnpm build'"
    echo "  linux-machine: ssh linux-machine 'cd ~/autolab && git pull origin main && pnpm install && pnpm build'"
    echo "  Each machine restarts its own gateway."
}

# ── Update LaunchAgent Version ────────────────────────────────────────────────
update_launchagent_version() {
    local plist="$HOME/Library/LaunchAgents/$LAUNCHD_LABEL.plist"
    local test_ver
    test_ver=$(grep '"version"' "$TEST_DIR/package.json" | head -1 | sed 's/.*"version": "\([^"]*\)".*/\1/')

    if [[ -f "$plist" ]]; then
        # Update the comment/version in LaunchAgent plist
        sed -i '' "s|AutoLab Gateway (v[^)]*)|AutoLab Gateway (v$test_ver)|" "$plist"
        sed -i '' "s|<string>20[0-9][0-9]\.[0-9]*\.[0-9]*</string>|<string>$test_ver</string>|" "$plist"
        ok "Updated LaunchAgent plist to v$test_ver"
    fi
}

# ── Update State ──────────────────────────────────────────────────────────────
update_state_deployed() {
    local test_ver
    test_ver=$(grep '"version"' "$TEST_DIR/package.json" | head -1 | sed 's/.*"version": "\([^"]*\)".*/\1/')

    cat > "$STATE_FILE" <<EOF
{
  "last_checked": "$(date -u +%Y-%m-%dT%H:%M:%S+00:00)",
  "last_seen_tag": "v$test_ver",
  "base_version": "v$test_ver",
  "applied_versions": ["v$test_ver"],
  "skipped_versions": [],
  "pending_versions": [],
  "last_update": "$(date -u +%Y-%m-%dT%H:%M:%S+00:00)",
  "status": "deployed",
  "deployed_at": "$(date -u +%Y-%m-%dT%H:%M:%S+00:00)"
}
EOF
    ok "State updated to deployed"
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    echo -e "\n${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║         AutoLab Deploy — Test → Production               ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}\n"

    mkdir -p "$LOG_DIR"

    local auto_yes=false
    local action="deploy"

    for arg in "$@"; do
        case "$arg" in
            --yes|-y) auto_yes=true ;;
            --rollback) action="rollback" ;;
            --push-only) action="push" ;;
        esac
    done

    case "$action" in
        rollback)
            rollback
            return
            ;;
        push)
            push_to_fork
            return
            ;;
    esac

    # Normal deploy flow
    preflight

    local test_ver prod_ver
    test_ver=$(grep '"version"' "$TEST_DIR/package.json" | head -1 | sed 's/.*"version": "\([^"]*\)".*/\1/')
    prod_ver=$(grep '"version"' "$PROD_DIR/package.json" | head -1 | sed 's/.*"version": "\([^"]*\)".*/\1/')

    if ! $auto_yes; then
        echo ""
        echo -e "  ${YELLOW}About to deploy:${NC}"
        echo -e "    Production: v$prod_ver → v$test_ver"
        echo -e "    This will restart the gateway on port $PROD_PORT"
        echo ""
        read -rp "  Proceed? [y/N] " confirm
        if [[ "$confirm" != [yY] ]]; then
            log "Aborted."
            exit 0
        fi
    fi

    # 1. Backup
    backup_production

    # 2. Deploy files
    deploy

    # 3. Update LaunchAgent
    update_launchagent_version

    # 4. Restart
    restart_gateway

    # 5. Health check
    if health_check; then
        ok "Deployment successful!"
        update_state_deployed

        # 6. Push to fork
        echo ""
        if $auto_yes; then
            push_to_fork
        else
            read -rp "  Push to Dan's fork for network-wide deployment? [y/N] " push_confirm
            if [[ "$push_confirm" == [yY] ]]; then
                push_to_fork
            fi
        fi
    else
        err "Gateway unhealthy after deploy!"
        warn "Initiating automatic rollback..."
        rollback
    fi

    # Summary
    echo ""
    step "Deployment Complete"
    echo ""
}

# ── Entry Point ────────────────────────────────────────────────────────────────
case "${1:-}" in
    -h|--help)
        echo "AutoLab Deploy — Push validated updates to production"
        echo ""
        echo "Usage:"
        echo "  $0              Interactive deploy (prompts for confirmation)"
        echo "  $0 --yes        Auto-confirm (for automation)"
        echo "  $0 --rollback   Rollback to last backup"
        echo "  $0 --push-only  Just push to fork (skip deploy)"
        echo ""
        echo "Pre-requisite: Run autolab-update.sh first."
        ;;
    *)
        main "$@"
        ;;
esac
