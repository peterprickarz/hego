#include "terrain_mesher.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/error_macros.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>
#include <map>
#include <set>

using namespace godot;

namespace Strata {
namespace {

constexpr int MAX_DEPTH = 12;
constexpr int MAX_BUDGET = 4096;

struct Patch {
    int x;
    int z;
    int span;
    int level;
};

using Patches = std::map<uint64_t, Patch>;

uint64_t patch_key(const Patch &p_patch) {
    return (uint64_t(p_patch.level) << 24) | (uint64_t(p_patch.z / p_patch.span) << 12) | uint64_t(p_patch.x / p_patch.span);
}

const Patch *find_patch(const Patches &p_patches, int p_x, int p_z, int p_units, int p_depth) {
    if (p_x < 0 || p_z < 0 || p_x >= p_units || p_z >= p_units) {
        return nullptr;
    }
    // At most thirteen lookups; callers stop at the coarsest level that can
    // influence balancing/stitching instead of probing equal/finer leaves.
    for (int level = 0; level <= p_depth; ++level) {
        const int span = p_units >> level;
        const uint64_t key = (uint64_t(level) << 24) | (uint64_t(p_z / span) << 12) | uint64_t(p_x / span);
        const auto found = p_patches.find(key);
        if (found != p_patches.end()) return &found->second;
    }
    return nullptr;
}

void neighbor_points(const Patch &p_patch, int (&r_x)[4], int (&r_z)[4]) {
    const int mid_x = p_patch.x + p_patch.span / 2;
    const int mid_z = p_patch.z + p_patch.span / 2;
    r_x[0] = p_patch.x - 1; r_z[0] = mid_z;
    r_x[1] = p_patch.x + p_patch.span; r_z[1] = mid_z;
    r_x[2] = mid_x; r_z[2] = p_patch.z - 1;
    r_x[3] = mid_x; r_z[3] = p_patch.z + p_patch.span;
}

void split_patch(Patches &r_patches, const Patch &p_patch) {
    r_patches.erase(patch_key(p_patch));
    const int half = p_patch.span / 2;
    for (int dz = 0; dz < 2; ++dz) {
        for (int dx = 0; dx < 2; ++dx) {
            const Patch child{p_patch.x + dx * half, p_patch.z + dz * half, half, p_patch.level + 1};
            r_patches.emplace(patch_key(child), child);
        }
    }
}

struct Selection {
    Rect2 bounds;
    Vector2 camera;
    double split_ratio;
    int units;
    int depth;
    int budget;
    int planned_leaves = 1;
    Patches leaves;

    bool request(const Patch &p_patch) {
        const double unit = static_cast<double>(bounds.size.x) / units;
        const double left = static_cast<double>(bounds.position.x) + p_patch.x * unit;
        const double north = static_cast<double>(bounds.position.y) + p_patch.z * unit;
        const double size = p_patch.span * unit;
        const double dx = std::max({left - camera.x, static_cast<double>(camera.x) - (left + size), 0.0});
        const double dz = std::max({north - camera.y, static_cast<double>(camera.y) - (north + size), 0.0});
        if (p_patch.level < depth && std::hypot(dx, dz) < size * split_ratio) {
            if (planned_leaves + 3 > budget) {
                return false;
            }
            planned_leaves += 3;
            const int half = p_patch.span / 2;
            for (int z = 0; z < 2; ++z) {
                for (int x = 0; x < 2; ++x) {
                    if (!request({p_patch.x + x * half, p_patch.z + z * half, half, p_patch.level + 1})) {
                        return false;
                    }
                }
            }
        } else {
            leaves.emplace(patch_key(p_patch), p_patch);
        }
        return true;
    }

