#include "copia_drawer.h"

#include "copia_format.h"

#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/basis.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <string>
#include <unordered_map>

using namespace godot;

namespace Copia {

namespace {

int64_t now_usec() {
    return std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now().time_since_epoch()).count();
}

// The camera must move this far before update_camera() evaluates shadow ranges again.
constexpr double CAMERA_EPSILON = 0.25;

const float KEEP_LEVELS[5] = { 1.0f, 0.75f, 0.5f, 0.25f, 0.0f };

bool read_number(const Variant &p_value, const char *p_key, double &r_value) {
    if (p_value.get_type() == Variant::INT || p_value.get_type() == Variant::FLOAT) {
        r_value = double(p_value);
        return true;
    }
    if (p_value.get_type() != Variant::NIL) {
        ERR_PRINT(String("CopiaDrawer: ") + p_key + " must be a number.");
    }
    return false;
}

bool read_rid(const Variant &p_value, const char *p_key, RID &r_value) {
    if (p_value.get_type() == Variant::RID) {
        r_value = p_value;
        return true;
    }
    if (p_value.get_type() != Variant::NIL) {
        ERR_PRINT(String("CopiaDrawer: ") + p_key + " must be an RID.");
    }
    return false;
}

// The params keys. Plain C and std types, so nothing is left for the engine to free when the
// library unloads.
enum ParamKey {
    KEY_MESH,
    KEY_MATERIAL_OVERRIDE,
    KEY_VISIBILITY_PARENT,
    KEY_VISIBILITY_BEGIN,
    KEY_VISIBILITY_END,
    KEY_VISIBILITY_BEGIN_MARGIN,
    KEY_VISIBILITY_END_MARGIN,
    KEY_SHADOW_RANGE,
    KEY_SHADOW_RANGE_MARGIN,
    KEY_LOD_BIAS,
    KEY_EXTRA_CULL_MARGIN,
    KEY_PRIORITY,
    KEY_FADE_MODE,
    KEY_CAST_SHADOWS,
    KEY_LAYERS,
    KEY_GI_MODE,
    KEY_OBJECT_ID,
    KEY_LOW_LOD_SHADOWS,
    KEY_IMPOSTOR_MIN_SCALE,
    KEY_SURFACE_MATERIALS,
    KEY_COUNT,
};

const char *const PARAM_NAMES[KEY_COUNT] = {
    "mesh",
    "material_override",
    "visibility_parent",
    "visibility_begin",
    "visibility_end",
    "visibility_begin_margin",
    "visibility_end_margin",
    "shadow_range",
    "shadow_range_margin",
    "lod_bias",
    "extra_cull_margin",
    "priority",
    "fade_mode",
    "cast_shadows",
    "layers",
    "gi_mode",
    "object_id",
    "low_lod_shadows",
    "impostor_min_scale",
    "surface_materials",
};

const std::unordered_map<std::string, int> &param_keys() {
    static const std::unordered_map<std::string, int> keys = []() {
        std::unordered_map<std::string, int> map;
        for (int k = 0; k < KEY_COUNT; k++) {
            map.emplace(PARAM_NAMES[k], k);
        }
        return map;
    }();
    return keys;
}

Transform3D transform_from_floats(const float *p_values) {
    Basis basis;
    basis.set_column(0, Vector3(p_values[0], p_values[1], p_values[2]));
    basis.set_column(1, Vector3(p_values[3], p_values[4], p_values[5]));
    basis.set_column(2, Vector3(p_values[6], p_values[7], p_values[8]));
    return Transform3D(basis, Vector3(p_values[9], p_values[10], p_values[11]));
}

// Smallest and largest distance from p_point to the points of p_box.
void box_distances(const AABB &p_box, const Vector3 &p_point, double &r_near, double &r_far) {
    double near_sq = 0.0;
    double far_sq = 0.0;
    for (int axis = 0; axis < 3; axis++) {
        double low = p_box.position[axis];
        double high = low + p_box.size[axis];
        double value = p_point[axis];
        double outside = value < low ? low - value : (value > high ? value - high : 0.0);
        double farthest = std::max(std::abs(value - low), std::abs(value - high));
        near_sq += outside * outside;
        far_sq += farthest * farthest;
    }
    r_near = std::sqrt(near_sq);
    r_far = std::sqrt(far_sq);
}

} // namespace

CopiaDrawer::~CopiaDrawer() {
    free_everything();
}

void CopiaDrawer::free_everything() {
    RenderingServer *server = RenderingServer::get_singleton();
    if (server == nullptr) {
        // Engine shutdown: the server frees what is left itself.
        groups.clear();
        free_queue.clear();
        warm_ups.clear();
        drawn_instances = 0;
        return;
    }
    drawn_instances = 0;
    for (auto &entry : groups) {
        for (Item &item : entry.second.items) {
            if (item.instance.is_valid() || item.multimesh.is_valid()) {
                free_unit({ item.instance, item.twin, item.multimesh });
            }
        }
    }
    groups.clear();
    create_queue.clear();
    queued_by_sequence.clear();
    for (const FreeUnit &unit : free_queue) {
        free_unit(unit);
    }
    free_queue.clear();
    for (const WarmUp &warm : warm_ups) {
        free_unit({ warm.instance, RID(), warm.base });
    }
    warm_ups.clear();
}

void CopiaDrawer::free_unit(const FreeUnit &p_unit) {
    RenderingServer *server = RenderingServer::get_singleton();
    // Instances first, so no instance is left pointing at a freed multimesh.
    for (const RID &rid : { p_unit.first, p_unit.second }) {
        if (rid.is_valid()) {
            server->free_rid(rid);
            live_instances--;
        }
    }
    if (p_unit.third.is_valid()) {
        server->free_rid(p_unit.third);
        live_multimeshes--;
    }
}

