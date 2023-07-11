#! /bin/bash

set -o errexit
set -o pipefail
set -o nounset
set -o errtrace

DEST=${1:-}

if [[ -z "$DEST" ]]; then
    echo "ERROR: expected a destination file as parameter ..." >&2
    exit 1
fi

if [[ -f "$DEST" ]]; then
    echo "INFO: '$DEST' already exists, not running $0" >&2
    exit 0
fi

if [[ -z "${PULL_NUMBER:-}" || -z "${REPO_OWNER:-}" || -z "${REPO_NAME:-}" ]]; then
    echo "ERROR: PULL_NUMBER=${PULL_NUMBER:-} or REPO_OWNER=${REPO_OWNER:-} or REPO_NAME=${REPO_NAME:-} not defined ..." >&2
    exit 1
fi

if [[ "$DEST" == "-" ]]; then
    DEST=/proc/self/fd/1
fi

PR_URL="https://api.github.com/repos/$REPO_OWNER/$REPO_NAME/pulls/$PULL_NUMBER"
PR_COMMENTS_URL="https://api.github.com/repos/$REPO_OWNER/$REPO_NAME/issues/$PULL_NUMBER/comments"

if [[ "${TEST_NAME:-}" ]]; then
    test_name=$TEST_NAME

elif [[ "${OPENSHIFT_CI:-}" == true ]]; then
    JOB_NAME_PREFIX=pull-ci-${REPO_OWNER}-${REPO_NAME}-${PULL_BASE_REF}
    test_name=$(echo "$JOB_NAME" | sed "s/$JOB_NAME_PREFIX-//")

    if [[ -z "${SHARED_DIR:-}" ]]; then
        echo "ERROR: running in OpenShift CI, but SHARED_DIR not defined." >&2
        exit 1
    fi

else
    echo "ERROR: not running in OpenShift CI and TEST_NAME not defined." >&2
    exit 1
fi

echo "PR URL: $PR_URL" >&2
if [[ "${OPENSHIFT_CI:-}" == true ]]; then
    PR_FILE="${SHARED_DIR}/pr.json"
    if [[ ! -e "$PR_FILE" ]]; then
        echo "PR file '$PR_FILE' does not exist. Downloading it from Github ..."
        curl -sSf "$PR_URL" -o "$PR_FILE"
    fi
    pr_json=$(cat "$PR_FILE")

else
    pr_json=$(curl -sSf "$PR_URL")
fi

pr_body=$(jq -r .body <<< "$pr_json")
pr_comments=$(jq -r .comments <<< "$pr_json")

if [[ "${JOB_SPEC:-}" ]]; then
    pr_author=$(echo "$JOB_SPEC" | jq -r .refs.pulls[0].author)
else
    pr_author=$(jq -r .user.login <<< "$pr_json")
fi

COMMENTS_PER_PAGE=30 # default
last_comment_page=$(($pr_comments / $COMMENTS_PER_PAGE))
[[ $(($pr_comments % $COMMENTS_PER_PAGE)) != 0 ]] && last_comment_page=$(($last_comment_page + 1))


PR_LAST_COMMENT_PAGE_URL="$PR_COMMENTS_URL?page=$last_comment_page"

if [[ "${OPENSHIFT_CI:-}" == true ]]; then
    LAST_COMMENT_PAGE_FILE="${SHARED_DIR}/pr_last_comment_page.json"
    if [[ ! -e "$LAST_COMMENT_PAGE_FILE" ]]; then
        echo "PR last comment file page '$LAST_COMMENT_PAGE_FILE' does not exist. Downloading it from Github ..."
        curl -sSf "$PR_LAST_COMMENT_PAGE_URL" -o "$LAST_COMMENT_PAGE_FILE"
    fi
    last_comment_page_json=$(cat "$LAST_COMMENT_PAGE_FILE")

else
    last_comment_page_json=$(curl -sSf "$PR_LAST_COMMENT_PAGE_URL")
fi

echo "PR comments URL: $PR_COMMENTS_URL" >&2
last_user_test_comment=$(echo "$last_comment_page_json" \
                             | jq '.[] | select(.user.login == "'$pr_author'") | .body' \
                             | (grep "$test_name" || true) \
                             | tail -1 | jq -r)

if [[ -z "$last_user_test_comment" ]]; then
    echo "WARNING: last comment of author '$pr_author' could not be found (searching for '$test_name') ..." >&2
fi

pos_args=$(echo "$last_user_test_comment" |
               (grep "$test_name" || true) | cut -d" " -f3- | tr -d '\n' | tr -d '\r')
if [[ "$pos_args" ]]; then
    echo "PR_POSITIONAL_ARGS='$pos_args'" >> "$DEST"
    i=1
    for pos_arg in $pos_args; do
        echo "PR_POSITIONAL_ARG_$i='$pos_arg'" >> "$DEST"
        i=$((i + 1))
    done
fi
echo "PR_POSITIONAL_ARG_0='$test_name'" >> "$DEST"

while read line; do
    [[ $line != "/var "* ]] && continue
    [[ $line != *=* ]] && continue

    key=$(echo "$line" | cut -d" " -f2- | cut -d= -f1)
    value=$(echo "$line" | cut -d= -f2 | tr -d '\n' | tr -d '\r')

    echo "$key='$value'" >> "$DEST"
done <<< $(echo "$pr_body"; echo "$last_user_test_comment")
