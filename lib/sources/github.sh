# ============================================
# TASK SOURCES - GITHUB ISSUES
# ============================================

get_tasks_github() {
  local args=(--repo "$GITHUB_REPO" --state open --limit 500 --json number,title --search "sort:created-asc")
  [[ -n "$GITHUB_LABEL" ]] && args+=(--label "$GITHUB_LABEL")

  gh issue list "${args[@]}" \
    --jq '.[] | "\(.number):\(.title)"' 2>/dev/null || true
}

get_next_task_github() {
  local args=(--repo "$GITHUB_REPO" --state open --limit 1 --json number,title --search "sort:created-asc")
  [[ -n "$GITHUB_LABEL" ]] && args+=(--label "$GITHUB_LABEL")

  gh issue list "${args[@]}" \
    --jq 'if length == 0 then "" else .[0] | "\(.number):\(.title)" end' 2>/dev/null || echo ""
}

count_remaining_github() {
  local args=(--repo "$GITHUB_REPO" --state open --limit 500 --json number)
  [[ -n "$GITHUB_LABEL" ]] && args+=(--label "$GITHUB_LABEL")

  gh issue list "${args[@]}" \
    --jq 'length' 2>/dev/null || echo "0"
}

count_completed_github() {
  local args=(--repo "$GITHUB_REPO" --state closed --limit 500 --json number)
  [[ -n "$GITHUB_LABEL" ]] && args+=(--label "$GITHUB_LABEL")

  gh issue list "${args[@]}" \
    --jq 'length' 2>/dev/null || echo "0"
}

mark_task_complete_github() {
  local task=$1
  local comment="${2:-}"
  # Extract issue number from "number:title" format
  local issue_num="${task%%:*}"

  # Add completion comment before closing (required)
  if [[ -n "$comment" ]]; then
    gh issue comment "$issue_num" --repo "$GITHUB_REPO" --body "$comment" >/dev/null 2>/dev/null || true
  else
    # Default comment if none provided
    gh issue comment "$issue_num" --repo "$GITHUB_REPO" --body "Task completed by Ralphy automated workflow." >/dev/null 2>/dev/null || true
  fi

  # Now close the issue
  gh issue close "$issue_num" --repo "$GITHUB_REPO" >/dev/null 2>/dev/null || true

  # Remove from blocked arrays — if a prior attempt was blocked but this one
  # succeeded, the issue isn't actually blocked anymore
  local new_blocked=()
  local new_reasons=()
  for i in "${!blocked_issues[@]}"; do
    local blocked_num="${blocked_issues[$i]%%:*}"
    if [[ "$blocked_num" != "$issue_num" ]]; then
      new_blocked+=("${blocked_issues[$i]}")
      new_reasons+=("${blocked_reasons[$i]}")
    fi
  done
  blocked_issues=("${new_blocked[@]+"${new_blocked[@]}"}")
  blocked_reasons=("${new_reasons[@]+"${new_reasons[@]}"}")
}

# Check if a GitHub issue has a label that allows closing without code changes
# Labels: no-code-required, decision, documentation, chore, wontfix, duplicate, invalid
issue_allows_no_code() {
  local task=$1
  local issue_num="${task%%:*}"

  local labels
  labels=$(gh issue view "$issue_num" --repo "$GITHUB_REPO" --json labels --jq '.labels[].name' 2>/dev/null || echo "")

  # Check for any label that indicates no code is required
  local no_code_labels="no-code-required|decision|documentation|docs|chore|wontfix|won't fix|duplicate|invalid|question"
  if echo "$labels" | grep -qiE "^($no_code_labels)$"; then
    return 0  # true - no code required
  fi

  return 1  # false - code is required
}

