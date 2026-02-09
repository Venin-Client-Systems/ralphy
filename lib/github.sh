# ============================================
# GITHUB PROJECT BOARD INTEGRATION
# ============================================

# Initialize project board: resolve IDs for fields and options
project_board_init() {
  if [[ -z "$PROJECT_BOARD_NUM" ]] || [[ -z "$PROJECT_BOARD_OWNER" ]]; then
    log_warn "No project board configured (use --project OWNER/NUM or add to ~/.ralphy/config)"
    return 0
  fi

  log_info "Connecting to GitHub Project #${PROJECT_BOARD_NUM}..."

  # Get project node ID and all fields in one query
  local result
  result=$(gh api graphql -f query='
    query($owner: String!, $num: Int!) {
      organization(login: $owner) {
        projectV2(number: $num) {
          id
          title
          fields(first: 30) {
            nodes {
              ... on ProjectV2Field { id name }
              ... on ProjectV2SingleSelectField {
                id name
                options { id name }
              }
              ... on ProjectV2IterationField { id name }
            }
          }
        }
      }
    }' -f owner="$PROJECT_BOARD_OWNER" -F num="$PROJECT_BOARD_NUM" 2>/dev/null) || {
    log_warn "Could not connect to project board (will continue without board updates)"
    PROJECT_BOARD_NUM=""
    return 0
  }

  PROJECT_NODE_ID=$(echo "$result" | jq -r '.data.organization.projectV2.id // empty')
  if [[ -z "$PROJECT_NODE_ID" ]]; then
    log_warn "Project board not found (will continue without board updates)"
    PROJECT_BOARD_NUM=""
    return 0
  fi

  local board_title
  board_title=$(echo "$result" | jq -r '.data.organization.projectV2.title')
  log_info "Connected to project: ${CYAN}${board_title}${RESET}"

  # Extract field IDs
  PROJECT_STATUS_FIELD_ID=$(echo "$result" | jq -r '.data.organization.projectV2.fields.nodes[] | select(.name == "Status") | .id // empty')
  PROJECT_BATCH_FIELD_ID=$(echo "$result" | jq -r '.data.organization.projectV2.fields.nodes[] | select(.name == "Ralphy Batch") | .id // empty')
  PROJECT_BRANCH_FIELD_ID=$(echo "$result" | jq -r '.data.organization.projectV2.fields.nodes[] | select(.name == "Branch") | .id // empty')

  # Extract status options
  local status_options
  status_options=$(echo "$result" | jq -r '.data.organization.projectV2.fields.nodes[] | select(.name == "Status") | .options[]? | "\(.name)=\(.id)"')
  while IFS='=' read -r name id; do
    [[ -n "$name" ]] && PROJECT_STATUS_OPTIONS["$name"]="$id"
  done <<< "$status_options"

  # Extract batch options (key by label prefix like "ralphy-0")
  local batch_options
  batch_options=$(echo "$result" | jq -r '.data.organization.projectV2.fields.nodes[] | select(.name == "Ralphy Batch") | .options[]? | "\(.name)=\(.id)"')
  while IFS='=' read -r name id; do
    if [[ -n "$name" ]]; then
      # Extract prefix like "ralphy-0" from "ralphy-0 (critical)"
      local prefix="${name%% *}"
      PROJECT_BATCH_OPTIONS["$prefix"]="$id"
    fi
  done <<< "$batch_options"

  log_debug "Project fields: status=${PROJECT_STATUS_FIELD_ID:-none} batch=${PROJECT_BATCH_FIELD_ID:-none} branch=${PROJECT_BRANCH_FIELD_ID:-none}"
  log_debug "Status options: ${!PROJECT_STATUS_OPTIONS[*]}"
  log_debug "Batch options: ${!PROJECT_BATCH_OPTIONS[*]}"
}