// One params value into r_params.
static void read_param(int p_key, const Variant &p_value, CopiaDrawer::Params &r_params) {
    const char *name = PARAM_NAMES[p_key];
    double number = 0.0;
    switch (p_key) {
        case KEY_MESH:
            read_rid(p_value, name, r_params.mesh);
            break;
        case KEY_MATERIAL_OVERRIDE:
            read_rid(p_value, name, r_params.material_override);
            break;
        case KEY_VISIBILITY_PARENT:
            read_rid(p_value, name, r_params.visibility_parent);
            break;
        case KEY_VISIBILITY_BEGIN:
            read_number(p_value, name, r_params.visibility_begin);
            break;
        case KEY_VISIBILITY_END:
            read_number(p_value, name, r_params.visibility_end);
            break;
        case KEY_VISIBILITY_BEGIN_MARGIN:
            read_number(p_value, name, r_params.visibility_begin_margin);
            break;
        case KEY_VISIBILITY_END_MARGIN:
            read_number(p_value, name, r_params.visibility_end_margin);
            break;
        case KEY_SHADOW_RANGE:
            read_number(p_value, name, r_params.shadow_range);
            break;
        case KEY_SHADOW_RANGE_MARGIN:
            read_number(p_value, name, r_params.shadow_range_margin);
            break;
        case KEY_LOD_BIAS:
            read_number(p_value, name, r_params.lod_bias);
            break;
        case KEY_EXTRA_CULL_MARGIN:
            read_number(p_value, name, r_params.extra_cull_margin);
            break;
        case KEY_PRIORITY:
            read_number(p_value, name, r_params.priority);
            break;
        case KEY_IMPOSTOR_MIN_SCALE:
            read_number(p_value, name, r_params.impostor_min_scale);
            break;
        case KEY_FADE_MODE:
            if (read_number(p_value, name, number)) {
                r_params.fade_mode = int(number);
            }
            break;
        case KEY_CAST_SHADOWS:
            if (read_number(p_value, name, number)) {
                r_params.cast_shadows = int(number);
            }
            break;
        case KEY_LAYERS:
            if (read_number(p_value, name, number)) {
                r_params.layers = uint32_t(int64_t(number));
            }
            break;
        case KEY_GI_MODE:
            if (read_number(p_value, name, number)) {
                r_params.gi_mode = int(number);
            }
            break;
        case KEY_OBJECT_ID:
            if (read_number(p_value, name, number)) {
                r_params.object_id = uint64_t(int64_t(p_value));
            }
            break;
        case KEY_LOW_LOD_SHADOWS:
            if (p_value.get_type() != Variant::NIL) {
                r_params.low_lod_shadows = bool(p_value);
            }
            break;
        case KEY_SURFACE_MATERIALS:
            if (p_value.get_type() == Variant::ARRAY) {
                Array list = p_value;
                r_params.surface_materials.assign(size_t(list.size()), RID());
                for (int64_t i = 0; i < list.size(); i++) {
                    Variant entry = list[i];
                    if (entry.get_type() == Variant::RID) {
                        r_params.surface_materials[size_t(i)] = entry;
                    } else if (entry.get_type() != Variant::NIL) {
                        ERR_PRINT("CopiaDrawer: surface_materials must hold RIDs.");
                    }
                }
            } else if (p_value.get_type() != Variant::NIL) {
                ERR_PRINT("CopiaDrawer: surface_materials must be an Array of RIDs.");
            }
            break;
    }
}

// Merges the keys present in p_source into r_params; unknown keys are ignored. A small update (a
// few keys) is read by walking its keys, so it costs one lookup per key; a full params dictionary
// is read by looking up each known key, which is cheaper than converting every key it holds.
void CopiaDrawer::read_params(const Dictionary &p_source, Params &r_params) {
    if (p_source.size() > 4) {
        for (int k = 0; k < KEY_COUNT; k++) {
            const Variant value = p_source.get(PARAM_NAMES[k], Variant());
            if (value.get_type() != Variant::NIL) {
                read_param(k, value, r_params);
            }
        }
        return;
    }
    const std::unordered_map<std::string, int> &known = param_keys();
    Array keys = p_source.keys();
    for (int64_t k = 0; k < keys.size(); k++) {
        const Variant key = keys[k];
        if (key.get_type() != Variant::STRING && key.get_type() != Variant::STRING_NAME) {
            continue;
        }
        const CharString utf8 = String(key).utf8();
        auto found = known.find(std::string(utf8.get_data(), size_t(utf8.length())));
        if (found != known.end()) {
            read_param(found->second, p_source[key], r_params);
        }
    }
}

Dictionary CopiaDrawer::params_dictionary(const Params &p_params) {
    Dictionary result;
    result["mesh"] = p_params.mesh;
    result["material_override"] = p_params.material_override;
    result["visibility_begin"] = p_params.visibility_begin;
    result["visibility_end"] = p_params.visibility_end;
    result["visibility_begin_margin"] = p_params.visibility_begin_margin;
    result["visibility_end_margin"] = p_params.visibility_end_margin;
    result["fade_mode"] = p_params.fade_mode;
    result["cast_shadows"] = p_params.cast_shadows;
    result["low_lod_shadows"] = p_params.low_lod_shadows;
    result["shadow_range"] = p_params.shadow_range;
    result["shadow_range_margin"] = p_params.shadow_range_margin;
    result["lod_bias"] = p_params.lod_bias;
    result["layers"] = int64_t(p_params.layers);
    result["gi_mode"] = p_params.gi_mode;
    result["extra_cull_margin"] = p_params.extra_cull_margin;
    result["visibility_parent"] = p_params.visibility_parent;
    result["object_id"] = int64_t(p_params.object_id);
    result["priority"] = p_params.priority;
    Array surfaces;
    for (const RID &material : p_params.surface_materials) {
        surfaces.push_back(material);
    }
    result["surface_materials"] = surfaces;
    result["impostor_min_scale"] = p_params.impostor_min_scale;
    return result;
}

void CopiaDrawer::set_scenario(const RID &p_scenario) {
    scenario = p_scenario;
    RenderingServer *server = RenderingServer::get_singleton();
    for (auto &entry : groups) {
        for (Item &item : entry.second.items) {
            for (const RID &rid : { item.instance, item.twin }) {
                if (rid.is_valid()) {
                    server->instance_set_scenario(rid, scenario);
                }
            }
        }
    }
}

RID CopiaDrawer::get_scenario() const {
    return scenario;
}

void CopiaDrawer::set_transform(const Transform3D &p_transform) {
    transform = p_transform;
    RenderingServer *server = RenderingServer::get_singleton();
    for (auto &entry : groups) {
        Group &group = entry.second;
        for (int32_t i = 0; i < int32_t(group.items.size()); i++) {
            const Item &item = group.items[size_t(i)];
            if (!item.instance.is_valid()) {
                continue;
            }
            Transform3D global = item_transform(group, i);
            server->instance_set_transform(item.instance, global);
            if (item.twin.is_valid()) {
                server->instance_set_transform(item.twin, global);
            }
        }
        evaluate_shadows(group, true);
    }
}

Transform3D CopiaDrawer::get_transform() const {
    return transform;
}

Transform3D CopiaDrawer::item_transform(const Group &p_group, int32_t p_index) const {
    if (p_group.multimesh) {
        return transform * Transform3D(Basis(), p_group.origins[size_t(p_index)]);
    }
    return transform * transform_from_floats(p_group.transforms.ptr() + size_t(p_index) * 12);
}

Vector3 CopiaDrawer::item_origin(const Group &p_group, int32_t p_index) const {
    if (p_group.multimesh) {
        return transform.xform(p_group.origins[size_t(p_index)]);
    }
    const float *values = p_group.transforms.ptr() + size_t(p_index) * 12;
    return transform.xform(Vector3(values[9], values[10], values[11]));
}

int32_t CopiaDrawer::visible_count(const Group &p_group, int32_t p_index) const {
    const int32_t total = p_group.instance_counts[size_t(p_index)];
    // The global density times the group's share.
    const double fraction = std::min(1.0, std::max(0.0, density * p_group.density));
    if (fraction >= 1.0) {
        return total;
    }
    const std::array<int32_t, 5> &keep = p_group.keep_counts[size_t(p_index)];
    // density d shows the instances with keep >= 1 - d at d = 0, 0.25, 0.5, 0.75 and 1; in
    // between, the count is interpolated (instances are ordered by keep, highest first).
    double level = fraction * 4.0;
    int low = std::min(3, int(std::floor(level)));
    double t = level - low;
    double count = keep[size_t(low)] + (keep[size_t(low) + 1] - keep[size_t(low)]) * t;
    return std::min(total, std::max(0, int32_t(std::lround(count))));
}

int64_t CopiaDrawer::add_group(Group &&p_group) {
    p_group.id = next_id++;
    p_group.sequence = next_sequence++;
    p_group.items.assign(size_t(p_group.count), Item());
    const int64_t id = p_group.id;
    Group &group = groups.emplace(id, std::move(p_group)).first->second;
    if (group.count > 0) {
        enqueue(group);
    }
    return id;
}

