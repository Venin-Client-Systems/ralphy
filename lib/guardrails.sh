# ============================================
# GIT STATE GUARDRAILS
# Fail-fast checks at startup, atomic operations
# during execution, audit verification at shutdown.
# ============================================

# ---- Preflight checks ----

guardrail_preflight() {
  log_debug "Running guardrail preflight checks..."

  # 1. Clean working tree: refuse staged/unstaged changes
  local dirty
  dirty=$(git status --porcelain 2>/dev/null | grep -v '^??' || true)
  if [[ -n "$dirty" ]]; then
    log_error "Working directory has uncommitted changes. Commit or stash before running ralphy."
    echo "$dirty" | head -10 >&2
    exit 1
  fi

  # 2. No in-progress git operations
  local git_dir
  git_dir=$(git rev-parse --git-dir 2>/dev/null || echo ".git")

  if [[ -f "$git_dir/MERGE_HEAD" ]]; then
    log_error "A merge is in progress. Complete or abort it before running ralphy."
    exit 1
  fi
  if [[ -d "$git_dir/rebase-merge" ]] || [[ -d "$git_dir/rebase-apply" ]]; then
    log_error "A rebase is in progress. Complete or abort it before running ralphy."
    exit 1
  fi
  if [[ -f "$git_dir/CHERRY_PICK_HEAD" ]]; then
    log_error "A cherry-pick is in progress. Complete or abort it before running ralphy."
    exit 1
  fi

  # 3. Validate BASE_BRANCH if set
  if [[ -n "$BASE_BRANCH" ]]; then
    if [[ "$BASE_BRANCH" == "HEAD" ]]; then
      log_error "BASE_BRANCH is 'HEAD' (detached HEAD state). Checkout a named branch first."
      exit 1
    fi
    if ! git rev-parse --verify "$BASE_BRANCH" >/dev/null 2>&1; then
      log_error "BASE_BRANCH '$BASE_BRANCH' does not exist."
      exit 1
    fi
  fi

  # In sequential mode, verify current branch matches BASE_BRANCH
  if [[ "$PARALLEL" != true ]] && [[ -n "$BASE_BRANCH" ]]; then
    local current_branch
    current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    if [[ "$current_branch" == "HEAD" ]]; then
      log_error "Detached HEAD state. Checkout a named branch before running ralphy."
      exit 1
    fi
    if [[ -n "$current_branch" ]] && [[ "$current_branch" != "$BASE_BRANCH" ]]; then
      log_warn "Current branch '$current_branch' differs from BASE_BRANCH '$BASE_BRANCH'"
    fi
  fi

  # 4. Scan for orphaned ralphy/* branches
  local orphaned_branches
  orphaned_branches=$(git branch --list 'ralphy/*' 2>/dev/null | sed 's/^[* ]*//' || true)
  if [[ -n "$orphaned_branches" ]]; then
    local count
    count=$(echo "$orphaned_branches" | wc -l | tr -d ' ')
    log_error "Found $count orphaned ralphy/* branch(es). Merge or delete them before proceeding."
    echo ""
    while IFS= read -r branch; do
      [[ -z "$branch" ]] && continue
      local commits
      commits=$(git rev-list --count "$branch" --not "$(git merge-base "$branch" HEAD 2>/dev/null || echo HEAD)" 2>/dev/null || echo "?")
      echo "  ${YELLOW}*${RESET} $branch ($commits unique commit(s))" >&2
    done <<< "$orphaned_branches"
    echo "" >&2
    echo "  To delete all:  git branch -D \$(git branch --list 'ralphy/*' | tr -d ' *')" >&2
    echo "  To merge one:   git merge <branch>" >&2
    exit 1
  fi

  # 5. Cross-instance check: warn if another instance targets same repo+branch
  local other_instances
  other_instances=$(get_other_instances 2>/dev/null || true)
  if [[ -n "$other_instances" ]]; then
    local same_branch_instances=0
    while IFS= read -r instance; do
      [[ -z "$instance" ]] && continue
      local inst_branch
      inst_branch=$(echo "$instance" | jq -r '.base_branch // ""' 2>/dev/null || echo "")
      if [[ -n "$inst_branch" ]] && [[ "$inst_branch" == "${BASE_BRANCH:-}" ]]; then
        ((same_branch_instances++)) || true
      fi
    done <<< "$other_instances"

    if [[ $same_branch_instances -gt 0 ]]; then
      log_warn "$same_branch_instances other ralphy instance(s) targeting the same branch. Branches are PID-namespaced to avoid collisions."
    fi
  fi

  log_debug "Guardrail preflight checks passed"
}

