#!/usr/bin/env bash
#
# publish-to-gitlab.sh - publish a local git repository to GitLab.
#
# Creates the GitLab project if it does not exist yet, registers it as a git
# remote, then pushes the repository's branches and tags to it.
#
# Usage:
#   GITLAB_TOKEN=glpat-... ./publish-to-gitlab.sh [options]
#
# Options:
#   -u, --url URL            GitLab instance (default: $GITLAB_URL or https://gitlab.com)
#   -n, --namespace PATH     Group, subgroup or user to publish under (default:
#                            $GITLAB_NAMESPACE, else the token owner's personal namespace)
#   -p, --project PATH       Project path (default: the repository directory name)
#   -v, --visibility LEVEL   private | internal | public (default: private)
#   -d, --description TEXT   Description used when the project is created
#   -r, --remote NAME        Name of the git remote to add or update (default: gitlab)
#   -C, --repo DIR           Repository to publish (default: current directory)
#   -b, --branch NAME        Push only this branch; repeat for several (default: all branches)
#       --mirror             Force-push all branches and tags and delete remote
#                            branches and tags that no longer exist locally
#       --ssh                Push over SSH instead of HTTPS
#       --no-create          Fail instead of creating a missing project
#       --dry-run            Show what would change without changing anything
#   -h, --help               Show this help
#
# Environment:
#   GITLAB_TOKEN   Personal, group or project access token with the "api" scope
#                  ("read_api" + "write_repository" is enough with --no-create).
#                  The token is passed to curl and git through stdin and the
#                  environment, never on the command line, and is not written
#                  to .git/config.

set -euo pipefail

GITLAB_URL=${GITLAB_URL:-https://gitlab.com}
NAMESPACE=${GITLAB_NAMESPACE:-}
PROJECT=""
VISIBILITY=private
DESCRIPTION=""
REMOTE=gitlab
REPO_DIR=.
BRANCHES=()
MIRROR=false
USE_SSH=false
CREATE=true
DRY_RUN=false

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
info() { printf '==> %s\n' "$*"; }
usage() { sed -n '3,/^$/{s/^# \{0,1\}//;p;}' "$0"; }

need_arg() { [[ $# -ge 2 && -n $2 ]] || die "$1 needs a value"; }

while [[ $# -gt 0 ]]; do
  case $1 in
    -u|--url)         need_arg "$@"; GITLAB_URL=$2; shift 2 ;;
    -n|--namespace)   need_arg "$@"; NAMESPACE=$2; shift 2 ;;
    -p|--project)     need_arg "$@"; PROJECT=$2; shift 2 ;;
    -v|--visibility)  need_arg "$@"; VISIBILITY=$2; shift 2 ;;
    -d|--description) need_arg "$@"; DESCRIPTION=$2; shift 2 ;;
    -r|--remote)      need_arg "$@"; REMOTE=$2; shift 2 ;;
    -C|--repo)        need_arg "$@"; REPO_DIR=$2; shift 2 ;;
    -b|--branch)      need_arg "$@"; BRANCHES+=("$2"); shift 2 ;;
    --mirror)         MIRROR=true; shift ;;
    --ssh)            USE_SSH=true; shift ;;
    --no-create)      CREATE=false; shift ;;
    --dry-run)        DRY_RUN=true; shift ;;
    -h|--help)        usage; exit 0 ;;
    *)                die "unknown option: $1 (see --help)" ;;
  esac
done

for cmd in git curl; do
  command -v "$cmd" >/dev/null 2>&1 || die "$cmd is required"
done
if command -v jq >/dev/null 2>&1; then
  JSON=jq
elif command -v python3 >/dev/null 2>&1; then
  JSON=python3
else
  die "jq or python3 is required to read GitLab API responses"
fi

[[ -n ${GITLAB_TOKEN:-} ]] || die "GITLAB_TOKEN is not set"
case $VISIBILITY in
  private|internal|public) ;;
  *) die "visibility must be private, internal or public" ;;