void CopiaDrawer::enqueue(Group &p_group) {
    if (!p_group.queued) {
        create_queue.insert({ p_group.params.priority, p_group.sequence });
        queued_by_sequence[p_group.sequence] = p_group.id;
        p_group.queued = true;
    }
}

void CopiaDrawer::dequeue(Group &p_group) {
    if (p_group.queued) {
        create_queue.erase({ p_group.params.priority, p_group.sequence });
        queued_by_sequence.erase(p_group.sequence);
        p_group.queued = false;
    }
}

int64_t CopiaDrawer::add_multimesh_group(const Dictionary &p_section, const Dictionary &p_params) {
    ERR_FAIL_COND_V_MSG(String(p_section.get("kind", "")) != "multimesh", 0,
            "CopiaDrawer: add_multimesh_group needs a section of kind \"multimesh\".");
    Group group;
    group.multimesh = true;
    read_params(p_params, group.params);
    PackedVector3Array origins = p_section.get("origins", PackedVector3Array());
    Array bounds = p_section.get("bounds", Array());
    PackedInt32Array counts = p_section.get("counts", PackedInt32Array());
    PackedInt32Array keep = p_section.get("keep_counts", PackedInt32Array());
    Array buffers = p_section.get("buffers", Array());
    const int64_t n = origins.size();
    ERR_FAIL_COND_V_MSG(bounds.size() != n || counts.size() != n || buffers.size() != n || keep.size() != n * 5, 0,
            "CopiaDrawer: the section's origins, bounds, counts, keep_counts and buffers do not match.");
    group.count = int32_t(n);
    group.origins.resize(size_t(n));
    group.bounds.resize(size_t(n));
    group.instance_counts.resize(size_t(n));
    group.keep_counts.resize(size_t(n));
    group.buffers.resize(size_t(n));
    for (int64_t i = 0; i < n; i++) {
        group.origins[size_t(i)] = origins[i];
        group.bounds[size_t(i)] = bounds[i];
        group.instance_counts[size_t(i)] = counts[i];
        for (int k = 0; k < 5; k++) {
            group.keep_counts[size_t(i)][size_t(k)] = keep[i * 5 + k];
        }
        group.buffers[size_t(i)] = buffers[i];
        ERR_FAIL_COND_V_MSG(group.buffers[size_t(i)].size() != int64_t(counts[i]) * FLOATS_PER_INSTANCE, 0,
                "CopiaDrawer: a batch buffer does not hold 20 floats per instance.");
        group.instance_total += counts[i];
        AABB box(group.origins[size_t(i)], Vector3());
        group.local_bounds = i == 0 ? box : group.local_bounds.merge(box);
    }
    return add_group(std::move(group));
}

int64_t CopiaDrawer::add_instance_group(const Dictionary &p_section, const Dictionary &p_params) {
    ERR_FAIL_COND_V_MSG(String(p_section.get("kind", "")) != "transforms", 0,
            "CopiaDrawer: add_instance_group needs a section of kind \"transforms\".");
    Group group;
    group.multimesh = false;
    read_params(p_params, group.params);
    group.transforms = p_section.get("transforms", PackedFloat32Array());
    ERR_FAIL_COND_V_MSG(group.transforms.size() % 12 != 0, 0, "CopiaDrawer: transforms must hold 12 floats per instance.");
    group.count = int32_t(group.transforms.size() / 12);
    group.instance_total = group.count;
    Variant parented = p_params.get("parented", p_section.get("parented", Variant()));
    if (parented.get_type() == Variant::PACKED_BYTE_ARRAY) {
        group.parented = parented;
        ERR_FAIL_COND_V_MSG(group.parented.size() != group.count, 0, "CopiaDrawer: parented must hold one byte per instance.");
    }
    const float *values = group.transforms.ptr();
    for (int32_t i = 0; i < group.count; i++) {
        AABB box(Vector3(values[i * 12 + 9], values[i * 12 + 10], values[i * 12 + 11]), Vector3());
        group.local_bounds = i == 0 ? box : group.local_bounds.merge(box);
    }
    return add_group(std::move(group));
}

void CopiaDrawer::apply_shadow(const Group &p_group, Item &r_item, bool p_on) {
    RenderingServer *server = RenderingServer::get_singleton();
    r_item.shadow_on = p_on;
    if (p_group.params.low_lod_shadows) {
        server->instance_geometry_set_cast_shadows_setting(r_item.instance, RenderingServer::SHADOW_CASTING_SETTING_OFF);
        if (r_item.twin.is_valid()) {
            server->instance_set_visible(r_item.twin, p_on);
        }
        return;
    }
    const int setting = p_group.params.cast_shadows;
    if (setting == RenderingServer::SHADOW_CASTING_SETTING_SHADOWS_ONLY) {
        server->instance_geometry_set_cast_shadows_setting(r_item.instance, RenderingServer::SHADOW_CASTING_SETTING_SHADOWS_ONLY);
        server->instance_set_visible(r_item.instance, p_on);
        return;
    }
    server->instance_set_visible(r_item.instance, true);
    server->instance_geometry_set_cast_shadows_setting(r_item.instance,
            RenderingServer::ShadowCastingSetting(p_on ? setting : int(RenderingServer::SHADOW_CASTING_SETTING_OFF)));
}

// Whether an object casts: on within shadow_range of any position, off beyond shadow_range +
// shadow_range_margin of every position; in between it keeps p_current (hysteresis).
bool CopiaDrawer::in_shadow_range(const Group &p_group, int32_t p_index, bool p_current) const {
    if (p_group.params.shadow_range <= 0.0 || !has_camera) {
        return true;
    }
    const double on = p_group.params.shadow_range;
    const double off = on + std::max(0.0, p_group.params.shadow_range_margin);
    const Vector3 origin = item_origin(p_group, p_index);
    bool beyond_all = true;
    for (const Vector3 &position : cameras) {
        const double distance = origin.distance_to(position);
        if (distance <= on) {
            return true;
        }
        if (distance <= off) {
            beyond_all = false;
        }
    }
    return beyond_all ? false : p_current;
}

// Every setting of one created item except its transform.
void CopiaDrawer::apply_item(const Group &p_group, int32_t p_index, Item &r_item, bool p_all) {
    RenderingServer *server = RenderingServer::get_singleton();
    const Params &params = p_group.params;
    RenderingServer::InstanceFlags baked = RenderingServer::INSTANCE_FLAG_USE_BAKED_LIGHT;
    RenderingServer::InstanceFlags dynamic = RenderingServer::INSTANCE_FLAG_USE_DYNAMIC_GI;
    for (const RID &rid : { r_item.instance, r_item.twin }) {
        if (!rid.is_valid()) {
            continue;
        }
        const bool twin = rid == r_item.twin;
        server->instance_geometry_set_lod_bias(rid, twin ? 0.001f : float(params.lod_bias));
        server->instance_set_layer_mask(rid, params.layers);
        server->instance_geometry_set_flag(rid, baked, params.gi_mode == 1);
        server->instance_geometry_set_flag(rid, dynamic, params.gi_mode == 2);
        server->instance_set_extra_visibility_margin(rid, float(params.extra_cull_margin));
        server->instance_geometry_set_material_override(rid, params.material_override);
        if (twin) {
            server->instance_geometry_set_cast_shadows_setting(rid, RenderingServer::SHADOW_CASTING_SETTING_SHADOWS_ONLY);
        }
        server->instance_attach_object_instance_id(rid, params.object_id);
    }
    // At creation only when there are any; on a params update always, so removed ones are reset.
    if (!p_group.multimesh && (!p_all || !params.surface_materials.empty())) {
        apply_surface_materials(p_group, r_item.instance, !p_all);
    }
    apply_range(p_group, p_index, r_item);
    // A new object inside the hysteresis band starts without shadows: they turn on within range.
    apply_shadow(p_group, r_item, in_shadow_range(p_group, p_index, p_all ? false : r_item.shadow_on));
}

