#ifndef COPIA_DRAWER_H
#define COPIA_DRAWER_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/aabb.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/rid.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/typed_array.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <array>
#include <cstdint>
#include <deque>
#include <set>
#include <unordered_map>
#include <utility>
#include <vector>

namespace Copia {

// Creates and frees the RenderingServer objects of built-cell sections. A group is what one
// section becomes: all batches of one object in one cell (multimesh), or all single instances
// of one object in one cell. Creation and freeing are queued and done by step() under a time
// budget; every RenderingServer call is made on the calling thread, which must be the main
// thread. The drawer owns every id it creates and frees them in its destructor. See
// docs/development/copia_design.md, "Run time", for the full contract.
class CopiaDrawer : public godot::RefCounted {
    GDCLASS(CopiaDrawer, godot::RefCounted)

public:
    struct Params {
        godot::RID mesh;
        godot::RID material_override;
        double visibility_begin = 0.0;
        double visibility_end = 0.0;
        double visibility_begin_margin = 0.0;
        double visibility_end_margin = 0.0;
        int fade_mode = 0;
        int cast_shadows = 1;
        bool low_lod_shadows = false;
        double shadow_range = 0.0;
        // Hysteresis of shadow_range: shadows turn on within shadow_range of a position and off
        // only beyond shadow_range + shadow_range_margin of every position.
        double shadow_range_margin = 0.0;
        double lod_bias = 1.0;
        uint32_t layers = 1;
        int gi_mode = 1;
        double extra_cull_margin = 0.0;
        godot::RID visibility_parent;
        uint64_t object_id = 0;
        double priority = 0.0;
        // Per-surface materials of single instances (RenderingServer ignores them on multimesh
        // instances); an invalid RID keeps the mesh's own material of that surface.
        std::vector<godot::RID> surface_materials;
        // Instance groups: instances whose scale is below this take no impostor link.
        double impostor_min_scale = 0.0;
    };

    CopiaDrawer() = default;
    ~CopiaDrawer() override;

    void set_scenario(const godot::RID &p_scenario);
    godot::RID get_scenario() const;
    void set_transform(const godot::Transform3D &p_transform);
    godot::Transform3D get_transform() const;

    int64_t add_multimesh_group(const godot::Dictionary &p_section, const godot::Dictionary &p_params);
    int64_t add_instance_group(const godot::Dictionary &p_section, const godot::Dictionary &p_params);
    void set_group_params(int64_t p_group, const godot::Dictionary &p_params);
    void set_groups_params(const godot::PackedInt64Array &p_groups, const godot::Dictionary &p_params);
    void remove_group(int64_t p_group);

    godot::Dictionary step(int64_t p_budget_usec);
    void update_camera(const godot::Vector3 &p_position);
    void update_cameras(const godot::PackedVector3Array &p_positions);
    void set_density(double p_fraction);
    double get_density() const;
    void set_group_density(int64_t p_group, double p_fraction);
    double get_group_density(int64_t p_group) const;

    godot::TypedArray<godot::RID> get_group_rids(int64_t p_group) const;
    godot::Dictionary get_group_info(int64_t p_group) const;
    int64_t get_group_count() const;
    godot::Dictionary get_stats() const;

    void warm_up(const godot::RID &p_mesh, const godot::RID &p_material, bool p_uses_color, bool p_uses_custom);

    void link_impostor(int64_t p_impostor_group, int64_t p_child_group, double p_swap_distance, int32_t p_batch);
    void unlink_impostor(int64_t p_impostor_group, int64_t p_child_group);

protected:
    static void _bind_methods();

private:
    enum ShadowState {
        SHADOW_UNKNOWN = -1,
        SHADOW_ALL_OFF = 0,
        SHADOW_ALL_ON = 1,
        SHADOW_MIXED = 2,
    };

    struct Item {
        godot::RID instance;
        godot::RID twin; // shadows-only instance of the same multimesh (low_lod_shadows)
        godot::RID multimesh;
        bool shadow_on = true;
        int32_t visible = -1; // visible instance count set on the multimesh
    };

