# ============================================
# PARALLEL TASK EXECUTION
# ============================================

# Create an isolated worktree for a parallel agent
create_agent_worktree() {
  local task_name="$1"
  local agent_num="$2"
  local branch_name="ralphy/agent-${agent_num}-$(slugify "$task_name")"
  local worktree_dir="${WORKTREE_BASE}/agent-${agent_num}"

  # Run git commands from original directory
  # All git output goes to stderr so it doesn't interfere with our return value
  (
    cd "$ORIGINAL_DIR" || { echo "Failed to cd to $ORIGINAL_DIR" >&2; exit 1; }

    # Prune any stale worktrees first
    git worktree prune >&2

    # Delete branch if it exists (force)
    git branch -D "$branch_name" >&2 2>/dev/null || true

    # Create branch from base
    git branch "$branch_name" "$BASE_BRANCH" >&2 || { echo "Failed to create branch $branch_name from $BASE_BRANCH" >&2; exit 1; }

    # Remove existing worktree dir if any
    rm -rf "$worktree_dir" 2>/dev/null || true

    # Create worktree
    git worktree add "$worktree_dir" "$branch_name" >&2 || { echo "Failed to create worktree at $worktree_dir" >&2; exit 1; }
  )

  # Only output the result - git commands above send their output to stderr
  echo "$worktree_dir|$branch_name"
}

# Cleanup worktree after agent completes
cleanup_agent_worktree() {
  local worktree_dir="$1"
  local branch_name="$2"
  local log_file="${3:-}"
  local dirty=false

  if [[ -d "$worktree_dir" ]]; then
    if git -C "$worktree_dir" status --porcelain 2>/dev/null | grep -q .; then
      dirty=true
    fi
  fi

  if [[ "$dirty" == true ]]; then
    if [[ -n "$log_file" ]]; then
      echo "Worktree left in place due to uncommitted changes: $worktree_dir" >> "$log_file"
    fi
    return 0
  fi

  # Run from original directory
  (
    cd "$ORIGINAL_DIR" || exit 1
    git worktree remove -f "$worktree_dir" 2>/dev/null || true
  )

  # Kill orphaned tsc/eslint processes from this agent's worktree
  # Only kill those that are descendants of this ralphy instance
  if [[ -n "$worktree_dir" ]] && [[ -n "$RALPHY_PID" ]]; then
    local all_descendants=$(get_all_descendants "$RALPHY_PID")
    if [[ -n "$all_descendants" ]]; then
      for pid in $all_descendants; do
        local cmdline=$(ps -p "$pid" -o command= 2>/dev/null || true)
        if [[ "$cmdline" == *"tsc"*"${worktree_dir}"* ]] || [[ "$cmdline" == *"eslint"*"${worktree_dir}"* ]]; then
          kill -TERM "$pid" 2>/dev/null || true
        fi
      done
    fi
  fi

  # Don't delete branch - it may have commits we want to keep/PR
}