# Add an issue to the project board and return the item ID
# Usage: project_board_add_issue <issue_number>
project_board_add_issue() {
  local issue_num="$1"
  if [[ -z "$PROJECT_NODE_ID" ]]; then return 0; fi

  # Check cache first
  if [[ -n "${PROJECT_ITEM_CACHE[$issue_num]:-}" ]]; then
    echo "${PROJECT_ITEM_CACHE[$issue_num]}"
    return 0
  fi

  # Get the issue's node ID
  local issue_node_id
  issue_node_id=$(gh api graphql -f query='
    query($owner: String!, $repo: String!, $num: Int!) {
      repository(owner: $owner, name: $repo) {
        issue(number: $num) { id }
      }
    }' -f owner="${GITHUB_REPO%%/*}" -f repo="${GITHUB_REPO##*/}" -F num="$issue_num" \
    --jq '.data.repository.issue.id' 2>/dev/null) || return 1

  if [[ -z "$issue_node_id" ]]; then return 1; fi

  # Add to project
  local item_id
  item_id=$(gh api graphql -f query='
    mutation($projectId: ID!, $contentId: ID!) {
      addProjectV2ItemById(input: {projectId: $projectId, contentId: $contentId}) {
        item { id }
      }
    }' -f projectId="$PROJECT_NODE_ID" -f contentId="$issue_node_id" \
    --jq '.data.addProjectV2ItemById.item.id' 2>/dev/null) || {
    log_debug "Failed to add issue #$issue_num to project board"
    return 1
  }

  if [[ -n "$item_id" ]]; then
    PROJECT_ITEM_CACHE[$issue_num]="$item_id"
    log_debug "Added issue #$issue_num to project board (item: ${item_id:0:20}...)"
    echo "$item_id"
  fi
}

# Update a single-select field on a project item
# Usage: project_board_update_select <item_id> <field_id> <option_id>
project_board_update_select() {
  local item_id="$1" field_id="$2" option_id="$3"
  if [[ -z "$PROJECT_NODE_ID" ]] || [[ -z "$item_id" ]] || [[ -z "$field_id" ]] || [[ -z "$option_id" ]]; then
    return 0
  fi

  gh api graphql -f query='
    mutation($projectId: ID!, $itemId: ID!, $fieldId: ID!, $optionId: String!) {
      updateProjectV2ItemFieldValue(input: {
        projectId: $projectId
        itemId: $itemId
        fieldId: $fieldId
        value: {singleSelectOptionId: $optionId}
      }) {
        projectV2Item { id }
      }
    }' -f projectId="$PROJECT_NODE_ID" -f itemId="$item_id" \
       -f fieldId="$field_id" -f optionId="$option_id" >/dev/null 2>&1 || {
    log_debug "Failed to update select field on item $item_id"
    return 1
  }
}

# Update a text field on a project item
# Usage: project_board_update_text <item_id> <field_id> <value>
project_board_update_text() {
  local item_id="$1" field_id="$2" value="$3"
  if [[ -z "$PROJECT_NODE_ID" ]] || [[ -z "$item_id" ]] || [[ -z "$field_id" ]]; then
    return 0
  fi

  gh api graphql -f query='
    mutation($projectId: ID!, $itemId: ID!, $fieldId: ID!, $text: String!) {
      updateProjectV2ItemFieldValue(input: {
        projectId: $projectId
        itemId: $itemId
        fieldId: $fieldId
        value: {text: $text}
      }) {
        projectV2Item { id }
      }
    }' -f projectId="$PROJECT_NODE_ID" -f itemId="$item_id" \
       -f fieldId="$field_id" -f text="$value" >/dev/null 2>&1 || {
    log_debug "Failed to update text field on item $item_id"
    return 1
  }
}

# Set the status of an issue on the project board
# Usage: project_board_set_status <issue_number> <status_name>
# status_name: "Todo", "Queued", "In Progress", "In Review", "Done"
project_board_set_status() {
  local issue_num="$1" status_name="$2"
  if [[ -z "$PROJECT_NODE_ID" ]] || [[ -z "$PROJECT_STATUS_FIELD_ID" ]]; then return 0; fi

  local option_id="${PROJECT_STATUS_OPTIONS[$status_name]:-}"
  if [[ -z "$option_id" ]]; then
    log_debug "Unknown project status: $status_name"
    return 1
  fi

  # Ensure issue is on the board
  local item_id
  item_id=$(project_board_add_issue "$issue_num") || return 1
  if [[ -z "$item_id" ]]; then return 1; fi

  project_board_update_select "$item_id" "$PROJECT_STATUS_FIELD_ID" "$option_id"
}

