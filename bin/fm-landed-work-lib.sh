#!/usr/bin/env bash
# fm-landed-work-lib.sh - the one owner of the landed-work test and of a
# landing-claim check for branch records.
#
# WHY. Two separate acts need the same proof that work actually landed:
# bin/fm-teardown.sh must not discard a worktree whose work is still only
# local, and a supervision-branch outcome must not turn a plausible SHA or PR
# number into a "merged" fact. The 2026-09-09 incident claimed a merged pull
# request at a commit that did not exist; a later actor acted on that claim.
# This library keeps ONE landed-work implementation and adds the claim check
# that uses it.
#
# CONTRACT. The functions below are parameterized by worktree, project clone,
# and PR URL so bin/fm-teardown.sh and the outcome store call the same code.
# They never mutate a repository: ensure_commit_object may fetch a PR head into
# the existing worktree, exactly as teardown already did, and nothing else
# writes. Every failure to prove landing returns nonzero; no caller may read a
# failed proof as success.
#
# fm_landed_claim_check is the refusal side for prose. It runs only when a
# summary asserts merged, landed, or released work. A named short or full SHA
# must exist in a readable repository and, under a path or target authority,
# must be contained in the named target revision. A named PR identity must be
# proven MERGED through a forge read or an authority string that carries that
# response. A broad legacy claim with no SHA and no PR identity is left to the
# outcome store's unverified marking rather than guessed at.
#
# No side effects on source. Bash 3.2 compatible. set -u safe.

# fm_landed_default_branch <repo>: origin/HEAD, else main, else master.
fm_landed_default_branch() {
  local repo=$1 ref branch
  ref=$(git -C "$repo" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    printf '%s\n' "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
      printf '%s\n' "$branch"
      return 0
    fi
  done
  return 1
}

# fm_landed_pr_number_from_branch <worktree> <branch>: one matching PR number.
fm_landed_pr_number_from_branch() {
  local wt=$1 branch=$2 out n
  [ -n "$branch" ] && [ "$branch" != HEAD ] || return 1
  out=$( cd "$wt" && gh-axi pr list --state all --head "$branch" --limit 1 2>/dev/null ) || return 1
  n=$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*\([0-9][0-9]*\),.*/\1/p' | head -1)
  [ -n "$n" ] || return 1
  printf '%s' "$n"
}

# fm_landed_pr_number_from_target <target>: a PR number from a URL or bare id.
fm_landed_pr_number_from_target() {
  local target=$1 n
  case "$target" in
    '' ) return 1 ;;
    *"/pull/"*)
      n=${target##*/pull/}
      n=${n%%[!0-9]*}
      ;;
    [0-9]*)
      n=${target%%[!0-9]*}
      ;;
    *) return 1 ;;
  esac
  [ -n "$n" ] || return 1
  printf '%s' "$n"
}

# fm_landed_ensure_commit_object <worktree> <target> <commit>: prove the commit
# object exists locally, fetching the PR head once when a PR target names it.
fm_landed_ensure_commit_object() {
  local wt=$1 target=$2 commit=$3 n
  git -C "$wt" cat-file -e "$commit^{commit}" 2>/dev/null && return 0
  n=$(fm_landed_pr_number_from_target "$target") || return 1
  git -C "$wt" remote get-url origin >/dev/null 2>&1 || return 1
  git -C "$wt" fetch --quiet origin "refs/pull/$n/head" >/dev/null 2>&1 || return 1
  git -C "$wt" cat-file -e "$commit^{commit}" 2>/dev/null
}

# fm_landed_patch_id_for_commit <worktree> <commit>: stable patch identity.
fm_landed_patch_id_for_commit() {
  local wt=$1 commit=$2
  git -C "$wt" show --pretty=medium --no-ext-diff "$commit" 2>/dev/null \
    | git patch-id --stable 2>/dev/null \
    | awk 'NR == 1 { print $1 }'
}