    struct Group {
        int64_t id = 0;
        uint64_t sequence = 0;
        bool multimesh = true;
        Params params;
        int32_t count = 0; // batches or instances
        int32_t created = 0;
        bool queued = false;
        // Share of the global density this group shows (set_group_density); 1 = the global one.
        double density = 1.0;
        // Multimesh groups: one entry per batch.
        std::vector<godot::Vector3> origins;
        std::vector<godot::AABB> bounds;
        std::vector<int32_t> instance_counts;
        std::vector<std::array<int32_t, 5>> keep_counts;
        std::vector<godot::PackedFloat32Array> buffers; // released once the batch is created
        // Instance groups.
        godot::PackedFloat32Array transforms; // 12 per instance, store space
        godot::PackedByteArray parented; // empty: every instance gets the visibility parent
        std::vector<Item> items;
        godot::AABB local_bounds; // origins of the batches or instances, store space
        int shadow_state = SHADOW_UNKNOWN;
        int64_t instance_total = 0;
        int64_t drawn = 0; // instances of the created objects, honouring density
        // Impostor link, child side: the impostor group, its batch and the swap distance.
        int64_t impostor = 0;
        int32_t impostor_batch = 0;
        double swap_distance = 0.0;
        // Impostor side: the linked child groups.
        std::vector<int64_t> children;
        std::set<int32_t> held; // batches kept at begin 0 after a linked child was removed
        bool ready() const { return created == count; }
    };

    struct FreeUnit {
        godot::RID first;
        godot::RID second;
        godot::RID third;
    };

    struct WarmUp {
        godot::RID instance;
        godot::RID base; // multimesh, or invalid for a mesh instance
        int64_t frame = 0;
        int64_t process_frame = 0;
    };

    godot::RID scenario;
    godot::Transform3D transform;
    double density = 1.0;
    // Shadow range positions (update_camera, update_cameras). has_camera false: never given, so
    // every object casts; true with no position: every object with a shadow range is out of it.
    bool has_camera = false;
    std::vector<godot::Vector3> cameras;
    std::vector<godot::Vector3> evaluated_cameras;
    bool camera_evaluated = false;

    int64_t next_id = 1;
    uint64_t next_sequence = 0;
    std::unordered_map<int64_t, Group> groups;
    std::set<std::pair<double, uint64_t>> create_queue; // (priority, sequence)
    std::unordered_map<uint64_t, int64_t> queued_by_sequence;
    std::deque<FreeUnit> free_queue;
    std::vector<WarmUp> warm_ups;
    int64_t live_instances = 0; // RenderingServer instances (objects, twins, warm-up)
    int64_t live_multimeshes = 0;
    int64_t drawn_instances = 0; // sum of the groups' drawn counts
    int64_t created_total = 0;
    int64_t freed_total = 0;

    static void read_params(const godot::Dictionary &p_source, Params &r_params);
    static godot::Dictionary params_dictionary(const Params &p_params);
    int64_t add_group(Group &&p_group);
    void enqueue(Group &p_group);
    void dequeue(Group &p_group);
    void create_item(Group &p_group, int32_t p_index);
    void apply_item(const Group &p_group, int32_t p_index, Item &r_item, bool p_all);
    void apply_params(Group &p_group, const godot::Dictionary &p_params);
    godot::Transform3D item_transform(const Group &p_group, int32_t p_index) const;
    godot::Vector3 item_origin(const Group &p_group, int32_t p_index) const;
    int32_t visible_count(const Group &p_group, int32_t p_index) const;
    bool in_shadow_range(const Group &p_group, int32_t p_index, bool p_current) const;
    void apply_shadow(const Group &p_group, Item &r_item, bool p_on);
    void evaluate_shadows(Group &p_group, bool p_force);
    void apply_density(Group &p_group);
    void free_unit(const FreeUnit &p_unit);
    const Group *linked_impostor(const Group &p_child) const;
    godot::RID link_parent(const Group &p_child) const;
    double effective_begin(const Group &p_group, int32_t p_index) const;
    bool impostor_eligible(const Group &p_group, int32_t p_index) const;
    void apply_surface_materials(const Group &p_group, const godot::RID &p_instance, bool p_reset) const;
    void refresh_impostor_batch(int64_t p_impostor, int32_t p_batch);
    void refresh_children(const Group &p_impostor, int32_t p_batch);
    void apply_range(const Group &p_group, int32_t p_index, const Item &p_item);
    void free_everything();
};

} // namespace Copia

#endif // COPIA_DRAWER_H