# Run a single agent in its own isolated worktree
run_parallel_agent() {
  local task_name="$1"
  local agent_num="$2"
  local output_file="$3"
  local status_file="$4"
  local log_file="$5"

  echo "setting up" > "$status_file"

  # Update project board: task starting (parallel agent)
  if [[ "$PRD_SOURCE" == "github" ]]; then
    project_board_task_started "$task_name"
  fi

  # Log setup info
  echo "Agent $agent_num starting for task: $task_name" >> "$log_file"
  echo "ORIGINAL_DIR=$ORIGINAL_DIR" >> "$log_file"
  echo "WORKTREE_BASE=$WORKTREE_BASE" >> "$log_file"
  echo "BASE_BRANCH=$BASE_BRANCH" >> "$log_file"

  # Create isolated worktree for this agent
  local worktree_info
  worktree_info=$(create_agent_worktree "$task_name" "$agent_num" 2>>"$log_file")
  local worktree_dir="${worktree_info%%|*}"
  local branch_name="${worktree_info##*|}"

  echo "Worktree dir: $worktree_dir" >> "$log_file"
  echo "Branch name: $branch_name" >> "$log_file"

  if [[ ! -d "$worktree_dir" ]]; then
    echo "failed" > "$status_file"
    echo "ERROR: Worktree directory does not exist: $worktree_dir" >> "$log_file"
    echo "0 0" > "$output_file"
    return 1
  fi

  local worktree_start_head=""
  worktree_start_head=$(git -C "$worktree_dir" rev-parse HEAD 2>/dev/null || echo "")
  local worktree_start_status=""
  worktree_start_status=$(git -C "$worktree_dir" status --porcelain 2>/dev/null || echo "")

  echo "running" > "$status_file"

  # Copy PRD file to worktree from original directory
  if [[ "$PRD_SOURCE" == "markdown" ]] || [[ "$PRD_SOURCE" == "yaml" ]]; then
    cp "$ORIGINAL_DIR/$PRD_FILE" "$worktree_dir/" 2>/dev/null || true
  fi

  # Ensure progress.txt exists in worktree
  touch "$worktree_dir/progress.txt"

  # Build prompt for this specific task
  local prompt="You are working on a specific task. Focus ONLY on this task:

TASK: $task_name

Instructions:
1. Implement this specific task completely
2. Write tests if appropriate
3. Update progress.txt with what you did
4. Commit your changes with a descriptive message
5. IMPORTANT: You MUST use tools to read and edit files in this repo. Do not respond with a plan only.
   If you cannot access tools or the repo, respond exactly with 'TOOL_ACCESS_FAILED'.

Do NOT modify PRD.md or mark tasks complete - that will be handled separately.
Focus only on implementing: $task_name"

  # Temp file for AI output
  local tmpfile
  tmpfile=$(mktemp)

  # Run AI agent in the worktree directory
  local result=""
  local success=false
  local retry=0

  while [[ $retry -lt $MAX_RETRIES ]]; do
    case "$AI_ENGINE" in
      opencode)
        (
          cd "$worktree_dir"
          OPENCODE_PERMISSION='{"*":"allow"}' opencode run \
            --format json \
            "$prompt"
        ) > "$tmpfile" 2>>"$log_file"
        ;;
      cursor)
        (
          cd "$worktree_dir"
          agent --print --force \
            --output-format stream-json \
            "$prompt"
        ) > "$tmpfile" 2>>"$log_file"
        ;;
      qwen)
        (
          cd "$worktree_dir"
          qwen --output-format stream-json \
            --approval-mode yolo \
            -p "$prompt"
        ) > "$tmpfile" 2>>"$log_file"
        ;;
      codex)
        (
          cd "$worktree_dir"
          CODEX_LAST_MESSAGE_FILE="$tmpfile.last"
          rm -f "$CODEX_LAST_MESSAGE_FILE"
          codex exec --full-auto \
            --json \
            --output-last-message "$CODEX_LAST_MESSAGE_FILE" \
            "$prompt"
        ) > "$tmpfile" 2>>"$log_file"
        ;;
      *)
        (
          cd "$worktree_dir"
          claude --dangerously-skip-permissions \
            --verbose \
            -p "$prompt" \
            --output-format stream-json
        ) > "$tmpfile" 2>>"$log_file"
        ;;
    esac

    result=$(cat "$tmpfile" 2>/dev/null || echo "")

    if [[ -n "$result" ]]; then
      local error_msg
      if ! error_msg=$(check_for_errors "$result"); then
        ((retry++))
        echo "API error: $error_msg (attempt $retry/$MAX_RETRIES)" >> "$log_file"
        sleep "$RETRY_DELAY"
        continue
      fi
      local repo_changed=false
      if has_repo_changes_since "$worktree_start_head" "$worktree_start_status" "$worktree_dir"; then
        repo_changed=true
      fi
      if [[ "$result" == *"TOOL_ACCESS_FAILED"* ]]; then
        echo "ERROR: Tool access failed; no tools available." >> "$log_file"
        break
      fi
      if ! has_tool_usage "$result" && [[ "$repo_changed" != true ]]; then
        echo "ERROR: No tool usage detected; treating task as failed." >> "$log_file"
        break
      fi
      success=true
      break
    fi

    ((retry++))
    echo "Retry $retry/$MAX_RETRIES after empty response" >> "$log_file"
    sleep "$RETRY_DELAY"
  done

  rm -f "$tmpfile"

  if [[ "$success" == true ]]; then
    # Parse tokens
    local parsed input_tokens output_tokens
    local CODEX_LAST_MESSAGE_FILE="${tmpfile}.last"
    parsed=$(parse_ai_result "$result")
    local token_data
    token_data=$(echo "$parsed" | sed -n '/^---TOKENS---$/,$p' | tail -3)
    input_tokens=$(echo "$token_data" | sed -n '1p')
    output_tokens=$(echo "$token_data" | sed -n '2p')
    [[ "$input_tokens" =~ ^[0-9]+$ ]] || input_tokens=0
    [[ "$output_tokens" =~ ^[0-9]+$ ]] || output_tokens=0
    rm -f "${tmpfile}.last"

    # Check if this issue allows closing without code changes
    local no_code_ok=false
    if [[ "$PRD_SOURCE" == "github" ]] && issue_allows_no_code "$task_name"; then
      no_code_ok=true
      echo "Issue has no-code-required label; documentation/decision changes are acceptable" >> "$log_file"
    fi

    # Ensure at least one commit exists before marking success
    local commit_count
    commit_count=$(git -C "$worktree_dir" rev-list --count "$BASE_BRANCH"..HEAD 2>/dev/null || echo "0")
    [[ "$commit_count" =~ ^[0-9]+$ ]] || commit_count=0
    if [[ "$commit_count" -eq 0 ]] && [[ "$no_code_ok" != true ]]; then
      echo "ERROR: No new commits created; treating task as failed." >> "$log_file"
      echo "blocked:No commits created" > "$status_file"
      echo "0 0" > "$output_file"
      cleanup_agent_worktree "$worktree_dir" "$branch_name" "$log_file"
      return 1
    fi
    if ! has_code_changes_between "$BASE_BRANCH" "HEAD" "$worktree_dir"; then
      if [[ "$no_code_ok" == true ]]; then
        echo "No code changes but issue allows it (decision/docs/chore)" >> "$log_file"
      else
        echo "ERROR: No code changes detected (only progress.txt); treating task as failed." >> "$log_file"
        echo "Tip: Add 'no-code-required', 'chore', 'documentation', or 'decision' label to allow closing without code" >> "$log_file"
        echo "blocked:No code changes detected" > "$status_file"
        echo "0 0" > "$output_file"
        cleanup_agent_worktree "$worktree_dir" "$branch_name" "$log_file"
        return 1
      fi
    fi

    # Create PR if requested
    if [[ "$CREATE_PR" == true ]]; then
      (
        cd "$worktree_dir"
        git push -u origin "$branch_name" 2>>"$log_file" || true
        gh pr create \
          --base "$BASE_BRANCH" \
          --head "$branch_name" \
          --title "$task_name" \
          --body "Automated implementation by Ralphy (Agent $agent_num)" \
          ${PR_DRAFT:+--draft} 2>>"$log_file" || true
      )
      # Update project board to "In Review"
      if [[ "$PRD_SOURCE" == "github" ]]; then
        project_board_task_in_review "$task_name" "$branch_name"
      fi
    fi

    # Capture summary info before cleanup
    local commits_summary=""
    commits_summary=$(git -C "$worktree_dir" log --oneline "$BASE_BRANCH"..HEAD 2>/dev/null | head -10)
    local files_changed=""
    files_changed=$(git -C "$worktree_dir" diff --stat "$BASE_BRANCH"..HEAD 2>/dev/null | tail -10)

    # Write success output with summary
    echo "done" > "$status_file"
    {
      echo "$input_tokens $output_tokens $branch_name"
      echo "---COMMITS---"
      echo "$commits_summary"
      echo "---FILES---"
      echo "$files_changed"
    } > "$output_file"

    # Cleanup worktree (but keep branch)
    cleanup_agent_worktree "$worktree_dir" "$branch_name" "$log_file"

    return 0
  else
    echo "failed" > "$status_file"
    echo "0 0" > "$output_file"
    cleanup_agent_worktree "$worktree_dir" "$branch_name" "$log_file"
    return 1
  fi
}