// Per-surface materials of a single instance. RenderingServer accepts them only on instances
// whose base is a mesh (a multimesh instance has no per-surface materials and the call fails), so
// multimesh groups never get here; CopiaObject draws those with a mesh carrying the materials.
void CopiaDrawer::apply_surface_materials(const Group &p_group, const RID &p_instance, bool p_reset) const {
    const Params &params = p_group.params;
    if (!params.mesh.is_valid() || !p_instance.is_valid()) {
        return;
    }
    RenderingServer *server = RenderingServer::get_singleton();
    const int64_t surfaces = server->mesh_get_surface_count(params.mesh);
    const int64_t given = int64_t(params.surface_materials.size());
    for (int64_t s = 0; s < surfaces; s++) {
        if (s < given) {
            server->instance_set_surface_override_material(p_instance, s, params.surface_materials[size_t(s)]);
        } else if (p_reset) {
            server->instance_set_surface_override_material(p_instance, s, RID());
        }
    }
}

// Whether an object of a group may take its impostor batch as visibility parent: always for a
// batch; for a single instance when its scale (the length of its basis Y column, as the build
// measures it) reaches impostor_min_scale, the scale from which the build gives it an impostor.
bool CopiaDrawer::impostor_eligible(const Group &p_group, int32_t p_index) const {
    if (p_group.multimesh || p_group.params.impostor_min_scale <= 0.0) {
        return true;
    }
    const float *values = p_group.transforms.ptr() + size_t(p_index) * 12;
    const double scale = std::sqrt(double(values[3]) * values[3] + double(values[4]) * values[4] + double(values[5]) * values[5]);
    return scale >= p_group.params.impostor_min_scale;
}

const CopiaDrawer::Group *CopiaDrawer::linked_impostor(const Group &p_child) const {
    if (p_child.impostor == 0) {
        return nullptr;
    }
    auto found = groups.find(p_child.impostor);
    return found == groups.end() ? nullptr : &found->second;
}

// The impostor batch that stands for object p_index of a linked child, or -1.
int32_t CopiaDrawer::child_batch(const Group &p_child, int32_t p_index) {
    if (p_child.impostor_batches.empty()) {
        return p_child.impostor_batch;
    }
    return p_index < int32_t(p_child.impostor_batches.size()) ? p_child.impostor_batches[size_t(p_index)] : -1;
}

bool CopiaDrawer::covers(const Group &p_child, int32_t p_batch) {
    return std::binary_search(p_child.linked_batches.begin(), p_child.linked_batches.end(), p_batch);
}

void CopiaDrawer::clear_link(Group &r_child) {
    r_child.impostor = 0;
    r_child.impostor_batch = 0;
    r_child.impostor_batches.clear();
    r_child.linked_batches.clear();
    r_child.swap_distance = 0.0;
}

RID CopiaDrawer::link_parent(const Group &p_child, int32_t p_index) const {
    const Group *impostor = linked_impostor(p_child);
    const int32_t batch = child_batch(p_child, p_index);
    if (impostor == nullptr || batch < 0 || batch >= impostor->created) {
        return RID();
    }
    return impostor->items[size_t(batch)].instance;
}

// Visibility range begin of an object: an impostor batch with linked children may hide near the
// camera (begin = swap distance) only while every linked child group is fully created; it keeps
// 0 while any is not, and after a linked child was removed until it is linked again.
double CopiaDrawer::effective_begin(const Group &p_group, int32_t p_index) const {
    bool linked = false;
    bool ready = true;
    double swap = 0.0;
    for (int64_t child_id : p_group.children) {
        auto found = groups.find(child_id);
        if (found == groups.end() || !covers(found->second, p_index)) {
            continue;
        }
        linked = true;
        ready = ready && found->second.ready();
        swap = std::max(swap, found->second.swap_distance);
    }
    if (linked) {
        return ready ? swap : 0.0;
    }
    if (p_group.held.count(p_index)) {
        return 0.0;
    }
    return p_group.params.visibility_begin;
}

// Range and visibility parent of one created object. A linked child's flagged objects take the
// impostor batch as visibility parent and no range of their own; the parent's begin decides.
void CopiaDrawer::apply_range(const Group &p_group, int32_t p_index, const Item &p_item) {
    RenderingServer *server = RenderingServer::get_singleton();
    const Params &params = p_group.params;
    const bool flagged = p_group.parented.is_empty() || p_group.parented[p_index] != 0;
    RID parent = flagged ? params.visibility_parent : RID();
    double begin = effective_begin(p_group, p_index);
    double end = params.visibility_end;
    double begin_margin = params.visibility_begin_margin;
    double end_margin = params.visibility_end_margin;
    if (flagged && p_group.impostor != 0 && impostor_eligible(p_group, p_index)) {
        RID impostor = link_parent(p_group, p_index);
        if (impostor.is_valid()) {
            parent = impostor;
            begin = end = begin_margin = end_margin = 0.0;
        }
    }
    for (const RID &rid : { p_item.instance, p_item.twin }) {
        if (rid.is_valid()) {
            server->instance_geometry_set_visibility_range(rid, float(begin), float(end), float(begin_margin),
                    float(end_margin), RenderingServer::VisibilityRangeFadeMode(params.fade_mode));
            server->instance_set_visibility_parent(rid, parent);
        }
    }
}

void CopiaDrawer::refresh_impostor_batch(int64_t p_impostor, int32_t p_batch) {
    auto found = groups.find(p_impostor);
    if (found == groups.end() || p_batch >= found->second.created) {
        return;
    }
    apply_range(found->second, p_batch, found->second.items[size_t(p_batch)]);
}

void CopiaDrawer::refresh_impostor_batches(int64_t p_impostor, const std::vector<int32_t> &p_batches) {
    for (int32_t batch : p_batches) {
        refresh_impostor_batch(p_impostor, batch);
    }
}

// Applies the range of every created object of the children of p_impostor that batch p_batch
// stands for.
void CopiaDrawer::refresh_children(const Group &p_impostor, int32_t p_batch) {
    for (int64_t child_id : p_impostor.children) {
        auto found = groups.find(child_id);
        if (found == groups.end() || !covers(found->second, p_batch)) {
            continue;
        }
        const Group &child = found->second;
        for (int32_t i = 0; i < child.created; i++) {
            if (child_batch(child, i) == p_batch) {
                apply_range(child, i, child.items[size_t(i)]);
            }
        }
    }
}

