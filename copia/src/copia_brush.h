#ifndef COPIA_BRUSH_H
#define COPIA_BRUSH_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/aabb.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <cstdint>
#include <string>
#include <unordered_map>
#include <vector>

namespace Copia {

// Fast editor-side spatial index, brush sampler, ray-OBB picker and sphere eraser query helper.
// Holds no Godot nodes and loads no resources; operates purely on store-local transforms and
// plain dictionaries so interactive painting and viewport picking run in microseconds.
class CopiaBrush : public godot::RefCounted {
    GDCLASS(CopiaBrush, godot::RefCounted)

public:
    void clear();
    void set_bucket_size(double p_size);
    double get_bucket_size() const;
    int64_t get_point_count() const;

    // Loads points returned by CopiaSets.read_points() / CopiaStore3D.read_points().
    // p_editable marks authored sets that can be picked/erased; false marks read-only avoidance sets.
    // p_object_radii maps object_path -> min_spacing radius (float, metres) for avoidance checks.
    int64_t load_points(const godot::Dictionary &p_points, bool p_editable = true,
            const godot::Dictionary &p_object_radii = godot::Dictionary());

    // Adds newly painted uncommitted stroke points into the spatial hash so subsequent dabs
    // respect minimum spacing against them.
    int64_t add_staging_points(const godot::Dictionary &p_points, const godot::String &p_set,
            const godot::Dictionary &p_object_radii = godot::Dictionary());

    // Filters surface ray hits, enforces spatial-hash minimum spacing, applies slope & radial
    // species falloff weights, and generates ready-to-stage Copia point columns.
    godot::Dictionary sample_dab(const godot::Dictionary &p_hits, const godot::Array &p_specs,
            const godot::Dictionary &p_options);

    // Ray-vs-OBB pick against all editable, non-erased points. Works without physics colliders.
    // p_object_aabbs maps object_path -> local AABB of the object's mesh.
    godot::Dictionary pick_ray(const godot::Vector3 &p_origin, const godot::Vector3 &p_dir,
            double p_max_distance, const godot::Dictionary &p_object_aabbs,
            const godot::PackedStringArray &p_set_filter = godot::PackedStringArray()) const;

    // Queries editable, non-erased points within p_radius of p_center (optionally matching
    // p_object_filter). When p_mark_erased is true, marks matched points erased in-memory so
    // subsequent erase dabs in the same stroke skip them.
    godot::Dictionary query_sphere(const godot::Vector3 &p_center, double p_radius,
            const godot::PackedStringArray &p_object_filter = godot::PackedStringArray(),
            bool p_mark_erased = false);

protected:
    static void _bind_methods();

private:
    struct Entry {
        std::string set_name;
        std::string object_path;
        float transform[12]{}; // basis x, y, z, origin (store local)
        float color[4]{};
        float custom[4]{};
        float keep = 1.0f;
        float radius = 0.0f;
        bool has_color = false;
        bool has_custom = false;
        bool editable = false;
        bool staging = false;
        bool erased = false;
    };

    double bucket_size = 4.0;
    double max_entry_radius = 0.0;
    std::vector<Entry> entries;
    std::unordered_map<uint64_t, std::vector<int32_t>> grid;

    static uint64_t bucket_key(int32_t p_bx, int32_t p_bz);
    int32_t bucket_coord(double p_v) const;
    void insert_entry(Entry &&p_entry);
    bool is_occupied(const godot::Vector3 &p_pos, double p_min_spacing, bool p_check_avoidance) const;
};

} // namespace Copia

#endif // COPIA_BRUSH_H
