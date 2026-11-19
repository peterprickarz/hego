#include "copia_colliders.h"

#include <godot_cpp/classes/physics_server3d.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/basis.hpp>

#include <algorithm>
#include <chrono>

using namespace godot;

namespace Copia {

namespace {

int64_t now_usec() {
    return std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now().time_since_epoch()).count();
}

Transform3D transform_from_floats(const float *p_values) {
    Basis basis;
    basis.set_column(0, Vector3(p_values[0], p_values[1], p_values[2]));
    basis.set_column(1, Vector3(p_values[3], p_values[4], p_values[5]));
    basis.set_column(2, Vector3(p_values[6], p_values[7], p_values[8]));
    return Transform3D(basis, Vector3(p_values[9], p_values[10], p_values[11]));
}

} // namespace

CopiaColliders::~CopiaColliders() {
    free_everything();
}

void CopiaColliders::free_everything() {
    PhysicsServer3D *server = PhysicsServer3D::get_singleton();
    if (server != nullptr) {
        for (auto &entry : groups) {
            for (int32_t i = 0; i < entry.second.created; i++) {
                server->free_rid(entry.second.bodies[size_t(i)]);
            }
        }
        for (const RID &body : free_queue) {
            server->free_rid(body);
        }
    }
    groups.clear();
    create_queue.clear();
    queued_by_sequence.clear();
    free_queue.clear();
    by_body.clear();
    live_bodies = 0;
}

void CopiaColliders::set_space(const RID &p_space) {
    space = p_space;
    PhysicsServer3D *server = PhysicsServer3D::get_singleton();
    for (auto &entry : groups) {
        for (int32_t i = 0; i < entry.second.created; i++) {
            server->body_set_space(entry.second.bodies[size_t(i)], space);
        }
    }
}

RID CopiaColliders::get_space() const {
    return space;
}

void CopiaColliders::set_transform(const Transform3D &p_transform) {
    transform = p_transform;
    for (auto &entry : groups) {
        for (int32_t i = 0; i < entry.second.created; i++) {
            place_body(entry.second, i, entry.second.bodies[size_t(i)], false);
        }
    }
}

Transform3D CopiaColliders::get_transform() const {
    return transform;
}

// The body gets the rotation and origin of store transform x instance transform; the rest of
// the basis (scale and shear) is baked into each shape's transform, so body x shape equals the
// full transform x the shape's own transform.
void CopiaColliders::place_body(const Group &p_group, int32_t p_index, const RID &p_body, bool p_new) const {
    PhysicsServer3D *server = PhysicsServer3D::get_singleton();
    const Transform3D full = transform * transform_from_floats(p_group.transforms.ptr() + size_t(p_index) * 12);
    Basis rotation = full.basis.orthonormalized();
    const Basis rest = rotation.transposed() * full.basis;
    for (int32_t s = 0; s < int32_t(p_group.shapes.size()); s++) {
        const Transform3D shape_transform = Transform3D(rest, Vector3()) * p_group.shapes[size_t(s)].transform;
        if (p_new) {
            server->body_add_shape(p_body, p_group.shapes[size_t(s)].shape, shape_transform);
        } else {
            server->body_set_shape_transform(p_body, s, shape_transform);
        }
    }
    server->body_set_state(p_body, PhysicsServer3D::BODY_STATE_TRANSFORM, Transform3D(rotation, full.origin));
}

int64_t CopiaColliders::add_group(const PackedFloat32Array &p_transforms, const Array &p_shapes, const Dictionary &p_params) {
    ERR_FAIL_COND_V_MSG(p_transforms.size() % 12 != 0, 0, "CopiaColliders: transforms must hold 12 floats per instance.");
    Group group;
    group.transforms = p_transforms;
    group.count = int32_t(p_transforms.size() / 12);
    for (int64_t i = 0; i < p_shapes.size(); i++) {
        Dictionary entry = p_shapes[i];
        Variant shape = entry.get("shape", Variant());
        ERR_FAIL_COND_V_MSG(shape.get_type() != Variant::RID, 0, "CopiaColliders: each shape needs a shape RID.");
        Shape value;
        value.shape = shape;
        value.transform = entry.get("transform", Transform3D());
        group.shapes.push_back(value);
    }
    group.layer = uint32_t(int64_t(p_params.get("collision_layer", 1)));
    group.mask = uint32_t(int64_t(p_params.get("collision_mask", 1)));
    group.object_id = uint64_t(int64_t(p_params.get("object_id", 0)));
    group.priority = double(p_params.get("priority", 0.0));
    group.id = next_id++;
    group.sequence = next_sequence++;
    group.bodies.assign(size_t(group.count), RID());
    const int64_t id = group.id;
    Group &stored = groups.emplace(id, std::move(group)).first->second;
    if (stored.count > 0) {
        create_queue.insert({ stored.priority, stored.sequence });
        queued_by_sequence[stored.sequence] = id;
        stored.queued = true;
    }
    return id;
}

void CopiaColliders::create_body(Group &p_group, int32_t p_index) {
    PhysicsServer3D *server = PhysicsServer3D::get_singleton();
    RID body = server->body_create();
    server->body_set_mode(body, PhysicsServer3D::BODY_MODE_STATIC);
    place_body(p_group, p_index, body, true);
    server->body_set_collision_layer(body, p_group.layer);
    server->body_set_collision_mask(body, p_group.mask);
    if (p_group.object_id != 0) {
        server->body_attach_object_instance_id(body, p_group.object_id);
    }
    server->body_set_space(body, space);
    p_group.bodies[size_t(p_index)] = body;
    by_body[body.get_id()] = { p_group.id, p_index };
    live_bodies++;
}

