#!/usr/bin/env bash
# Stage or publish matched addon packages from one committed source revision.
# Usage: scripts/publish-next.sh [remote=origin] [source=HEAD] [--dry-run]
set -euo pipefail
remote="${1:-origin}"
source="${2:-HEAD}"
dry_run="${3:-}"
if [[ "$dry_run" != "" && "$dry_run" != "--dry-run" ]]; then
    echo "usage: $0 [remote=origin] [source=HEAD] [--dry-run]" >&2
    exit 2
fi
sha="$(git rev-parse --verify "$source^{commit}")"
root="$(git rev-parse --show-toplevel)"
manifest_tool="$root/scripts/native_build_manifest.py"
for addon in hego strata; do
    python3 "$manifest_tool" validate --addon "$addon" --ref "$sha"
done

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export GIT_INDEX_FILE="$tmp/index"

add_file() {
    local name="$1" content="$2" blob
    printf '%s' "$content" > "$tmp/$name"
    blob="$(git hash-object -w "$tmp/$name")"
    git update-index --add --cacheinfo "100644,$blob,$name"
}

REFSPECS=()

package_tree() {
    local kind="$1" readme="$2" package_json="$3"
    # Runs inside a command substitution, which Bash starts without errexit: re-enable it
    # so an addon missing from the source revision stops the publish instead of shipping
    # a package with only the generated files in it.
    set -e
    git read-tree --empty
    case "$kind" in
        hego) git read-tree "$sha:demo/addons/hego" ;;
        strata) git read-tree "$sha:demo/addons/strata" ;;
        bridge) git read-tree "$sha:demo/addons/hego_strata" ;;
        terrain3d) git read-tree "$sha:demo/addons/hego_terrain3d" ;;
        bundle)
            git read-tree --prefix=hego/ "$sha:demo/addons/hego"
            git read-tree --prefix=strata/ "$sha:demo/addons/strata"
            git read-tree --prefix=hego_strata/ "$sha:demo/addons/hego_strata"
            git read-tree --prefix=hego_terrain3d/ "$sha:demo/addons/hego_terrain3d"
            ;;
    esac
    # The generated header carries the source revision; the addon's own README, when
    # it has one, follows it so the package documents itself.
    local addon_readme=""
    case "$kind" in
        hego) addon_readme="$(git show "$sha:demo/addons/hego/README.md" 2>/dev/null || true)" ;;
        strata) addon_readme="$(git show "$sha:demo/addons/strata/README.md" 2>/dev/null || true)" ;;
        bridge) addon_readme="$(git show "$sha:demo/addons/hego_strata/README.md" 2>/dev/null || true)" ;;
        terrain3d) addon_readme="$(git show "$sha:demo/addons/hego_terrain3d/README.md" 2>/dev/null || true)" ;;
    esac
    if [[ -n "$addon_readme" ]]; then
        readme="$readme"$'\n\n'"$addon_readme"
    fi
    add_file README.md "$readme"
    add_file LICENSE "$(git show "$sha:LICENSE")"
    add_file SOURCE_COMMIT "$sha"$'\n'
    add_file PACKAGE.json "$package_json"
    git write-tree
}

publish_tree() {
    local branch="$1" tree="$2" existing parent commit
    local ref="refs/heads/$branch"
    if [[ "$dry_run" == "--dry-run" ]]; then
        echo "DRY RUN $branch tree=$tree"
        return 0
    fi
    existing="$(git ls-remote --exit-code "$remote" "$ref")" || {
        result=$?
        if [[ $result != 2 ]]; then return "$result"; fi
        existing=""
    }
    parent=""
    if [[ -n "$existing" ]]; then
        git fetch --no-tags "$remote" "$ref" >/dev/null
        parent="$(git rev-parse FETCH_HEAD)"
        if [[ "$tree" == "$(git rev-parse "$parent^{tree}")" ]]; then
            echo "$branch already contains $sha"
            return 0
        fi
    fi
    local -a parents=()
    if [[ -n "$parent" ]]; then parents=(-p "$parent"); fi
    commit="$(printf 'Publish %s package\n\nSource-Commit: %s\n' "$branch" "$sha" | git commit-tree "$tree" "${parents[@]}")"
    # A concurrent update is rejected, never overwritten. Push the matched set atomically.
    REFSPECS+=("$commit:$ref")
}

