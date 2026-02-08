# ============================================
# ARGUMENT PARSING
# ============================================

parse_args() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      --no-tests|--skip-tests)
        SKIP_TESTS=true
        shift
        ;;
      --no-lint|--skip-lint)
        SKIP_LINT=true
        shift
        ;;
      --fast)
        SKIP_TESTS=true
        SKIP_LINT=true
        shift
        ;;
      --opencode)
        AI_ENGINE="opencode"
        shift
        ;;
      --claude)
        AI_ENGINE="claude"
        shift
        ;;
      --cursor|--agent)
        AI_ENGINE="cursor"
        shift
        ;;
      --codex)
        AI_ENGINE="codex"
        shift
        ;;
      --qwen)
        AI_ENGINE="qwen"
        shift
        ;;
      --fallback)
        local fallback_value="${2:-claude}"
        if [[ -z "$FALLBACK_ENGINE" ]]; then
          FALLBACK_ENGINE="$fallback_value"
        else
          FALLBACK_ENGINE="${FALLBACK_ENGINE},${fallback_value}"
        fi
        shift 2
        ;;
      --test-fallback)
        # Simulate rate limit on first attempt to test fallback mechanism
        TEST_FALLBACK=true
        shift
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      --max-iterations)
        MAX_ITERATIONS="${2:-0}"
        shift 2
        ;;
      --max-retries)
        MAX_RETRIES="${2:-3}"
        shift 2
        ;;
      --retry-delay)
        RETRY_DELAY="${2:-5}"
        shift 2
        ;;
      --parallel)
        PARALLEL=true
        shift
        ;;
      --max-parallel)
        MAX_PARALLEL="${2:-3}"
        shift 2
        ;;
      --no-auto-parallel)
        AUTO_PARALLEL=false
        shift
        ;;
      --branch-per-task)
        BRANCH_PER_TASK=true
        shift
        ;;
      --base-branch)
        BASE_BRANCH="${2:-}"
        shift 2
        ;;
      --create-pr)
        CREATE_PR=true
        shift
        ;;
      --draft-pr)
        PR_DRAFT=true
        shift
        ;;
      --prd)
        PRD_FILE="${2:-PRD.md}"
        PRD_SOURCE="markdown"
        shift 2
        ;;
      --yaml)
        PRD_FILE="${2:-tasks.yaml}"
        PRD_SOURCE="yaml"
        shift 2
        ;;
      --github)
        GITHUB_REPO="${2:-}"
        PRD_SOURCE="github"
        shift 2
        ;;
      --github-label)
        GITHUB_LABEL="${2:-}"
        shift 2
        ;;
      --project)
        # Format: --project OWNER/NUM (e.g., Venin-Client-Systems/2)
        local project_val="${2:-}"
        PROJECT_BOARD_OWNER="${project_val%%/*}"
        PROJECT_BOARD_NUM="${project_val##*/}"
        shift 2
        ;;
      -v|--verbose)
        VERBOSE=true
        shift
        ;;
      -h|--help)
        show_help
        exit 0
        ;;
      --version)
        show_version
        exit 0
        ;;
      *)
        log_error "Unknown option: $1"
        echo "Use --help for usage"
        exit 1
        ;;
    esac
  done
}
