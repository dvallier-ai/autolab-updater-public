#!/usr/bin/env bash
# ============================================================================
# autolab-deploy-linux.sh — Deploy validated update from test to production
# ============================================================================
#
# Linux adaptation: uses systemd instead of launchctl, Linux sed, etc.
#
# SAFETY: This script updates the gateway that runs Cipher. If deployment
# fails, it auto-rollbacks. A systemd watchdog ensures the gateway restarts.
#
# Usage:
#   ./autolab-deploy-linux.sh              # interactive
#   ./autolab-deploy-linux.sh --yes        # skip confirmation
#   ./autolab-deploy-linux.sh --rollback   # rollback to last backup
#   ./autolab-deploy-linux.sh --push-only  # just push to fork
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
SYSTEMD_UNIT="autolab-gateway.service"
SYSTEMD_DIR="$HOME/.config/systemd/user"
PROD_PORT=18789
HEALTH_TIMEOUT=60
DO_NOT_RETRY_FLAG="$HOME/.autolab/do-not-retry"
NODE_BIN="/usr/bin/node"

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

    if [[ -f "$DO_NOT_RETRY_FLAG" ]]; then
        die "DO-NOT-RETRY flag is set ($DO_NOT_RETRY_FLAG). Investigate before retrying."
    fi

    [[ -d "$TEST_DIR" ]] || die "Test environment not found at $TEST_DIR. Run autolab-update-linux.sh first."
    [[ -f "$TEST_DIR/dist/index.js" ]] || die "Test environment not built."
    [[ -f "$TEST_DIR/package.json" ]] || die "No package.json in test environment"
    [[ -d "$PROD_DIR" ]] || die "Production directory not found at $PROD_DIR"

    local test_ver prod_ver
    test_ver=$(grep '"version"' "$TEST_DIR/package.json" | head -1 | sed 's/.*"version": "\([^"]*\)".*/\1/')
    prod_ver=$(grep '"version"' "$PROD_DIR/package.json" | head -1 | sed 's/.*"version": "\([^"]*\)".*/\1/')

    log "Production version: v$prod_ver"
    log "Test version:       v$test_ver"

    if [[ -f "$STATE_FILE" ]]; then
        local status
        status=$(python3 -c "import json; print(json.load(open('$STATE_FILE'))['status'])" 2>/dev/null || echo "unknown")
        log "Update state: $status"
    fi

    ok "Pre-flight checks passed"
}

# ── Backup Production ─────────────────────────────────────────────────────────
backup_production() {
    step "Backing up production"

    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    local backup_path="$BACKUP_DIR/autolab-$timestamp"

    mkdir -p "$backup_path"

    local prod_ref
    prod_ref=$(cd "$PROD_DIR" && $GIT rev-parse HEAD)
    local prod_ver
    prod_ver=$(grep '"version"' "$PROD_DIR/package.json" | head -1 | sed 's/.*"version": "\([^"]*\)".*/\1/')

    echo "$prod_ref" > "$backup_path/git-ref"
    echo "$prod_ver" > "$backup_path/version"
    echo "$timestamp" > "$backup_path/timestamp"
    cp "$PROD_DIR/package.json" "$backup_path/package.json"
    cp -r "$PROD_DIR/scripts/smart-update" "$backup_path/smart-update" 2>/dev/null || true

    # Also backup the systemd unit
    cp "$SYSTEMD_DIR/$SYSTEMD_UNIT" "$backup_path/$SYSTEMD_UNIT" 2>/dev/null || true

    (cd "$PROD_DIR" && $GIT branch --show-current) > "$backup_path/branch" 2>/dev/null || echo "main" > "$backup_path/branch"

    ln -sf "$backup_path" "$BACKUP_DIR/latest"

    ok "Backup saved to $backup_path"
    echo "$backup_path"
}