# Mark a GitHub issue as blocked (add label and track for summary)
mark_issue_blocked() {
  local task="$1"
  local reason="$2"
  local issue_num="${task%%:*}"

  # Add to tracking arrays
  blocked_issues+=("$task")
  blocked_reasons+=("$reason")

  # Add ralphy-blocked label to the issue
  if [[ "$PRD_SOURCE" == "github" ]] && [[ -n "$GITHUB_REPO" ]]; then
    gh issue edit "$issue_num" --repo "$GITHUB_REPO" --add-label "ralphy-blocked" >/dev/null 2>/dev/null || true
    gh issue comment "$issue_num" --repo "$GITHUB_REPO" --body "## Ralphy Blocked

**Reason:** $reason

This issue was skipped by Ralphy and needs manual review.

**To unblock:**
- If no code changes are needed, add one of these labels: \`chore\`, \`documentation\`, \`decision\`, \`no-code-required\`
- Remove the \`ralphy-blocked\` label
- Re-run ralphy" >/dev/null 2>/dev/null || true
  fi

  # Update project board status to Blocked
  project_board_set_status "$issue_num" "Blocked"

  log_warn "Issue $issue_num blocked: $reason"
}

# Check if a task title indicates it's a docs/chore issue that shouldn't require code
is_docs_or_chore_task() {
  local title="$1"
  # Match [Docs], [Documentation], [Chore], [Decision], etc. at start of title
  if echo "$title" | grep -qiE '^\[docs\]|^\[documentation\]|^\[chore\]|^\[decision\]|^\[planning\]|^\[rfc\]'; then
    return 0  # true
  fi
  return 1  # false
}

# Auto-add documentation label to docs issues so they can close without code changes
auto_label_docs_issue() {
  local task="$1"
  local issue_num="${task%%:*}"
  local title="${task#*:}"

  if [[ "$PRD_SOURCE" != "github" ]] || [[ -z "$GITHUB_REPO" ]]; then
    return 1
  fi

  # Check if it's a docs/chore task by title
  if is_docs_or_chore_task "$title"; then
    # Check if it already has a no-code-required label
    if ! issue_allows_no_code "$task"; then
      log_info "Auto-adding 'documentation' label to docs issue #$issue_num"
      gh issue edit "$issue_num" --repo "$GITHUB_REPO" --add-label "documentation" >/dev/null 2>/dev/null || true
      return 0
    fi
  fi
  return 1
}

# Track a failed task and check for loops
# Returns 0 if loop detected (same task failed too many times), 1 otherwise
track_failed_task() {
  local task="$1"
  local issue_num="${task%%:*}"

  # Add to recent failures
  recent_failed_tasks+=("$issue_num")

  # Keep only last N*2 entries (enough to detect patterns)
  local max_entries=$((MAX_CONSECUTIVE_FAILURES * 2))
  if [[ ${#recent_failed_tasks[@]} -gt $max_entries ]]; then
    recent_failed_tasks=("${recent_failed_tasks[@]: -$max_entries}")
  fi

  # Count consecutive failures of this specific issue
  local consecutive=0
  for ((i=${#recent_failed_tasks[@]}-1; i>=0; i--)); do
    if [[ "${recent_failed_tasks[$i]}" == "$issue_num" ]]; then
      ((consecutive++)) || true
    else
      break  # Different issue, stop counting
    fi
  done

  if [[ $consecutive -ge $MAX_CONSECUTIVE_FAILURES ]]; then
    return 0  # Loop detected
  fi
  return 1  # No loop
}

# Handle a detected loop - try to fix or exit gracefully
handle_task_loop() {
  local task="$1"
  local issue_num="${task%%:*}"
  local title="${task#*:}"

  echo ""
  echo "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo "${RED}LOOP DETECTED${RESET}: Issue #$issue_num failed $MAX_CONSECUTIVE_FAILURES+ times consecutively"
  echo "${DIM}$title${RESET}"
  echo "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo ""

  # Try to auto-fix if it's a docs issue
  if is_docs_or_chore_task "$title"; then
    echo "${YELLOW}This appears to be a documentation/chore issue.${RESET}"
    echo "${YELLOW}Attempting auto-fix: adding 'documentation' label...${RESET}"

    if gh issue edit "$issue_num" --repo "$GITHUB_REPO" --add-label "documentation" 2>/dev/null; then
      echo "${GREEN}✓ Added 'documentation' label to issue #$issue_num${RESET}"
      echo "${GREEN}The issue should now close on the next attempt.${RESET}"
      echo ""
      # Clear the failure tracking for this issue so it gets another chance
      recent_failed_tasks=()
      return 0  # Continue running
    else
      echo "${RED}✗ Failed to add label. Manual intervention required.${RESET}"
    fi
  fi

  # Can't auto-fix - block and exit
  echo ""
  echo "${YELLOW}Ralphy is stopping to prevent infinite loop.${RESET}"
  echo ""
  echo "${BOLD}To fix this issue:${RESET}"
  echo "  1. Add one of these labels: ${CYAN}documentation${RESET}, ${CYAN}chore${RESET}, ${CYAN}no-code-required${RESET}, ${CYAN}decision${RESET}"
  echo "  2. Re-run: ${CYAN}ralphy $GITHUB_LABEL${RESET}"
  echo ""

  # Mark blocked so it shows in summary
  mark_issue_blocked "$task" "Loop detected - task failed $MAX_CONSECUTIVE_FAILURES+ times"

  return 1  # Signal to exit
}

get_github_issue_body() {
  local task=$1
  local issue_num="${task%%:*}"
  gh issue view "$issue_num" --repo "$GITHUB_REPO" --json body --jq '.body' 2>/dev/null || echo ""
}

get_github_issue_labels() {
  local task=$1
  local issue_num="${task%%:*}"
  gh issue view "$issue_num" --repo "$GITHUB_REPO" --json labels --jq '[.labels[].name] | join(",")' 2>/dev/null || echo ""
}
