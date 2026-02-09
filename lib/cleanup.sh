# ============================================
# CLEANUP HANDLER
# ============================================

# Reap orphaned tsc/eslint/node processes left by previous ralphy or Claude Code sessions.
# These accumulate when a session dies without cleanup, get reparented to PID 1,
# and silently eat hundreds of MB each.
#
# Called at: startup (preflight), between tasks, and at exit.
# Safe: only kills processes matching tsc/eslint patterns, never touches dev server or active claude.
reap_orphaned_processes() {
  local repo_root
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
  local killed=0

  # Find tsc/eslint npm wrapper processes whose parent is PID 1 (orphaned)
  # or whose parent no longer exists (dead session)
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local pid ppid cmdline
    pid=$(echo "$line" | awk '{print $1}')
    ppid=$(echo "$line" | awk '{print $2}')
    cmdline=$(echo "$line" | awk '{$1=$2=""; print $0}' | sed 's/^ *//')

    # Skip our own process tree
    [[ "$pid" == "$$" || "$pid" == "$RALPHY_PID" ]] && continue

    # Only target tsc/eslint processes
    if [[ "$cmdline" != *"tsc"* ]] && [[ "$cmdline" != *"eslint"* ]]; then
      continue
    fi

    # Skip if parent is alive and is NOT PID 1 (legitimately running)
    if [[ "$ppid" != "1" ]] && kill -0 "$ppid" 2>/dev/null; then
      continue
    fi

    # Kill the orphan and its children
    local children
    children=$(pgrep -P "$pid" 2>/dev/null || true)
    for child in $children; do
      kill -TERM "$child" 2>/dev/null || true
      ((killed++))
    done
    kill -TERM "$pid" 2>/dev/null || true
    ((killed++))
  done < <(ps -eo pid,ppid,args 2>/dev/null | grep -E 'tsc|eslint' | grep -v grep || true)

  # Also find node processes whose parent is a dead npm/tsc process (reparented to 1)
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local pid ppid rss cmdline
    pid=$(echo "$line" | awk '{print $1}')
    ppid=$(echo "$line" | awk '{print $2}')
    rss=$(echo "$line" | awk '{print $3}')
    cmdline=$(echo "$line" | awk '{$1=$2=$3=""; print $0}' | sed 's/^ *//')

    # Only target large orphaned node processes (>100MB, parent=1)
    [[ "$ppid" != "1" ]] && continue
    [[ "$rss" -lt 102400 ]] 2>/dev/null && continue

    # Skip the dev server and Claude processes
    [[ "$cmdline" == *"next-server"* ]] && continue
    [[ "$cmdline" == *"next dev"* ]] && continue
    [[ "$cmdline" == *"claude"* ]] && continue

    # Skip if it's a known long-running process (running before this ralphy started)
    # Only kill if it looks like a tsc/eslint worker node
    # Check if its original parent was tsc/eslint by looking at the command
    if [[ "$cmdline" == *"node"* ]]; then
      kill -TERM "$pid" 2>/dev/null || true
      ((killed++))
    fi
  done < <(ps -eo pid,ppid,rss,args 2>/dev/null | grep -E '^\s*[0-9]+\s+1\s+[0-9]+\s+.*node' | grep -v grep || true)

  # Clean up stale Claude Code shell snapshots (parent=1, old snapshot files)
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local pid ppid cmdline
    pid=$(echo "$line" | awk '{print $1}')
    ppid=$(echo "$line" | awk '{print $2}')
    cmdline=$(echo "$line" | awk '{$1=$2=""; print $0}' | sed 's/^ *//')

    [[ "$ppid" != "1" ]] && continue
    [[ "$cmdline" != *"shell-snapshots"* ]] && continue
    [[ "$cmdline" != *"tsc"* ]] && [[ "$cmdline" != *"eslint"* ]] && continue

    local children
    children=$(pgrep -P "$pid" 2>/dev/null || true)
    for child in $children; do
      kill -TERM "$child" 2>/dev/null || true
      ((killed++))
    done
    kill -TERM "$pid" 2>/dev/null || true
    ((killed++))
  done < <(ps -eo pid,ppid,args 2>/dev/null | grep "shell-snapshots" | grep -v grep || true)

  if [[ $killed -gt 0 ]]; then
    log_info "Reaped $killed orphaned process(es) (tsc/eslint/stale nodes)"
  fi
}

