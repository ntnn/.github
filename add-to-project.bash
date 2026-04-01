#!/usr/bin/env bash

log() { echo ">>> $@" >&2; }
die() { log "$@"; exit 1; }

[[ -n "$GH_TOKEN" ]] || die "GH_TOKEN must be set"
[[ -n "$PROJECT_OWNER" ]] || die "PROJECT_OWNER must be set"
[[ -n "$PROJECT_ID" ]] || die "PROJECT_ID must be set"

query_node_ids() {
    local query="$1"
    [[ -z "$query" ]] && die "no query passed"

    gh api graphql --paginate -f query='
        query($search: String!, $cursor: String) {
            search(query: $search, type: ISSUE, first: 100, after: $cursor) {
              pageInfo {
                hasNextPage
                endCursor
              }
              nodes {
                ... on Issue { id }
                ... on PullRequest { id }
              }
            }
          }
        ' -f search="$query" --jq '.data.search.nodes[].id'
}

add_node_to_project() {
    local project_id="$1"
    [[ -z "$project_id" ]] && die "No project_id passed"
    local node_id="$2"
    [[ -z "$node_id" ]] && die "No node_id passed"

    gh api graphql -f query='
          mutation($projectId: ID!, $contentId: ID!) {
            addProjectV2ItemById(input: {projectId: $projectId, contentId: $contentId}) {
              item {
                id
              }
            }
          }
        ' -f projectId="$PROJECT_ID" -f contentId="$node_id" --jq '.data.addProjectV2ItemById.item.id'
}

query_archived_project_item_content_ids() {
    local project_id="$1"
    [[ -z "$project_id" ]] && die "No project_id passed"

    gh api graphql --paginate -f query='
        query($projectId: ID!, $cursor: String) {
            node(id: $projectId) {
                ... on ProjectV2 {
                    items(first: 100, after: $cursor, query: "is:archived") {
                        pageInfo {
                            hasNextPage
                            endCursor
                        }
                        nodes {
                            content {
                                ... on Issue { id }
                                ... on PullRequest { id }
                            }
                        }
                    }
                }
            }
        }
    ' -f projectId="$project_id" --jq '.data.node.items.nodes[].content.id'
}

query_status_fields() {
    local project_id="$1"
    [[ -z "$project_id" ]] && die "No project_id passed"

    gh api graphql -f query='
        query($projectId: ID!) {
            node(id: $projectId) {
                ... on ProjectV2 {
                    fields(first: 50) {
                        nodes {
                            ... on ProjectV2SingleSelectField {
                                id
                                name
                                options { id name }
                            }
                        }
                    }
                }
            }
        }
    ' -f projectId="$project_id" \
        --jq '.data.node.fields.nodes[] | select(.name != null) | "\(.name) (\(.id)):", (.options[] | "  \(.name) (\(.id))")'
}

set_item_status() {
    local project_id="$1"
    [[ -z "$project_id" ]] && die "No project_id passed"
    local item_id="$2"
    [[ -z "$item_id" ]] && die "No item_id passed"
    local field_id="$3"
    [[ -z "$field_id" ]] && die "No field_id passed"
    local option_id="$4"
    [[ -z "$option_id" ]] && die "No option_id passed"

    gh api graphql -f query='
        mutation($projectId: ID!, $itemId: ID!, $fieldId: ID!, $optionId: String!) {
            updateProjectV2ItemFieldValue(input: {
                projectId: $projectId,
                itemId: $itemId,
                fieldId: $fieldId,
                value: { singleSelectOptionId: $optionId }
            }) {
                projectV2Item { id }
            }
        }
    ' -f projectId="$project_id" -f itemId="$item_id" -f fieldId="$field_id" -f optionId="$option_id" --silent
}

declare -A handled_nodes=()

populate_archived_nodes() {
    local project_id="$1"
    [[ -z "$project_id" ]] && die "No project_id passed"

    for node_id in $(query_archived_project_item_content_ids "$project_id"); do
        log "Skipping archived node '$node_id'"
        handled_nodes["$node_id"]="archived"
    done
}

add_query_result_to_project() {
    local project_id="$1"
    [[ -z "$project_id" ]] && die "No project_id passed"
    local query="$2"
    [[ -z "$query" ]] && die "no query passed"
    local field_id="$3"
    local option_id="$4"

    for node_id in $(query_node_ids "$query"); do
        if [[ -n "${handled_nodes["$node_id"]}" ]]; then
            # skip already handled nodes
            continue
        fi
        log "Handling node '$node_id'"
        local item_id
        if item_id=$(add_node_to_project "$project_id" "$node_id"); then
            handled_nodes["$node_id"]=done
            if [[ -n "$field_id" ]] && [[ -n "$option_id" ]]; then
                log "Setting status on item '$item_id'"
                set_item_status "$project_id" "$item_id" "$field_id" "$option_id"
            fi
        fi
    done
}

do_queries() {
    # costs too many api requests
    # populate_archived_nodes "$PROJECT_ID"

    local since="$(date -u -d '2 hours ago' '+%Y-%m-%dT%H:%M:%S')"

    add_query_result_to_project "$PROJECT_ID" "org:${PROJECT_OWNER} is:issue updated:>=$since"
    add_query_result_to_project "$PROJECT_ID" "org:${PROJECT_OWNER} is:pr updated:>=$since" "$STATUS_FIELD" "$STATUS_OPT_REVIEWING"

    add_query_result_to_project "$PROJECT_ID" "author:${PROJECT_OWNER} is:issue updated:>=$since"
    add_query_result_to_project "$PROJECT_ID" "author:${PROJECT_OWNER} is:pr updated:>=$since" "$STATUS_FIELD" "$STATUS_OPT_IN_REVIEW"

    add_query_result_to_project "$PROJECT_ID" "commenter:${PROJECT_OWNER} is:issue updated:>=$since" "$STATUS_FIELD" "$STATUS_OPT_KEEPING_TAGS"
    add_query_result_to_project "$PROJECT_ID" "commenter:${PROJECT_OWNER} is:pr updated:>=$since" "$STATUS_FIELD" "$STATUS_OPT_REVIEWING"

    add_query_result_to_project "$PROJECT_ID" "author:${PROJECT_OWNER} is:issue updated:>=$since" "$STATUS_FIELD" "$STATUS_OPT_KEEPING_TAGS"

    add_query_result_to_project "$PROJECT_ID" "reviewed-by:${PROJECT_OWNER} is:pr updated:>=$since" "$STATUS_FIELD" "$STATUS_OPT_REVIEWING"
}

cmd="$1"
shift

case "$cmd" in
    (all) do_queries;;
    (fields) query_status_fields "$PROJECT_ID";;
    (archived) query_archived_project_item_content_ids "$@";;
    (query) query_node_ids "$@";;
    (add) add_query_result_to_project "$PROJECT_ID" "$@";;
    (*) die "Unknown command $cmd";;
esac
