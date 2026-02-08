# ============================================
# NOTIFICATION (Cross-platform)
# ============================================

notify_done() {
  local message="${1:-Ralphy has completed all tasks!}"

  # Clean up orphaned processes before notifying
  reap_orphaned_processes

  # macOS
  if command -v afplay &>/dev/null; then
    afplay /System/Library/Sounds/Glass.aiff 2>/dev/null &
  fi

  # macOS notification
  if command -v osascript &>/dev/null; then
    osascript -e "display notification \"$message\" with title \"Ralphy\"" 2>/dev/null || true
  fi

  # Linux (notify-send)
  if command -v notify-send &>/dev/null; then
    notify-send "Ralphy" "$message" 2>/dev/null || true
  fi

  # Linux (paplay for sound)
  if command -v paplay &>/dev/null; then
    paplay /usr/share/sounds/freedesktop/stereo/complete.oga 2>/dev/null &
  fi

  # Windows (powershell)
  if command -v powershell.exe &>/dev/null; then
    powershell.exe -Command "[System.Media.SystemSounds]::Asterisk.Play()" 2>/dev/null || true
  fi
}

notify_error() {
  local message="${1:-Ralphy encountered an error}"

  # macOS - error sound + notification
  if command -v afplay &>/dev/null; then
    afplay /System/Library/Sounds/Basso.aiff 2>/dev/null &
  fi
  if command -v osascript &>/dev/null; then
    osascript -e "display notification \"$message\" with title \"Ralphy - Error\"" 2>/dev/null || true
  fi

  # Linux
  if command -v notify-send &>/dev/null; then
    notify-send -u critical "Ralphy - Error" "$message" 2>/dev/null || true
  fi
}

notify_task_done() {
  local task_desc="${1:-Task completed}"

  # macOS - subtle chime per task
  if command -v afplay &>/dev/null; then
    afplay /System/Library/Sounds/Pop.aiff 2>/dev/null &
  fi
  if command -v osascript &>/dev/null; then
    osascript -e "display notification \"$task_desc\" with title \"Ralphy - Issue Done\"" 2>/dev/null || true
  fi

  # Linux
  if command -v notify-send &>/dev/null; then
    notify-send "Ralphy - Issue Done" "$task_desc" 2>/dev/null || true
  fi
}

notify_task_stuck() {
  local task_desc="${1:-Task appears stuck}"
  local elapsed_mins="${2:-?}"

  # macOS - attention-getting sound
  if command -v afplay &>/dev/null; then
    afplay /System/Library/Sounds/Sosumi.aiff 2>/dev/null &
  fi
  if command -v osascript &>/dev/null; then
    osascript -e "display notification \"$task_desc (${elapsed_mins}m elapsed)\" with title \"Ralphy - Agent Stuck\"" 2>/dev/null || true
  fi

  # Linux
  if command -v notify-send &>/dev/null; then
    notify-send -u critical "Ralphy - Agent Stuck" "$task_desc (${elapsed_mins}m elapsed)" 2>/dev/null || true
  fi
}