void CopiaColliders::remove_group(int64_t p_group) {
    auto found = groups.find(p_group);
    ERR_FAIL_COND_MSG(found == groups.end(), "CopiaColliders: no such group.");
    Group &group = found->second;
    if (group.queued) {
        create_queue.erase({ group.priority, group.sequence });
        queued_by_sequence.erase(group.sequence);
    }
    for (int32_t i = 0; i < group.created; i++) {
        by_body.erase(group.bodies[size_t(i)].get_id());
        free_queue.push_back(group.bodies[size_t(i)]);
    }
    groups.erase(found);
}

Dictionary CopiaColliders::step(int64_t p_budget_usec) {
    const int64_t start = now_usec();
    const int64_t budget = std::max<int64_t>(0, p_budget_usec);
    int64_t created = 0;
    int64_t freed = 0;
    PhysicsServer3D *server = PhysicsServer3D::get_singleton();
    if (server != nullptr && budget > 0) {
        bool first = true;
        auto spent = [&]() { return now_usec() - start >= budget; };
        while (!free_queue.empty() && (first || !spent())) {
            server->free_rid(free_queue.front());
            free_queue.pop_front();
            live_bodies--;
            freed++;
            first = false;
        }
        while (!create_queue.empty() && (first || !spent())) {
            const auto key = *create_queue.begin();
            Group &group = groups.at(queued_by_sequence.at(key.second));
            create_body(group, group.created);
            group.created++;
            created++;
            first = false;
            if (group.created >= group.count) {
                create_queue.erase(create_queue.begin());
                queued_by_sequence.erase(key.second);
                group.queued = false;
            }
        }
    }
    created_total += created;
    freed_total += freed;
    int64_t pending = 0;
    for (const auto &entry : groups) {
        pending += entry.second.count - entry.second.created;
    }
    Dictionary result;
    result["created"] = created;
    result["freed"] = freed;
    result["pending_create"] = pending;
    result["pending_free"] = int64_t(free_queue.size());
    result["usec"] = now_usec() - start;
    return result;
}

Dictionary CopiaColliders::find_body(const RID &p_body) const {
    Dictionary result;
    auto found = by_body.find(p_body.get_id());
    if (found != by_body.end()) {
        result["group"] = found->second.first;
        result["index"] = found->second.second;
    }
    return result;
}

TypedArray<RID> CopiaColliders::get_group_rids(int64_t p_group) const {
    TypedArray<RID> result;
    auto found = groups.find(p_group);
    ERR_FAIL_COND_V_MSG(found == groups.end(), result, "CopiaColliders: no such group.");
    for (int32_t i = 0; i < found->second.created; i++) {
        result.push_back(found->second.bodies[size_t(i)]);
    }
    return result;
}

Dictionary CopiaColliders::get_group_info(int64_t p_group) const {
    Dictionary result;
    auto found = groups.find(p_group);
    if (found == groups.end()) {
        return result;
    }
    result["ready"] = found->second.created >= found->second.count;
    result["count"] = found->second.count;
    result["created"] = found->second.created;
    return result;
}

int64_t CopiaColliders::get_group_count() const {
    return int64_t(groups.size());
}

Dictionary CopiaColliders::get_stats() const {
    int64_t pending = 0;
    for (const auto &entry : groups) {
        pending += entry.second.count - entry.second.created;
    }
    Dictionary result;
    result["groups"] = int64_t(groups.size());
    result["bodies"] = live_bodies;
    result["pending_create"] = pending;
    result["pending_free"] = int64_t(free_queue.size());
    result["created_total"] = created_total;
    result["freed_total"] = freed_total;
    return result;
}

void CopiaColliders::_bind_methods() {
    ClassDB::bind_method(D_METHOD("set_space", "space"), &CopiaColliders::set_space);
    ClassDB::bind_method(D_METHOD("get_space"), &CopiaColliders::get_space);
    ClassDB::bind_method(D_METHOD("set_transform", "transform"), &CopiaColliders::set_transform);
    ClassDB::bind_method(D_METHOD("get_transform"), &CopiaColliders::get_transform);
    ClassDB::bind_method(D_METHOD("add_group", "transforms", "shapes", "params"), &CopiaColliders::add_group, DEFVAL(Dictionary()));
    ClassDB::bind_method(D_METHOD("remove_group", "group"), &CopiaColliders::remove_group);
    ClassDB::bind_method(D_METHOD("step", "budget_usec"), &CopiaColliders::step);
    ClassDB::bind_method(D_METHOD("find_body", "body"), &CopiaColliders::find_body);
    ClassDB::bind_method(D_METHOD("get_group_rids", "group"), &CopiaColliders::get_group_rids);
    ClassDB::bind_method(D_METHOD("get_group_info", "group"), &CopiaColliders::get_group_info);
    ClassDB::bind_method(D_METHOD("get_group_count"), &CopiaColliders::get_group_count);
    ClassDB::bind_method(D_METHOD("get_stats"), &CopiaColliders::get_stats);
    ADD_PROPERTY(PropertyInfo(Variant::RID, "space"), "set_space", "get_space");
    ADD_PROPERTY(PropertyInfo(Variant::TRANSFORM3D, "transform"), "set_transform", "get_transform");
}

} // namespace Copia