void CopiaDrawer::link_impostor(int64_t p_impostor_group, int64_t p_child_group, double p_swap_distance, const Variant &p_batch) {
    auto impostor_found = groups.find(p_impostor_group);
    auto child_found = groups.find(p_child_group);
    ERR_FAIL_COND_MSG(impostor_found == groups.end() || child_found == groups.end(), "CopiaDrawer: no such group.");
    const Group &impostor = impostor_found->second;
    ERR_FAIL_COND_MSG(!impostor.multimesh, "CopiaDrawer: the impostor group must be a multimesh group.");
    ERR_FAIL_COND_MSG(p_impostor_group == p_child_group, "CopiaDrawer: a group cannot be its own impostor.");
    ERR_FAIL_COND_MSG(p_swap_distance < 0.0, "CopiaDrawer: swap_distance must not be negative.");
    int32_t uniform = 0;
    std::vector<int32_t> per_object;
    if (p_batch.get_type() == Variant::INT) {
        uniform = int32_t(int64_t(p_batch));
        ERR_FAIL_INDEX_MSG(uniform, impostor.count, "CopiaDrawer: the impostor group has no such batch.");
    } else if (p_batch.get_type() == Variant::PACKED_INT32_ARRAY) {
        PackedInt32Array values = p_batch;
        ERR_FAIL_COND_MSG(values.size() != child_found->second.count,
                "CopiaDrawer: batch must hold one impostor batch per object of the child group.");
        per_object.resize(size_t(values.size()));
        for (int64_t i = 0; i < values.size(); i++) {
            ERR_FAIL_COND_MSG(values[i] < -1 || values[i] >= impostor.count, "CopiaDrawer: the impostor group has no such batch.");
            per_object[size_t(i)] = values[i];
        }
    } else {
        ERR_FAIL_MSG("CopiaDrawer: batch must be an int or a PackedInt32Array.");
    }
    if (child_found->second.impostor != 0) {
        unlink_impostor(child_found->second.impostor, p_child_group);
    }
    Group &child = groups.at(p_child_group);
    child.impostor = p_impostor_group;
    child.impostor_batch = per_object.empty() ? uniform : -1;
    child.impostor_batches = std::move(per_object);
    child.linked_batches.clear();
    if (child.impostor_batches.empty()) {
        child.linked_batches.push_back(uniform);
    } else {
        std::set<int32_t> unique(child.impostor_batches.begin(), child.impostor_batches.end());
        unique.erase(-1);
        child.linked_batches.assign(unique.begin(), unique.end());
    }
    child.swap_distance = p_swap_distance;
    Group &linked = groups.at(p_impostor_group);
    linked.children.push_back(p_child_group);
    for (int32_t batch : child.linked_batches) {
        linked.held.erase(batch);
    }
    // Children first (parented and hidden while the impostor's begin is 0), then the impostor's
    // begins; all in this call, so no frame sees one without the other.
    for (int32_t i = 0; i < child.created; i++) {
        apply_range(child, i, child.items[size_t(i)]);
    }
    refresh_impostor_batches(p_impostor_group, child.linked_batches);
}

void CopiaDrawer::unlink_impostor(int64_t p_impostor_group, int64_t p_child_group) {
    auto impostor_found = groups.find(p_impostor_group);
    auto child_found = groups.find(p_child_group);
    ERR_FAIL_COND_MSG(impostor_found == groups.end() || child_found == groups.end(), "CopiaDrawer: no such group.");
    Group &impostor = impostor_found->second;
    Group &child = child_found->second;
    ERR_FAIL_COND_MSG(child.impostor != p_impostor_group, "CopiaDrawer: the groups are not linked.");
    const std::vector<int32_t> batches = child.linked_batches;
    impostor.children.erase(std::remove(impostor.children.begin(), impostor.children.end(), p_child_group), impostor.children.end());
    clear_link(child);
    for (int32_t i = 0; i < child.created; i++) {
        apply_range(child, i, child.items[size_t(i)]);
    }
    refresh_impostor_batches(p_impostor_group, batches);
}

void CopiaDrawer::create_item(Group &p_group, int32_t p_index) {
    RenderingServer *server = RenderingServer::get_singleton();
    Item &item = p_group.items[size_t(p_index)];
    const Transform3D global = item_transform(p_group, p_index);
    if (p_group.multimesh) {
        const int32_t count = p_group.instance_counts[size_t(p_index)];
        item.multimesh = server->multimesh_create();
        server->multimesh_set_mesh(item.multimesh, p_group.params.mesh);
        server->multimesh_allocate_data(item.multimesh, count, RenderingServer::MULTIMESH_TRANSFORM_3D, true, true);
        server->multimesh_set_buffer(item.multimesh, p_group.buffers[size_t(p_index)]);
        server->multimesh_set_custom_aabb(item.multimesh, p_group.bounds[size_t(p_index)]);
        item.visible = visible_count(p_group, p_index);
        if (item.visible != count) {
            server->multimesh_set_visible_instances(item.multimesh, item.visible);
        }
        p_group.buffers[size_t(p_index)] = PackedFloat32Array();
        p_group.drawn += item.visible;
        drawn_instances += item.visible;
        live_multimeshes++;
        item.instance = server->instance_create2(item.multimesh, scenario);
        if (p_group.params.low_lod_shadows) {
            item.twin = server->instance_create2(item.multimesh, scenario);
            live_instances++;
        }
    } else {
        item.instance = server->instance_create2(p_group.params.mesh, scenario);
        p_group.drawn++;
        drawn_instances++;
    }
    live_instances++;
    server->instance_set_transform(item.instance, global);
    if (item.twin.is_valid()) {
        server->instance_set_transform(item.twin, global);
    }
    apply_item(p_group, p_index, item, true);
    if (!p_group.children.empty()) {
        // A new impostor batch becomes the visibility parent of its linked children.
        refresh_children(p_group, p_index);
    }
}

Dictionary CopiaDrawer::step(int64_t p_budget_usec) {
    const int64_t start = now_usec();
    int64_t created = 0;
    int64_t freed = 0;
    const int64_t budget = std::max<int64_t>(0, p_budget_usec);
    auto spent = [&]() { return now_usec() - start >= budget; };
    RenderingServer *server = RenderingServer::get_singleton();
    if (server != nullptr && budget > 0) {
        // Warm-up objects are freed once two frames have been drawn with them.
        if (!warm_ups.empty()) {
            const int64_t frame = Engine::get_singleton()->get_frames_drawn();
            const int64_t process_frame = int64_t(Engine::get_singleton()->get_process_frames());
            for (size_t i = 0; i < warm_ups.size();) {
                // Two drawn frames, or 60 process frames when nothing is drawn (headless).
                if (frame >= warm_ups[i].frame + 2 || process_frame >= warm_ups[i].process_frame + 60) {
                    free_unit({ warm_ups[i].instance, RID(), warm_ups[i].base });
                    warm_ups.erase(warm_ups.begin() + int64_t(i));
                } else {
                    i++;
                }
            }
        }
        // Frees first, then creations, nearest (lowest priority value) first. One object is
        // always done, so a budget below one object's cost still makes progress.
        bool first = true;
        while (!free_queue.empty() && (first || !spent())) {
            free_unit(free_queue.front());
            free_queue.pop_front();
            freed++;
            first = false;
        }
        while (!create_queue.empty() && (first || !spent())) {
            const auto key = *create_queue.begin();
            Group &group = groups.at(queued_by_sequence.at(key.second));
            create_item(group, group.created);
            group.created++;
            created++;
            first = false;
            if (group.created >= group.count) {
                dequeue(group);
                if (group.impostor != 0) {
                    // The last child object exists: the impostor may now hide near the camera.
                    refresh_impostor_batches(group.impostor, group.linked_batches);
                }
            }
        }
    }
    created_total += created;
    freed_total += freed;
    int64_t pending_create = 0;
    for (const auto &key : create_queue) {
        const Group &group = groups.at(queued_by_sequence.at(key.second));
        pending_create += group.count - group.created;
    }
    Dictionary result;
    result["created"] = created;
    result["freed"] = freed;
    result["pending_create"] = pending_create;
    result["pending_free"] = int64_t(free_queue.size());
    result["usec"] = now_usec() - start;
    return result;
}

