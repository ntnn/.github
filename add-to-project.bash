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
        ' -f projectId="$PROJECT_ID" -f contentId="$node_id" --silent
}

declare -A handled_nodes=()

add_query_result_to_project() {
    local project_id="$1"
    [[ -z "$project_id" ]] && die "No project_id passed"
    local query="$2"
    [[ -z "$query" ]] && die "no query passed"

    query_node_ids "$query" | while read node_id; do
        if [[ -n "${handled_nodes["$node_id"]}" ]]; then
            # skip already handled nodes
            continue
        fi
        log "Handling node '$node_id'"
        if add_node_to_project "$project_id" "$node_id"; then
            handled_nodes["$node_id"]=done
        fi
    done
}

do_queries() {
    local since="$(date -u -d '24 hours ago' '+%Y-%m-%dT%H:%M:%S')"

    add_query_result_to_project "$PROJECT_ID" "org:${PROJECT_OWNER} is:issue updated:>=$since"
    add_query_result_to_project "$PROJECT_ID" "org:${PROJECT_OWNER} is:pr updated:>=$since"
    add_query_result_to_project "$PROJECT_ID" "author:${PROJECT_OWNER} is:issue updated:>=$since"
    add_query_result_to_project "$PROJECT_ID" "author:${PROJECT_OWNER} is:pr updated:>=$since"
    add_query_result_to_project "$PROJECT_ID" "commenter:${PROJECT_OWNER} is:issue updated:>=$since"
    add_query_result_to_project "$PROJECT_ID" "commenter:${PROJECT_OWNER} is:pr updated:>=$since"
    add_query_result_to_project "$PROJECT_ID" "reviewed-by:${PROJECT_OWNER} is:pr updated:>=$since"
}

cmd="$1"
shift

case "$cmd" in
    (all) do_queries;;
    (query) query_node_ids "$@";;
    (add) add_query_result_to_project "$PROJECT_ID" "$@";;
    (*) die "Unknown command $cmd";;
esac
