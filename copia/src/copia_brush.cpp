#include "copia_brush.h"

#include "copia_format.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/basis.hpp>
#include <godot_cpp/variant/color.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/quaternion.hpp>

#include <algorithm>
#include <cmath>
#include <limits>
#include <set>

using namespace godot;

namespace Copia {

namespace {

constexpr double PI_D = 3.14159265358979323846;
constexpr double TAU_D = 6.28318530717958647692;
constexpr double RAD_TO_DEG_D = 180.0 / PI_D;
constexpr double DEG_TO_RAD_D = PI_D / 180.0;

// Deterministic fast PRNG (SplitMix64) for brush sampling.
struct Rng {
    uint64_t state;
    explicit Rng(uint64_t p_seed) : state(p_seed ? p_seed : 0x9E3779B97F4A7C15ULL) {}
    uint64_t next_u64() {
        uint64_t z = (state += 0x9E3779B97F4A7C15ULL);
        z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL;
        z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL;
        return z ^ (z >> 31);
    }
    double next_f() {
        return double(next_u64() >> 11) * (1.0 / 9007199254740992.0);
    }
    double range(double p_min, double p_max) {
        return p_min + (p_max - p_min) * next_f();
    }
};

struct DabSpec {
    std::string object_path;
    double weight = 1.0;
    std::vector<float> band_curve;
    double band_min = 0.0;
    double band_max = 1.0;
    double min_spacing = 0.0;
    double scale_min = 1.0;
    double scale_max = 1.0;
    double scale_jitter = 0.0;
    double align_normal = 0.0;
    bool random_yaw = true;
    double random_tilt_deg = 0.0;
    double slope_min_deg = 0.0;
    double slope_max_deg = 90.0;
    double y_offset_min = 0.0;
    double y_offset_max = 0.0;
    double keep_min = 0.85;
    double keep_max = 1.0;
    bool use_color = false;
    Color color_a = Color(1, 1, 1, 1);
    Color color_b = Color(1, 1, 1, 1);
    bool preserve_alpha = true;
    float default_alpha = 1.0f;
    bool use_custom = false;
    Color custom = Color(0, 0, 0, 0);
};

double eval_band(const DabSpec &p_spec, double p_t) {
    double t = std::clamp(p_t, 0.0, 1.0);
    if (!p_spec.band_curve.empty()) {
        if (p_spec.band_curve.size() == 1) {
            return std::max(0.0, double(p_spec.band_curve[0]));
        }
        double scaled = t * double(p_spec.band_curve.size() - 1);
        size_t i0 = size_t(std::floor(scaled));
        size_t i1 = std::min(i0 + 1, p_spec.band_curve.size() - 1);
        double frac = scaled - double(i0);
        double v = double(p_spec.band_curve[i0]) * (1.0 - frac) + double(p_spec.band_curve[i1]) * frac;
        return std::max(0.0, v);
    }
    if (t < p_spec.band_min || t > p_spec.band_max) {
        return 0.0;
    }
    return 1.0;
}

float quiet_nan_f() {
    float v = 0.0f;
    std::memcpy(&v, &NONE_BITS, 4);
    return v;
}

Transform3D transform_from_arr(const float *p_t) {
    Basis b;
    b.set_column(0, Vector3(p_t[0], p_t[1], p_t[2]));
    b.set_column(1, Vector3(p_t[3], p_t[4], p_t[5]));
    b.set_column(2, Vector3(p_t[6], p_t[7], p_t[8]));
    return Transform3D(b, Vector3(p_t[9], p_t[10], p_t[11]));
}

void write_transform_arr(const Transform3D &p_xform, float *r_out) {
    Vector3 cx = p_xform.basis.get_column(0);
    Vector3 cy = p_xform.basis.get_column(1);
    Vector3 cz = p_xform.basis.get_column(2);
    Vector3 o = p_xform.origin;
    r_out[0] = float(cx.x); r_out[1] = float(cx.y); r_out[2] = float(cx.z);
    r_out[3] = float(cy.x); r_out[4] = float(cy.y); r_out[5] = float(cy.z);
    r_out[6] = float(cz.x); r_out[7] = float(cz.y); r_out[8] = float(cz.z);
    r_out[9] = float(o.x);  r_out[10] = float(o.y); r_out[11] = float(o.z);
}

// Slab ray-AABB intersection in local space; returns true if hit in [0, p_max_t].
bool ray_aabb(const Vector3 &p_origin, const Vector3 &p_dir, const AABB &p_box, double p_max_t, double &r_t) {
    double tmin = 0.0;
    double tmax = p_max_t;
    for (int axis = 0; axis < 3; axis++) {
        double o = p_origin[axis];
        double d = p_dir[axis];
        double bmin = p_box.position[axis];
        double bmax = bmin + p_box.size[axis];
        if (std::fabs(d) < 1e-9) {
            if (o < bmin || o > bmax) {
                return false;
            }
        } else {
            double inv = 1.0 / d;
            double t1 = (bmin - o) * inv;
            double t2 = (bmax - o) * inv;
            if (t1 > t2) {
                std::swap(t1, t2);
            }
            tmin = std::max(tmin, t1);
            tmax = std::min(tmax, t2);
            if (tmin > tmax) {
                return false;
            }
        }
    }
    r_t = tmin;
    return tmax >= 0.0 && tmin <= p_max_t;
}

double lookup_radius(const Dictionary &p_radii, const std::string &p_path) {
    if (p_radii.is_empty()) {
        return 0.0;
    }
    Variant v = p_radii.get(to_godot(p_path), Variant());
    if (v.get_type() == Variant::FLOAT || v.get_type() == Variant::INT) {
        return std::max(0.0, double(v));
    }
    return 0.0;
}

} // namespace

uint64_t CopiaBrush::bucket_key(int32_t p_bx, int32_t p_bz) {
    return (uint64_t(uint32_t(p_bx)) << 32) | uint64_t(uint32_t(p_bz));
}

int32_t CopiaBrush::bucket_coord(double p_v) const {
    return int32_t(std::floor(p_v / bucket_size));
}

void CopiaBrush::clear() {
    entries.clear();
    grid.clear();
    max_entry_radius = 0.0;
}

void CopiaBrush::set_bucket_size(double p_size) {
    if (std::isfinite(p_size) && p_size > 0.1) {
        bucket_size = p_size;
        grid.clear();
        for (size_t i = 0; i < entries.size(); i++) {
            const Entry &e = entries[i];
            int32_t bx = bucket_coord(double(e.transform[9]));
            int32_t bz = bucket_coord(double(e.transform[11]));
            grid[bucket_key(bx, bz)].push_back(int32_t(i));
        }
    }
}

double CopiaBrush::get_bucket_size() const {
    return bucket_size;
}

int64_t CopiaBrush::get_point_count() const {
    return int64_t(entries.size());
}

void CopiaBrush::insert_entry(Entry &&p_entry) {
    int32_t idx = int32_t(entries.size());
    int32_t bx = bucket_coord(double(p_entry.transform[9]));
    int32_t bz = bucket_coord(double(p_entry.transform[11]));
    if (double(p_entry.radius) > max_entry_radius) {
        max_entry_radius = double(p_entry.radius);
    }
    entries.push_back(std::move(p_entry));
    grid[bucket_key(bx, bz)].push_back(idx);
}

int64_t CopiaBrush::load_points(const Dictionary &p_points, bool p_editable, const Dictionary &p_object_radii) {
    if (p_points.is_empty()) {
        return 0;
    }
    Variant tv = p_points.get("transform", Variant());
    Variant ov = p_points.get("object", Variant());
    Variant pv = p_points.get("object_paths", Variant());
    if (tv.get_type() != Variant::PACKED_FLOAT32_ARRAY || ov.get_type() != Variant::PACKED_INT32_ARRAY ||
            pv.get_type() != Variant::PACKED_STRING_ARRAY) {
        return 0;
    }
    PackedFloat32Array transforms = tv;
    PackedInt32Array objects = ov;
    PackedStringArray object_paths = pv;
    int64_t n = objects.size();
    if (n == 0 || transforms.size() != n * 12) {
        return 0;
    }
    PackedInt32Array sets;
    PackedStringArray set_names;
    bool has_sets = false;
    if (p_points.has("set") && p_points.has("set_names")) {
        sets = p_points["set"];
        set_names = p_points["set_names"];
        has_sets = sets.size() == n;
    }
    PackedFloat32Array colors, customs, keeps;
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
    bool has_keep = p_points.has("keep") && p_points["keep"].get_type() == Variant::PACKED_FLOAT32_ARRAY;
    if (has_keep) {
        keeps = p_points["keep"];
        has_keep = keeps.size() == n;
    }

    std::vector<std::string> path_cache(size_t(object_paths.size()));
    std::vector<float> radius_cache(size_t(object_paths.size()), 0.0f);
    for (int64_t i = 0; i < object_paths.size(); i++) {
        path_cache[size_t(i)] = to_std(object_paths[i]);
        radius_cache[size_t(i)] = float(lookup_radius(p_object_radii, path_cache[size_t(i)]));
    }
    std::vector<std::string> set_cache(size_t(set_names.size()));
    for (int64_t i = 0; i < set_names.size(); i++) {
        set_cache[size_t(i)] = to_std(set_names[i]);
    }

    const float *tptr = transforms.ptr();
    const int32_t *optr = objects.ptr();
    const int32_t *sptr = has_sets ? sets.ptr() : nullptr;
    const float *cptr = has_color ? colors.ptr() : nullptr;
    const float *uptr = has_custom ? customs.ptr() : nullptr;
    const float *kptr = has_keep ? keeps.ptr() : nullptr;
    const float nan_f = quiet_nan_f();

    int64_t added = 0;
    entries.reserve(entries.size() + size_t(n));
    for (int64_t i = 0; i < n; i++) {
        int32_t oid = optr[i];
        if (oid < 0 || oid >= int32_t(path_cache.size())) {
            continue;
        }
        Entry e;
        e.object_path = path_cache[size_t(oid)];
        e.radius = radius_cache[size_t(oid)];
        if (sptr && sptr[i] >= 0 && sptr[i] < int32_t(set_cache.size())) {
            e.set_name = set_cache[size_t(sptr[i])];
        } else {
            e.set_name = "default";
        }
        std::memcpy(e.transform, tptr + i * 12, 48);
        if (cptr && !std::isnan(cptr[i * 4])) {
            std::memcpy(e.color, cptr + i * 4, 16);
            e.has_color = true;
        } else {
            e.color[0] = e.color[1] = e.color[2] = e.color[3] = nan_f;
            e.has_color = false;
        }
        if (uptr && !std::isnan(uptr[i * 4])) {
            std::memcpy(e.custom, uptr + i * 4, 16);
            e.has_custom = true;
        } else {
            e.custom[0] = e.custom[1] = e.custom[2] = e.custom[3] = nan_f;
            e.has_custom = false;
        }
        e.keep = kptr ? kptr[i] : 1.0f;
        e.editable = p_editable;
        e.staging = false;
        e.erased = false;
        insert_entry(std::move(e));
        added++;
    }
    return added;
}

int64_t CopiaBrush::add_staging_points(const Dictionary &p_points, const String &p_set, const Dictionary &p_object_radii) {
    size_t before = entries.size();
    Dictionary copy = p_points.duplicate();
    int64_t n = 0;
    if (copy.has("object") && copy["object"].get_type() == Variant::PACKED_INT32_ARRAY) {
        n = PackedInt32Array(copy["object"]).size();
    }
    if (n == 0) {
        return 0;
    }
    PackedInt32Array set_idx;
    set_idx.resize(n);
    set_idx.fill(0);
    PackedStringArray set_names;
    set_names.push_back(p_set);
    copy["set"] = set_idx;
    copy["set_names"] = set_names;
    int64_t added = load_points(copy, true, p_object_radii);
    for (size_t i = before; i < entries.size(); i++) {
        entries[i].staging = true;
    }
    return added;
}

bool CopiaBrush::is_occupied(const Vector3 &p_pos, double p_min_spacing, bool p_check_avoidance) const {
    if (entries.empty()) {
        return false;
    }
    double search_r = std::max(p_min_spacing, max_entry_radius);
    if (search_r <= 0.0) {
        return false;
    }
    int32_t min_bx = bucket_coord(double(p_pos.x) - search_r);
    int32_t max_bx = bucket_coord(double(p_pos.x) + search_r);
    int32_t min_bz = bucket_coord(double(p_pos.z) - search_r);
    int32_t max_bz = bucket_coord(double(p_pos.z) + search_r);
    for (int32_t bx = min_bx; bx <= max_bx; bx++) {
        for (int32_t bz = min_bz; bz <= max_bz; bz++) {
            auto it = grid.find(bucket_key(bx, bz));
            if (it == grid.end()) {
                continue;
            }
            for (int32_t idx : it->second) {
                const Entry &e = entries[size_t(idx)];
                if (e.erased) {
                    continue;
                }
                if (!p_check_avoidance && !e.editable) {
                    continue;
                }
                double req = std::max(p_min_spacing, double(e.radius));
                if (req <= 0.0) {
                    continue;
                }
                double dx = double(p_pos.x) - double(e.transform[9]);
                double dy = double(p_pos.y) - double(e.transform[10]);
                double dz = double(p_pos.z) - double(e.transform[11]);
                if (dx * dx + dy * dy + dz * dz < req * req) {
                    return true;
                }
            }
        }
    }
    return false;
}

Dictionary CopiaBrush::sample_dab(const Dictionary &p_hits, const Array &p_specs, const Dictionary &p_options) {
    Dictionary out;
    out["count"] = 0;
    out["transform"] = PackedFloat32Array();
    out["object"] = PackedInt32Array();
    out["object_paths"] = PackedStringArray();
    if (p_hits.is_empty() || p_specs.is_empty()) {
        return out;
    }
    Variant pos_v = p_hits.get("positions", Variant());
    Variant norm_v = p_hits.get("normals", Variant());
    if (pos_v.get_type() != Variant::PACKED_VECTOR3_ARRAY || norm_v.get_type() != Variant::PACKED_VECTOR3_ARRAY) {
        return out;
    }
    PackedVector3Array positions = pos_v;
    PackedVector3Array normals = norm_v;
    int64_t hit_count = positions.size();
    if (hit_count == 0 || normals.size() != hit_count) {
        return out;
    }
    PackedFloat32Array radial_t;
    bool has_radial = p_hits.has("radial_t") && p_hits["radial_t"].get_type() == Variant::PACKED_FLOAT32_ARRAY;
    if (has_radial) {
        radial_t = p_hits["radial_t"];
        has_radial = radial_t.size() == hit_count;
    }

    // Parse specs once per dab.
    std::vector<DabSpec> specs;
    specs.reserve(size_t(p_specs.size()));
    for (int64_t i = 0; i < p_specs.size(); i++) {
        if (p_specs[i].get_type() != Variant::DICTIONARY) {
            continue;
        }
        Dictionary d = p_specs[i];
        DabSpec s;
        s.object_path = to_std(String(d.get("object_path", String())));
        if (s.object_path.empty()) {
            continue;
        }
        s.weight = std::max(0.0, double(d.get("weight", 1.0)));
        if (s.weight <= 0.0) {
            continue;
        }
        Variant curve_v = d.get("band_curve", Variant());
        if (curve_v.get_type() == Variant::PACKED_FLOAT32_ARRAY) {
            PackedFloat32Array lut = curve_v;
            s.band_curve.assign(lut.ptr(), lut.ptr() + lut.size());
        }
        s.band_min = double(d.get("band_min", 0.0));
        s.band_max = double(d.get("band_max", 1.0));
        s.min_spacing = std::max(0.0, double(d.get("min_spacing", 0.0)));
        s.scale_min = std::max(0.001, double(d.get("scale_min", 1.0)));
        s.scale_max = std::max(s.scale_min, double(d.get("scale_max", s.scale_min)));
        s.scale_jitter = std::clamp(double(d.get("scale_jitter", 0.0)), 0.0, 0.9);
        s.align_normal = std::clamp(double(d.get("align_normal", 0.0)), 0.0, 1.0);
        s.random_yaw = bool(d.get("random_yaw", true));
        s.random_tilt_deg = std::max(0.0, double(d.get("random_tilt_deg", 0.0)));
        s.slope_min_deg = std::clamp(double(d.get("slope_min_deg", 0.0)), 0.0, 180.0);
        s.slope_max_deg = std::clamp(double(d.get("slope_max_deg", 90.0)), s.slope_min_deg, 180.0);
        s.y_offset_min = double(d.get("y_offset_min", 0.0));
        s.y_offset_max = double(d.get("y_offset_max", s.y_offset_min));
        s.keep_min = std::clamp(double(d.get("keep_min", 0.85)), 0.0, 1.0);
        s.keep_max = std::clamp(double(d.get("keep_max", 1.0)), s.keep_min, 1.0);
        s.use_color = bool(d.get("use_color", false));
        if (s.use_color) {
            s.color_a = d.get("color_a", Color(1, 1, 1, 1));
            s.color_b = d.get("color_b", s.color_a);
            s.preserve_alpha = bool(d.get("preserve_alpha", true));
            s.default_alpha = float(double(d.get("default_alpha", 1.0)));
        }
        s.use_custom = bool(d.get("use_custom", false));
        if (s.use_custom) {
            s.custom = d.get("custom", Color(0, 0, 0, 0));
        }
        specs.push_back(std::move(s));
    }
    if (specs.empty()) {
        return out;
    }

    uint64_t seed = uint64_t(int64_t(p_options.get("seed", int64_t(1))));
    double spacing_scale = std::max(0.0, double(p_options.get("spacing_scale", 1.0)));
    bool check_avoidance = bool(p_options.get("check_avoidance", true));
    bool add_to_staging = bool(p_options.get("add_to_staging", true));
    std::string set_name = to_std(String(p_options.get("set_name", String("handpainted"))));
    Rng rng(seed);

    std::vector<double> weights(specs.size(), 0.0);
    std::unordered_map<std::string, int32_t> path_to_idx;
    PackedStringArray object_paths;
    PackedFloat32Array out_transform;
    PackedInt32Array out_object;
    PackedFloat32Array out_color;
    PackedFloat32Array out_custom;
    PackedFloat32Array out_keep;
    bool any_color = false;
    bool any_custom = false;
    const float nan_f = quiet_nan_f();
    int64_t accepted = 0;

    for (int64_t h = 0; h < hit_count; h++) {
        Vector3 pos = positions[h];
        Vector3 n = normals[h];
        if (!pos.is_finite() || !n.is_finite() || n.length_squared() < 1e-8f) {
            continue;
        }
        n.normalize();
        double slope_deg = std::acos(std::clamp(double(n.y), -1.0, 1.0)) * RAD_TO_DEG_D;
        double rt = has_radial ? double(radial_t[h]) : 1.0;

        double total_w = 0.0;
        for (size_t s = 0; s < specs.size(); s++) {
            const DabSpec &spec = specs[s];
            if (slope_deg < spec.slope_min_deg || slope_deg > spec.slope_max_deg) {
                weights[s] = 0.0;
                continue;
            }
            double w = spec.weight * eval_band(spec, rt);
            weights[s] = w;
            total_w += w;
        }
        if (total_w <= 0.0) {
            continue;
        }

        double pick = rng.next_f() * total_w;
        size_t chosen = specs.size() - 1;
        double acc = 0.0;
        for (size_t s = 0; s < specs.size(); s++) {
            acc += weights[s];
            if (pick <= acc && weights[s] > 0.0) {
                chosen = s;
                break;
            }
        }
        const DabSpec &spec = specs[chosen];
        double spacing = spec.min_spacing * spacing_scale;
        if (spacing > 0.0 && is_occupied(pos, spacing, check_avoidance)) {
            continue;
        }

        // Build transform: align up to normal, random yaw, optional random tilt, scale + jitter.
        Vector3 up = Vector3(0, 1, 0).lerp(n, real_t(spec.align_normal));
        if (up.length_squared() < 1e-8f) {
            up = Vector3(0, 1, 0);
        } else {
            up.normalize();
        }
        Quaternion align_q(Vector3(0, 1, 0), up);
        double yaw = spec.random_yaw ? rng.next_f() * TAU_D : 0.0;
        Quaternion yaw_q(Vector3(0, 1, 0), real_t(yaw));
        Quaternion tilt_q;
        if (spec.random_tilt_deg > 0.0) {
            double tilt_rad = rng.range(0.0, spec.random_tilt_deg) * DEG_TO_RAD_D;
            double tilt_az = rng.next_f() * TAU_D;
            Vector3 tilt_axis(real_t(std::cos(tilt_az)), 0.0f, real_t(std::sin(tilt_az)));
            tilt_q = Quaternion(tilt_axis, real_t(tilt_rad));
        }
        Basis basis(align_q * tilt_q * yaw_q);
        double uniform_scale = rng.range(spec.scale_min, spec.scale_max);
        double sx = uniform_scale;
        double sy = uniform_scale;
        double sz = uniform_scale;
        if (spec.scale_jitter > 0.0) {
            sx *= rng.range(1.0 - spec.scale_jitter, 1.0 + spec.scale_jitter);
            sy *= rng.range(1.0 - spec.scale_jitter, 1.0 + spec.scale_jitter);
            sz *= rng.range(1.0 - spec.scale_jitter, 1.0 + spec.scale_jitter);
        }
        basis.scale_local(Vector3(real_t(sx), real_t(sy), real_t(sz)));
        double y_off = rng.range(spec.y_offset_min, spec.y_offset_max);
        Vector3 final_pos = pos + up * real_t(y_off);
        Transform3D xform(basis, final_pos);

        float tarr[12];
        write_transform_arr(xform, tarr);
        for (int k = 0; k < 12; k++) {
            out_transform.push_back(tarr[k]);
        }

        int32_t oid = 0;
        auto pit = path_to_idx.find(spec.object_path);
        if (pit == path_to_idx.end()) {
            oid = int32_t(object_paths.size());
            path_to_idx[spec.object_path] = oid;
            object_paths.push_back(to_godot(spec.object_path));
        } else {
            oid = pit->second;
        }
        out_object.push_back(oid);

        float col[4] = { nan_f, nan_f, nan_f, nan_f };
        if (spec.use_color) {
            double ct = rng.next_f();
            Color c = spec.color_a.lerp(spec.color_b, real_t(ct));
            col[0] = c.r;
            col[1] = c.g;
            col[2] = c.b;
            col[3] = spec.preserve_alpha ? spec.default_alpha : c.a;
            any_color = true;
        }
        for (int k = 0; k < 4; k++) {
            out_color.push_back(col[k]);
        }

        float cust[4] = { nan_f, nan_f, nan_f, nan_f };
        if (spec.use_custom) {
            cust[0] = spec.custom.r;
            cust[1] = spec.custom.g;
            cust[2] = spec.custom.b;
            cust[3] = spec.custom.a;
            any_custom = true;
        }
        for (int k = 0; k < 4; k++) {
            out_custom.push_back(cust[k]);
        }

        float keep_v = float(rng.range(spec.keep_min, spec.keep_max));
        out_keep.push_back(keep_v);

        if (add_to_staging) {
            Entry e;
            e.set_name = set_name;
            e.object_path = spec.object_path;
            std::memcpy(e.transform, tarr, 48);
            std::memcpy(e.color, col, 16);
            std::memcpy(e.custom, cust, 16);
            e.has_color = spec.use_color;
            e.has_custom = spec.use_custom;
            e.keep = keep_v;
            e.radius = float(spacing);
            e.editable = true;
            e.staging = true;
            e.erased = false;
            insert_entry(std::move(e));
        }
        accepted++;
    }

    out["count"] = accepted;
    out["transform"] = out_transform;
    out["object"] = out_object;
    out["object_paths"] = object_paths;
    if (any_color) {
        out["color"] = out_color;
    }
    if (any_custom) {
        out["custom"] = out_custom;
    }
    if (accepted > 0) {
        out["keep"] = out_keep;
    }
    return out;
}

Dictionary CopiaBrush::pick_ray(const Vector3 &p_origin, const Vector3 &p_dir, double p_max_distance,
        const Dictionary &p_object_aabbs, const PackedStringArray &p_set_filter) const {
    Dictionary result;
    result["hit"] = false;
    if (entries.empty() || !std::isfinite(p_max_distance) || p_max_distance <= 0.0) {
        return result;
    }
    Vector3 dir = p_dir;
    if (dir.length_squared() < 1e-12f) {
        return result;
    }
    dir.normalize();

    std::set<std::string> set_filter;
    for (int64_t i = 0; i < p_set_filter.size(); i++) {
        set_filter.insert(to_std(p_set_filter[i]));
    }

    // Cache AABBs by std::string to avoid repeated Variant lookups.
    std::unordered_map<std::string, AABB> aabb_cache;
    const AABB fallback_aabb(Vector3(-0.25f, -0.25f, -0.25f), Vector3(0.5f, 0.5f, 0.5f));
    auto get_aabb = [&](const std::string &p_path) -> const AABB & {
        auto it = aabb_cache.find(p_path);
        if (it != aabb_cache.end()) {
            return it->second;
        }
        AABB box = fallback_aabb;
        Variant v = p_object_aabbs.get(to_godot(p_path), Variant());
        if (v.get_type() == Variant::AABB) {
            AABB candidate = v;
            if (candidate.size.length_squared() > 1e-8f) {
                box = candidate;
            }
        }
        return aabb_cache.emplace(p_path, box).first->second;
    };

    int64_t best_index = -1;
    double best_dist = p_max_distance;
    for (size_t i = 0; i < entries.size(); i++) {
        const Entry &e = entries[i];
        if (!e.editable || e.erased) {
            continue;
        }
        if (!set_filter.empty() && set_filter.count(e.set_name) == 0) {
            continue;
        }
        const AABB &local_box = get_aabb(e.object_path);
        Transform3D xform = transform_from_arr(e.transform);

        // Quick bounding sphere pre-rejection.
        Vector3 world_center = xform.xform(local_box.get_center());
        Vector3 half = local_box.size * 0.5f;
        double sx = double(xform.basis.get_column(0).length());
        double sy = double(xform.basis.get_column(1).length());
        double sz = double(xform.basis.get_column(2).length());
        double max_s = std::max(sx, std::max(sy, sz));
        double bound_r = double(half.length()) * max_s + 0.05;
        Vector3 oc = world_center - p_origin;
        double proj = double(oc.dot(dir));
        if (proj + bound_r < 0.0 || proj - bound_r > best_dist) {
            continue;
        }
        double perp2 = double(oc.length_squared()) - proj * proj;
        if (perp2 > bound_r * bound_r) {
            continue;
        }

        // Exact ray vs OBB via inverse transform.
        if (std::fabs(double(xform.basis.determinant())) < 1e-12) {
            continue;
        }
        Transform3D inv = xform.affine_inverse();
        Vector3 local_origin = inv.xform(p_origin);
        Vector3 local_dir = inv.basis.xform(dir);
        double hit_t = 0.0;
        if (ray_aabb(local_origin, local_dir, local_box, best_dist, hit_t)) {
            if (hit_t < best_dist) {
                best_dist = hit_t;
                best_index = int64_t(i);
            }
        }
    }

    if (best_index < 0) {
        return result;
    }
    const Entry &e = entries[size_t(best_index)];
    PackedFloat32Array tfloats;
    tfloats.resize(12);
    std::memcpy(tfloats.ptrw(), e.transform, 48);
    result["hit"] = true;
    result["index"] = best_index;
    result["set"] = to_godot(e.set_name);
    result["object_path"] = to_godot(e.object_path);
    result["transform"] = transform_from_arr(e.transform);
    result["transform_floats"] = tfloats;
    result["has_color"] = e.has_color;
    result["color"] = e.has_color ? Color(e.color[0], e.color[1], e.color[2], e.color[3]) : Color(1, 1, 1, 1);
    result["has_custom"] = e.has_custom;
    result["custom"] = e.has_custom ? Color(e.custom[0], e.custom[1], e.custom[2], e.custom[3]) : Color(0, 0, 0, 0);
    result["keep"] = e.keep;
    result["staging"] = e.staging;
    result["distance"] = best_dist;
    return result;
}

Dictionary CopiaBrush::query_sphere(const Vector3 &p_center, double p_radius,
        const PackedStringArray &p_object_filter, bool p_mark_erased) {
    Dictionary out;
    out["count"] = 0;
    out["persistent"] = Dictionary();
    out["staging_indices"] = PackedInt32Array();
    if (entries.empty() || !std::isfinite(p_radius) || p_radius <= 0.0) {
        return out;
    }
    std::set<std::string> filter;
    for (int64_t i = 0; i < p_object_filter.size(); i++) {
        filter.insert(to_std(p_object_filter[i]));
    }
    double r2 = p_radius * p_radius;
    int32_t min_bx = bucket_coord(double(p_center.x) - p_radius);
    int32_t max_bx = bucket_coord(double(p_center.x) + p_radius);
    int32_t min_bz = bucket_coord(double(p_center.z) - p_radius);
    int32_t max_bz = bucket_coord(double(p_center.z) + p_radius);

    PackedFloat32Array p_transform, p_color, p_custom, p_keep;
    PackedInt32Array p_object;
    PackedStringArray p_object_paths;
    std::unordered_map<std::string, int32_t> path_to_idx;
    bool any_color = false;
    bool any_custom = false;
    PackedInt32Array staging_indices;
    int64_t total = 0;

    for (int32_t bx = min_bx; bx <= max_bx; bx++) {
        for (int32_t bz = min_bz; bz <= max_bz; bz++) {
            auto it = grid.find(bucket_key(bx, bz));
            if (it == grid.end()) {
                continue;
            }
            for (int32_t idx : it->second) {
                Entry &e = entries[size_t(idx)];
                if (!e.editable || e.erased) {
                    continue;
                }
                if (!filter.empty() && filter.count(e.object_path) == 0) {
                    continue;
                }
                double dx = double(e.transform[9]) - double(p_center.x);
                double dy = double(e.transform[10]) - double(p_center.y);
                double dz = double(e.transform[11]) - double(p_center.z);
                if (dx * dx + dy * dy + dz * dz > r2) {
                    continue;
                }
                if (p_mark_erased) {
                    e.erased = true;
                }
                total++;
                if (e.staging) {
                    staging_indices.push_back(idx);
                    continue;
                }
                int32_t oid = 0;
                auto pit = path_to_idx.find(e.object_path);
                if (pit == path_to_idx.end()) {
                    oid = int32_t(p_object_paths.size());
                    path_to_idx[e.object_path] = oid;
                    p_object_paths.push_back(to_godot(e.object_path));
                } else {
                    oid = pit->second;
                }
                for (int k = 0; k < 12; k++) {
                    p_transform.push_back(e.transform[k]);
                }
                p_object.push_back(oid);
                for (int k = 0; k < 4; k++) {
                    p_color.push_back(e.color[k]);
                    p_custom.push_back(e.custom[k]);
                }
                p_keep.push_back(e.keep);
                any_color = any_color || e.has_color;
                any_custom = any_custom || e.has_custom;
            }
        }
    }

    Dictionary persistent;
    if (!p_object.is_empty()) {
        persistent["transform"] = p_transform;
        persistent["object"] = p_object;
        persistent["object_paths"] = p_object_paths;
        if (any_color) {
            persistent["color"] = p_color;
        }
        if (any_custom) {
            persistent["custom"] = p_custom;
        }
        persistent["keep"] = p_keep;
    }
    out["count"] = total;
    out["persistent"] = persistent;
    out["staging_indices"] = staging_indices;
    return out;
}

void CopiaBrush::_bind_methods() {
    using namespace godot;
    ClassDB::bind_method(D_METHOD("clear"), &CopiaBrush::clear);
    ClassDB::bind_method(D_METHOD("set_bucket_size", "size"), &CopiaBrush::set_bucket_size);
    ClassDB::bind_method(D_METHOD("get_bucket_size"), &CopiaBrush::get_bucket_size);
    ClassDB::bind_method(D_METHOD("get_point_count"), &CopiaBrush::get_point_count);
    ClassDB::bind_method(D_METHOD("load_points", "points", "editable", "object_radii"),
            &CopiaBrush::load_points, DEFVAL(true), DEFVAL(Dictionary()));
    ClassDB::bind_method(D_METHOD("add_staging_points", "points", "set", "object_radii"),
            &CopiaBrush::add_staging_points, DEFVAL(Dictionary()));
    ClassDB::bind_method(D_METHOD("sample_dab", "hits", "specs", "options"), &CopiaBrush::sample_dab);
    ClassDB::bind_method(D_METHOD("pick_ray", "origin", "dir", "max_distance", "object_aabbs", "set_filter"),
            &CopiaBrush::pick_ray, DEFVAL(PackedStringArray()));
    ClassDB::bind_method(D_METHOD("query_sphere", "center", "radius", "object_filter", "mark_erased"),
            &CopiaBrush::query_sphere, DEFVAL(PackedStringArray()), DEFVAL(false));
}

} // namespace Copia