void CopiaDrawer::set_group_params(int64_t p_group, const Dictionary &p_params) {
    auto found = groups.find(p_group);
    ERR_FAIL_COND_MSG(found == groups.end(), "CopiaDrawer: no such group.");
    apply_params(found->second, p_params);
}

void CopiaDrawer::set_groups_params(const PackedInt64Array &p_groups, const Dictionary &p_params) {
    for (int64_t i = 0; i < p_groups.size(); i++) {
        auto found = groups.find(p_groups[i]);
        if (found == groups.end()) {
            ERR_PRINT("CopiaDrawer: no such group: " + String::num_int64(p_groups[i]) + ".");
            continue;
        }
        apply_params(found->second, p_params);
    }
}

// Merges p_params into the group's params and applies to its created objects only the values that
// differ from the group's current ones, each with the RenderingServer calls that set it:
//   material_override: instance_geometry_set_material_override (object and twin)
//   lod_bias: instance_geometry_set_lod_bias (object; the twin keeps its own)
//   layers: instance_set_layer_mask; gi_mode: instance_geometry_set_flag x 2;
//   extra_cull_margin: instance_set_extra_visibility_margin; object_id:
//   instance_attach_object_instance_id (object and twin each)
//   visibility_*, fade_mode, visibility_parent, impostor_min_scale: instance_geometry_set_visibility_range
//     and instance_set_visibility_parent (object and twin)
//   cast_shadows, shadow_range, shadow_range_margin: the shadow state (instance_set_visible and
//     instance_geometry_set_cast_shadows_setting, or the twin's instance_set_visible)
//   surface_materials (single instances): mesh_get_surface_count and
//     instance_set_surface_override_material per surface
//   priority: none (creation order only)
// A change of mesh or low_lod_shadows re-applies every value, as the objects change base or twin.
void CopiaDrawer::apply_params(Group &p_group, const Dictionary &p_params) {
    Params next = p_group.params;
    read_params(p_params, next);
    const Params before = p_group.params;
    const bool requeue = p_group.queued && next.priority != before.priority;
    if (requeue) {
        dequeue(p_group);
    }
    p_group.params = next;
    if (requeue) {
        enqueue(p_group);
    }
    RenderingServer *server = RenderingServer::get_singleton();
    if (server == nullptr || p_group.created == 0) {
        return;
    }
    const bool full = next.mesh != before.mesh || next.low_lod_shadows != before.low_lod_shadows;
    const bool material = next.material_override != before.material_override;
    const bool lod = next.lod_bias != before.lod_bias;
    const bool layers = next.layers != before.layers;
    const bool gi = next.gi_mode != before.gi_mode;
    const bool margin = next.extra_cull_margin != before.extra_cull_margin;
    const bool object_id = next.object_id != before.object_id;
    const bool range = next.visibility_begin != before.visibility_begin || next.visibility_end != before.visibility_end ||
            next.visibility_begin_margin != before.visibility_begin_margin ||
            next.visibility_end_margin != before.visibility_end_margin || next.fade_mode != before.fade_mode ||
            next.visibility_parent != before.visibility_parent || next.impostor_min_scale != before.impostor_min_scale;
    const bool shadow = next.cast_shadows != before.cast_shadows || next.shadow_range != before.shadow_range ||
            next.shadow_range_margin != before.shadow_range_margin;
    const bool surfaces = !p_group.multimesh && next.surface_materials != before.surface_materials;
    if (!full && !material && !lod && !layers && !gi && !margin && !object_id && !range && !shadow && !surfaces) {
        return;
    }
    const RenderingServer::InstanceFlags baked = RenderingServer::INSTANCE_FLAG_USE_BAKED_LIGHT;
    const RenderingServer::InstanceFlags dynamic = RenderingServer::INSTANCE_FLAG_USE_DYNAMIC_GI;
    for (int32_t i = 0; i < p_group.created; i++) {
        Item &item = p_group.items[size_t(i)];
        if (full) {
            if (next.mesh != before.mesh) {
                if (p_group.multimesh) {
                    server->multimesh_set_mesh(item.multimesh, next.mesh);
                } else {
                    server->instance_set_base(item.instance, next.mesh);
                }
            }
            if (next.low_lod_shadows && !item.twin.is_valid() && item.multimesh.is_valid()) {
                item.twin = server->instance_create2(item.multimesh, scenario);
                server->instance_set_transform(item.twin, item_transform(p_group, i));
                live_instances++;
            } else if (!next.low_lod_shadows && item.twin.is_valid()) {
                server->free_rid(item.twin);
                item.twin = RID();
                live_instances--;
            }
            apply_item(p_group, i, item, false);
            continue;
        }
        for (const RID &rid : { item.instance, item.twin }) {
            if (!rid.is_valid()) {
                continue;
            }
            const bool twin = rid == item.twin;
            if (material) {
                server->instance_geometry_set_material_override(rid, next.material_override);
            }
            if (lod && !twin) {
                server->instance_geometry_set_lod_bias(rid, float(next.lod_bias));
            }
            if (layers) {
                server->instance_set_layer_mask(rid, next.layers);
            }
            if (gi) {
                server->instance_geometry_set_flag(rid, baked, next.gi_mode == 1);
                server->instance_geometry_set_flag(rid, dynamic, next.gi_mode == 2);
            }
            if (margin) {
                server->instance_set_extra_visibility_margin(rid, float(next.extra_cull_margin));
            }
            if (object_id) {
                server->instance_attach_object_instance_id(rid, next.object_id);
            }
        }
        if (surfaces) {
            apply_surface_materials(p_group, item.instance, true);
        }
        if (range) {
            apply_range(p_group, i, item);
        }
        if (shadow) {
            apply_shadow(p_group, item, in_shadow_range(p_group, i, item.shadow_on));
        }
    }
    if (full || shadow) {
        p_group.shadow_state = SHADOW_UNKNOWN;
    }
}