# fm_landed_unpushed_patches_are_in_pr_head <worktree> <pr-head>: true when
# every commit not on a remote is present by patch identity in the PR head.
fm_landed_unpushed_patches_are_in_pr_head() {
  local wt=$1 pr_head=$2 current base pr_patch_ids commit patch_id unpushed
  current=$(git -C "$wt" rev-parse --verify HEAD 2>/dev/null) || return 1
  base=$(git -C "$wt" merge-base "$current" "$pr_head" 2>/dev/null) || return 1
  pr_patch_ids=$(
    git -C "$wt" log --format=%H "$base..$pr_head" -- 2>/dev/null \
      | while IFS= read -r commit; do
          fm_landed_patch_id_for_commit "$wt" "$commit"
        done \
      | sed '/^$/d' \
      | sort -u
  ) || return 1
  [ -n "$pr_patch_ids" ] || return 1
  unpushed=$(git -C "$wt" log --format=%H HEAD --not --remotes -- 2>/dev/null) || return 1
  [ -n "$unpushed" ] || return 1
  while IFS= read -r commit; do
    [ -n "$commit" ] || continue
    patch_id=$(fm_landed_patch_id_for_commit "$wt" "$commit") || return 1
    [ -n "$patch_id" ] || return 1
    printf '%s\n' "$pr_patch_ids" | grep -qxF "$patch_id" || return 1
  done <<EOF
$unpushed
EOF
}

# fm_landed_pr_is_merged <worktree> <pr-url-or-empty> <branch>: 0 when the PR is
# merged and the worktree's current work is contained in its head. Prints the
# resolved PR URL on stdout so a caller that started from a branch name can
# record it. All lookup failure is nonzero, never a guess.
fm_landed_pr_is_merged() {
  local wt=$1 pr_url=$2 branch=$3 target view state remainder head resolved_url current landed=0
  if [ -n "$pr_url" ]; then
    target=$pr_url
  else
    target=$(fm_landed_pr_number_from_branch "$wt" "$branch") || return 1
  fi
  [ -n "$target" ] || return 1
  view=$(cd "$wt" && gh pr view "$target" --json state,headRefOid,url -q '.state + "\t" + .headRefOid + "\t" + .url' 2>/dev/null) || return 1
  state=${view%%$'\t'*}
  remainder=${view#*$'\t'}
  [ "$state" != "$view" ] || return 1
  head=${remainder%%$'\t'*}
  resolved_url=${remainder#*$'\t'}
  [ "$head" != "$remainder" ] || return 1
  case "$state" in
    MERGED|merged) ;;
    *) return 1 ;;
  esac
  [ -n "$head" ] || return 1
  fm_landed_ensure_commit_object "$wt" "$target" "$head" || return 1
  current=$(git -C "$wt" rev-parse --verify HEAD 2>/dev/null) || return 1
  if git -C "$wt" merge-base --is-ancestor "$current" "$head" 2>/dev/null; then
    landed=1
  elif fm_landed_unpushed_patches_are_in_pr_head "$wt" "$head"; then
    landed=1
  fi
  [ "$landed" = 1 ] || return 1
  [ -n "$resolved_url" ] || return 1
  printf '%s\n' "$resolved_url"
}

# fm_landed_content_in_default <worktree> <repo>: true when the branch's content
# is already in the default tree (squash/rebase landing), without counting
# unrelated default-branch commits past the merge base.
fm_landed_content_in_default() {
  local wt=$1 repo=$2 name ref default_tree merged_tree
  name=$(fm_landed_default_branch "$repo") || return 1
  if git -C "$wt" remote get-url origin >/dev/null 2>&1; then
    git -C "$wt" fetch --quiet origin "+refs/heads/$name:refs/remotes/origin/$name" >/dev/null 2>&1 || return 1
    ref="refs/remotes/origin/$name"
  elif git -C "$wt" rev-parse --quiet --verify "refs/heads/$name" >/dev/null 2>&1; then
    ref="refs/heads/$name"
  else
    return 1
  fi
  default_tree=$(git -C "$wt" rev-parse --quiet --verify "$ref^{tree}" 2>/dev/null) || return 1
  [ -n "$default_tree" ] || return 1
  merged_tree=$(git -C "$wt" merge-tree --write-tree "$ref" HEAD 2>/dev/null) || return 1
  merged_tree=$(printf '%s\n' "$merged_tree" | head -1)
  [ "$merged_tree" = "$default_tree" ]
}

