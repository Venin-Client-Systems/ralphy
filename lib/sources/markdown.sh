# ============================================
# TASK SOURCES - MARKDOWN
# ============================================

get_tasks_markdown() {
  grep '^\- \[ \]' "$PRD_FILE" 2>/dev/null | sed 's/^- \[ \] //' || true
}

get_next_task_markdown() {
  grep -m1 '^\- \[ \]' "$PRD_FILE" 2>/dev/null | sed 's/^- \[ \] //' || echo ""
}

count_remaining_markdown() {
  grep -c '^\- \[ \]' "$PRD_FILE" 2>/dev/null || echo "0"
}

count_completed_markdown() {
  grep -c '^\- \[x\]' "$PRD_FILE" 2>/dev/null || echo "0"
}

mark_task_complete_markdown() {
  local task=$1
  # For macOS sed (BRE), we need to:
  # - Escape: [ ] \ . * ^ $ /
  # - NOT escape: { } ( ) + ? | (these are literal in BRE)
  local escaped_task
  escaped_task=$(printf '%s\n' "$task" | sed 's/[[\.*^$/]/\\&/g')
  # Replacement string also needs & escaped (references matched text in sed)
  local escaped_replacement
  escaped_replacement=$(printf '%s\n' "$task" | sed 's/[[\.*^$/&]/\\&/g')
  sed -i.bak "s/^- \[ \] ${escaped_task}/- [x] ${escaped_replacement}/" "$PRD_FILE"
  rm -f "${PRD_FILE}.bak"
}