void CopiaDrawer::remove_group(int64_t p_group) {
    auto found = groups.find(p_group);
    ERR_FAIL_COND_MSG(found == groups.end(), "CopiaDrawer: no such group.");
    Group &group = found->second;
    dequeue(group);
    RenderingServer *server = RenderingServer::get_singleton();
    if (group.impostor != 0) {
        // A linked child: its impostor batch goes back to begin 0 now, before any of the
        // child's objects is freed (they stay parented and hidden until then).
        const int64_t impostor_id = group.impostor;
        const std::vector<int32_t> batches = group.linked_batches;
        auto impostor = groups.find(impostor_id);
        if (impostor != groups.end()) {
            std::vector<int64_t> &children = impostor->second.children;
            children.erase(std::remove(children.begin(), children.end(), p_group), children.end());
            impostor->second.held.insert(batches.begin(), batches.end());
        }
        clear_link(group);
        if (server != nullptr) {
            refresh_impostor_batches(impostor_id, batches);
        }
        found = groups.find(p_group);
    }
    Group &removed = found->second;
    if (!removed.children.empty()) {
        // An impostor with linked children: they are unparented and get their own range back,
        // and the impostor stops drawing now (its ids are freed later).
        std::vector<int64_t> children = removed.children;
        removed.children.clear();
        for (int64_t child_id : children) {
            auto child = groups.find(child_id);
            if (child == groups.end()) {
                continue;
            }
            clear_link(child->second);
            if (server != nullptr) {
                for (int32_t i = 0; i < child->second.created; i++) {
                    apply_range(child->second, i, child->second.items[size_t(i)]);
                }
            }
        }
        if (server != nullptr) {
            for (int32_t i = 0; i < removed.created; i++) {
                server->instance_set_visible(removed.items[size_t(i)].instance, false);
                if (removed.items[size_t(i)].twin.is_valid()) {
                    server->instance_set_visible(removed.items[size_t(i)].twin, false);
                }
            }
        }
    }
    for (int32_t i = 0; i < removed.created; i++) {
        const Item &item = removed.items[size_t(i)];
        free_queue.push_back({ item.instance, item.twin, item.multimesh });
    }
    drawn_instances -= removed.drawn;
    groups.erase(found);
}

void CopiaDrawer::evaluate_shadows(Group &p_group, bool p_force) {
    if (p_group.params.shadow_range <= 0.0 || p_group.created == 0) {
        return;
    }
    int target = SHADOW_MIXED;
    if (has_camera) {
        // The group's origins lie inside its bounds: when the whole box is inside the range of
        // one position, every object casts; when it is beyond range + margin of every position,
        // none does; either way no object needs a test. Otherwise each object is tested, keeping
        // its state inside the hysteresis band.
        const AABB box = transform.xform(p_group.local_bounds);
        const double off = p_group.params.shadow_range + std::max(0.0, p_group.params.shadow_range_margin);
        bool all_out = true;
        for (const Vector3 &position : cameras) {
            double near_distance, far_distance;
            box_distances(box, position, near_distance, far_distance);
            if (far_distance <= p_group.params.shadow_range) {
                target = SHADOW_ALL_ON;
                all_out = false;
                break;
            }
            if (near_distance <= off) {
                all_out = false;
            }
        }
        if (all_out) {
            target = SHADOW_ALL_OFF;
        }
    } else {
        target = SHADOW_ALL_ON;
    }
    if (target != SHADOW_MIXED && target == p_group.shadow_state && !p_force && p_group.created == p_group.count) {
        return;
    }
    for (int32_t i = 0; i < p_group.created; i++) {
        Item &item = p_group.items[size_t(i)];
        bool on = target == SHADOW_MIXED ? in_shadow_range(p_group, i, item.shadow_on) : target == SHADOW_ALL_ON;
        if (on != item.shadow_on || p_force) {
            apply_shadow(p_group, item, on);
        }
    }
    p_group.shadow_state = p_group.created == p_group.count ? target : SHADOW_UNKNOWN;
}

void CopiaDrawer::update_camera(const Vector3 &p_position) {
    PackedVector3Array positions;
    positions.push_back(p_position);
    update_cameras(positions);
}

void CopiaDrawer::update_cameras(const PackedVector3Array &p_positions) {
    cameras.assign(p_positions.ptr(), p_positions.ptr() + p_positions.size());
    has_camera = true;
    // No evaluation unless the number of positions changed or one of them moved by the epsilon.
    if (camera_evaluated && evaluated_cameras.size() == cameras.size()) {
        bool moved = false;
        for (size_t i = 0; i < cameras.size() && !moved; i++) {
            moved = evaluated_cameras[i].distance_to(cameras[i]) >= CAMERA_EPSILON;
        }
        if (!moved) {
            return;
        }
    }
    camera_evaluated = true;
    evaluated_cameras = cameras;
    for (auto &entry : groups) {
        evaluate_shadows(entry.second, false);
    }
}

void CopiaDrawer::apply_density(Group &p_group) {
    RenderingServer *server = RenderingServer::get_singleton();
    if (server == nullptr || !p_group.multimesh) {
        return;
    }
    for (int32_t i = 0; i < p_group.created; i++) {
        Item &item = p_group.items[size_t(i)];
        int32_t visible = visible_count(p_group, i);
        if (visible != item.visible) {
            p_group.drawn += visible - item.visible;
            drawn_instances += visible - item.visible;
            item.visible = visible;
            server->multimesh_set_visible_instances(item.multimesh,
                    visible == p_group.instance_counts[size_t(i)] ? -1 : visible);
        }
    }
}

void CopiaDrawer::set_density(double p_fraction) {
    density = std::min(1.0, std::max(0.0, p_fraction));
    for (auto &entry : groups) {
        apply_density(entry.second);
    }
}

double CopiaDrawer::get_density() const {
    return density;
}

void CopiaDrawer::set_group_density(int64_t p_group, double p_fraction) {
    auto found = groups.find(p_group);
    ERR_FAIL_COND_MSG(found == groups.end(), "CopiaDrawer: no such group.");
    Group &group = found->second;
    const double fraction = std::min(1.0, std::max(0.0, p_fraction));
    if (fraction == group.density) {
        return;
    }
    group.density = fraction;
    apply_density(group);
}

double CopiaDrawer::get_group_density(int64_t p_group) const {
    auto found = groups.find(p_group);
    ERR_FAIL_COND_V_MSG(found == groups.end(), 1.0, "CopiaDrawer: no such group.");
    return found->second.density;
}

TypedArray<RID> CopiaDrawer::get_group_rids(int64_t p_group) const {
    TypedArray<RID> result;
    auto found = groups.find(p_group);
    ERR_FAIL_COND_V_MSG(found == groups.end(), result, "CopiaDrawer: no such group.");
    const Group &group = found->second;
    for (int32_t i = 0; i < group.created; i++) {
        result.push_back(group.items[size_t(i)].instance);
    }
    return result;
}

Dictionary CopiaDrawer::get_group_info(int64_t p_group) const {
    Dictionary result;
    auto found = groups.find(p_group);
    if (found == groups.end()) {
        return result;
    }
    const Group &group = found->second;
    result["id"] = group.id;
    result["kind"] = group.multimesh ? "multimesh" : "instance";
    result["state"] = group.created == group.count ? "created" : (group.created == 0 ? "queued" : "partial");
    result["count"] = group.count;
    result["created"] = group.created;
    result["instance_count"] = group.instance_total;
    result["density"] = group.density;
    result["params"] = params_dictionary(group.params);
    result["bounds"] = group.local_bounds;
    int64_t shadows_on = 0;
    PackedInt32Array visible;
    for (int32_t i = 0; i < group.created; i++) {
        const Item &item = group.items[size_t(i)];
        shadows_on += item.shadow_on ? 1 : 0;
        if (group.multimesh) {
            visible.push_back(item.visible);
        }
    }
    result["shadows_on"] = shadows_on;
    if (group.multimesh) {
        result["visible_counts"] = visible;
    }
    result["ready"] = group.ready();
    // Visibility range begin each created object has now (an impostor's swap state).
    PackedFloat32Array begins;
    for (int32_t i = 0; i < group.created; i++) {
        const bool linked_child = group.impostor != 0 && link_parent(group, i).is_valid() &&
                (group.parented.is_empty() || group.parented[i] != 0) && impostor_eligible(group, i);
        begins.push_back(float(linked_child ? 0.0 : effective_begin(group, i)));
    }
    result["visibility_begins"] = begins;
    if (group.impostor != 0) {
        Dictionary link;
        link["impostor"] = group.impostor;
        link["batch"] = group.impostor_batch;
        if (!group.impostor_batches.empty()) {
            PackedInt32Array batches;
            for (int32_t batch : group.impostor_batches) {
                batches.push_back(batch);
            }
            link["batches"] = batches;
        }
        link["swap_distance"] = group.swap_distance;
        link["parent"] = group.impostor_batches.empty() ? link_parent(group, 0) : RID();
        result["impostor_link"] = link;
    }
    PackedInt64Array children;
    for (int64_t child : group.children) {
        children.push_back(child);
    }
    result["linked_children"] = children;
    return result;
}