# ============================================
# AUTO-PARALLEL EXECUTION (Smart 2-at-a-time)
# ============================================

# Run 1-2 tasks based on domain detection
# Returns: 0=success, 1=error, 2=no tasks
run_auto_parallel_batch() {
  # Get safe batch (returns 1 to AUTO_PARALLEL_MAX tasks)
  local tasks=()
  while IFS= read -r task; do
    [[ -n "$task" ]] && tasks+=("$task")
  done < <(get_parallel_safe_pair)

  local task_count=${#tasks[@]}

  if [[ $task_count -eq 0 ]]; then
    return 2  # No tasks
  fi

  # Claim the issues and auto-label docs issues
  for task in "${tasks[@]}"; do
    local issue_num="${task%%:*}"
    claim_issue "$issue_num"
    # Pre-emptively label docs issues so they can close without code changes
    auto_label_docs_issue "$task"
  done

  if [[ $task_count -eq 1 ]]; then
    # Single task - run normally
    local task="${tasks[0]}"
    echo ""
    echo "${BOLD}>>> Task $iteration${RESET} ${DIM}(sequential - no safe parallel pair found)${RESET}"
    local result_code=0
    run_single_task "$task" "$iteration" || result_code=$?

    # Release the issue
    local issue_num="${task%%:*}"
    release_issue "$issue_num"

    return $result_code
  fi

  # Multiple tasks - run in parallel
  # Re-detect domains here because get_parallel_safe_pair runs in a process substitution
  # (subshell), so domain cache variables don't propagate back to this shell.
  local domains=()
  for task in "${tasks[@]}"; do
    local t_title="${task#*:}"
    local t_body="" t_labels=""
    if [[ "$PRD_SOURCE" == "github" ]]; then
      t_body=$(get_github_issue_body "$task" 2>/dev/null || echo "")
      t_labels=$(get_github_issue_labels "$task" 2>/dev/null || echo "")
    fi
    domains+=($(get_issue_domain "$t_title" "$t_body" "$t_labels"))
  done

  local last_task_idx=$((iteration + task_count - 1))
  local domain_display
  domain_display=$(IFS=" + "; echo "${domains[*]}")

  echo ""
  echo "${BOLD}>>> Tasks $iteration-$last_task_idx${RESET} ${GREEN}(auto-parallel: $domain_display)${RESET}"
  for task in "${tasks[@]}"; do
    echo "  ${CYAN}◉${RESET} ${task:0:60}"
  done
  echo ""

  # Store original directory
  ORIGINAL_DIR=$(pwd)
  export ORIGINAL_DIR

  # Set up worktree base
  WORKTREE_BASE=$(mktemp -d)
  export WORKTREE_BASE

  # Ensure base branch
  if [[ -z "$BASE_BRANCH" ]]; then
    BASE_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
  fi
  export BASE_BRANCH

  # Export needed vars
  export AI_ENGINE MAX_RETRIES RETRY_DELAY PRD_SOURCE PRD_FILE CREATE_PR PR_DRAFT GITHUB_REPO GITHUB_LABEL

  # Setup for both tasks
  local status_files=() output_files=() log_files=()
  local pids=()

  for idx in "${!tasks[@]}"; do
    local task="${tasks[$idx]}"
    local agent_num=$((iteration + idx))
    local status_file=$(mktemp)
    local output_file=$(mktemp)
    local log_file=$(mktemp)

    status_files+=("$status_file")
    output_files+=("$output_file")
    log_files+=("$log_file")

    echo "waiting" > "$status_file"

    # Run agent in background
    (
      run_parallel_agent "$task" "$agent_num" "$output_file" "$status_file" "$log_file"
    ) &
    pids+=($!)
  done

  # Wait with spinner, timeout, and stuck detection
  local spinner_chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  local spin_idx=0
  local start_time=$SECONDS
  local stuck_warned=false
  local PARALLEL_TIMEOUT_SECS=1800  # 30 minutes max per batch
  local STUCK_WARNING_SECS=900      # Warn after 15 minutes

  while true; do
    local all_done=true
    local running=0 done_count=0 failed=0

    for idx in "${!status_files[@]}"; do
      local status=$(cat "${status_files[$idx]}" 2>/dev/null || echo "waiting")
      case "$status" in
        done) ((done_count++)) ;;
        failed|blocked:*) ((failed++)) ;;
        *)
          if kill -0 "${pids[$idx]}" 2>/dev/null; then
            all_done=false
            ((running++))
          fi
          ;;
      esac
    done

    [[ "$all_done" == true ]] && break

    local elapsed=$((SECONDS - start_time))

    # Stuck detection: warn once after 15 minutes
    if [[ $elapsed -ge $STUCK_WARNING_SECS ]] && [[ "$stuck_warned" == false ]]; then
      stuck_warned=true
      local stuck_tasks=""
      for idx in "${!status_files[@]}"; do
        local st=$(cat "${status_files[$idx]}" 2>/dev/null || echo "waiting")
        if [[ "$st" != "done" ]] && [[ "$st" != "failed" ]] && [[ "$st" != blocked:* ]]; then
          stuck_tasks+="${tasks[$idx]:0:50} "
        fi
      done
      notify_task_stuck "$stuck_tasks" "$((elapsed / 60))"
      log_warn "Agents running for ${elapsed}s — may be stuck: $stuck_tasks"
    fi

    # Hard timeout: kill remaining agents after 30 minutes
    if [[ $elapsed -ge $PARALLEL_TIMEOUT_SECS ]]; then
      log_error "Parallel batch timed out after $((elapsed / 60))m — killing remaining agents"
      notify_error "Batch timed out after $((elapsed / 60))m"
      for idx in "${!pids[@]}"; do
        local st=$(cat "${status_files[$idx]}" 2>/dev/null || echo "waiting")
        if [[ "$st" != "done" ]] && [[ "$st" != "failed" ]] && [[ "$st" != blocked:* ]]; then
          kill "${pids[$idx]}" 2>/dev/null || true
          echo "failed" > "${status_files[$idx]}"
        fi
      done
      break
    fi

    local spin_char="${spinner_chars:$spin_idx:1}"
    spin_idx=$(( (spin_idx + 1) % ${#spinner_chars} ))

    printf "\r  ${CYAN}%s${RESET} Running: %d | Done: %d | Failed: %d | %02d:%02d " \
      "$spin_char" "$running" "$done_count" "$failed" $((elapsed / 60)) $((elapsed % 60))

    sleep 0.3
  done

  printf "\r%80s\r" ""  # Clear line

  # Wait for processes
  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done

  # Process results
  local any_failed=false
  local tasks_succeeded=0

  for idx in "${!status_files[@]}"; do
    local task="${tasks[$idx]}"
    local issue_num="${task%%:*}"
    local status=$(cat "${status_files[$idx]}" 2>/dev/null || echo "unknown")
    local agent_num=$((iteration + idx))

    local icon color
    case "$status" in
      done)
        icon="✓" color="$GREEN"
        ((tasks_succeeded++))
        ((session_processed++))
        notify_task_done "#${issue_num}: ${task#*:}"

        # Get tokens and summary from output file
        local output_content=$(cat "${output_files[$idx]}" 2>/dev/null || echo "0 0 unknown")
        local first_line=$(echo "$output_content" | head -1)
        local in_tok=$(echo "$first_line" | awk '{print $1}')
        local out_tok=$(echo "$first_line" | awk '{print $2}')
        local branch=$(echo "$first_line" | awk '{print $3}')

        # Extract commits and files summary
        local commits_section=$(echo "$output_content" | sed -n '/---COMMITS---/,/---FILES---/p' | grep -v '^---')
        local files_section=$(echo "$output_content" | sed -n '/---FILES---/,$ p' | grep -v '^---')
        [[ "$in_tok" =~ ^[0-9]+$ ]] || in_tok=0
        [[ "$out_tok" =~ ^[0-9]+$ ]] || out_tok=0
        total_input_tokens=$((total_input_tokens + in_tok))
        total_output_tokens=$((total_output_tokens + out_tok))

        # Mark complete
        if [[ "$PRD_SOURCE" == "markdown" ]]; then
          mark_task_complete_markdown "$task"
        elif [[ "$PRD_SOURCE" == "yaml" ]]; then
          mark_task_complete_yaml "$task"
        elif [[ "$PRD_SOURCE" == "github" ]]; then
          local comment="## Task Completed by Ralphy (Agent $agent_num)

**Branch:** \`$branch\`
**Engine:** ${AI_ENGINE}

### Commits
\`\`\`
${commits_section:-No commits captured}
\`\`\`

### Files Changed
\`\`\`
${files_section:-No file changes captured}
\`\`\`"
          mark_task_complete_github "$task" "$comment"
          project_board_task_completed "$task" "$branch"
        fi
        ;;
      blocked:*)
        icon="⊘" color="$YELLOW"
        local reason="${status#blocked:}"
        mark_issue_blocked "$task" "$reason"
        ;;
      failed)
        icon="✗" color="$RED"
        any_failed=true
        notify_error "Issue #${issue_num} failed: ${task#*:}"
        ;;
      *)
        icon="?" color="$YELLOW"
        ;;
    esac

    printf "  ${color}%s${RESET} Agent %d: %s\n" "$icon" "$agent_num" "${task:0:55}"

    # Show log for failures
    if [[ "$status" == "failed" ]] && [[ -s "${log_files[$idx]}" ]]; then
      echo "${DIM}    └─ $(tail -1 "${log_files[$idx]}")${RESET}"
    fi

    # Release the issue
    release_issue "$issue_num"

    # Cleanup temp files
    rm -f "${status_files[$idx]}" "${output_files[$idx]}" "${log_files[$idx]}"
  done

  # Cleanup worktree base
  if [[ -d "$WORKTREE_BASE" ]]; then
    rm -rf "$WORKTREE_BASE" 2>/dev/null || true
  fi

  # Increment iteration for additional tasks (first one is counted by the main loop)
  iteration=$((iteration + task_count - 1))

  # Check remaining tasks
  local remaining
  remaining=$(count_remaining_tasks | tr -d '[:space:]')
  remaining=${remaining:-0}
  [[ "$remaining" =~ ^[0-9]+$ ]] || remaining=0

  if [[ "$remaining" -eq 0 ]]; then
    return 2  # All complete
  fi

  [[ "$any_failed" == true ]] && return 1
  return 0
}

run_parallel_tasks() {
  log_info "Running ${BOLD}$MAX_PARALLEL parallel agents${RESET} (each in isolated worktree)..."

  local all_tasks=()

  # Get all pending tasks
  while IFS= read -r task; do
    [[ -n "$task" ]] && all_tasks+=("$task")
  done < <(get_all_tasks)

  if [[ ${#all_tasks[@]} -eq 0 ]]; then
    log_info "No tasks to run"
    return 2
  fi

  local total_tasks=${#all_tasks[@]}
  log_info "Found $total_tasks tasks to process"

  # Store original directory for git operations from subshells
  ORIGINAL_DIR=$(pwd)
  export ORIGINAL_DIR

  # Set up worktree base directory
  WORKTREE_BASE=$(mktemp -d)
  export WORKTREE_BASE
  log_debug "Worktree base: $WORKTREE_BASE"

  # Ensure we have a base branch set
  if [[ -z "$BASE_BRANCH" ]]; then
    BASE_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
  fi
  export BASE_BRANCH
  log_info "Base branch: $BASE_BRANCH"

  # Export variables needed by subshell agents
  export AI_ENGINE MAX_RETRIES RETRY_DELAY PRD_SOURCE PRD_FILE CREATE_PR PR_DRAFT

  local batch_num=0
  local completed_branches=()
  local any_failed=false
  local groups=("all")

  if [[ "$PRD_SOURCE" == "yaml" ]]; then
    groups=()
    while IFS= read -r group; do
      [[ -n "$group" ]] && groups+=("$group")
    done < <(yq -r '.tasks[] | select(.completed != true) | (.parallel_group // 0)' "$PRD_FILE" 2>/dev/null | sort -n | uniq)
  fi

  for group in "${groups[@]}"; do
    local tasks=()
    local group_label=""

    if [[ "$PRD_SOURCE" == "yaml" ]]; then
      while IFS= read -r task; do
        [[ -n "$task" ]] && tasks+=("$task")
      done < <(get_tasks_in_group_yaml "$group")
      [[ ${#tasks[@]} -eq 0 ]] && continue
      group_label=" (group $group)"
    else
      tasks=("${all_tasks[@]}")
    fi

    local batch_start=0
    local total_group_tasks=${#tasks[@]}

    while [[ $batch_start -lt $total_group_tasks ]]; do
      ((batch_num++))
      local batch_end=$((batch_start + MAX_PARALLEL))
      [[ $batch_end -gt $total_group_tasks ]] && batch_end=$total_group_tasks
      local batch_size=$((batch_end - batch_start))

      echo ""
      echo "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
      echo "${BOLD}Batch $batch_num${group_label}: Spawning $batch_size parallel agents${RESET}"
      echo "${DIM}Each agent runs in its own git worktree with isolated workspace${RESET}"
      echo "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
      echo ""

      # Setup arrays for this batch
      parallel_pids=()
      local batch_tasks=()
      local status_files=()
      local output_files=()
      local log_files=()

      # Start all agents in the batch
      for ((i = batch_start; i < batch_end; i++)); do
        local task="${tasks[$i]}"
        local agent_num=$((iteration + 1))
        ((iteration++))

        local status_file=$(mktemp)
        local output_file=$(mktemp)
        local log_file=$(mktemp)

        batch_tasks+=("$task")
        status_files+=("$status_file")
        output_files+=("$output_file")
        log_files+=("$log_file")

        echo "waiting" > "$status_file"

        # Show initial status
        printf "  ${CYAN}◉${RESET} Agent %d: %s
" "$agent_num" "${task:0:50}"

        # Run agent in background
        (
          run_parallel_agent "$task" "$agent_num" "$output_file" "$status_file" "$log_file"
        ) &
        parallel_pids+=($!)
      done

      echo ""

      # Monitor progress with a spinner
      local spinner_chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
      local spin_idx=0
      local start_time=$SECONDS

      while true; do
        # Check if all processes are done
        local all_done=true
        local setting_up=0
        local running=0
        local done_count=0
        local failed_count=0

        for ((j = 0; j < batch_size; j++)); do
          local pid="${parallel_pids[$j]}"
          local status_file="${status_files[$j]}"
          local status=$(cat "$status_file" 2>/dev/null || echo "waiting")

          case "$status" in
            "setting up")
              all_done=false
              ((setting_up++))
              ;;
            running)
              all_done=false
              ((running++))
              ;;
            done)
              ((done_count++))
              ;;
            failed)
              ((failed_count++))
              ;;
            *)
              # Check if process is still running
              if kill -0 "$pid" 2>/dev/null; then
                all_done=false
              fi
              ;;
          esac
        done

        [[ "$all_done" == true ]] && break

        # Update spinner
        local elapsed=$((SECONDS - start_time))
        local spin_char="${spinner_chars:$spin_idx:1}"
        spin_idx=$(( (spin_idx + 1) % ${#spinner_chars} ))

        printf "  ${CYAN}%s${RESET} Agents: ${BLUE}%d setup${RESET} | ${YELLOW}%d running${RESET} | ${GREEN}%d done${RESET} | ${RED}%d failed${RESET} | %02d:%02d " \
          "$spin_char" "$setting_up" "$running" "$done_count" "$failed_count" $((elapsed / 60)) $((elapsed % 60))

        sleep 0.3
      done

      # Clear the spinner line
      printf "%100s" ""

      # Wait for all processes to fully complete
      for pid in "${parallel_pids[@]}"; do
        wait "$pid" 2>/dev/null || true
      done

      # Show final status for this batch
      echo ""
      echo "${BOLD}Batch $batch_num Results:${RESET}"
      for ((j = 0; j < batch_size; j++)); do
        local task="${batch_tasks[$j]}"
        local status_file="${status_files[$j]}"
        local output_file="${output_files[$j]}"
        local log_file="${log_files[$j]}"
        local status=$(cat "$status_file" 2>/dev/null || echo "unknown")
        local agent_num=$((iteration - batch_size + j + 1))

        local icon color branch_info=""
        case "$status" in
          done)
            icon="✓"
            color="$GREEN"
            ((session_processed++))
            # Collect tokens and branch name
            local output_data=$(cat "$output_file" 2>/dev/null || echo "0 0")
            local in_tok=$(echo "$output_data" | awk '{print $1}')
            local out_tok=$(echo "$output_data" | awk '{print $2}')
            local branch=$(echo "$output_data" | awk '{print $3}')
            [[ "$in_tok" =~ ^[0-9]+$ ]] || in_tok=0
            [[ "$out_tok" =~ ^[0-9]+$ ]] || out_tok=0
            total_input_tokens=$((total_input_tokens + in_tok))
            total_output_tokens=$((total_output_tokens + out_tok))
            if [[ -n "$branch" ]]; then
              completed_branches+=("$branch")
              branch_info=" → ${CYAN}$branch${RESET}"
            fi

            # Mark task complete in PRD
            if [[ "$PRD_SOURCE" == "markdown" ]]; then
              mark_task_complete_markdown "$task"
            elif [[ "$PRD_SOURCE" == "yaml" ]]; then
              mark_task_complete_yaml "$task"
            elif [[ "$PRD_SOURCE" == "github" ]]; then
              # Build completion comment for parallel agent
              local parallel_comment="## Task Completed by Ralphy (Parallel Agent $agent_num)

**Branch:** \`$branch\`
**Engine:** ${AI_ENGINE}

Implementation completed successfully. See branch for commit details."
              mark_task_complete_github "$task" "$parallel_comment"
              project_board_task_completed "$task" "$branch"
            fi
            ;;
          blocked:*)
            icon="⊘"
            color="$YELLOW"
            local block_reason="${status#blocked:}"
            mark_issue_blocked "$task" "$block_reason"
            branch_info=" ${DIM}(blocked)${RESET}"
            ;;
          failed)
            icon="✗"
            color="$RED"
            any_failed=true
            if [[ -s "$log_file" ]]; then
              branch_info=" ${DIM}(error below)${RESET}"
            fi
            ;;
          *)
            icon="?"
            color="$YELLOW"
            ;;
        esac

        printf "  ${color}%s${RESET} Agent %d: %s%s
" "$icon" "$agent_num" "${task:0:45}" "$branch_info"

        # Show log for failed agents
        if [[ "$status" == "failed" ]] && [[ -s "$log_file" ]]; then
          echo "${DIM}    ┌─ Agent $agent_num log:${RESET}"
          sed 's/^/    │ /' "$log_file" | head -20
          local log_lines=$(wc -l < "$log_file")
          if [[ $log_lines -gt 20 ]]; then
            echo "${DIM}    │ ... ($((log_lines - 20)) more lines)${RESET}"
          fi
          echo "${DIM}    └─${RESET}"
        fi

        # Cleanup temp files
        rm -f "$status_file" "$output_file" "$log_file"
      done

      batch_start=$batch_end

      # Check if we've hit max iterations
      if [[ $MAX_ITERATIONS -gt 0 ]] && [[ $iteration -ge $MAX_ITERATIONS ]]; then
        log_warn "Reached max iterations ($MAX_ITERATIONS)"
        break
      fi
    done

    if [[ $MAX_ITERATIONS -gt 0 ]] && [[ $iteration -ge $MAX_ITERATIONS ]]; then
      break
    fi
  done

  # Cleanup worktree base
  if ! find "$WORKTREE_BASE" -maxdepth 1 -type d -name 'agent-*' -print -quit 2>/dev/null | grep -q .; then
    rm -rf "$WORKTREE_BASE" 2>/dev/null || true
  else
    log_warn "Preserving worktree base with dirty agents: $WORKTREE_BASE"
  fi

  # Handle completed branches
  if [[ ${#completed_branches[@]} -gt 0 ]]; then
    echo ""
    echo "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"

    if [[ "$CREATE_PR" == true ]]; then
      # PRs were created, just show the branches
      echo "${BOLD}Branches created by agents:${RESET}"
      for branch in "${completed_branches[@]}"; do
        echo "  ${CYAN}•${RESET} $branch"
      done
    else
      # Auto-merge branches back to main
      echo "${BOLD}Merging agent branches into ${BASE_BRANCH}...${RESET}"
      echo ""

      if ! git checkout "$BASE_BRANCH" >/dev/null 2>&1; then
        log_warn "Could not checkout $BASE_BRANCH; leaving agent branches unmerged."
        echo "${BOLD}Branches created by agents:${RESET}"
        for branch in "${completed_branches[@]}"; do
          echo "  ${CYAN}•${RESET} $branch"
        done
        return 0
      fi

      local merge_failed=()

      for branch in "${completed_branches[@]}"; do
        printf "  Merging ${CYAN}%s${RESET}..." "$branch"

        # Attempt to merge
        if git merge --no-edit "$branch" >/dev/null 2>&1; then
          printf " ${GREEN}✓${RESET}
"
          # Delete the branch after successful merge
          git branch -d "$branch" >/dev/null 2>&1 || true
        else
          printf " ${YELLOW}conflict${RESET}"
          merge_failed+=("$branch")
          # Don't abort yet - try AI resolution
        fi
      done

      # Use AI to resolve merge conflicts
      if [[ ${#merge_failed[@]} -gt 0 ]]; then
        echo ""
        echo "${BOLD}Using AI to resolve ${#merge_failed[@]} merge conflict(s)...${RESET}"
        echo ""

        local still_failed=()

        for branch in "${merge_failed[@]}"; do
          printf "  Resolving ${CYAN}%s${RESET}..." "$branch"

          # Get list of conflicted files
          local conflicted_files
          conflicted_files=$(git diff --name-only --diff-filter=U 2>/dev/null)

          if [[ -z "$conflicted_files" ]]; then
            # No conflicts found (maybe already resolved or aborted)
            git merge --abort 2>/dev/null || true
            git merge --no-edit "$branch" >/dev/null 2>&1 || {
              printf " ${RED}✗${RESET}
"
              still_failed+=("$branch")
              git merge --abort 2>/dev/null || true
              continue
            }
            printf " ${GREEN}✓${RESET}
"
            git branch -d "$branch" >/dev/null 2>&1 || true
            continue
          fi

          # Build prompt for AI to resolve conflicts
          local resolve_prompt="You are resolving a git merge conflict. The following files have conflicts:

$conflicted_files

For each conflicted file:
1. Read the file to see the conflict markers (<<<<<<< HEAD, =======, >>>>>>> branch)
2. Understand what both versions are trying to do
3. Edit the file to resolve the conflict by combining both changes intelligently
4. Remove all conflict markers
5. Make sure the resulting code is valid and compiles

After resolving all conflicts:
1. Run 'git add' on each resolved file
2. Run 'git commit --no-edit' to complete the merge

Be careful to preserve functionality from BOTH branches. The goal is to integrate all features."

          # Run AI to resolve conflicts
          local resolve_tmpfile
          resolve_tmpfile=$(mktemp)

          case "$AI_ENGINE" in
            opencode)
              OPENCODE_PERMISSION='{"*":"allow"}' opencode run \
                --format json \
                "$resolve_prompt" > "$resolve_tmpfile" 2>&1
              ;;
            cursor)
              agent --print --force \
                --output-format stream-json \
                "$resolve_prompt" > "$resolve_tmpfile" 2>&1
              ;;
            qwen)
              qwen --output-format stream-json \
                --approval-mode yolo \
                -p "$resolve_prompt" > "$resolve_tmpfile" 2>&1
              ;;
            codex)
              codex exec --full-auto \
                --json \
                "$resolve_prompt" > "$resolve_tmpfile" 2>&1
              ;;
            *)
              claude --dangerously-skip-permissions \
                -p "$resolve_prompt" \
                --output-format stream-json > "$resolve_tmpfile" 2>&1
              ;;
          esac

          rm -f "$resolve_tmpfile"

          # Check if merge was completed
          if ! git diff --name-only --diff-filter=U 2>/dev/null | grep -q .; then
            # No more conflicts - merge succeeded
            printf " ${GREEN}✓ (AI resolved)${RESET}
"
            git branch -d "$branch" >/dev/null 2>&1 || true
          else
            # Still has conflicts
            printf " ${RED}✗ (AI couldn't resolve)${RESET}
"
            still_failed+=("$branch")
            git merge --abort 2>/dev/null || true
          fi
        done

        if [[ ${#still_failed[@]} -gt 0 ]]; then
          echo ""
          echo "${YELLOW}Some conflicts could not be resolved automatically:${RESET}"
          for branch in "${still_failed[@]}"; do
            echo "  ${YELLOW}•${RESET} $branch"
          done
          echo ""
          echo "${DIM}Resolve conflicts manually: git merge <branch>${RESET}"
        else
          echo ""
          echo "${GREEN}All branches merged successfully!${RESET}"
        fi
      else
        echo ""
        echo "${GREEN}All branches merged successfully!${RESET}"
      fi
    fi
  fi

  if [[ "$any_failed" == true ]]; then
    return 1
  fi

  return 0
}
