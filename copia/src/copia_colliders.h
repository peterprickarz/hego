#ifndef COPIA_COLLIDERS_H
#define COPIA_COLLIDERS_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/rid.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/typed_array.hpp>

#include <cstdint>
#include <deque>
#include <set>
#include <unordered_map>
#include <utility>
#include <vector>

namespace Copia {

// Static PhysicsServer3D bodies for a built cell's collider sections: one body per instance
// carrying every shape of the object. Creation and freeing are queued and done by step() under a
// time budget on the calling (main) thread; the object owns its bodies and frees them in its
// destructor. The instance's scale is baked into the shape transforms and the body gets the
// orthonormal part of the transform. See docs/development/copia_design.md, "Run time".
class CopiaColliders : public godot::RefCounted {
    GDCLASS(CopiaColliders, godot::RefCounted)

public:
    CopiaColliders() = default;
    ~CopiaColliders() override;

    void set_space(const godot::RID &p_space);
    godot::RID get_space() const;
    void set_transform(const godot::Transform3D &p_transform);
    godot::Transform3D get_transform() const;

    int64_t add_group(const godot::PackedFloat32Array &p_transforms, const godot::Array &p_shapes,
            const godot::Dictionary &p_params);
    void remove_group(int64_t p_group);
    godot::Dictionary step(int64_t p_budget_usec);
    godot::Dictionary find_body(const godot::RID &p_body) const;
    godot::TypedArray<godot::RID> get_group_rids(int64_t p_group) const;
    // {ready (every body created), count, created}; {} for an unknown id.
    godot::Dictionary get_group_info(int64_t p_group) const;
    int64_t get_group_count() const;
    godot::Dictionary get_stats() const;

protected:
    static void _bind_methods();

private:
    struct Shape {
        godot::RID shape;
        godot::Transform3D transform;
    };

    struct Group {
        int64_t id = 0;
        uint64_t sequence = 0;
        godot::PackedFloat32Array transforms;
        std::vector<Shape> shapes;
        uint32_t layer = 1;
        uint32_t mask = 1;
        uint64_t object_id = 0;
        double priority = 0.0;
        int32_t count = 0;
        int32_t created = 0;
        bool queued = false;
        std::vector<godot::RID> bodies;
    };

    godot::RID space;
    godot::Transform3D transform;
    int64_t next_id = 1;
    uint64_t next_sequence = 0;
    std::unordered_map<int64_t, Group> groups;
    std::set<std::pair<double, uint64_t>> create_queue;
    std::unordered_map<uint64_t, int64_t> queued_by_sequence;
    std::deque<godot::RID> free_queue;
    std::unordered_map<uint64_t, std::pair<int64_t, int32_t>> by_body;
    int64_t live_bodies = 0;
    int64_t created_total = 0;
    int64_t freed_total = 0;

    void place_body(const Group &p_group, int32_t p_index, const godot::RID &p_body, bool p_new) const;
    void create_body(Group &p_group, int32_t p_index);
    void free_everything();
};

} // namespace Copia

#endif // COPIA_COLLIDERS_H