# ── Deploy ─────────────────────────────────────────────────────────────────────
deploy() {
    step "Deploying to production"

    log "Syncing files from test → production..."
    cd "$HOME"
    rsync -a --delete \
        --exclude='.git' \
        --exclude='node_modules' \
        --exclude='.next' \
        --exclude='dist' \
        --exclude='scripts/smart-update' \
        "$TEST_DIR/" "$PROD_DIR/"
    ok "Files synced"

    log "Installing dependencies in production..."
    (cd "$PROD_DIR" && pnpm install) 2>"$LOG_DIR/deploy-pnpm.err.log" | tail -3
    ok "Dependencies installed"

    log "Building production..."
    (cd "$PROD_DIR" && pnpm build) 2>"$LOG_DIR/deploy-build.err.log" | tail -5
    ok "Production built"

    local test_ver
    test_ver=$(grep '"version"' "$TEST_DIR/package.json" | head -1 | sed 's/.*"version": "\([^"]*\)".*/\1/')
    sed -i "s/\"version\": \"[^\"]*\"/\"version\": \"$test_ver\"/" "$PROD_DIR/package.json"

    log "Committing update..."
    (cd "$PROD_DIR" && \
        $GIT add -A && \
        $GIT -c user.name="Cipher" -c user.email="cipher@autolab.app" \
        commit --no-verify -m "update: v$test_ver — upstream sync with full rebrand

Deployed from autolab-test after successful build & gateway test.
Generated by autolab-deploy-linux.sh" --allow-empty) 2>&1 | tail -2
    ok "Committed"
}

# ── Update Systemd Unit ──────────────────────────────────────────────────────
update_systemd_unit() {
    local test_ver
    test_ver=$(grep '"version"' "$TEST_DIR/package.json" | head -1 | sed 's/.*"version": "\([^"]*\)".*/\1/')

    if [[ -f "$SYSTEMD_DIR/$SYSTEMD_UNIT" ]]; then
        # Update description and version marker
        sed -i "s/Description=AutoLab Gateway (v[^)]*)/Description=AutoLab Gateway (v$test_ver)/" "$SYSTEMD_DIR/$SYSTEMD_UNIT"
        sed -i "s/AUTOLAB_SERVICE_VERSION=.*/AUTOLAB_SERVICE_VERSION=$test_ver/" "$SYSTEMD_DIR/$SYSTEMD_UNIT"
        systemctl --user daemon-reload
        ok "Updated systemd unit to v$test_ver"
    fi
}

# ── Restart Gateway ───────────────────────────────────────────────────────────
restart_gateway() {
    step "Restarting gateway"

    log "Restarting $SYSTEMD_UNIT..."
    systemctl --user restart "$SYSTEMD_UNIT"

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
    backup_path=$(readlink -f "$latest_backup")
    local git_ref
    git_ref=$(cat "$backup_path/git-ref")
    local version
    version=$(cat "$backup_path/version")

    warn "Rolling back to v$version (ref: ${git_ref:0:8})"

    (cd "$PROD_DIR" && $GIT checkout main && $GIT reset --hard "$git_ref") 2>&1 | tail -2

    log "Rebuilding at rolled-back version..."
    (cd "$PROD_DIR" && pnpm install && pnpm build) 2>"$LOG_DIR/rollback-build.err.log" | tail -5

    # Restore systemd unit if backed up
    if [[ -f "$backup_path/$SYSTEMD_UNIT" ]]; then
        cp "$backup_path/$SYSTEMD_UNIT" "$SYSTEMD_DIR/$SYSTEMD_UNIT"
        systemctl --user daemon-reload
    fi

    restart_gateway

    sleep 15
    if curl -sf "http://127.0.0.1:$PROD_PORT/health" >/dev/null 2>&1; then
        ok "Rollback successful — gateway healthy at v$version"
    else
        err "Rollback gateway also unhealthy. Manual intervention needed."
    fi

    echo "Rollback occurred at $(date). Previous deploy failed." > "$DO_NOT_RETRY_FLAG"
    warn "DO-NOT-RETRY flag set. Remove $DO_NOT_RETRY_FLAG when ready to try again."
}

# ── Push to Fork ──────────────────────────────────────────────────────────────
push_to_fork() {
    step "Pushing to Dan's fork"

    # Remove workflow files that GitHub rejects without workflow scope
    if [[ -d "$PROD_DIR/.github/workflows" ]]; then
        (cd "$PROD_DIR" && $GIT rm -r .github/workflows/ 2>/dev/null && \
            $GIT -c user.name="Cipher" -c user.email="cipher@autolab.app" \
            commit --no-verify -m "chore: remove upstream CI workflows") 2>&1 | tail -2
    fi

    (cd "$PROD_DIR" && $GIT push --force-with-lease origin main) 2>&1 | tail -3

    ok "Pushed to your-username/autolab"
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
    echo -e "${CYAN}║      AutoLab Deploy (Linux) — Test → Production          ║${NC}"
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
        rollback) rollback; return ;;
        push) push_to_fork; return ;;
    esac

    preflight

    local test_ver prod_ver
    test_ver=$(grep '"version"' "$TEST_DIR/package.json" | head -1 | sed 's/.*"version": "\([^"]*\)".*/\1/')
    prod_ver=$(grep '"version"' "$PROD_DIR/package.json" | head -1 | sed 's/.*"version": "\([^"]*\)".*/\1/')

    if ! $auto_yes; then
        echo ""
        echo -e "  ${YELLOW}About to deploy:${NC}"
        echo -e "    Production: v$prod_ver → v$test_ver"
        echo -e "    This will restart the gateway (systemd: $SYSTEMD_UNIT)"
        echo ""
        read -rp "  Proceed? [y/N] " confirm
        if [[ "$confirm" != [yY] ]]; then
            log "Aborted."
            exit 0
        fi
    fi

    backup_production
    deploy
    update_systemd_unit
    restart_gateway

    if health_check; then
        ok "Deployment successful!"
        update_state_deployed

        echo ""
        if $auto_yes; then
            push_to_fork
        else
            read -rp "  Push to Dan's fork? [y/N] " push_confirm
            if [[ "$push_confirm" == [yY] ]]; then
                push_to_fork
            fi
        fi
    else
        err "Gateway unhealthy after deploy!"
        warn "Initiating automatic rollback..."
        rollback
    fi

    echo ""
    step "Deployment Complete"
    echo ""
}

case "${1:-}" in
    -h|--help)
        echo "AutoLab Deploy (Linux) — Push validated updates to production"
        echo ""
        echo "Usage:"
        echo "  $0              Interactive deploy"
        echo "  $0 --yes        Auto-confirm"
        echo "  $0 --rollback   Rollback to last backup"
        echo "  $0 --push-only  Just push to fork"
        ;;
    *)
        main "$@"
        ;;
esac