# fm_landed_work_is_landed <worktree> <pr-url-or-empty> <branch> <repo>: the
# single landed-work verdict shared with bin/fm-teardown.sh. True when a merged
# PR contains the current work OR the content is already in the default branch.
fm_landed_work_is_landed() {
  local wt=$1 pr_url=$2 branch=$3 repo=$4
  fm_landed_pr_is_merged "$wt" "$pr_url" "$branch" >/dev/null && return 0
  fm_landed_content_in_default "$wt" "$repo"
}

# --- landing-claim check ------------------------------------------------------

fm_landed_claim_words() {  # <summary>
  printf '%s' "${1-}" | grep -Eiq '(^|[^[:alnum:]_])(merged|landed|released)([^[:alnum:]_]|$)'
}

fm_landed_claim_sha() {  # <summary> -> the named commit, if any
  local summary=${1-} sha
  sha=$(printf '%s' "$summary" \
    | grep -Eio '(at|commit|sha|head|revision|merge commit)[^0-9a-f]{0,4}[0-9a-f]{7,40}' \
    | grep -Eo '[0-9a-f]{7,40}$' \
    | head -1)
  [ -n "$sha" ] || sha=$(printf '%s' "$summary" | grep -Eo '\b[0-9a-f]{40}\b' | head -1)
  printf '%s' "$sha"
}

fm_landed_claim_refuse() {
  printf 'REFUSED: %s\n' "$1" >&2
  return 3
}

