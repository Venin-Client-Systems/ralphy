# ============================================
# ENGINE HELPERS
# ============================================

init_fallback_engines() {
  FALLBACK_ENGINES=()
  FALLBACK_INDEX=0
  FALLBACK_USED=false

  if [[ -z "$FALLBACK_ENGINE" ]]; then
    return
  fi

  local raw
  raw=$(echo "$FALLBACK_ENGINE" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
  IFS=',' read -r -a FALLBACK_ENGINES <<< "$raw"
}

engine_display_name() {
  local engine="$1"
  case "$engine" in
    opencode) echo "${CYAN}OpenCode${RESET}" ;;
    cursor) echo "${YELLOW}Cursor Agent${RESET}" ;;
    codex) echo "${BLUE}Codex${RESET}" ;;
    qwen) echo "${GREEN}Qwen-Code${RESET}" ;;
    claude|"") echo "${MAGENTA}Claude Code${RESET}" ;;
    *) echo "${MAGENTA}${engine}${RESET}" ;;
  esac
}

require_engine_cli() {
  local engine="$1"
  case "$engine" in
    opencode)
      if ! command -v opencode &>/dev/null; then
        log_error "OpenCode CLI not found. Install from https://opencode.ai/docs/"
        exit 1
      fi
      ;;
    codex)
      if ! command -v codex &>/dev/null; then
        log_error "Codex CLI not found. Make sure 'codex' is in your PATH."
        exit 1
      fi
      ;;
    cursor)
      if ! command -v agent &>/dev/null; then
        log_error "Cursor agent CLI not found. Make sure Cursor is installed and 'agent' is in your PATH."
        exit 1
      fi
      ;;
    qwen)
      if ! command -v qwen &>/dev/null; then
        log_error "Qwen-Code CLI not found. Make sure 'qwen' is in your PATH."
        exit 1
      fi
      ;;
    claude|"")
      if ! command -v claude &>/dev/null; then
        log_error "Claude Code CLI not found. Install from https://github.com/anthropics/claude-code"
        exit 1
      fi
      ;;
    *)
      log_error "Unknown AI engine: $engine"
      exit 1
      ;;
  esac
}

# ============================================
# PRE-FLIGHT CHECKS
# ============================================

check_requirements() {
  local missing=()

  # Check for PRD source
  case "$PRD_SOURCE" in
    markdown)
      if [[ ! -f "$PRD_FILE" ]]; then
        log_error "$PRD_FILE not found in current directory"
        exit 1
      fi
      ;;
    yaml)
      if [[ ! -f "$PRD_FILE" ]]; then
        log_error "$PRD_FILE not found in current directory"
        exit 1
      fi
      if ! command -v yq &>/dev/null; then
        log_error "yq is required for YAML parsing. Install from https://github.com/mikefarah/yq"
        exit 1
      fi
      ;;
    github)
      if [[ -z "$GITHUB_REPO" ]]; then
        log_error "GitHub repository not specified. Use --github owner/repo"
        exit 1
      fi
      if ! command -v gh &>/dev/null; then
        log_error "GitHub CLI (gh) is required. Install from https://cli.github.com/"
        exit 1
      fi
      ;;
  esac

  # Warn if --github-label used without --github
  if [[ -n "$GITHUB_LABEL" ]] && [[ "$PRD_SOURCE" != "github" ]]; then
    log_warn "--github-label has no effect without --github"
  fi

  # Check for AI CLI
  require_engine_cli "$AI_ENGINE"
  if [[ ${#FALLBACK_ENGINES[@]} -gt 0 ]]; then
    local fallback_engine
    for fallback_engine in "${FALLBACK_ENGINES[@]}"; do
      require_engine_cli "$fallback_engine"
    done
  fi

  # Check for jq
  if ! command -v jq &>/dev/null; then
    missing+=("jq")
  fi

  # Check for gh if PR creation is requested
  if [[ "$CREATE_PR" == true ]] && ! command -v gh &>/dev/null; then
    log_error "GitHub CLI (gh) is required for --create-pr. Install from https://cli.github.com/"
    exit 1
  fi

  if [[ ${#missing[@]} -gt 0 ]]; then
    log_warn "Missing optional dependencies: ${missing[*]}"
    log_warn "Token tracking and multi-instance coordination may not work properly"
  fi

  # Run git state guardrails
  guardrail_preflight
  guardrail_init_ledger

  # Create progress.txt if missing
  if [[ ! -f "progress.txt" ]]; then
    log_warn "progress.txt not found, creating it..."
    touch progress.txt
  fi

  # Set base branch if not specified
  if [[ "$BRANCH_PER_TASK" == true ]] && [[ -z "$BASE_BRANCH" ]]; then
    BASE_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
    log_debug "Using base branch: $BASE_BRANCH"
  fi

  # Auto-detect project board from per-repo config if --project not specified
  if [[ -z "$PROJECT_BOARD_NUM" ]] && [[ "$PRD_SOURCE" == "github" ]] && [[ -n "$GITHUB_REPO" ]]; then
    local config_file="${HOME}/.ralphy/config"
    if [[ -f "$config_file" ]]; then
      # Look up repo-specific mapping: project.<owner/repo>=<owner/project-number>
      local config_project
      config_project=$(grep -E "^project\\.${GITHUB_REPO}=" "$config_file" 2>/dev/null | head -1 | cut -d= -f2-)
      if [[ -n "$config_project" ]]; then
        PROJECT_BOARD_OWNER="${config_project%%/*}"
        PROJECT_BOARD_NUM="${config_project##*/}"
        log_debug "Auto-detected project board for ${GITHUB_REPO}: $PROJECT_BOARD_OWNER/$PROJECT_BOARD_NUM"
      fi
    fi
  fi
}