esac
[[ $MIRROR == true && ${#BRANCHES[@]} -gt 0 ]] && die "--mirror and --branch cannot be combined"

GITLAB_URL=${GITLAB_URL%/}
API="$GITLAB_URL/api/v4"
NAMESPACE=${NAMESPACE#/}
NAMESPACE=${NAMESPACE%/}

# --- repository checks -------------------------------------------------------

TOPLEVEL=$(git -C "$REPO_DIR" rev-parse --show-toplevel 2>/dev/null) \
  || die "$REPO_DIR is not inside a git work tree"
git -C "$TOPLEVEL" rev-parse --verify --quiet HEAD >/dev/null \
  || die "$TOPLEVEL has no commits yet; nothing to publish"

for b in ${BRANCHES[@]+"${BRANCHES[@]}"}; do
  git -C "$TOPLEVEL" show-ref --verify --quiet "refs/heads/$b" || die "no local branch named $b"
done

if [[ -z $PROJECT ]]; then
  # GitLab paths may only contain letters, digits, '_', '-' and '.'.
  PROJECT=$(basename "$TOPLEVEL" | sed -e 's/[^A-Za-z0-9_.-]/-/g' -e 's/^[-.]*//' -e 's/[-.]*$//')
  [[ -n $PROJECT ]] || die "cannot derive a project path from $TOPLEVEL; pass --project"
fi

# --- GitLab API helpers --------------------------------------------------------

# api METHOD PATH [curl args...] - sets API_STATUS and API_BODY.
api() {
  local method=$1 path=$2 tmp
  shift 2
  tmp=$(mktemp)
  # The token goes in through stdin so it never shows up in the process list.
  if ! API_STATUS=$(printf 'PRIVATE-TOKEN: %s\n' "$GITLAB_TOKEN" |
      curl -sS -o "$tmp" -w '%{http_code}' -X "$method" -H @- "$@" "$API/$path"); then
    rm -f "$tmp"
    die "cannot reach $GITLAB_URL"
  fi
  API_BODY=$(<"$tmp")
  rm -f "$tmp"
  if [[ $API_STATUS == 401 ]]; then
    die "GitLab rejected the token (HTTP 401); check GITLAB_TOKEN and its scopes"
  fi
}

# json_get FIELD - print a top-level field of API_BODY, or nothing if absent.
json_get() {
  if [[ $JSON == jq ]]; then
    jq -r --arg k "$1" '.[$k] // empty' <<<"$API_BODY"
  else
    python3 -c 'import json, sys
v = json.load(sys.stdin).get(sys.argv[1])
print("" if v is None else v)' "$1" <<<"$API_BODY"
  fi
}

api_fail() { die "$1 (HTTP $API_STATUS): ${API_BODY:-no response body}"; }

urlencode_path() { printf '%s' "${1//\//%2F}"; }

# --- resolve the target project ------------------------------------------------

if [[ -z $NAMESPACE ]]; then
  api GET user
  [[ $API_STATUS == 200 ]] || api_fail "cannot identify the token's owner"
  NAMESPACE=$(json_get username)
fi
FULL_PATH="$NAMESPACE/$PROJECT"

info "Target: $GITLAB_URL/$FULL_PATH"
api GET "projects/$(urlencode_path "$FULL_PATH")"
CREATED=false
case $API_STATUS in
  200)
    info "Project already exists"
    ;;
  404)
    [[ $CREATE == true ]] || die "project $FULL_PATH does not exist (and --no-create was given)"
    api GET "namespaces/$(urlencode_path "$NAMESPACE")"
    [[ $API_STATUS == 200 ]] || api_fail "cannot find namespace $NAMESPACE"
    NAMESPACE_ID=$(json_get id)
    if [[ $DRY_RUN == true ]]; then
      info "[dry-run] would create $VISIBILITY project $FULL_PATH"
      API_BODY=$(printf '{"http_url_to_repo":"%s","ssh_url_to_repo":"%s","web_url":"%s"}' \
        "$GITLAB_URL/$FULL_PATH.git" "git@${GITLAB_URL#*://}:$FULL_PATH.git" "$GITLAB_URL/$FULL_PATH")
    else
      info "Creating $VISIBILITY project $FULL_PATH"
      api POST projects \
        --data-urlencode "name=$PROJECT" \
        --data-urlencode "path=$PROJECT" \
        --data-urlencode "namespace_id=$NAMESPACE_ID" \
        --data-urlencode "visibility=$VISIBILITY" \
        --data-urlencode "description=$DESCRIPTION"
      [[ $API_STATUS == 201 ]] || api_fail "cannot create project $FULL_PATH"
      CREATED=true
    fi
    ;;
  *)   api_fail "cannot look up project $FULL_PATH" ;;
esac

PROJECT_ID=$(json_get id)
WEB_URL=$(json_get web_url)
if [[ $USE_SSH == true ]]; then
  REMOTE_URL=$(json_get ssh_url_to_repo)
else
  REMOTE_URL=$(json_get http_url_to_repo)
fi
[[ -n $REMOTE_URL ]] || die "GitLab did not return a clone URL for $FULL_PATH"

# --- configure the remote ----------------------------------------------------

run() {
  if [[ $DRY_RUN == true ]]; then
    printf '[dry-run] %s\n' "$*"
  else
    "$@"
  fi
}

CURRENT_URL=$(git -C "$TOPLEVEL" remote get-url "$REMOTE" 2>/dev/null || true)
if [[ -z $CURRENT_URL ]]; then
  info "Adding remote $REMOTE -> $REMOTE_URL"
  run git -C "$TOPLEVEL" remote add "$REMOTE" "$REMOTE_URL"
elif [[ $CURRENT_URL != "$REMOTE_URL" ]]; then
  info "Pointing remote $REMOTE at $REMOTE_URL (was ${CURRENT_URL/:\/\/*@/://})"
  run git -C "$TOPLEVEL" remote set-url "$REMOTE" "$REMOTE_URL"
fi

# --- push --------------------------------------------------------------------

if [[ $MIRROR == true ]]; then
  REFSPECS=(--prune '+refs/heads/*:refs/heads/*' '+refs/tags/*:refs/tags/*')
elif [[ ${#BRANCHES[@]} -gt 0 ]]; then
  REFSPECS=(--follow-tags)
  for b in ${BRANCHES[@]+"${BRANCHES[@]}"}; do REFSPECS+=("refs/heads/$b:refs/heads/$b"); done
else
  REFSPECS=('refs/heads/*:refs/heads/*' 'refs/tags/*:refs/tags/*')
fi

if [[ $USE_SSH == false ]]; then
  # Authenticate the HTTPS push with the token through git's environment-based
  # config, scoped to the push URL, so it never lands on disk or in `ps`.
  export GIT_CONFIG_COUNT=1
  export GIT_CONFIG_KEY_0="http.$REMOTE_URL.extraHeader"
  GIT_CONFIG_VALUE_0="Authorization: Basic $(printf 'oauth2:%s' "$GITLAB_TOKEN" | base64 | tr -d '\n')"
  export GIT_CONFIG_VALUE_0
fi
export GIT_TERMINAL_PROMPT=0

info "Pushing to $REMOTE"
run git -C "$TOPLEVEL" push "$REMOTE" "${REFSPECS[@]}"

# A new project's default branch is whatever GitLab picked from the first push;
# make it match the branch that is checked out locally, when it was pushed.
if [[ $CREATED == true ]]; then
  HEAD_BRANCH=$(git -C "$TOPLEVEL" symbolic-ref --quiet --short HEAD || true)
  if [[ -n $HEAD_BRANCH ]] &&
      git -C "$TOPLEVEL" ls-remote --exit-code --heads "$REMOTE" "$HEAD_BRANCH" >/dev/null; then
    api PUT "projects/$PROJECT_ID" --data-urlencode "default_branch=$HEAD_BRANCH"
    [[ $API_STATUS == 200 ]] || api_fail "cannot set default branch to $HEAD_BRANCH"
  fi
fi

info "Published: ${WEB_URL:-$GITLAB_URL/$FULL_PATH}"