# Validate BASE_BRANCH mid-run (called from parallel.sh after BASE_BRANCH is set)
guardrail_validate_base_branch() {
  if [[ -z "$BASE_BRANCH" ]]; then
    log_error "BASE_BRANCH is empty. Cannot proceed with parallel execution."
    exit 1
  fi
  if [[ "$BASE_BRANCH" == "HEAD" ]]; then
    log_error "BASE_BRANCH resolved to 'HEAD' (detached HEAD). Checkout a named branch first."
    exit 1
  fi
  if ! git rev-parse --verify "$BASE_BRANCH" >/dev/null 2>&1; then
    log_error "BASE_BRANCH '$BASE_BRANCH' does not exist."
    exit 1
  fi
  log_debug "BASE_BRANCH '$BASE_BRANCH' validated"
}

# ---- Branch ledger ----

guardrail_init_ledger() {
  local repo_hash
  repo_hash=$(get_repo_hash)
  local ledger_dir="${HOME}/.ralphy/branches"
  mkdir -p "$ledger_dir"

  RALPHY_BRANCH_LEDGER="${ledger_dir}/${repo_hash}.ledger"
  export RALPHY_BRANCH_LEDGER

  # Touch to ensure it exists (append-only, never truncate)
  touch "$RALPHY_BRANCH_LEDGER"
  log_debug "Branch ledger: $RALPHY_BRANCH_LEDGER"
}

guardrail_record_branch() {
  local branch="$1"
  local issue="$2"
  local status="$3"

  if [[ -z "$RALPHY_BRANCH_LEDGER" ]]; then
    return
  fi

  local timestamp
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  echo "$timestamp $branch $issue $status $RALPHY_PID" >> "$RALPHY_BRANCH_LEDGER"
}

guardrail_update_branch() {
  local branch="$1"
  local status="$2"

  if [[ -z "$RALPHY_BRANCH_LEDGER" ]]; then
    return
  fi

  local timestamp
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  echo "$timestamp $branch - $status $RALPHY_PID" >> "$RALPHY_BRANCH_LEDGER"
}

# ---- Atomic worktree creation ----

guardrail_atomic_worktree() {
  local task_name="$1"
  local agent_num="$2"
  local issue="${3:-unknown}"
  local branch_name="ralphy/${RALPHY_PID}-agent-${agent_num}-$(slugify "$task_name")"
  local worktree_dir="${WORKTREE_BASE}/agent-${agent_num}"

  # Run git commands from original directory
  # All git output goes to stderr so it doesn't interfere with our return value
  (
    cd "$ORIGINAL_DIR" || { echo "Failed to cd to $ORIGINAL_DIR" >&2; exit 1; }

    # Prune any stale worktrees first
    git worktree prune >&2 2>/dev/null || true

    # Delete branch if it exists (force) — shouldn't with PID namespace, but be safe
    git branch -D "$branch_name" >&2 2>/dev/null || true

    # Create branch from base
    if ! git branch "$branch_name" "$BASE_BRANCH" >&2; then
      echo "Failed to create branch $branch_name from $BASE_BRANCH" >&2
      exit 1
    fi

    # Remove existing worktree dir if any
    rm -rf "$worktree_dir" 2>/dev/null || true

    # Create worktree — rollback branch on failure
    if ! git worktree add "$worktree_dir" "$branch_name" >&2; then
      echo "Worktree creation failed; rolling back branch $branch_name" >&2
      git branch -D "$branch_name" >&2 2>/dev/null || true
      exit 1
    fi
  )

  local rc=$?
  if [[ $rc -ne 0 ]]; then
    return $rc
  fi

  # Record branch in ledger
  guardrail_record_branch "$branch_name" "$issue" "created"

  # Only output the result
  echo "$worktree_dir|$branch_name"
}