# Dependencies point one way: HEGo and Strata each stand alone, the Strata bridge
# requires both at the same source revision, and the Terrain3D bridge requires HEGo at
# that revision plus Terrain3D itself, which is not ours to publish.
hego_json="$(printf '{\n  "format_version": 1,\n  "package": "hego",\n  "addon_path": "addons/hego",\n  "source_commit": "%s",\n  "requires": []\n}\n' "$sha")"
strata_json="$(printf '{\n  "format_version": 1,\n  "package": "strata",\n  "addon_path": "addons/strata",\n  "source_commit": "%s",\n  "requires": [],\n  "build_requires": ["godot-cpp submodule"],\n  "requires_hego": false,\n  "requires_houdini_sdk_for_build": false\n}\n' "$sha")"
bridge_json="$(printf '{\n  "format_version": 1,\n  "package": "hego-strata",\n  "addon_path": "addons/hego_strata",\n  "source_commit": "%s",\n  "requires": [{"package": "hego", "branch": "release-next", "addon_path": "addons/hego", "source_commit": "%s"}, {"package": "strata", "branch": "strata-release-next", "addon_path": "addons/strata", "source_commit": "%s"}]\n}\n' "$sha" "$sha" "$sha")"
terrain3d_json="$(printf '{\n  "format_version": 1,\n  "package": "hego-terrain3d",\n  "addon_path": "addons/hego_terrain3d",\n  "source_commit": "%s",\n  "requires": [{"package": "hego", "branch": "release-next", "addon_path": "addons/hego", "source_commit": "%s"}],\n  "external_requires": [{"name": "Terrain3D", "author": "TokisanGames", "url": "https://github.com/TokisanGames/Terrain3D", "addon_path": "addons/terrain_3d", "tested_version": "1.0.1", "installed_by": "user"}]\n}\n' "$sha" "$sha")"
bundle_json="$(printf '{\n  "format_version": 1,\n  "package": "hego-strata-bundle",\n  "source_commit": "%s",\n  "addons": {"hego": "hego", "strata": "strata", "hego-strata": "hego_strata", "hego-terrain3d": "hego_terrain3d"},\n  "requires": [],\n  "external_requires": [{"name": "Terrain3D", "author": "TokisanGames", "url": "https://github.com/TokisanGames/Terrain3D", "addon_path": "addons/terrain_3d", "tested_version": "1.0.1", "installed_by": "user", "needed_by": ["hego-terrain3d"]}]\n}\n' "$sha")"
hego_readme="$(cat <<EOF
# HEGo addon package

This package is built from source commit $sha. It has no package dependencies.
To cook HDAs into Strata layers, also install the Strata package and
the HEGo Strata package from the same source revision; for Terrain3D, install
the HEGo Terrain3D package from the same revision and Terrain3D itself. Native
binaries are accepted only when their build receipts match this source revision.
EOF
)"
bridge_readme="$(cat <<EOF
# HEGo Strata package

This package is built from source commit $sha. It cooks Houdini Digital Assets
into Strata layers and requires both other packages from the same source
revision: HEGo at \`addons/hego\` and Strata at \`addons/strata\`.
See \`PACKAGE.json\` for their branches. It contains no native code.
EOF
)"
terrain3d_readme="$(cat <<EOF
# HEGo Terrain3D package

This package is built from source commit $sha. It sends Terrain3D nodes to HDAs
as heightfield inputs and turns cooked heightfields and points into Terrain3D
terrains and instances. It requires HEGo from the same source revision at
\`addons/hego\`, and the Terrain3D addon by TokisanGames (tested with 1.0.1),
which you install yourself at \`addons/terrain_3d\`. See \`PACKAGE.json\` for
both. It contains no native code.
EOF
)"
strata_readme="$(cat <<EOF
# Strata addon package

This standalone package is built from source commit $sha. It depends on Godot
and godot-cpp, but does not require HEGo or Houdini. See \`PACKAGE.json\` for
the package dependency declaration and \`native-build.json\` for binary receipts.
EOF
)"
bundle_readme="$(cat <<EOF
# HEGo + Strata addon bundle

This bundle contains HEGo, Strata, the HEGo Strata bridge and the HEGo Terrain3D
bridge, all from source commit $sha. Copy its four directories into a Godot
project's \`addons/\` directory. HEGo Terrain3D also needs the Terrain3D addon
by TokisanGames (tested with 1.0.1) at \`addons/terrain_3d\`, which this bundle
does not include; leave \`hego_terrain3d/\` out if you do not use Terrain3D.
HEGo and Strata binaries have matching native build receipts; see each addon's
\`native-build.json\`.
EOF
)"

hego_tree="$(package_tree hego "$hego_readme" "$hego_json")"
strata_tree="$(package_tree strata "$strata_readme" "$strata_json")"
bridge_tree="$(package_tree bridge "$bridge_readme" "$bridge_json")"
terrain3d_tree="$(package_tree terrain3d "$terrain3d_readme" "$terrain3d_json")"
bundle_tree="$(package_tree bundle "$bundle_readme" "$bundle_json")"
publish_tree release-next "$hego_tree"
publish_tree strata-release-next "$strata_tree"
publish_tree hego-strata-release-next "$bridge_tree"
publish_tree hego-terrain3d-release-next "$terrain3d_tree"
publish_tree release-next-bundle "$bundle_tree"
if [[ "$dry_run" != "--dry-run" && ${#REFSPECS[@]} -gt 0 ]]; then
    git push --atomic "$remote" "${REFSPECS[@]}"
fi
