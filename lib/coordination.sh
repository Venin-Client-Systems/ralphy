# ============================================
# MULTI-INSTANCE COORDINATION
# ============================================

# Get a hash of the current repo for lock file namespacing
get_repo_hash() {
  local repo_root
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
  echo "$repo_root" | md5sum 2>/dev/null | cut -c1-12 || echo "$repo_root" | shasum | cut -c1-12
}

# Initialize lock file for this instance
init_instance_lock() {
  local repo_hash
  repo_hash=$(get_repo_hash)
  local lock_dir="${RALPHY_LOCK_DIR}/${repo_hash}"
  mkdir -p "$lock_dir"

  RALPHY_LOCK_FILE="${lock_dir}/${RALPHY_PID}.json"

  # Write initial lock file
  cat > "$RALPHY_LOCK_FILE" << EOF
{
  "pid": $RALPHY_PID,
  "label": "${GITHUB_LABEL:-}",
  "repo": "${GITHUB_REPO:-}",
  "prd_source": "${PRD_SOURCE}",
  "base_branch": "${BASE_BRANCH:-}",
  "started": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "current_issues": [],
  "cwd": "$(pwd)"
}
EOF
  log_debug "Created instance lock: $RALPHY_LOCK_FILE"
}

# Cleanup lock file on exit
cleanup_instance_lock() {
  if [[ -n "$RALPHY_LOCK_FILE" ]] && [[ -f "$RALPHY_LOCK_FILE" ]]; then
    rm -f "$RALPHY_LOCK_FILE"
    log_debug "Removed instance lock: $RALPHY_LOCK_FILE"
  fi
}

# Get list of other running ralphy instances (returns JSON lines)
get_other_instances() {
  local repo_hash
  repo_hash=$(get_repo_hash)
  local lock_dir="${RALPHY_LOCK_DIR}/${repo_hash}"

  [[ ! -d "$lock_dir" ]] && return

  for lock_file in "$lock_dir"/*.json; do
    [[ ! -f "$lock_file" ]] && continue

    local pid
    pid=$(jq -r '.pid' "$lock_file" 2>/dev/null || echo "")
    [[ -z "$pid" ]] && continue

    # Skip our own instance
    [[ "$pid" == "$RALPHY_PID" ]] && continue

    # Check if process is still alive
    if kill -0 "$pid" 2>/dev/null; then
      cat "$lock_file"
    else
      # Stale lock file, remove it
      rm -f "$lock_file" 2>/dev/null || true
    fi
  done
}

# Show status of other running instances
show_instance_status() {
  local instances
  instances=$(get_other_instances)

  [[ -z "$instances" ]] && return 0

  echo ""
  echo "${BOLD}>>> Other Ralphy Instances Running${RESET}"

  local count=0
  while IFS= read -r instance; do
    [[ -z "$instance" ]] && continue
    ((count++))

    local pid label issues started
    pid=$(echo "$instance" | jq -r '.pid')
    label=$(echo "$instance" | jq -r '.label // "none"')
    issues=$(echo "$instance" | jq -r '.current_issues | if length > 0 then map(tostring) | join(", ") else "idle" end')
    started=$(echo "$instance" | jq -r '.started // "unknown"')

    echo "  ${CYAN}◉${RESET} PID $pid: ${YELLOW}$label${RESET} (issues: $issues)"
  done <<< "$instances"

  if [[ $count -gt 0 ]]; then
    echo ""
    echo "${DIM}Issue claiming is active - instances will coordinate automatically${RESET}"
  fi

  return 0
}

# Claim an issue (mark as being worked on by this instance)
claim_issue() {
  local issue_num="$1"
  [[ -z "$issue_num" ]] && return 1

  # Add to local tracking
  CLAIMED_ISSUES+=("$issue_num")

  # Update lock file
  if [[ -n "$RALPHY_LOCK_FILE" ]] && [[ -f "$RALPHY_LOCK_FILE" ]]; then
    local issues_json
    issues_json=$(printf '%s\n' "${CLAIMED_ISSUES[@]}" | jq -R . | jq -s .)
    jq --argjson issues "$issues_json" '.current_issues = $issues' "$RALPHY_LOCK_FILE" > "${RALPHY_LOCK_FILE}.tmp" && \
      mv "${RALPHY_LOCK_FILE}.tmp" "$RALPHY_LOCK_FILE"
  fi

  log_debug "Claimed issue: $issue_num"
}

# Release an issue (unmark when done)
release_issue() {
  local issue_num="$1"
  [[ -z "$issue_num" ]] && return

  # Remove from local tracking
  local new_claimed=()
  for i in "${CLAIMED_ISSUES[@]}"; do
    [[ "$i" != "$issue_num" ]] && new_claimed+=("$i")
  done
  CLAIMED_ISSUES=("${new_claimed[@]}")

  # Update lock file
  if [[ -n "$RALPHY_LOCK_FILE" ]] && [[ -f "$RALPHY_LOCK_FILE" ]]; then
    local issues_json
    if [[ ${#CLAIMED_ISSUES[@]} -gt 0 ]]; then
      issues_json=$(printf '%s\n' "${CLAIMED_ISSUES[@]}" | jq -R . | jq -s .)
    else
      issues_json="[]"
    fi
    jq --argjson issues "$issues_json" '.current_issues = $issues' "$RALPHY_LOCK_FILE" > "${RALPHY_LOCK_FILE}.tmp" && \
      mv "${RALPHY_LOCK_FILE}.tmp" "$RALPHY_LOCK_FILE"
  fi

  log_debug "Released issue: $issue_num"
}

# Check if an issue is claimed by another instance
is_issue_claimed() {
  local issue_num="$1"
  [[ -z "$issue_num" ]] && return 1

  local instances
  instances=$(get_other_instances)
  [[ -z "$instances" ]] && return 1

  while IFS= read -r instance; do
    [[ -z "$instance" ]] && continue

    local claimed
    claimed=$(echo "$instance" | jq -r ".current_issues[]" 2>/dev/null || true)

    for claimed_num in $claimed; do
      if [[ "$claimed_num" == "$issue_num" ]]; then
        return 0  # Issue is claimed
      fi
    done
  done <<< "$instances"

  return 1  # Issue is not claimed
}
