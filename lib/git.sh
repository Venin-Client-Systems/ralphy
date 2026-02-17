# ============================================
# GIT BRANCH MANAGEMENT
# ============================================

create_task_branch() {
  local task=$1
  local branch_name="ralphy/$(slugify "$task")"

  log_debug "Creating branch: $branch_name from $BASE_BRANCH"

  # Stash any changes (only pop if a new stash was created)
  local stash_before stash_after stashed=false
  stash_before=$(git stash list -1 --format='%gd %s' 2>/dev/null || true)
  git stash push -m "ralphy-autostash" >/dev/null 2>&1 || true
  stash_after=$(git stash list -1 --format='%gd %s' 2>/dev/null || true)
  if [[ -n "$stash_after" ]] && [[ "$stash_after" != "$stash_before" ]] && [[ "$stash_after" == *"ralphy-autostash"* ]]; then
    stashed=true
  fi

  # Create and checkout new branch
  git checkout "$BASE_BRANCH" 2>/dev/null || true
  git pull origin "$BASE_BRANCH" 2>/dev/null || true
  git checkout -b "$branch_name" 2>/dev/null || {
    # Branch might already exist
    git checkout "$branch_name" 2>/dev/null || true
  }

  # Pop stash if we stashed
  if [[ "$stashed" == true ]]; then
    git stash pop >/dev/null 2>&1 || true
  fi

  task_branches+=("$branch_name")
  echo "$branch_name"
}

create_pull_request() {
  local branch=$1
  local task=$2
  local body="${3:-Automated PR created by Ralphy}"

  local draft_flag=""
  [[ "$PR_DRAFT" == true ]] && draft_flag="--draft"

  log_info "Creating pull request for $branch..."

  # Push branch first
  git push -u origin "$branch" 2>/dev/null || {
    log_warn "Failed to push branch $branch"
    return 1
  }

  # Create PR
  local pr_url
  pr_url=$(gh pr create \
    --base "$BASE_BRANCH" \
    --head "$branch" \
    --title "$task" \
    --body "$body" \
    $draft_flag 2>/dev/null) || {
    log_warn "Failed to create PR for $branch"
    return 1
  }

  log_success "PR created: $pr_url"
  echo "$pr_url"
}

return_to_base_branch() {
  if [[ "$BRANCH_PER_TASK" == true ]]; then
    git checkout "$BASE_BRANCH" 2>/dev/null || true
  fi
}

# Delete a task branch that produced no useful work (failed/empty).
# Must already be on BASE_BRANCH (call return_to_base_branch first).
# Args: $1=branch_name
cleanup_failed_branch() {
  local branch="$1"
  if [[ -z "$branch" ]] || [[ "$BRANCH_PER_TASK" != true ]]; then
    return 0
  fi
  if git branch -D "$branch" >/dev/null 2>&1; then
    log_debug "Deleted failed task branch: $branch"
  else
    log_warn "Could not delete failed task branch: $branch"
  fi
}

# Merge a task branch into BASE_BRANCH, verify, and delete.
# Called after return_to_base_branch (must already be on BASE_BRANCH).
# Skipped when CREATE_PR=true (branch stays for the PR).
# Args: $1=branch_name  $2=repo_dir (optional, defaults to pwd)
merge_and_cleanup_branch() {
  local branch="$1"
  local repo_dir="${2:-.}"

  # Nothing to do if no branch or PRs are being created
  if [[ -z "$branch" ]] || [[ "$branch" == "unknown" ]]; then
    return 0
  fi
  if [[ "$CREATE_PR" == true ]]; then
    return 0
  fi

  # Verify we're on the expected branch before merging
  local current_head
  current_head=$(git -C "$repo_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  if [[ "$current_head" != "$BASE_BRANCH" ]]; then
    log_warn "Expected $BASE_BRANCH but on $current_head — skipping merge of $branch"
    return 1
  fi

  # Stash uncommitted bookkeeping files before merge
  local stash_created=false
  local stash_status
  stash_status=$(git -C "$repo_dir" status --porcelain -- progress.txt RALPHY_LESSONS.md 2>/dev/null || true)
  if [[ -n "$stash_status" ]]; then
    if git -C "$repo_dir" stash push -m "ralphy-pre-merge-$$" -- progress.txt RALPHY_LESSONS.md >/dev/null 2>&1; then
      stash_created=true
      log_debug "Stashed bookkeeping files before merge"
    fi
  fi

  if git -C "$repo_dir" merge --no-edit "$branch" >/dev/null 2>&1; then
    log_debug "Merged $branch into $BASE_BRANCH"

    # Restore stashed bookkeeping files
    if [[ "$stash_created" == true ]]; then
      git -C "$repo_dir" stash pop --quiet 2>/dev/null || true
    fi

    # Verify merge landed, then delete branch
    if guardrail_verify_merge "$branch" "$repo_dir"; then
      if ! git -C "$repo_dir" branch -d "$branch" >/dev/null 2>&1; then
        log_warn "Branch deletion failed for $branch (merge verified, but git branch -d refused) — manual cleanup needed"
      fi
    else
      log_warn "Merge verification failed for $branch — branch preserved"
    fi
  else
    # Restore stash on merge failure
    if [[ "$stash_created" == true ]]; then
      git -C "$repo_dir" stash pop --quiet 2>/dev/null || true
    fi

    log_warn "Merge conflict merging $branch into $BASE_BRANCH — aborting merge, branch preserved"
    git -C "$repo_dir" merge --abort 2>/dev/null || true
    guardrail_update_branch "$branch" "failed"
    return 1
  fi
}
