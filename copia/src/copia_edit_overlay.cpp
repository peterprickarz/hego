#include "copia_edit_overlay.h"

#include "copia_format.h"

#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>

#include <algorithm>
#include <cmath>
#include <cstring>

using namespace godot;

namespace Copia {

CopiaEditOverlay::~CopiaEditOverlay() {
    clear_all();
}

void CopiaEditOverlay::set_scenario(const RID &p_scenario) {
    if (scenario == p_scenario) {
        return;
    }
    scenario = p_scenario;
    RenderingServer *server = RenderingServer::get_singleton();
    if (!server) {
        return;
    }
    for (auto &entry : buckets) {
        if (entry.second.instance.is_valid()) {
            server->instance_set_scenario(entry.second.instance, scenario);
        }
    }
    if (ghost_instance.is_valid()) {
        server->instance_set_scenario(ghost_instance, scenario);
    }
}

RID CopiaEditOverlay::get_scenario() const {
    return scenario;
}

void CopiaEditOverlay::set_transform(const Transform3D &p_transform) {
    transform = p_transform;
    RenderingServer *server = RenderingServer::get_singleton();
    if (!server) {
        return;
    }
    for (auto &entry : buckets) {
        if (entry.second.instance.is_valid()) {
            server->instance_set_transform(entry.second.instance, transform);
        }
    }
}

Transform3D CopiaEditOverlay::get_transform() const {
    return transform;
}

void CopiaEditOverlay::set_object_visual(const String &p_object_path, const RID &p_mesh,
        const RID &p_material_override, const Color &p_default_color, const Color &p_default_custom,
        uint32_t p_layers, int p_cast_shadows) {
    std::string path = to_std(p_object_path);
    Visual &v = visuals[path];
    v.mesh = p_mesh;
    v.material_override = p_material_override;
    v.default_color = p_default_color;
    v.default_custom = p_default_custom;
    v.layers = p_layers;
    v.cast_shadows = p_cast_shadows;

    auto bit = buckets.find(path);
    if (bit != buckets.end()) {
        RenderingServer *server = RenderingServer::get_singleton();
        if (server) {
            if (bit->second.multimesh.is_valid() && v.mesh.is_valid()) {
                server->multimesh_set_mesh(bit->second.multimesh, v.mesh);
            }
            if (bit->second.instance.is_valid()) {
                server->instance_geometry_set_material_override(bit->second.instance, v.material_override);
                server->instance_set_layer_mask(bit->second.instance, v.layers);
                server->instance_geometry_set_cast_shadows_setting(bit->second.instance,
                        RenderingServer::ShadowCastingSetting(v.cast_shadows));
            }
        }
    }
}

void CopiaEditOverlay::ensure_bucket(const std::string &p_path, Bucket &r_bucket, int32_t p_needed) {
    RenderingServer *server = RenderingServer::get_singleton();
    if (!server || !scenario.is_valid()) {
        return;
    }
    auto vit = visuals.find(p_path);
    if (vit == visuals.end() || !vit->second.mesh.is_valid()) {
        return;
    }
    const Visual &v = vit->second;
    if (!r_bucket.multimesh.is_valid()) {
        r_bucket.multimesh = server->multimesh_create();
        server->multimesh_set_mesh(r_bucket.multimesh, v.mesh);
        r_bucket.instance = server->instance_create();
        server->instance_set_base(r_bucket.instance, r_bucket.multimesh);
        server->instance_set_scenario(r_bucket.instance, scenario);
        server->instance_set_transform(r_bucket.instance, transform);
        server->instance_geometry_set_material_override(r_bucket.instance, v.material_override);
        server->instance_set_layer_mask(r_bucket.instance, v.layers);
        server->instance_geometry_set_cast_shadows_setting(r_bucket.instance,
                RenderingServer::ShadowCastingSetting(v.cast_shadows));
        // Disable frustum culling surprises on dynamically growing staging MultiMeshes.
        server->instance_set_custom_aabb(r_bucket.instance, AABB(Vector3(-1e6f, -1e6f, -1e6f), Vector3(2e6f, 2e6f, 2e6f)));
    }
    if (p_needed > r_bucket.capacity) {
        int32_t next_cap = std::max(64, r_bucket.capacity);
        while (next_cap < p_needed) {
            next_cap *= 2;
        }
        int32_t old_count = r_bucket.count;
        r_bucket.buffer.resize(int64_t(next_cap) * FLOATS_PER_INSTANCE);
        // Zero newly allocated tail.
        if (next_cap > old_count) {
            std::memset(r_bucket.buffer.ptrw() + int64_t(old_count) * FLOATS_PER_INSTANCE, 0,
                    size_t(next_cap - old_count) * FLOATS_PER_INSTANCE * sizeof(float));
        }
        server->multimesh_allocate_data(r_bucket.multimesh, next_cap,
                RenderingServer::MULTIMESH_TRANSFORM_3D, true, true, false);
        r_bucket.capacity = next_cap;
    }
}

int64_t CopiaEditOverlay::append_points(const Dictionary &p_points) {
    RenderingServer *server = RenderingServer::get_singleton();
    if (!server || !scenario.is_valid() || p_points.is_empty()) {
        return staged_total;
    }
    Variant tv = p_points.get("transform", Variant());
    Variant ov = p_points.get("object", Variant());
    Variant pv = p_points.get("object_paths", Variant());
    if (tv.get_type() != Variant::PACKED_FLOAT32_ARRAY || ov.get_type() != Variant::PACKED_INT32_ARRAY ||
            pv.get_type() != Variant::PACKED_STRING_ARRAY) {
        return staged_total;
    }
    PackedFloat32Array transforms = tv;
    PackedInt32Array objects = ov;
    PackedStringArray object_paths = pv;
    int64_t n = objects.size();
    if (n == 0 || transforms.size() != n * 12) {
        return staged_total;
    }
    PackedFloat32Array colors, customs;
    bool has_color = p_points.has("color") && p_points["color"].get_type() == Variant::PACKED_FLOAT32_ARRAY;
    if (has_color) {
        colors = p_points["color"];
        has_color = colors.size() == n * 4;
    }
    bool has_custom = p_points.has("custom") && p_points["custom"].get_type() == Variant::PACKED_FLOAT32_ARRAY;
    if (has_custom) {
        customs = p_points["custom"];
        has_custom = customs.size() == n * 4;
    }

    // Group indices by object path so each bucket grows & uploads at most once per call.
    std::vector<std::string> paths(size_t(object_paths.size()));
    std::vector<std::vector<int64_t>> by_obj(size_t(object_paths.size()));
    for (int64_t i = 0; i < object_paths.size(); i++) {
        paths[size_t(i)] = to_std(object_paths[i]);
    }
    const int32_t *optr = objects.ptr();
    for (int64_t i = 0; i < n; i++) {
        int32_t oid = optr[i];
        if (oid >= 0 && oid < int32_t(paths.size())) {
            by_obj[size_t(oid)].push_back(i);
        }
    }

    const float *tptr = transforms.ptr();
    const float *cptr = has_color ? colors.ptr() : nullptr;
    const float *uptr = has_custom ? customs.ptr() : nullptr;

    for (size_t oid = 0; oid < paths.size(); oid++) {
        const auto &indices = by_obj[oid];
        if (indices.empty()) {
            continue;
        }
        const std::string &path = paths[oid];
        auto vit = visuals.find(path);
        if (vit == visuals.end() || !vit->second.mesh.is_valid()) {
            continue;
        }
        const Visual &v = vit->second;
        Bucket &bucket = buckets[path];
        ensure_bucket(path, bucket, bucket.count + int32_t(indices.size()));
        if (!bucket.multimesh.is_valid()) {
            continue;
        }
        float *dst = bucket.buffer.ptrw();
        for (int64_t i : indices) {
            const float *t = tptr + i * 12;
            float *out = dst + int64_t(bucket.count) * FLOATS_PER_INSTANCE;
            // MultiMesh expects 3x4 row-major transform:
            // row 0: basis.x.x, basis.y.x, basis.z.x, origin.x
            // row 1: basis.x.y, basis.y.y, basis.z.y, origin.y
            // row 2: basis.x.z, basis.y.z, basis.z.z, origin.z
            out[0] = t[0]; out[1] = t[3]; out[2] = t[6]; out[3] = t[9];
            out[4] = t[1]; out[5] = t[4]; out[6] = t[7]; out[7] = t[10];
            out[8] = t[2]; out[9] = t[5]; out[10] = t[8]; out[11] = t[11];

            if (cptr && !std::isnan(cptr[i * 4])) {
                out[12] = cptr[i * 4 + 0];
                out[13] = cptr[i * 4 + 1];
                out[14] = cptr[i * 4 + 2];
                out[15] = cptr[i * 4 + 3];
            } else {
                out[12] = v.default_color.r;
                out[13] = v.default_color.g;
                out[14] = v.default_color.b;
                out[15] = v.default_color.a;
            }
            if (uptr && !std::isnan(uptr[i * 4])) {
                out[16] = uptr[i * 4 + 0];
                out[17] = uptr[i * 4 + 1];
                out[18] = uptr[i * 4 + 2];
                out[19] = uptr[i * 4 + 3];
            } else {
                out[16] = v.default_custom.r;
                out[17] = v.default_custom.g;
                out[18] = v.default_custom.b;
                out[19] = v.default_custom.a;
            }
            bucket.count++;
            staged_total++;
        }
        server->multimesh_set_buffer(bucket.multimesh, bucket.buffer);
        server->multimesh_set_visible_instances(bucket.multimesh, bucket.count);
        server->instance_set_visible(bucket.instance, bucket.count > 0);
    }
    return staged_total;
}

void CopiaEditOverlay::set_ghost(const String &p_object_path, const Transform3D &p_transform, bool p_visible) {
    RenderingServer *server = RenderingServer::get_singleton();
    if (!server || !scenario.is_valid()) {
        return;
    }
    std::string path = to_std(p_object_path);
    auto vit = visuals.find(path);
    if (!p_visible || vit == visuals.end() || !vit->second.mesh.is_valid()) {
        hide_ghost();
        return;
    }
    const Visual &v = vit->second;
    if (!ghost_instance.is_valid()) {
        ghost_instance = server->instance_create();
        server->instance_set_scenario(ghost_instance, scenario);
    }
    if (ghost_object != path) {
        ghost_object = path;
        server->instance_set_base(ghost_instance, v.mesh);
        server->instance_geometry_set_material_override(ghost_instance, v.material_override);
        server->instance_set_layer_mask(ghost_instance, v.layers);
        server->instance_geometry_set_cast_shadows_setting(ghost_instance,
                RenderingServer::ShadowCastingSetting(v.cast_shadows));
    }
    server->instance_set_transform(ghost_instance, transform * p_transform);
    server->instance_set_visible(ghost_instance, true);
    ghost_visible = true;
}

void CopiaEditOverlay::hide_ghost() {
    RenderingServer *server = RenderingServer::get_singleton();
    if (server && ghost_instance.is_valid()) {
        server->instance_set_visible(ghost_instance, false);
    }
    ghost_visible = false;
}

int64_t CopiaEditOverlay::get_staged_count() const {
    return staged_total;
}

void CopiaEditOverlay::free_bucket(Bucket &r_bucket) {
    RenderingServer *server = RenderingServer::get_singleton();
    if (server) {
        if (r_bucket.instance.is_valid()) {
            server->free_rid(r_bucket.instance);
        }
        if (r_bucket.multimesh.is_valid()) {
            server->free_rid(r_bucket.multimesh);
        }
    }
    r_bucket.instance = RID();
    r_bucket.multimesh = RID();
    r_bucket.capacity = 0;
    r_bucket.count = 0;
    r_bucket.buffer.clear();
}

void CopiaEditOverlay::free_ghost() {
    RenderingServer *server = RenderingServer::get_singleton();
    if (server && ghost_instance.is_valid()) {
        server->free_rid(ghost_instance);
    }
    ghost_instance = RID();
    ghost_object.clear();
    ghost_visible = false;
}

void CopiaEditOverlay::clear_stroke() {
    for (auto &entry : buckets) {
        free_bucket(entry.second);
    }
    buckets.clear();
    staged_total = 0;
}

void CopiaEditOverlay::clear_all() {
    clear_stroke();
    free_ghost();
    visuals.clear();
}

void CopiaEditOverlay::_bind_methods() {
    using namespace godot;
    ClassDB::bind_method(D_METHOD("set_scenario", "scenario"), &CopiaEditOverlay::set_scenario);
    ClassDB::bind_method(D_METHOD("get_scenario"), &CopiaEditOverlay::get_scenario);
    ClassDB::bind_method(D_METHOD("set_transform", "transform"), &CopiaEditOverlay::set_transform);
    ClassDB::bind_method(D_METHOD("get_transform"), &CopiaEditOverlay::get_transform);
    ClassDB::bind_method(D_METHOD("set_object_visual", "object_path", "mesh", "material_override", "default_color", "default_custom", "layers", "cast_shadows"),
            &CopiaEditOverlay::set_object_visual, DEFVAL(RID()), DEFVAL(Color(1, 1, 1, 1)), DEFVAL(Color(0, 0, 0, 0)), DEFVAL(uint32_t(1)), DEFVAL(1));
    ClassDB::bind_method(D_METHOD("append_points", "points"), &CopiaEditOverlay::append_points);
    ClassDB::bind_method(D_METHOD("set_ghost", "object_path", "transform", "visible"), &CopiaEditOverlay::set_ghost);
    ClassDB::bind_method(D_METHOD("hide_ghost"), &CopiaEditOverlay::hide_ghost);
    ClassDB::bind_method(D_METHOD("get_staged_count"), &CopiaEditOverlay::get_staged_count);
    ClassDB::bind_method(D_METHOD("clear_stroke"), &CopiaEditOverlay::clear_stroke);
    ClassDB::bind_method(D_METHOD("clear_all"), &CopiaEditOverlay::clear_all);
}

} // namespace Copia