# Helper: Get all descendant PIDs recursively
get_all_descendants() {
  local pid=$1
  local descendants=$(pgrep -P "$pid" 2>/dev/null || true)

  if [[ -n "$descendants" ]]; then
    echo "$descendants"
    for child_pid in $descendants; do
      get_all_descendants "$child_pid"
    done
  fi
}

cleanup() {
  local exit_code=$?

  # Kill background processes and their entire process trees
  if [[ -n "$monitor_pid" ]]; then
    pkill -P "$monitor_pid" 2>/dev/null || true
    kill "$monitor_pid" 2>/dev/null || true
  fi
  if [[ -n "$ai_pid" ]]; then
    # Kill entire process tree rooted at ai_pid (claude -> npm exec -> node)
    pkill -P "$ai_pid" 2>/dev/null || true
    kill "$ai_pid" 2>/dev/null || true
  fi

  # Kill parallel processes and their trees
  for pid in "${parallel_pids[@]+"${parallel_pids[@]}"}"; do
    pkill -P "$pid" 2>/dev/null || true
    kill "$pid" 2>/dev/null || true
  done

  # Kill any remaining child processes
  pkill -P $$ 2>/dev/null || true

  # Kill orphaned Claude Code processes spawned by agents
  # Only kill descendants of THIS ralphy instance, not all Claude Code instances
  if [[ -n "$RALPHY_PID" ]]; then
    local all_descendants=$(get_all_descendants "$RALPHY_PID")
    if [[ -n "$all_descendants" ]]; then
      # Kill any Claude Code processes that are descendants of this ralphy
      for pid in $all_descendants; do
        local cmdline=$(ps -p "$pid" -o command= 2>/dev/null || true)
        if [[ "$cmdline" == *"claude-code"* ]] || [[ "$cmdline" == *"npm exec"* ]]; then
          kill -TERM "$pid" 2>/dev/null || true
        fi
      done
    fi
  fi

  # Kill orphaned tsc/eslint processes spawned by agents
  # Only kill those from this ralphy instance's working directory
  if [[ -n "$ORIGINAL_DIR" ]]; then
    if [[ -n "$RALPHY_PID" ]]; then
      local all_descendants=$(get_all_descendants "$RALPHY_PID")
      if [[ -n "$all_descendants" ]]; then
        for pid in $all_descendants; do
          local cmdline=$(ps -p "$pid" -o command= 2>/dev/null || true)
          if [[ "$cmdline" == *"tsc"*"${ORIGINAL_DIR}"* ]] || [[ "$cmdline" == *"eslint"*"${ORIGINAL_DIR}"* ]]; then
            kill -TERM "$pid" 2>/dev/null || true
          fi
        done
      fi
    fi
  fi

  # Final sweep for any orphaned processes
  reap_orphaned_processes

  # Release all claimed issues so other instances can pick them up
  for claimed_issue in "${CLAIMED_ISSUES[@]+"${CLAIMED_ISSUES[@]}"}"; do
    release_issue "$claimed_issue" 2>/dev/null || true
  done

  # Remove temp file
  [[ -n "$tmpfile" ]] && rm -f "$tmpfile"
  [[ -n "$CODEX_LAST_MESSAGE_FILE" ]] && rm -f "$CODEX_LAST_MESSAGE_FILE"

  # Cleanup instance lock file
  cleanup_instance_lock

  # Post-run audit: detect unmerged branches from this instance
  guardrail_post_run_audit 2>/dev/null || true

  # Cleanup parallel worktrees
  if [[ -n "$WORKTREE_BASE" ]] && [[ -d "$WORKTREE_BASE" ]]; then
    # Remove all worktrees we created
    for dir in "$WORKTREE_BASE"/agent-*; do
      if [[ -d "$dir" ]]; then
        if git -C "$dir" status --porcelain 2>/dev/null | grep -q .; then
          log_warn "Preserving dirty worktree: $dir"
          continue
        fi
        git worktree remove "$dir" 2>/dev/null || true
      fi
    done
    if ! find "$WORKTREE_BASE" -maxdepth 1 -type d -name 'agent-*' -print -quit 2>/dev/null | grep -q .; then
      rm -rf "$WORKTREE_BASE" 2>/dev/null || true
    else
      log_warn "Preserving worktree base with dirty agents: $WORKTREE_BASE"
    fi
  fi

  # Show message on interrupt
  if [[ $exit_code -eq 130 ]]; then
    printf "\n"
    log_warn "Interrupted! Cleaned up."

    # Show branches created if any
    if [[ -n "${task_branches[*]+"${task_branches[*]}"}" ]]; then
      log_info "Branches created: ${task_branches[*]}"
    fi
  fi
}
