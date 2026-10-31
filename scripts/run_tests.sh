#!/usr/bin/env bash
# Run the repository's test suites from one place.
#
#   scripts/run_tests.sh                 # Python suite + headless Godot tests + addon split + runtime suites
#   scripts/run_tests.sh --houdini       # also the tests that need a Houdini Engine licence (hython + HAPI)
#   scripts/run_tests.sh --gpu           # also the Forward+ tests, which need a real display
#   scripts/run_tests.sh --only python   # one group: python, godot, split, runtime, houdini, gpu
#   scripts/run_tests.sh --skip-import   # the demo project is already imported
#
# GODOT_BIN must be the real Godot 4.7.2 executable; a launcher that opens a terminal
# window never returns here. HFS points Houdini tests at the Houdini installation.
# Island tests that read demo/island/terrain are skipped when the checkout holds Git LFS
# pointers instead of the data (git lfs pull fetches it).
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/demo"
GODOT="${GODOT_BIN:-}"
HOUDINI=false
GPU=false
SKIP_IMPORT=false
ONLY=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --houdini) HOUDINI=true ;;
        --gpu) GPU=true ;;
        --skip-import) SKIP_IMPORT=true ;;
        --only) ONLY="$2"; shift ;;
        -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
        *) echo "unknown option $1" >&2; exit 2 ;;
    esac
    shift
done
if [[ -z "$GODOT" ]]; then
    for candidate in "$HOME/Godot/Godot_v4.7.2-stable_linux.x86_64" "$(command -v godot || true)"; do
        [[ -n "$candidate" && -x "$candidate" ]] && GODOT="$candidate" && break
    done
fi
[[ -n "$GODOT" && -x "$GODOT" ]] || { echo "error: set GODOT_BIN to the Godot 4.7.2 executable" >&2; exit 2; }

# Headless Godot tests that need neither Houdini nor a GPU. hego_standalone_test,
# terrain_cache_standalone_test and the runtime_* suites run in their own staged projects
# (addon split and runtime runners).
GODOT_TESTS=(
    brush_radius_test displacement_refinement_settings_test
    hego_asset_agent_test hego_await_task_test hego_extension_points_test hego_geo_output_test
    hego_graph_input_test hego_input_children_test hego_input_ui_test hego_log_test
    hego_mesh_copy_lod_test hego_mesh_output_test hego_output_skip_test hego_panel_async_test
    hego_panel_contract_test hego_point_util_test hego_terrain3d_bridge_test
    island_transition_test material_binding_test material_distribution_test
    material_preview_cutoff_test material_resource_test native_data_test
    procedural_transaction_test stage_material_persistence_test stage_material_transport_test
    terrain_bulk_test terrain_cell_mask_test terrain_material_soft_limit_test terrain_mesher_test terrain_refinement_test
    terrain_runtime_intent_test terrain_transport_lifetime_test
)
# These read the saved island under demo/island/terrain (Git LFS).
ISLAND_DATA_TESTS=(island_storage_test terrain_demo_scene_test)
# Real HAPI sessions; the editor test discovers the island HDAs through otls/ at Houdini
# startup, so HOUDINI_OTLSCAN_PATH and HOUDINI_PACKAGE_DIR must not be inherited.
HOUDINI_GODOT_TESTS=(
    editor_hda_package_test hego_graph_native_test hego_heightfield_fields_native_test
    hego_input_children_native_test hego_parameter_native_test hego_surface_preload_test
)
HYTHON_TESTS=(test_hda_package_graphs test_island_stage_materials test_material_distribution test_terrain_tint test_island_transition)
# Forward+ on a real display.
GPU_TESTS=(
    island_showcase_test material_preview_gpu_test render_material_test render_state_test terrain_height_blend_test
    terrain_shading_test terrain_normal_displacement_test terrain_triplanar_test terrain_appearance_test
)

LOG_DIR="${TEST_LOG_DIR:-$(mktemp -d /tmp/hego-tests.XXXXXX)}"
mkdir -p "$LOG_DIR"
PASSED=(); FAILED=(); SKIPPED=()

run_group() { [[ -z "$ONLY" || "$ONLY" == "$1" ]]; }

record() {
    local status="$1" name="$2"
    case "$status" in
        0) PASSED+=("$name"); printf '  PASS  %s\n' "$name" ;;
        skip) SKIPPED+=("$name"); printf '  SKIP  %s\n' "$name" ;;
        *) FAILED+=("$name"); printf '  FAIL  %s  (see %s/%s.log)\n' "$name" "$LOG_DIR" "$name" ;;
    esac
}

godot_test() {
    local name="$1" headless="$2"
    shift 2
    local args=("$GODOT" --path "$PROJECT")
    [[ "$headless" == true ]] && args+=(--headless) || args+=(--rendering-method forward_plus)
    timeout "${TEST_TIMEOUT:-600}" "${args[@]}" --script "res://tests/$name.gd" "$@" > "$LOG_DIR/$name.log" 2>&1
    record $? "$name"
}

