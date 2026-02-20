#!/usr/bin/env bash

# ============================================
# Ralphy - Autonomous AI Coding Loop
# Supports Claude Code, OpenCode, Codex, and Cursor
# Runs until PRD is complete
# ============================================

set -euo pipefail

# Resolve the directory where ralphy.sh lives (follows symlinks)
RALPHY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source all modules in dependency order
source "$RALPHY_DIR/lib/config.sh"
source "$RALPHY_DIR/lib/utils.sh"
source "$RALPHY_DIR/lib/help.sh"
source "$RALPHY_DIR/lib/args.sh"
source "$RALPHY_DIR/lib/github.sh"
source "$RALPHY_DIR/lib/coordination.sh"
source "$RALPHY_DIR/lib/notifications.sh"
source "$RALPHY_DIR/lib/cleanup.sh"
source "$RALPHY_DIR/lib/domain.sh"
source "$RALPHY_DIR/lib/sources/markdown.sh"
source "$RALPHY_DIR/lib/sources/yaml.sh"
source "$RALPHY_DIR/lib/sources/github.sh"
source "$RALPHY_DIR/lib/sources/dispatch.sh"
source "$RALPHY_DIR/lib/git.sh"
source "$RALPHY_DIR/lib/monitor.sh"
source "$RALPHY_DIR/lib/prompt.sh"
source "$RALPHY_DIR/lib/engines.sh"
source "$RALPHY_DIR/lib/cost.sh"
source "$RALPHY_DIR/lib/preflight.sh"
source "$RALPHY_DIR/lib/guardrails.sh"
source "$RALPHY_DIR/lib/execution.sh"
source "$RALPHY_DIR/lib/parallel.sh"
source "$RALPHY_DIR/lib/summary.sh"
source "$RALPHY_DIR/lib/main.sh"

# Run main
main "$@"