# ---- Lessons merging ----

# Extract new learnings from an agent's worktree and append to the main repo's lessons file.
# Called after a successful merge, before worktree cleanup.
guardrail_merge_lessons() {
  local worktree_dir="$1"
  local repo_dir="${2:-$ORIGINAL_DIR}"

  local worktree_lessons="$worktree_dir/RALPHY_LESSONS.md"
  local main_lessons="$repo_dir/RALPHY_LESSONS.md"

  # Skip if agent didn't have a lessons file
  [[ -f "$worktree_lessons" ]] || return 0
  [[ -f "$main_lessons" ]] || return 0

  # Extract new content after the "Agent Learnings" marker
  local marker="## Agent Learnings"
  local worktree_section main_section

  worktree_section=$(sed -n "/${marker}/,\$p" "$worktree_lessons" 2>/dev/null || echo "")
  main_section=$(sed -n "/${marker}/,\$p" "$main_lessons" 2>/dev/null || echo "")

  # If the agent's section is longer than the main's, there are new entries
  local worktree_lines main_lines
  worktree_lines=$(echo "$worktree_section" | wc -l | tr -d ' ')
  main_lines=$(echo "$main_section" | wc -l | tr -d ' ')

  if [[ "$worktree_lines" -gt "$main_lines" ]]; then
    # Extract only the new lines (after the main file's content)
    local new_entries
    new_entries=$(echo "$worktree_section" | tail -n +"$((main_lines + 1))")

    if [[ -n "$new_entries" ]] && [[ "$new_entries" =~ [^[:space:]] ]]; then
      echo "$new_entries" >> "$main_lessons"
      log_debug "Appended new learnings to RALPHY_LESSONS.md"
    fi
  fi
}

# ---- Merge verification ----

guardrail_verify_merge() {
  local branch="$1"
  local repo_dir="${2:-$ORIGINAL_DIR}"

  # Get the head of the branch before it might be deleted
  local branch_head
  branch_head=$(git -C "$repo_dir" rev-parse "$branch" 2>/dev/null || echo "")

  if [[ -z "$branch_head" ]]; then
    log_warn "Cannot verify merge: branch '$branch' not found"
    guardrail_update_branch "$branch" "orphaned"
    return 1
  fi

  # Verify commits landed: branch head should be ancestor of current HEAD
  if git -C "$repo_dir" merge-base --is-ancestor "$branch_head" HEAD 2>/dev/null; then
    log_debug "Merge verified: $branch commits are in HEAD"
    guardrail_update_branch "$branch" "merged"
    return 0
  else
    log_error "Merge verification FAILED for $branch — commits not in HEAD. Branch preserved."
    guardrail_update_branch "$branch" "orphaned"
    return 1
  fi
}

# ---- Post-run audit ----

guardrail_post_run_audit() {
  # Only audit branches created by THIS instance (PID-namespaced)
  local our_branches
  our_branches=$(git branch --list "ralphy/${RALPHY_PID}-*" 2>/dev/null | sed 's/^[* ]*//' || true)

  if [[ -z "$our_branches" ]]; then
    log_debug "Post-run audit: no unmerged branches from this instance"
    return 0
  fi

  local count=0
  local branch_list=""

  while IFS= read -r branch; do
    [[ -z "$branch" ]] && continue
    ((count++)) || true
    local commits
    commits=$(git rev-list --count "$branch" --not "$(git merge-base "$branch" HEAD 2>/dev/null || echo HEAD)" 2>/dev/null || echo "?")
    branch_list+="  ${YELLOW}*${RESET} $branch ($commits unique commit(s))\n"
    guardrail_update_branch "$branch" "orphaned"
  done <<< "$our_branches"

  if [[ $count -gt 0 ]]; then
    echo ""
    log_warn "$count unmerged branch(es) from this session:"
    printf "$branch_list"
    echo ""
    echo "${DIM}Recovery: merge these branches manually before they are lost${RESET}"
    echo "${DIM}  git merge <branch>        # to merge${RESET}"
    echo "${DIM}  git branch -D <branch>    # to discard${RESET}"
  fi
}