# fm_landed_claim_check <summary> <authority> <worktree> <repo> <pr-url>:
# returns 0 when the summary makes no landing claim or makes one that a
# verifiable read supports. Returns 3 with an explicit refusal when it names a
# commit or PR identity that no readable record supports, or when the claim
# carries no authority at all. A broad claim that names neither is left to the
# outcome store's unverified marking.
fm_landed_claim_check() {
  local summary=${1-} authority=${2-} wt=${3-} repo=${4-} pr=${5-}
  local sha release=0 pr_ref=0 authority_shape=0 candidate found=0 auth_target=
  local spec target rev view state head merge_oid
  fm_landed_claim_words "$summary" || return 0
  if printf '%s' "$summary" | grep -Eiq 'released|release[[:space:]]+to'; then
    release=1
  fi
  sha=$(fm_landed_claim_sha "$summary")
  case "$summary" in
    *'#'[0-9]*|*'/pull/'*) pr_ref=1 ;;
  esac
  case "$authority" in
    pr:*) pr_ref=1 ;;
  esac

  if [ "$release" = 1 ]; then
    case "$authority" in
      path:*@*|target:*@*) ;;
      *)
        fm_landed_claim_refuse "summary asserts a release, but its authority read does not name the target home revision (expected path:<repo>@<rev> or target:<home>@<rev>); no landed record"
        return 3
        ;;
    esac
  fi

  if [ -z "$authority" ] || [ "$authority" = "unverified: no authority read supplied" ]; then
    if [ -n "$sha" ] || [ "$pr_ref" = 1 ]; then
      fm_landed_claim_refuse "summary asserts merged, landed, or released work at a named commit or PR identity, but carries no authority read; name the PR response, a path plus revision, or command output"
      return 3
    fi
    return 0
  fi

  case "$authority" in
    path:*@?*|file:*@?*|target:*@?*) authority_shape=1 ;;
    pr:?*) authority_shape=1 ;;
    api:?*) authority_shape=1 ;;
    command:?*) authority_shape=1 ;;
  esac
  case "$authority" in
    path:*@*|file:*@*|target:*@*) spec=${authority#*:}; auth_target=${spec%@*} ;;
  esac
  if [ "$authority_shape" = 0 ]; then
    if [ -n "$sha" ] || [ "$pr_ref" = 1 ]; then
      fm_landed_claim_refuse "authority read '$authority' is not a verifiable shape (expected path:<repo>@<rev>, target:<home>@<rev>, pr:<url>, api:<response>, file:<path>@<rev>, or command:<output>); no landed record"
      return 3
    fi
    return 0
  fi

  if [ -n "$sha" ]; then
    for candidate in "$wt" "$repo" "$auth_target" "$FM_HOME" "${FM_ROOT:-}"; do
      [ -n "$candidate" ] && [ -d "$candidate" ] || continue
      if git -C "$candidate" cat-file -e "$sha^{commit}" 2>/dev/null; then
        found=1
        break
      fi
    done
    if [ "$found" = 0 ] && [ -n "$pr" ] && [ -n "$wt" ]; then
      fm_landed_ensure_commit_object "$wt" "$pr" "$sha" && found=1
    fi
    if [ "$found" = 0 ]; then
      fm_landed_claim_refuse "summary asserts a landing at commit $sha, but that commit is absent from every repository this home can read; no landed record"
      return 3
    fi
  fi

  case "$authority" in
    path:*@*|file:*@*|target:*@*)
      spec=${authority#*:}
      target=${spec%@*}
      rev=${spec##*@}
      [ -n "$target" ] && [ -d "$target" ] \
        || { fm_landed_claim_refuse "authority target '$target' is not a readable repository; no landed record"; return 3; }
      git -C "$target" rev-parse --verify "$rev^{commit}" >/dev/null 2>&1 \
        || { fm_landed_claim_refuse "authority revision '$rev' does not exist in '$target'; no landed record"; return 3; }
      if [ -n "$sha" ]; then
        git -C "$target" merge-base --is-ancestor "$sha" "$rev" 2>/dev/null \
          || { fm_landed_claim_refuse "target revision '$rev' in '$target' does not contain the named commit $sha, so the target revision did not move to it; no landed record"; return 3; }
      fi
      ;;
    pr:*)
      target=${authority#pr:}
      [ -n "$target" ] || { fm_landed_claim_refuse "authority read names no pull request; no landed record"; return 3; }
      [ -n "$wt" ] && [ -d "$wt" ] \
        || { fm_landed_claim_refuse "no readable worktree is available to verify the named pull request; no landed record"; return 3; }
      view=$(cd "$wt" && gh pr view "$target" --json state,headRefOid,mergeCommit,url -q '.state + "\t" + .headRefOid + "\t" + ((.mergeCommit.oid) // "") + "\t" + .url' 2>/dev/null) \
        || { fm_landed_claim_refuse "the named pull request could not be read; no landed record"; return 3; }
      state=${view%%$'\t'*}
      view=${view#*$'\t'}
      head=${view%%$'\t'*}
      view=${view#*$'\t'}
      merge_oid=${view%%$'\t'*}
      case "$state" in
        MERGED|merged) ;;
        *) fm_landed_claim_refuse "the named pull request reports state '${state:-unknown}', not MERGED; no landed record"; return 3 ;;
      esac
      if [ -n "$sha" ]; then
        fm_landed_ensure_commit_object "$wt" "$target" "$sha" || true
        { [ -n "$head" ] && git -C "$wt" merge-base --is-ancestor "$sha" "$head" 2>/dev/null; } \
          || { [ -n "$merge_oid" ] && [ "$sha" = "$merge_oid" ]; } \
          || { fm_landed_claim_refuse "the named pull request is merged, but its head and merge commit do not contain the named commit $sha; no landed record"; return 3; }
      fi
      ;;
    command:*|api:*)
      if [ "$pr_ref" = 1 ] && [ -z "$sha" ]; then
        printf '%s' "$authority" | grep -Eiq 'merged|state[=:][[:space:]]*MERGED|merged=true' \
          || { fm_landed_claim_refuse "summary names a pull request, but its authority read does not carry a merged response; no landed record"; return 3; }
      fi
      ;;
  esac
  return 0
}