int64_t CopiaDrawer::get_group_count() const {
    return int64_t(groups.size());
}

Dictionary CopiaDrawer::get_stats() const {
    int64_t pending_create = 0;
    int64_t queued = 0;
    for (const auto &entry : groups) {
        pending_create += entry.second.count - entry.second.created;
        queued += entry.second.queued ? 1 : 0;
    }
    Dictionary result;
    result["groups"] = int64_t(groups.size());
    result["queued_groups"] = queued;
    result["objects"] = live_instances;
    result["instances"] = drawn_instances;
    result["multimeshes"] = live_multimeshes;
    result["pending_create"] = pending_create;
    result["pending_free"] = int64_t(free_queue.size());
    result["warm_up"] = int64_t(warm_ups.size());
    result["created_total"] = created_total;
    result["freed_total"] = freed_total;
    return result;
}

void CopiaDrawer::warm_up(const RID &p_mesh, const RID &p_material, bool p_uses_color, bool p_uses_custom) {
    RenderingServer *server = RenderingServer::get_singleton();
    ERR_FAIL_NULL(server);
    // Drawn for two frames, never culled (huge bounds), shrunk to nothing at the camera (or the
    // store's origin before update_camera()), casting shadows so the shadow pipelines compile too.
    const Vector3 at = !cameras.empty() ? cameras[0] : transform.origin;
    const Transform3D place(Basis().scaled(Vector3(1e-4, 1e-4, 1e-4)), at);
    const AABB everywhere(Vector3(-1e5, -1e5, -1e5), Vector3(2e5, 2e5, 2e5));
    const int64_t frame = Engine::get_singleton()->get_frames_drawn();
    const int64_t process_frame = int64_t(Engine::get_singleton()->get_process_frames());

    RID multimesh = server->multimesh_create();
    server->multimesh_set_mesh(multimesh, p_mesh);
    server->multimesh_allocate_data(multimesh, 1, RenderingServer::MULTIMESH_TRANSFORM_3D, p_uses_color, p_uses_custom);
    PackedFloat32Array buffer;
    buffer.resize(12 + (p_uses_color ? 4 : 0) + (p_uses_custom ? 4 : 0));
    float *write = buffer.ptrw();
    const float identity[12] = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0 };
    std::copy(identity, identity + 12, write);
    int64_t at_float = 12;
    if (p_uses_color) {
        write[at_float++] = 1;
        write[at_float++] = 1;
        write[at_float++] = 1;
        write[at_float++] = 1;
    }
    if (p_uses_custom) {
        for (int k = 0; k < 4; k++) {
            write[at_float++] = 0;
        }
    }
    server->multimesh_set_buffer(multimesh, buffer);
    server->multimesh_set_custom_aabb(multimesh, everywhere);
    live_multimeshes++;
    RID batch = server->instance_create2(multimesh, scenario);
    RID single = server->instance_create2(p_mesh, scenario);
    live_instances += 2;
    for (const RID &rid : { batch, single }) {
        server->instance_set_transform(rid, place);
        server->instance_geometry_set_material_override(rid, p_material);
        server->instance_geometry_set_cast_shadows_setting(rid, RenderingServer::SHADOW_CASTING_SETTING_ON);
    }
    server->instance_set_custom_aabb(single, everywhere);
    warm_ups.push_back({ batch, multimesh, frame, process_frame });
    warm_ups.push_back({ single, RID(), frame, process_frame });
}

void CopiaDrawer::_bind_methods() {
    ClassDB::bind_method(D_METHOD("set_scenario", "scenario"), &CopiaDrawer::set_scenario);
    ClassDB::bind_method(D_METHOD("get_scenario"), &CopiaDrawer::get_scenario);
    ClassDB::bind_method(D_METHOD("set_transform", "transform"), &CopiaDrawer::set_transform);
    ClassDB::bind_method(D_METHOD("get_transform"), &CopiaDrawer::get_transform);
    ClassDB::bind_method(D_METHOD("add_multimesh_group", "section", "params"), &CopiaDrawer::add_multimesh_group, DEFVAL(Dictionary()));
    ClassDB::bind_method(D_METHOD("add_instance_group", "section", "params"), &CopiaDrawer::add_instance_group, DEFVAL(Dictionary()));
    ClassDB::bind_method(D_METHOD("set_group_params", "group", "params"), &CopiaDrawer::set_group_params);
    ClassDB::bind_method(D_METHOD("set_groups_params", "groups", "params"), &CopiaDrawer::set_groups_params);
    ClassDB::bind_method(D_METHOD("remove_group", "group"), &CopiaDrawer::remove_group);
    ClassDB::bind_method(D_METHOD("step", "budget_usec"), &CopiaDrawer::step);
    ClassDB::bind_method(D_METHOD("update_camera", "position"), &CopiaDrawer::update_camera);
    ClassDB::bind_method(D_METHOD("update_cameras", "positions"), &CopiaDrawer::update_cameras);
    ClassDB::bind_method(D_METHOD("set_density", "fraction"), &CopiaDrawer::set_density);
    ClassDB::bind_method(D_METHOD("get_density"), &CopiaDrawer::get_density);
    ClassDB::bind_method(D_METHOD("set_group_density", "group", "fraction"), &CopiaDrawer::set_group_density);
    ClassDB::bind_method(D_METHOD("get_group_density", "group"), &CopiaDrawer::get_group_density);
    ClassDB::bind_method(D_METHOD("get_group_rids", "group"), &CopiaDrawer::get_group_rids);
    ClassDB::bind_method(D_METHOD("get_group_info", "group"), &CopiaDrawer::get_group_info);
    ClassDB::bind_method(D_METHOD("get_group_count"), &CopiaDrawer::get_group_count);
    ClassDB::bind_method(D_METHOD("get_stats"), &CopiaDrawer::get_stats);
    ClassDB::bind_method(D_METHOD("warm_up", "mesh", "material", "uses_color", "uses_custom"), &CopiaDrawer::warm_up,
            DEFVAL(RID()), DEFVAL(true), DEFVAL(true));
    ClassDB::bind_method(D_METHOD("link_impostor", "impostor_group", "child_group", "swap_distance", "batch"),
            &CopiaDrawer::link_impostor, DEFVAL(0));
    ClassDB::bind_method(D_METHOD("unlink_impostor", "impostor_group", "child_group"), &CopiaDrawer::unlink_impostor);
    ADD_PROPERTY(PropertyInfo(Variant::RID, "scenario"), "set_scenario", "get_scenario");
    ADD_PROPERTY(PropertyInfo(Variant::TRANSFORM3D, "transform"), "set_transform", "get_transform");
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "density"), "set_density", "get_density");
}

} // namespace Copia
