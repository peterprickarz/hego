#ifndef STRATA_MESHER_H
#define STRATA_MESHER_H

#include <godot_cpp/classes/array_mesh.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/rect2.hpp>
#include <godot_cpp/variant/vector2.hpp>

namespace Strata {

// Geometry and quadtree selection only; callers own caching and height sampling.
class StrataMesher : public godot::RefCounted {
    GDCLASS(StrataMesher, godot::RefCounted)

public:
    enum StitchEdge { WEST = 1, EAST = 2, NORTH = 4, SOUTH = 8 };

    godot::Ref<godot::ArrayMesh> build_patch(int p_cells, double p_patch_size, int p_stitch_mask) const;
    // The budget is a complete-partition limit, never a truncation limit. If
    // requested detail or balancing exceeds it, retry with a smaller global
    // maximum depth until a balanced complete partition fits (root always fits).
    // Supports depths 0..12 and budgets 1..4096. Invalid inputs return empty.
    // Each descriptor also has integer lattice_origin/span/units. Reconstruct
    // normalized coordinates as origin/units + mesh UV * (span/units), then
    // apply the common root bounds. This avoids per-patch float roundoff seams.
    godot::Array select_patches(godot::Rect2 p_bounds, godot::Vector2 p_camera_position,
            double p_min_patch_size, double p_split_ratio = 2.0, int p_max_patches = 512) const;
    // Adds only descendants of the original balanced base leaves. Refinement
    // and its balancing use an additional-leaf budget, with total <= 4096.
    // A whole-circle target is retried at coarser levels if it cannot fit;
    // the original base plan is never coarsened to fund local detail.
    // effective_refinement_patch_size is the actual largest leaf intersecting
    // the circle (the guaranteed detail bound), or base finest size if outside.
    // Invalid input returns {}; radius/budget zero retain the complete base.
    godot::Dictionary select_refined_patches(godot::Rect2 p_bounds, godot::Vector2 p_camera_position,
            double p_min_patch_size, double p_split_ratio, int p_max_patches,
            double p_refinement_patch_size, double p_refinement_radius, int p_refinement_budget) const;

protected:
    static void _bind_methods();
};

} // namespace Strata

VARIANT_ENUM_CAST(Strata::StrataMesher::StitchEdge);

#endif