# Set the Ralphy Batch field for an issue
# Usage: project_board_set_batch <issue_number> <label>  (e.g., "ralphy-1")
project_board_set_batch() {
  local issue_num="$1" label="$2"
  if [[ -z "$PROJECT_NODE_ID" ]] || [[ -z "$PROJECT_BATCH_FIELD_ID" ]]; then return 0; fi

  local option_id="${PROJECT_BATCH_OPTIONS[$label]:-}"
  if [[ -z "$option_id" ]]; then
    log_debug "No batch option for label: $label"
    return 0
  fi

  local item_id
  item_id=$(project_board_add_issue "$issue_num") || return 1
  if [[ -z "$item_id" ]]; then return 1; fi

  project_board_update_select "$item_id" "$PROJECT_BATCH_FIELD_ID" "$option_id"
}

# Set the Branch field for an issue
# Usage: project_board_set_branch <issue_number> <branch_name>
project_board_set_branch() {
  local issue_num="$1" branch_name="$2"
  if [[ -z "$PROJECT_NODE_ID" ]] || [[ -z "$PROJECT_BRANCH_FIELD_ID" ]]; then return 0; fi

  local item_id
  item_id=$(project_board_add_issue "$issue_num") || return 1
  if [[ -z "$item_id" ]]; then return 1; fi

  project_board_update_text "$item_id" "$PROJECT_BRANCH_FIELD_ID" "$branch_name"
}

# Convenience: set up a task on the board when processing starts
# Usage: project_board_task_started <task>  (format: "number:title")
project_board_task_started() {
  local task="$1"
  local issue_num="${task%%:*}"
  if [[ -z "$PROJECT_NODE_ID" ]]; then return 0; fi

  # Add to board, set status, set batch label (suppress stdout to avoid clobbering spinner)
  project_board_set_status "$issue_num" "In Progress" >/dev/null &
  if [[ -n "$GITHUB_LABEL" ]]; then
    project_board_set_batch "$issue_num" "$GITHUB_LABEL" >/dev/null &
  fi
  wait
}

# Convenience: mark a task done on the board
# Usage: project_board_task_completed <task> [branch_name]
project_board_task_completed() {
  local task="$1"
  local branch_name="${2:-}"
  local issue_num="${task%%:*}"
  if [[ -z "$PROJECT_NODE_ID" ]]; then return 0; fi

  project_board_set_status "$issue_num" "Done" >/dev/null &
  if [[ -n "$branch_name" ]]; then
    project_board_set_branch "$issue_num" "$branch_name" >/dev/null &
  fi
  wait
}

# Convenience: mark a task as in review on the board
# Usage: project_board_task_in_review <task> [branch_name]
project_board_task_in_review() {
  local task="$1"
  local branch_name="${2:-}"
  local issue_num="${task%%:*}"
  if [[ -z "$PROJECT_NODE_ID" ]]; then return 0; fi

  project_board_set_status "$issue_num" "In Review" >/dev/null &
  if [[ -n "$branch_name" ]]; then
    project_board_set_branch "$issue_num" "$branch_name" >/dev/null &
  fi
  wait
}

# Convenience: mark a task as queued on the board
# Usage: project_board_task_queued <task>
project_board_task_queued() {
  local task="$1"
  local issue_num="${task%%:*}"
  if [[ -z "$PROJECT_NODE_ID" ]]; then return 0; fi

  project_board_set_status "$issue_num" "Queued"
  if [[ -n "$GITHUB_LABEL" ]]; then
    project_board_set_batch "$issue_num" "$GITHUB_LABEL"
  fi
}