    bool balance() {
        for (;;) {
            std::set<uint64_t> to_split;
            for (const auto &entry : leaves) {
                int nx[4], nz[4];
                neighbor_points(entry.second, nx, nz);
                for (int edge = 0; edge < 4; ++edge) {
                    const Patch *neighbor = find_patch(leaves, nx[edge], nz[edge], units, entry.second.level - 2);
                    if (neighbor && neighbor->span > entry.second.span * 2) {
                        to_split.insert(patch_key(*neighbor));
                    }
                }
            }
            if (to_split.empty()) {
                return true;
            }
            if (leaves.size() + to_split.size() * 3 > static_cast<size_t>(budget)) {
                return false;
            }
            for (uint64_t key : to_split) {
                // Copy before erasing the map entry that owns the reference.
                const Patch patch = leaves.at(key);
                split_patch(leaves, patch);
            }
        }
    }
};

bool lattice_depth(Rect2 bounds, double minimum, int &depth) {
    const double ratio = static_cast<double>(bounds.size.x) / minimum;
    ERR_FAIL_COND_V_MSG(!std::isfinite(ratio) || ratio < 1.0 - 0.000001 || ratio > (1 << MAX_DEPTH) * (1.0 + 0.000001), false, "Terrain root/minimum size ratio must be a power of two with depth at most twelve.");
    depth = static_cast<int>(std::round(std::log2(ratio)));
    ERR_FAIL_COND_V_MSG(std::abs(ratio - std::ldexp(1.0, depth)) > std::ldexp(1.0, depth) * 0.000001, false, "Terrain root/minimum size ratio must be a power of two.");
    return true;
}

bool precise_lattice(Rect2 bounds, int units) {
    const double unit = static_cast<double>(bounds.size.x) / units;
    for (int axis = 0; axis < 2; ++axis) {
        const double origin = axis == 0 ? bounds.position.x : bounds.position.y;
        real_t previous = static_cast<real_t>(origin);
        for (int i = 1; i <= units; ++i) {
            const real_t coordinate = static_cast<real_t>(origin + i * unit);
            ERR_FAIL_COND_V_MSG(coordinate <= previous, false, "Terrain minimum patch boundaries exceed Vector2 coordinate precision at this origin.");
            previous = coordinate;
        }
    }
    return true;
}

bool base_plan(Rect2 bounds, Vector2 camera, double minimum, double split_ratio, int budget, Patches &leaves, int &depth) {
    ERR_FAIL_COND_V_MSG(!std::isfinite(bounds.position.x) || !std::isfinite(bounds.position.y) || !std::isfinite(bounds.size.x) || !std::isfinite(bounds.size.y) || bounds.size.x <= 0 || bounds.size.x != bounds.size.y, false, "Terrain patch bounds must be a finite positive square.");
    ERR_FAIL_COND_V_MSG(!std::isfinite(camera.x) || !std::isfinite(camera.y) || !std::isfinite(minimum) || minimum <= 0 || !std::isfinite(split_ratio) || split_ratio <= 0, false, "Terrain patch camera, minimum size and split ratio must be finite; sizes and ratio must be positive.");
    ERR_FAIL_COND_V_MSG(budget < 1 || budget > MAX_BUDGET, false, "Terrain patch budget must be from 1 through 4096.");
    if (!lattice_depth(bounds, minimum, depth)) return false;
    const double max_coordinate = std::numeric_limits<real_t>::max();
    ERR_FAIL_COND_V_MSG(std::abs(static_cast<double>(bounds.position.x) + bounds.size.x) > max_coordinate || std::abs(static_cast<double>(bounds.position.y) + bounds.size.y) > max_coordinate, false, "Terrain patch bounds exceed Vector2 coordinate range.");
    const int units = 1 << depth;
    if (!precise_lattice(bounds, units)) return false;
    for (int maximum = depth; maximum >= 0; --maximum) {
        Selection selection{bounds, camera, split_ratio, units, maximum, budget, 1, {}};
        if (selection.request({0, 0, units, 0}) && selection.balance()) {
            leaves = std::move(selection.leaves);
            return true;
        }
    }
    return false;
}

Array describe_patches(Rect2 bounds, const Patches &leaves, int units) {
    Array result;
    const double unit = static_cast<double>(bounds.size.x) / units;
    // Per-call Godot key lifetimes remain inside GDExtension lifetime.
    const Variant origin_key("origin"), size_key("size"), level_key("level"), stitch_key("stitch_mask");
    const Variant lattice_origin_key("lattice_origin"), lattice_span_key("lattice_span"), lattice_units_key("lattice_units");
    for (const auto &entry : leaves) {
        const Patch &patch = entry.second;
        int nx[4], nz[4];
        neighbor_points(patch, nx, nz);
        int mask = 0;
        for (int edge = 0; edge < 4; ++edge) {
            const Patch *neighbor = find_patch(leaves, nx[edge], nz[edge], units, patch.level - 1);
            if (neighbor && neighbor->span > patch.span) mask |= 1 << edge;
        }
        Dictionary descriptor;
        descriptor[origin_key] = Vector2(static_cast<double>(bounds.position.x) + patch.x * unit, static_cast<double>(bounds.position.y) + patch.z * unit);
        descriptor[size_key] = patch.span * unit;
        descriptor[level_key] = patch.level;
        descriptor[stitch_key] = mask;
        descriptor[lattice_origin_key] = Vector2i(patch.x, patch.z);
        descriptor[lattice_span_key] = patch.span;
        descriptor[lattice_units_key] = units;
        result.push_back(descriptor);
    }
    return result;
}

bool intersects_circle(const Patch &patch, Rect2 bounds, Vector2 camera, int units, double radius) {
    const double unit = static_cast<double>(bounds.size.x) / units;
    const double x = static_cast<double>(bounds.position.x) + patch.x * unit;
    const double z = static_cast<double>(bounds.position.y) + patch.z * unit;
    const double size = patch.span * unit;
    const double dx = std::max({x - camera.x, static_cast<double>(camera.x) - (x + size), 0.0});
    const double dz = std::max({z - camera.y, static_cast<double>(camera.y) - (z + size), 0.0});
    return std::hypot(dx, dz) <= radius;
}

bool request_refinement(Selection &selection, const Patch &patch, double radius) {
    if (patch.level < selection.depth && intersects_circle(patch, selection.bounds, selection.camera, selection.units, radius)) {
        if (selection.planned_leaves + 3 > selection.budget) return false;
        selection.planned_leaves += 3;
        const int half = patch.span / 2;
        for (int z = 0; z < 2; ++z) for (int x = 0; x < 2; ++x) {
            if (!request_refinement(selection, {patch.x + x * half, patch.z + z * half, half, patch.level + 1}, radius)) return false;
        }
    } else {
        selection.leaves.emplace(patch_key(patch), patch);
    }
    return true;
}

double effective_size(const Patches &leaves, Rect2 bounds, Vector2 camera, int units, double radius) {
    int largest = 0, smallest = units;
    for (const auto &entry : leaves) {
        smallest = std::min(smallest, entry.second.span);
        if (intersects_circle(entry.second, bounds, camera, units, radius)) largest = std::max(largest, entry.second.span);
    }
    return static_cast<double>(bounds.size.x) * (largest ? largest : smallest) / units;
}

Dictionary refinement_result(Rect2 bounds, Vector2 camera, const Patches &leaves, int units, int base_count, bool limited, double radius) {
    Dictionary result;
    result["patches"] = describe_patches(bounds, leaves, units);
    result["base_patch_count"] = base_count;
    result["refinement_patch_count"] = static_cast<int>(leaves.size()) - base_count;
    result["refinement_limited"] = limited;
    result["effective_refinement_patch_size"] = effective_size(leaves, bounds, camera, units, radius);
    return result;
}

} // namespace

void StrataMesher::_bind_methods() {
    ClassDB::bind_method(D_METHOD("build_patch", "cells", "patch_size", "stitch_mask"), &StrataMesher::build_patch);
    ClassDB::bind_method(D_METHOD("select_patches", "bounds", "camera_position", "min_patch_size", "split_ratio", "max_patches"), &StrataMesher::select_patches, DEFVAL(2.0), DEFVAL(512));
    ClassDB::bind_method(D_METHOD("select_refined_patches", "bounds", "camera_position", "min_patch_size", "split_ratio", "max_patches", "refinement_patch_size", "refinement_radius", "refinement_budget"), &StrataMesher::select_refined_patches);
    BIND_ENUM_CONSTANT(WEST);
    BIND_ENUM_CONSTANT(EAST);
    BIND_ENUM_CONSTANT(NORTH);
    BIND_ENUM_CONSTANT(SOUTH);
}

Ref<ArrayMesh> StrataMesher::build_patch(int p_cells, double p_patch_size, int p_stitch_mask) const {
    ERR_FAIL_COND_V_MSG(p_cells < 2 || p_cells > 128 || (p_cells & (p_cells - 1)) != 0, Ref<ArrayMesh>(), "Terrain patch cells must be a power of two from 2 through 128.");
    ERR_FAIL_COND_V_MSG(!std::isfinite(p_patch_size) || p_patch_size <= 0.0 || p_patch_size > std::numeric_limits<real_t>::max(), Ref<ArrayMesh>(), "Terrain patch size must be finite, positive and representable by Vector3.");
    ERR_FAIL_COND_V_MSG(p_stitch_mask < 0 || p_stitch_mask > 15, Ref<ArrayMesh>(), "Terrain patch stitch mask must use only the four edge bits.");
    const int stride = p_cells + 1;
    const int vertex_count = stride * stride;
    PackedVector3Array vertices;
    PackedVector3Array normals;
    PackedVector2Array uvs;
    PackedInt32Array indices;
    vertices.resize(vertex_count);
    normals.resize(vertex_count);
    uvs.resize(vertex_count);
    real_t previous = -1;
    for (int x = 0; x <= p_cells; ++x) {
        const real_t coordinate = static_cast<real_t>(p_patch_size * x / p_cells);
        ERR_FAIL_COND_V_MSG(x > 0 && coordinate <= previous, Ref<ArrayMesh>(), "Terrain patch cells exceed Vector3 coordinate precision.");
        previous = coordinate;
    }
    for (int z = 0; z <= p_cells; ++z) {
        for (int x = 0; x <= p_cells; ++x) {
            const int index = z * stride + x;
            vertices.set(index, Vector3(p_patch_size * x / p_cells, 0, p_patch_size * z / p_cells));
            normals.set(index, Vector3(0, 1, 0));
            uvs.set(index, Vector2(static_cast<real_t>(x) / p_cells, static_cast<real_t>(z) / p_cells));
        }
    }
    const auto remap = [p_cells, p_stitch_mask, stride](int x, int z) {
        if ((x == 0 && (p_stitch_mask & WEST)) || (x == p_cells && (p_stitch_mask & EAST))) {
            z -= z % 2;
        }
        if ((z == 0 && (p_stitch_mask & NORTH)) || (z == p_cells && (p_stitch_mask & SOUTH))) {
            x -= x % 2;
        }
        return z * stride + x;
    };
    const auto triangle = [&indices, stride](int a, int b, int c) {
        // Integer area also catches three distinct but collinear vertices.
        const int ax = a % stride, az = a / stride;
        const int bx = b % stride, bz = b / stride;
        const int cx = c % stride, cz = c / stride;
        if ((bx - ax) * (cz - az) - (bz - az) * (cx - ax) > 0) {
            indices.push_back(a);
            indices.push_back(b);
            indices.push_back(c);
        }
    };
    for (int z = 0; z < p_cells; ++z) {
        for (int x = 0; x < p_cells; ++x) {
            const int a = remap(x, z), b = remap(x + 1, z);
            const int c = remap(x, z + 1), d = remap(x + 1, z + 1);
            if (x == p_cells - 1 && z == p_cells - 1 && (p_stitch_mask & (EAST | SOUTH)) == (EAST | SOUTH)) {
                // Odd-to-previous remaps on these two edges place a on b--c.
                // Splitting b,d,c through a removes the internal T-junction;
                // merely dropping collinear a,b,c would crack after displacement.
                triangle(a, b, d);
                triangle(a, d, c);
            } else {
                triangle(a, b, c);
                triangle(b, d, c);
            }
        }
    }
    Array arrays;
    arrays.resize(Mesh::ARRAY_MAX);
    arrays[Mesh::ARRAY_VERTEX] = vertices;
    arrays[Mesh::ARRAY_NORMAL] = normals;
    arrays[Mesh::ARRAY_TEX_UV] = uvs;
    arrays[Mesh::ARRAY_INDEX] = indices;
    Ref<ArrayMesh> mesh;
    mesh.instantiate();
    mesh->add_surface_from_arrays(Mesh::PRIMITIVE_TRIANGLES, arrays);
    return mesh;
}

Array StrataMesher::select_patches(Rect2 p_bounds, Vector2 p_camera_position, double p_min_patch_size, double p_split_ratio, int p_max_patches) const {
    Patches leaves;
    int depth;
    if (!base_plan(p_bounds, p_camera_position, p_min_patch_size, p_split_ratio, p_max_patches, leaves, depth)) return Array();
    return describe_patches(p_bounds, leaves, 1 << depth);
}

Dictionary StrataMesher::select_refined_patches(Rect2 p_bounds, Vector2 p_camera_position,
        double p_min_patch_size, double p_split_ratio, int p_max_patches,
        double p_refinement_patch_size, double p_refinement_radius, int p_refinement_budget) const {
    Dictionary empty;
    ERR_FAIL_COND_V_MSG(!std::isfinite(p_refinement_patch_size) || p_refinement_patch_size <= 0 || !std::isfinite(p_refinement_radius) || p_refinement_radius < 0, empty, "Terrain refinement size must be finite and positive; radius must be finite and nonnegative.");
    ERR_FAIL_COND_V_MSG(p_refinement_budget < 0 || p_refinement_budget > MAX_BUDGET, empty, "Terrain additional refinement budget must be from 0 through 4096.");
    Patches base;
    int base_depth;
    if (!base_plan(p_bounds, p_camera_position, p_min_patch_size, p_split_ratio, p_max_patches, base, base_depth)) return empty;
    int requested_depth = 0;
    if (p_refinement_patch_size < p_bounds.size.x && !lattice_depth(p_bounds, p_refinement_patch_size, requested_depth)) return empty;
    const int base_units = 1 << base_depth;
    bool needed = false;
    if (p_refinement_radius > 0) {
        for (const auto &entry : base) {
            if (entry.second.level < requested_depth && intersects_circle(entry.second, p_bounds, p_camera_position, base_units, p_refinement_radius)) {
                needed = true;
                break;
            }
        }
    }
    const int base_count = static_cast<int>(base.size());
    if (!needed || p_refinement_budget == 0 || base_count == MAX_BUDGET) {
        return refinement_result(p_bounds, p_camera_position, base, base_units, base_count, needed, p_refinement_radius);
    }
    const int depth = std::max(base_depth, requested_depth);
    const int units = 1 << depth;
    if (!precise_lattice(p_bounds, units)) return empty;
    const int multiplier = units / base_units;
    Patches extended_base;
    for (const auto &entry : base) {
        const Patch &p = entry.second;
        extended_base.emplace(entry.first, Patch{p.x * multiplier, p.z * multiplier, p.span * multiplier, p.level});
    }
    const int total_budget = std::min(MAX_BUDGET, base_count + p_refinement_budget);
    for (int target = requested_depth; target >= 0; --target) {
        Selection selection{p_bounds, p_camera_position, p_split_ratio, units, target, total_budget, base_count, {}};
        bool complete = true;
        for (const auto &entry : extended_base) {
            if (!request_refinement(selection, entry.second, p_refinement_radius)) {
                complete = false;
                break;
            }
        }
        if (!complete || !selection.balance()) continue;
        // Preserve byte-equivalent old descriptors when no splits survived.
        if (selection.leaves.size() == base.size()) {
            return refinement_result(p_bounds, p_camera_position, base, base_units, base_count, true, p_refinement_radius);
        }
        return refinement_result(p_bounds, p_camera_position, selection.leaves, units, base_count, target < requested_depth, p_refinement_radius);
    }
    return refinement_result(p_bounds, p_camera_position, base, base_units, base_count, true, p_refinement_radius);
}

} // namespace Strata
