# ============================================
# PARALLEL TASK EXECUTION
# ============================================

# Create an isolated worktree for a parallel agent
# Delegates to guardrail_atomic_worktree for rollback-safe creation + ledger tracking
create_agent_worktree() {
  local task_name="$1"
  local agent_num="$2"
  local issue="${3:-unknown}"

  guardrail_atomic_worktree "$task_name" "$agent_num" "$issue"
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

  # Log setup info
  echo "Agent $agent_num starting for task: $task_name" >> "$log_file"
  echo "ORIGINAL_DIR=$ORIGINAL_DIR" >> "$log_file"
  echo "WORKTREE_BASE=$WORKTREE_BASE" >> "$log_file"
  echo "BASE_BRANCH=$BASE_BRANCH" >> "$log_file"

  # Create isolated worktree for this agent
  local issue_id="${task_name%%:*}"
  local worktree_info
  worktree_info=$(create_agent_worktree "$task_name" "$agent_num" "$issue_id" 2>>"$log_file")
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

  # Copy repo-specific lessons file to worktree (if it exists)
  if [[ -f "$ORIGINAL_DIR/RALPHY_LESSONS.md" ]]; then
    cp "$ORIGINAL_DIR/RALPHY_LESSONS.md" "$worktree_dir/" 2>/dev/null || true
  fi

  # Build prompt for this specific task
  local lessons_ref=""
  if [[ -f "$worktree_dir/RALPHY_LESSONS.md" ]]; then
    lessons_ref="
BEFORE STARTING: Read @RALPHY_LESSONS.md for repo-specific rules and past mistakes. Follow all rules in that file."
  fi

  local prompt="You are working on a specific task. Focus ONLY on this task:

TASK: $task_name
${lessons_ref}

Instructions:
1. Implement this specific task completely
2. Write tests if appropriate
3. Update progress.txt with what you did
4. Commit your changes with a descriptive message
5. IMPORTANT: You MUST use tools to read and edit files in this repo. Do not respond with a plan only.
   If you cannot access tools or the repo, respond exactly with 'TOOL_ACCESS_FAILED'.

SCOPE RULES (MANDATORY):
- ONLY modify files directly required by this task.
- Do NOT refactor, rename, delete, or 'clean up' code outside the task scope.
- Do NOT remove imports, files, or utilities used by other parts of the codebase.
- Do NOT undo or revert changes from other issues/PRs.
- If you think something outside scope needs changing, note it in progress.txt but do NOT change it.
- Other agents are working on other tasks in parallel. Their work must not be disrupted.

LEARNINGS: If you discover a new pattern, pitfall, or rule specific to this repo, append it to RALPHY_LESSONS.md under 'Agent Learnings' before committing.

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
        ((retry++)) || true
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

    ((retry++)) || true
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

    # Extract learnings from agent worktree before cleanup
    guardrail_merge_lessons "$worktree_dir" "$ORIGINAL_DIR" 2>/dev/null || true

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
# AUTO-PARALLEL EXECUTION (Sliding Window)
# ============================================

# Run tasks with a sliding window: as soon as any agent finishes,
# immediately start the next compatible task. No waiting for a full batch.
# Returns: 0=success, 1=some failed, 2=all complete/no tasks
run_auto_parallel_batch() {
  # Get all available (unclaimed) tasks
  local all_tasks=()
  while IFS= read -r task; do
    [[ -z "$task" ]] && continue
    local issue_num="${task%%:*}"
    if is_issue_claimed "$issue_num"; then
      log_debug "Skipping issue $issue_num (claimed by another instance)"
      continue
    fi
    all_tasks+=("$task")
  done < <(get_all_tasks)

  local total_tasks=${#all_tasks[@]}
  [[ $total_tasks -eq 0 ]] && return 2

  # Setup worktree infrastructure
  ORIGINAL_DIR=$(pwd)
  export ORIGINAL_DIR
  WORKTREE_BASE=$(mktemp -d)
  export WORKTREE_BASE
  if [[ -z "$BASE_BRANCH" ]]; then
    BASE_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
  fi
  export BASE_BRANCH
  guardrail_validate_base_branch
  export AI_ENGINE MAX_RETRIES RETRY_DELAY PRD_SOURCE PRD_FILE CREATE_PR PR_DRAFT GITHUB_REPO GITHUB_LABEL

  # Pre-compute domains for all tasks (avoids repeated API calls)
  local -a task_domains=()
  for task in "${all_tasks[@]}"; do
    local t_title="${task#*:}"
    local t_body="" t_labels=""
    if [[ "$PRD_SOURCE" == "github" ]]; then
      t_body=$(get_github_issue_body "$task" 2>/dev/null || echo "")
      t_labels=$(get_github_issue_labels "$task" 2>/dev/null || echo "")
    fi
    task_domains+=("$(get_issue_domain "$t_title" "$t_body" "$t_labels")")
  done

  # Track which tasks have been started (by index into all_tasks)
  local -a task_started=()
  for ((i=0; i<total_tasks; i++)); do task_started+=(""); done

  # Sliding window: fixed-size slot arrays (empty pid = free slot)
  local -a sw_pids=() sw_tasks=() sw_domains=() sw_start_times=()
  local -a sw_status_files=() sw_output_files=() sw_log_files=() sw_agent_nums=()
  for ((s=0; s<AUTO_PARALLEL_MAX; s++)); do
    sw_pids+=("") sw_tasks+=("") sw_domains+=("") sw_start_times+=("$SECONDS")
    sw_status_files+=("") sw_output_files+=("") sw_log_files+=("") sw_agent_nums+=("")
  done

  local sw_active=0 sw_started=0 sw_done=0 sw_failed=0
  local sw_any_failed=false
  local sw_start_time=$SECONDS

  # Display header
  echo ""
  echo "${BOLD}>>> Sliding window${RESET} ${GREEN}(up to $AUTO_PARALLEL_MAX concurrent, $total_tasks tasks queued)${RESET}"
  echo ""

  # --- Fill initial slots ---
  for ((s=0; s<AUTO_PARALLEL_MAX; s++)); do
    # Find next compatible task
    local found_idx=""
    for ((t=0; t<total_tasks; t++)); do
      [[ -n "${task_started[$t]}" ]] && continue
      local candidate_domain="${task_domains[$t]}"
      local compatible=true
      for ((s2=0; s2<AUTO_PARALLEL_MAX; s2++)); do
        [[ -z "${sw_pids[$s2]}" ]] && continue
        if ! are_domains_compatible "$candidate_domain" "${sw_domains[$s2]}"; then
          compatible=false
          break
        fi
      done
      if [[ "$compatible" == true ]]; then
        found_idx="$t"
        break
      fi
    done

    [[ -z "$found_idx" ]] && break

    # Start task in this slot
    local task="${all_tasks[$found_idx]}"
    local domain="${task_domains[$found_idx]}"
    local issue_num="${task%%:*}"
    task_started[$found_idx]="true"
    ((iteration++)) || true
    ((sw_started++)) || true
    claim_issue "$issue_num"
    auto_label_docs_issue "$task"

    if [[ "$PRD_SOURCE" == "github" ]]; then
      project_board_task_started "$task"
    fi

    local status_file=$(mktemp) output_file=$(mktemp) log_file=$(mktemp)
    echo "waiting" > "$status_file"

    sw_tasks[$s]="$task"
    sw_domains[$s]="$domain"
    sw_status_files[$s]="$status_file"
    sw_output_files[$s]="$output_file"
    sw_log_files[$s]="$log_file"
    sw_agent_nums[$s]="$iteration"

    ( run_parallel_agent "$task" "$iteration" "$output_file" "$status_file" "$log_file" ) &
    sw_pids[$s]=$!
    sw_start_times[$s]=$SECONDS
    ((sw_active++)) || true

    printf "  ${CYAN}▶${RESET} Slot %d ${DIM}[%d/%d]${RESET}: %s ${DIM}(%s)${RESET}\n" "$((s + 1))" "$sw_started" "$total_tasks" "${task:0:55}" "$domain"
  done

  # --- Sliding window loop ---
  local spinner_chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  local spin_idx=0
  local stuck_warned=false
  local PARALLEL_TIMEOUT_SECS=1800  # 30 minutes max
  local STUCK_WARNING_SECS=900      # Warn after 15 minutes
  local last_status_print=0         # Timestamp of last newline status print
  local STATUS_PRINT_INTERVAL=30    # Print a persistent status line every 30s

  while [[ $sw_active -gt 0 ]]; do
    # Check each slot for completion
    for ((s=0; s<AUTO_PARALLEL_MAX; s++)); do
      [[ -z "${sw_pids[$s]}" ]] && continue

      # Early timeout bailout (checked per-slot, not just per-iteration)
      if [[ $(( SECONDS - sw_start_time )) -ge $PARALLEL_TIMEOUT_SECS ]]; then
        break
      fi

      # Is this agent still running?
      if kill -0 "${sw_pids[$s]}" 2>/dev/null; then
        continue
      fi

      # --- Agent in slot $s completed ---
      wait "${sw_pids[$s]}" 2>/dev/null || true
      ((sw_active--)) || true

      local task="${sw_tasks[$s]}"
      local issue_num="${task%%:*}"
      local agent_num="${sw_agent_nums[$s]}"
      local status=$(cat "${sw_status_files[$s]}" 2>/dev/null || echo "unknown")
      local agent_elapsed=$(( SECONDS - ${sw_start_times[$s]:-$sw_start_time} ))
      local agent_elapsed_fmt
      if [[ $agent_elapsed -ge 60 ]]; then
        agent_elapsed_fmt="$(( agent_elapsed / 60 ))m$(( agent_elapsed % 60 ))s"
      else
        agent_elapsed_fmt="${agent_elapsed}s"
      fi

      local icon color detail_line=""
      case "$status" in
        done)
          icon="✓" color="$GREEN"
          ((sw_done++)) || true
          ((session_processed++)) || true
          notify_task_done "#${issue_num}: ${task#*:}"

          local output_content=$(cat "${sw_output_files[$s]}" 2>/dev/null || echo "0 0 unknown")
          local first_line=$(echo "$output_content" | head -1)
          local in_tok=$(echo "$first_line" | awk '{print $1}')
          local out_tok=$(echo "$first_line" | awk '{print $2}')
          local branch=$(echo "$first_line" | awk '{print $3}')
          local commits_section=$(echo "$output_content" | sed -n '/---COMMITS---/,/---FILES---/p' | grep -v '^---')
          local files_section=$(echo "$output_content" | sed -n '/---FILES---/,$ p' | grep -v '^---')
          [[ "$in_tok" =~ ^[0-9]+$ ]] || in_tok=0
          [[ "$out_tok" =~ ^[0-9]+$ ]] || out_tok=0
          total_input_tokens=$((total_input_tokens + in_tok))
          total_output_tokens=$((total_output_tokens + out_tok))
          local file_count=$(echo "$files_section" | grep -c '|' 2>/dev/null || echo "0")
          detail_line=" → ${CYAN}${branch:0:35}${RESET} ${DIM}(${file_count} files, ${agent_elapsed_fmt})${RESET}"
          completed_task_details+=("done|$agent_num|$issue_num|${task#*:}|${branch:-}|$agent_elapsed")

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

          # Merge agent branch back into base branch (skip if PRs are being created)
          if [[ "$CREATE_PR" != true ]] && [[ -n "$branch" ]] && [[ "$branch" != "unknown" ]]; then
            # Verify we're on the expected branch before merging
            local current_head
            current_head=$(git -C "$ORIGINAL_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
            if [[ "$current_head" != "$BASE_BRANCH" ]]; then
              log_warn "Expected $BASE_BRANCH but on $current_head — skipping merge of $branch"
            elif git -C "$ORIGINAL_DIR" merge --no-edit "$branch" >/dev/null 2>&1; then
              log_debug "Merged $branch into $BASE_BRANCH"
              # Verify merge actually landed commits before deleting branch
              if guardrail_verify_merge "$branch" "$ORIGINAL_DIR"; then
                git -C "$ORIGINAL_DIR" branch -d "$branch" >/dev/null 2>&1 || true
              else
                log_warn "Merge verification failed for $branch — branch preserved"
              fi
            else
              log_warn "Merge conflict merging $branch into $BASE_BRANCH — aborting merge, branch preserved for manual resolution"
              git -C "$ORIGINAL_DIR" merge --abort 2>/dev/null || true
              guardrail_update_branch "$branch" "failed"
            fi
          fi
          ;;
        blocked:*)
          icon="⊘" color="$YELLOW"
          ((sw_failed++)) || true
          local reason="${status#blocked:}"
          mark_issue_blocked "$task" "$reason"
          detail_line=" ${DIM}— ${reason} (${agent_elapsed_fmt})${RESET}"
          completed_task_details+=("blocked|$agent_num|$issue_num|${task#*:}||$agent_elapsed")
          ;;
        failed)
          icon="✗" color="$RED"
          ((sw_failed++)) || true
          sw_any_failed=true
          notify_error "Issue #${issue_num} failed: ${task#*:}"
          detail_line=" ${DIM}(${agent_elapsed_fmt})${RESET}"
          completed_task_details+=("failed|$agent_num|$issue_num|${task#*:}||$agent_elapsed")
          ;;
        *)
          icon="?" color="$YELLOW"
          ((sw_failed++)) || true
          detail_line=" ${DIM}(${agent_elapsed_fmt})${RESET}"
          completed_task_details+=("unknown|$agent_num|$issue_num|${task#*:}||$agent_elapsed")
          ;;
      esac

      # Clear spinner line, print result with details
      printf "\r%80s\r" ""
      printf "  ${color}%s${RESET} Slot %d: %s%s\n" "$icon" "$((s + 1))" "${task:0:55}" "$detail_line"

      if [[ "$status" == "failed" ]] && [[ -s "${sw_log_files[$s]}" ]]; then
        echo "${DIM}    └─ $(tail -1 "${sw_log_files[$s]}")${RESET}"
      fi

      # Progress tally after each completion
      local queued_now=$(( total_tasks - sw_started ))
      [[ $queued_now -lt 0 ]] && queued_now=0
      printf "    ${DIM}Progress: ${GREEN}%d done${RESET}${DIM} · ${YELLOW}%d blocked${RESET}${DIM} · ${CYAN}%d active${RESET}${DIM} · %d queued · %d total${RESET}\n" \
        "$sw_done" "$sw_failed" "$sw_active" "$queued_now" "$total_tasks"

      release_issue "$issue_num"
      rm -f "${sw_status_files[$s]}" "${sw_output_files[$s]}" "${sw_log_files[$s]}"

      # Free the slot
      sw_pids[$s]=""
      sw_tasks[$s]=""
      sw_domains[$s]=""

      # --- Try to fill this slot with the next compatible task ---
      local found_idx=""
      for ((t=0; t<total_tasks; t++)); do
        [[ -n "${task_started[$t]}" ]] && continue
        local candidate_domain="${task_domains[$t]}"
        local compatible=true
        for ((s2=0; s2<AUTO_PARALLEL_MAX; s2++)); do
          [[ -z "${sw_pids[$s2]}" ]] && continue
          if ! are_domains_compatible "$candidate_domain" "${sw_domains[$s2]}"; then
            compatible=false
            break
          fi
        done
        if [[ "$compatible" == true ]]; then
          found_idx="$t"
          break
        fi
      done

      if [[ -n "$found_idx" ]]; then
        local next_task="${all_tasks[$found_idx]}"
        local next_domain="${task_domains[$found_idx]}"
        local next_issue="${next_task%%:*}"
        task_started[$found_idx]="true"
        ((iteration++)) || true
        ((sw_started++)) || true
        claim_issue "$next_issue"
        auto_label_docs_issue "$next_task"

        if [[ "$PRD_SOURCE" == "github" ]]; then
          project_board_task_started "$next_task"
        fi

        local new_sf=$(mktemp) new_of=$(mktemp) new_lf=$(mktemp)
        echo "waiting" > "$new_sf"

        sw_tasks[$s]="$next_task"
        sw_domains[$s]="$next_domain"
        sw_status_files[$s]="$new_sf"
        sw_output_files[$s]="$new_of"
        sw_log_files[$s]="$new_lf"
        sw_agent_nums[$s]="$iteration"

        ( run_parallel_agent "$next_task" "$iteration" "$new_of" "$new_sf" "$new_lf" ) &
        sw_pids[$s]=$!
        sw_start_times[$s]=$SECONDS
        ((sw_active++)) || true

        printf "  ${CYAN}▶${RESET} Slot %d ${DIM}[%d/%d]${RESET}: %s ${DIM}(%s)${RESET}\n" "$((s + 1))" "$sw_started" "$total_tasks" "${next_task:0:55}" "$next_domain"
      fi
    done

    # Exit if nothing running
    [[ $sw_active -eq 0 ]] && break

    local elapsed=$(( SECONDS - sw_start_time ))

    # Stuck detection
    if [[ $elapsed -ge $STUCK_WARNING_SECS ]] && [[ "$stuck_warned" == false ]]; then
      stuck_warned=true
      local stuck_tasks=""
      for ((s=0; s<AUTO_PARALLEL_MAX; s++)); do
        [[ -z "${sw_pids[$s]}" ]] && continue
        stuck_tasks+="${sw_tasks[$s]:0:50} "
      done
      notify_task_stuck "$stuck_tasks" "$((elapsed / 60))"
      log_warn "Agents running for ${elapsed}s — may be stuck: $stuck_tasks"
    fi

    # Hard timeout
    if [[ $elapsed -ge $PARALLEL_TIMEOUT_SECS ]]; then
      log_error "Sliding window timed out after $((elapsed / 60))m — killing remaining agents"
      notify_error "Timed out after $((elapsed / 60))m"
      for ((s=0; s<AUTO_PARALLEL_MAX; s++)); do
        [[ -z "${sw_pids[$s]}" ]] && continue
        # Kill entire process tree (claude + children)
        local descendants
        descendants=$(get_all_descendants "${sw_pids[$s]}" 2>/dev/null || true)
        for dpid in $descendants; do
          kill -TERM "$dpid" 2>/dev/null || true
        done
        kill -TERM "${sw_pids[$s]}" 2>/dev/null || true
        echo "failed" > "${sw_status_files[$s]}"
        wait "${sw_pids[$s]}" 2>/dev/null || true
        ((sw_active--)) || true
        ((sw_failed++)) || true
        local t_task="${sw_tasks[$s]}"
        local t_issue="${t_task%%:*}"
        printf "  ${RED}✗${RESET} Slot %d: %s ${DIM}(timed out)${RESET}\n" "$((s + 1))" "${t_task:0:55}"
        release_issue "$t_issue"
        rm -f "${sw_status_files[$s]}" "${sw_output_files[$s]}" "${sw_log_files[$s]}"
        sw_pids[$s]=""
      done
      break
    fi

    # Update spinner
    local spin_char="${spinner_chars:$spin_idx:1}"
    spin_idx=$(( (spin_idx + 1) % ${#spinner_chars} ))
    local queued=$(( total_tasks - sw_started ))
    [[ $queued -lt 0 ]] && queued=0

    # Periodic persistent status line (newline-based, can't be clobbered)
    if [[ $((elapsed - last_status_print)) -ge $STATUS_PRINT_INTERVAL ]]; then
      last_status_print=$elapsed
      printf "\r%80s\r" ""
      printf "  ${DIM}[%02d:%02d]${RESET} Running: ${CYAN}%d${RESET} | Done: ${GREEN}%d${RESET} | Failed: ${RED}%d${RESET} | Queued: %d\n" \
        $((elapsed / 60)) $((elapsed % 60)) "$sw_active" "$sw_done" "$sw_failed" "$queued"
    fi

    # In-place spinner (fast update between persistent lines)
    printf "\r  ${CYAN}%s${RESET} Running: %d | Done: %d | Failed: %d | Queued: %d | %02d:%02d " \
      "$spin_char" "$sw_active" "$sw_done" "$sw_failed" "$queued" \
      $((elapsed / 60)) $((elapsed % 60))

    sleep 0.3
  done

  printf "\r%80s\r" ""  # Clear spinner line

  # Cleanup worktree base
  if [[ -d "$WORKTREE_BASE" ]]; then
    rm -rf "$WORKTREE_BASE" 2>/dev/null || true
  fi

  # Summary line
  local sw_total_elapsed=$(( SECONDS - sw_start_time ))
  local sw_elapsed_fmt
  if [[ $sw_total_elapsed -ge 60 ]]; then
    sw_elapsed_fmt="$(( sw_total_elapsed / 60 ))m$(( sw_total_elapsed % 60 ))s"
  else
    sw_elapsed_fmt="${sw_total_elapsed}s"
  fi

  echo ""
  echo "${BOLD}━━━ Round complete (${sw_elapsed_fmt}) ━━━${RESET}"
  echo "  ${GREEN}✓ $sw_done done${RESET}  ·  ${YELLOW}⊘ $sw_failed blocked/failed${RESET}  ·  ${DIM}$total_tasks total${RESET}"

  # Check remaining tasks
  local remaining
  remaining=$(count_remaining_tasks | tr -d '[:space:]')
  remaining=${remaining:-0}
  [[ "$remaining" =~ ^[0-9]+$ ]] || remaining=0

  if [[ "$remaining" -eq 0 ]]; then
    return 2  # All complete
  fi

  [[ "$sw_any_failed" == true ]] && return 1
  return 0
}
