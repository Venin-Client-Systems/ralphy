# ============================================
# UTILITY FUNCTIONS
# ============================================

log_info() {
  echo "${BLUE}[INFO]${RESET} $*"
}

log_success() {
  echo "${GREEN}[OK]${RESET} $*"
}

log_warn() {
  echo "${YELLOW}[WARN]${RESET} $*"
}

log_error() {
  echo "${RED}[ERROR]${RESET} $*" >&2
}

log_debug() {
  if [[ "$VERBOSE" == true ]]; then
    echo "${DIM}[DEBUG] $*${RESET}"
  fi
}

# Slugify text for branch names
slugify() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g' | sed -E 's/^-|-$//g' | cut -c1-50
}

# Check for non-trivial file changes between two refs (exclude progress/docs/README/CHANGELOG)
has_code_changes_between() {
  local base_ref="$1"
  local head_ref="$2"
  local repo_dir="${3:-}"

  if [[ -z "$base_ref" || -z "$head_ref" ]]; then
    return 1
  fi

  local diff_files
  if [[ -n "$repo_dir" ]]; then
    diff_files=$(git -C "$repo_dir" diff --name-only "$base_ref".."$head_ref" 2>/dev/null || true)
  else
    diff_files=$(git diff --name-only "$base_ref".."$head_ref" 2>/dev/null || true)
  fi
  local skip_regex='^(progress\.txt|README(\.[^/]+)?|CHANGELOG(\.[^/]+)?|docs/|doc/)'
  diff_files=$(echo "$diff_files" | grep -Ev "$skip_regex" | sed '/^$/d' || true)

  [[ -n "$diff_files" ]]
}
