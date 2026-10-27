#!/usr/bin/env bash
# Publish a committed addon snapshot without touching the working tree or index.
# Usage: scripts/publish-next.sh [remote=origin] [source=HEAD]
set -euo pipefail
remote="${1:-origin}"
source="${2:-HEAD}"
sha="$(git rev-parse --verify "$source^{commit}")"
branch=refs/heads/release-next
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export GIT_INDEX_FILE="$tmp/index"

# ls-remote failures must fail publication, not be mistaken for a new branch.
existing="$(git ls-remote --exit-code "$remote" "$branch")" || {
    result=$?
    if [[ $result != 2 ]]; then exit "$result"; fi
    existing=""
}
parent=""
if [[ -n "$existing" ]]; then
    git fetch --no-tags "$remote" "$branch"
    parent="$(git rev-parse FETCH_HEAD)"
fi

git read-tree "$sha:demo/addons/hego"
git show "$sha:README.md" | sed 's|demo/addons/hego/assets/|assets/|g' > "$tmp/README.md"
git show "$sha:LICENSE" > "$tmp/LICENSE"
printf '%s\n' "$sha" > "$tmp/SOURCE_COMMIT"
for file in README.md LICENSE SOURCE_COMMIT; do
    blob="$(git hash-object -w "$tmp/$file")"
    git update-index --add --cacheinfo "100644,$blob,$file"
done
tree="$(git write-tree)"
if [[ -n "$parent" && "$tree" == "$(git rev-parse "$parent^{tree}")" ]]; then
    echo "release-next already contains $sha"
    exit 0
fi
parents=()
if [[ -n "$parent" ]]; then parents=(-p "$parent"); fi
commit="$(printf 'Publish next addon\n\nSource-Commit: %s\n' "$sha" |
    git commit-tree "$tree" "${parents[@]}")"
# A concurrent update is rejected, never overwritten. Re-run to append to it.
git push "$remote" "$commit:$branch"