island_data_present() {
    local sample="$PROJECT/island/terrain/rough_base.res"
    [[ -f "$sample" ]] && ! head -c 7 "$sample" | grep -q '^version'
}

if run_group python; then
    echo "── Python ──"
    (cd "$ROOT_DIR" && python3 -m unittest discover -s scripts/tests -q > "$LOG_DIR/python.log" 2>&1); record $? python
fi

if [[ "$SKIP_IMPORT" != true ]] && (run_group godot || run_group houdini || run_group gpu); then
    echo "── Import the demo project ──"
    # Godot 4.7 aborts while quitting a headless import that discovered its GDExtensions
    # during that same first scan (fresh checkout, CI). Pre-registering them as the editor
    # itself would avoids it.
    if [[ ! -f "$PROJECT/.godot/extension_list.cfg" ]]; then
        mkdir -p "$PROJECT/.godot"
        (cd "$PROJECT" && find addons -name '*.gdextension' | sort | sed 's|^|res://|') > "$PROJECT/.godot/extension_list.cfg"
    fi
    timeout 900 "$GODOT" --headless --editor --path "$PROJECT" --import --quit > "$LOG_DIR/import.log" 2>&1; record $? import
fi

if run_group godot; then
    echo "── Godot, headless ──"
    for name in "${GODOT_TESTS[@]}"; do godot_test "$name" true; done
    if island_data_present; then
        for name in "${ISLAND_DATA_TESTS[@]}"; do godot_test "$name" true; done
    else
        for name in "${ISLAND_DATA_TESTS[@]}"; do record skip "$name (island data is a Git LFS pointer)"; done
    fi
fi

if run_group split; then
    echo "── Addon split ──"
    python3 "$PROJECT/tests/addon_split_runner.py" --godot "$GODOT" > "$LOG_DIR/addon_split.log" 2>&1; record $? addon_split
fi

if run_group runtime; then
    echo "── Runtime suites ──"
    python3 "$PROJECT/tests/runtime_test_runner.py" --godot "$GODOT" > "$LOG_DIR/runtime_suites.log" 2>&1; record $? runtime_suites
fi

if [[ "$HOUDINI" == true ]] && run_group houdini; then
    echo "── Houdini ──"
    HFS_DIR="${HFS:-/opt/hfs22.0}"
    HYTHON="$HFS_DIR/bin/hython"
    [[ -x "$HYTHON" ]] || { echo "error: hython not found at $HYTHON; set HFS" >&2; exit 2; }
    for name in "${HOUDINI_GODOT_TESTS[@]}"; do
        ( unset HOUDINI_OTLSCAN_PATH HOUDINI_PACKAGE_DIR; godot_test "$name" true )
    done
    # Drives demo/tests/hego_named_pipe_session_test.gd against disposable HAPI servers.
    ( cd "$ROOT_DIR" && unset HOUDINI_OTLSCAN_PATH HOUDINI_PACKAGE_DIR && timeout 1800 "$HYTHON" scripts/test_named_pipe_sessions.py --godot "$GODOT" > "$LOG_DIR/hego_named_pipe_session_test.log" 2>&1 ); record $? hego_named_pipe_session_test
    for name in "${HYTHON_TESTS[@]}"; do
        ( cd "$ROOT_DIR" && unset HOUDINI_OTLSCAN_PATH && HOUDINI_PATH="$ROOT_DIR:&" timeout 1800 "$HYTHON" "scripts/houdini/$name.py" > "$LOG_DIR/$name.log" 2>&1 ); record $? "$name"
    done
    ( cd "$ROOT_DIR" && unset HOUDINI_OTLSCAN_PATH && timeout 1800 "$HYTHON" scripts/houdini/test_material_inheritance.py --erosion-hda otls/HEGo_IslandErosion.hda --material-hda otls/HEGo_MaterialDistribution.hda --out-dir "$LOG_DIR/inheritance" > "$LOG_DIR/test_material_inheritance.log" 2>&1 ); record $? test_material_inheritance
    ( cd "$ROOT_DIR" && unset HOUDINI_OTLSCAN_PATH && timeout 1800 "$HYTHON" scripts/houdini/test_material_weight_limit.py --hda otls/util_MaterialWeightLimit.hda --out-dir "$LOG_DIR/weight-limit" > "$LOG_DIR/test_material_weight_limit.log" 2>&1 ); record $? test_material_weight_limit
fi

if [[ "$GPU" == true ]] && run_group gpu; then
    echo "── Forward+ (display) ──"
    for name in "${GPU_TESTS[@]}"; do godot_test "$name" false; done
fi

echo
echo "passed ${#PASSED[@]}, failed ${#FAILED[@]}, skipped ${#SKIPPED[@]}; logs in $LOG_DIR"
[[ ${#FAILED[@]} -eq 0 ]]
