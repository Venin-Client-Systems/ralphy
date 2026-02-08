# ============================================
# TASK SOURCES - YAML
# ============================================

get_tasks_yaml() {
  yq -r '.tasks[] | select(.completed != true) | .title' "$PRD_FILE" 2>/dev/null || true
}

get_next_task_yaml() {
  yq -r '.tasks[] | select(.completed != true) | .title' "$PRD_FILE" 2>/dev/null | head -1 || echo ""
}

count_remaining_yaml() {
  yq -r '[.tasks[] | select(.completed != true)] | length' "$PRD_FILE" 2>/dev/null || echo "0"
}

count_completed_yaml() {
  yq -r '[.tasks[] | select(.completed == true)] | length' "$PRD_FILE" 2>/dev/null || echo "0"
}

mark_task_complete_yaml() {
  local task=$1
  yq -i "(.tasks[] | select(.title == \"$task\")).completed = true" "$PRD_FILE"
}

get_parallel_group_yaml() {
  local task=$1
  yq -r ".tasks[] | select(.title == \"$task\") | .parallel_group // 0" "$PRD_FILE" 2>/dev/null || echo "0"
}

get_tasks_in_group_yaml() {
  local group=$1
  yq -r ".tasks[] | select(.completed != true and (.parallel_group // 0) == $group) | .title" "$PRD_FILE" 2>/dev/null || true
}
