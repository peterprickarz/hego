#include "copia_points.h"

#include "copia_format.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/color.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_color_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/packed_vector4_array.hpp>
#include <godot_cpp/variant/quaternion.hpp>
#include <godot_cpp/variant/vector2i.hpp>
#include <godot_cpp/variant/vector3.hpp>
#include <godot_cpp/variant/vector3i.hpp>
#include <godot_cpp/variant/vector4.hpp>
#include <godot_cpp/variant/vector4i.hpp>

#include <cmath>
#include <map>
#include <vector>
#include <set>
#include <unordered_map>

using namespace godot;

namespace Copia {

namespace {

const char *DEFAULT_NAMES[] = { "P", "orient", "N", "up", "scale", "pscale", "object", "set", "Cd", "custom", "custom_w",
    "keep", "clear", "cell" };

String name_of(const Dictionary &p_names, const char *p_default) {
    Variant value = p_names.get(p_default, Variant());
    return value.get_type() == Variant::STRING || value.get_type() == Variant::STRING_NAME ? String(value) : String(p_default);
}

const char *type_name(Variant::Type p_type) {
    switch (p_type) {
        case Variant::BOOL: return "bool";
        case Variant::INT: return "int";
        case Variant::FLOAT: return "float";
        case Variant::STRING: return "String";
        case Variant::VECTOR2: return "Vector2";
        case Variant::VECTOR3: return "Vector3";
        case Variant::VECTOR4: return "Vector4";
        case Variant::COLOR: return "Color";
        case Variant::QUATERNION: return "Quaternion";
        case Variant::DICTIONARY: return "Dictionary";
        case Variant::ARRAY: return "Array";
        default: return "another type";
    }
}

// One attribute: a packed array or a plain Array of Variants. Values are read without creating
// Variants; a value of a type the attribute does not take reads as missing and is counted.
struct Column {
    enum Kind {
        NONE,
        VECTOR3_ARRAY,
        VECTOR4_ARRAY,
        COLOR_ARRAY,
        FLOAT32_ARRAY,
        FLOAT64_ARRAY,
        INT32_ARRAY,
        INT64_ARRAY,
        STRING_ARRAY,
        VARIANT_ARRAY,
    };
    Kind kind = NONE;
    String name;
    Variant holder; // keeps the array alive
    const void *data = nullptr;
    int64_t size = 0;
    int64_t bad = 0;
    int64_t first_bad = -1;
    Variant::Type bad_type = Variant::NIL;

    bool bind(const Dictionary &p_attributes, const String &p_name, int64_t p_count, PackedStringArray &r_errors) {
        name = p_name;
        if (!p_attributes.has(p_name)) {
            return false;
        }
        holder = p_attributes[p_name];
        switch (holder.get_type()) {
            case Variant::PACKED_VECTOR3_ARRAY: {
                PackedVector3Array a = holder;
                kind = VECTOR3_ARRAY;
                size = a.size();
                data = a.ptr();
            } break;
            case Variant::PACKED_VECTOR4_ARRAY: {
                PackedVector4Array a = holder;
                kind = VECTOR4_ARRAY;
                size = a.size();
                data = a.ptr();
            } break;
            case Variant::PACKED_COLOR_ARRAY: {
                PackedColorArray a = holder;
                kind = COLOR_ARRAY;
                size = a.size();
                data = a.ptr();
            } break;
            case Variant::PACKED_FLOAT32_ARRAY: {
                PackedFloat32Array a = holder;
                kind = FLOAT32_ARRAY;
                size = a.size();
                data = a.ptr();
            } break;
            case Variant::PACKED_FLOAT64_ARRAY: {
                PackedFloat64Array a = holder;
                kind = FLOAT64_ARRAY;
                size = a.size();
                data = a.ptr();
            } break;
            case Variant::PACKED_INT32_ARRAY: {
                PackedInt32Array a = holder;
                kind = INT32_ARRAY;
                size = a.size();
                data = a.ptr();
            } break;
            case Variant::PACKED_INT64_ARRAY: {
                PackedInt64Array a = holder;
                kind = INT64_ARRAY;
                size = a.size();
                data = a.ptr();
            } break;
            case Variant::PACKED_STRING_ARRAY: {
                PackedStringArray a = holder;
                kind = STRING_ARRAY;
                size = a.size();
                data = a.ptr();
            } break;
            case Variant::ARRAY: {
                const Array a = holder;
                kind = VARIANT_ARRAY;
                size = a.size();
                // An Array's elements are one contiguous Vector<Variant>; holder keeps it alive.
                data = size ? &a[0] : nullptr;
            } break;
            default:
                r_errors.push_back("attribute \"" + p_name + "\" is not an array; ignored");
                kind = NONE;
                return false;
        }
        if (size != p_count) {
            r_errors.push_back("attribute \"" + p_name + "\" has " + String::num_int64(size) + " values for " + String::num_int64(p_count) + " points; ignored");
            kind = NONE;
            return false;
        }
        return true;
    }

    bool present() const { return kind != NONE; }
    const Variant &variant(int64_t i) const { return static_cast<const Variant *>(data)[i]; }

    bool reject(int64_t i, Variant::Type p_type) {
        if (bad++ == 0) {
            first_bad = i;
            bad_type = p_type;
        }
        return false;
    }

    // Vector3 (also Vector3i, and Color as r g b when p_color).
    bool vec3(int64_t i, double r_out[3], bool p_color = false) {
        switch (kind) {
            case VECTOR3_ARRAY: {
                const Vector3 &v = static_cast<const Vector3 *>(data)[i];
                r_out[0] = v.x, r_out[1] = v.y, r_out[2] = v.z;
                return true;
            }
            case COLOR_ARRAY: {
                if (!p_color) {
                    return reject(i, Variant::COLOR);
                }
                const Color &c = static_cast<const Color *>(data)[i];
                r_out[0] = c.r, r_out[1] = c.g, r_out[2] = c.b;
                return true;
            }
            case VARIANT_ARRAY: {
                const Variant &v = variant(i);
                switch (v.get_type()) {
                    case Variant::NIL:
                        return false;
                    case Variant::VECTOR3: {
                        Vector3 x = v;
                        r_out[0] = x.x, r_out[1] = x.y, r_out[2] = x.z;
                        return true;
                    }
                    case Variant::VECTOR3I: {
                        Vector3i x = v;
                        r_out[0] = x.x, r_out[1] = x.y, r_out[2] = x.z;
                        return true;
                    }
                    case Variant::COLOR:
                        if (p_color) {
                            Color c = v;
                            r_out[0] = c.r, r_out[1] = c.g, r_out[2] = c.b;
                            return true;
                        }
                        return reject(i, v.get_type());
                    default:
                        return reject(i, v.get_type());
                }
            }
            default:
                return reject(i, Variant::NIL);
        }
    }

    // Four floats: Vector4, Quaternion (x y z w) or Color (r g b a). r_had_w is false for a
    // value given as three components (Vector3), whose w the caller supplies.
    bool vec4(int64_t i, double r_out[4], bool p_accept_vec3, bool &r_had_w) {
        r_had_w = true;
        switch (kind) {
            case VECTOR4_ARRAY: {
                const Vector4 &v = static_cast<const Vector4 *>(data)[i];
                r_out[0] = v.x, r_out[1] = v.y, r_out[2] = v.z, r_out[3] = v.w;
                return true;
            }
            case COLOR_ARRAY: {
                const Color &c = static_cast<const Color *>(data)[i];
                r_out[0] = c.r, r_out[1] = c.g, r_out[2] = c.b, r_out[3] = c.a;
                return true;
            }
            case VECTOR3_ARRAY: {
                if (!p_accept_vec3) {
                    return reject(i, Variant::VECTOR3);
                }
                const Vector3 &v = static_cast<const Vector3 *>(data)[i];
                r_out[0] = v.x, r_out[1] = v.y, r_out[2] = v.z, r_out[3] = 0.0;
                r_had_w = false;
                return true;
            }
            case VARIANT_ARRAY: {
                const Variant &v = variant(i);
                switch (v.get_type()) {
                    case Variant::NIL:
                        return false;
                    case Variant::VECTOR4: {
                        Vector4 x = v;
                        r_out[0] = x.x, r_out[1] = x.y, r_out[2] = x.z, r_out[3] = x.w;
                        return true;
                    }
                    case Variant::VECTOR4I: {
                        Vector4i x = v;
                        r_out[0] = x.x, r_out[1] = x.y, r_out[2] = x.z, r_out[3] = x.w;
                        return true;
                    }
                    case Variant::QUATERNION: {
                        Quaternion x = v;
                        r_out[0] = x.x, r_out[1] = x.y, r_out[2] = x.z, r_out[3] = x.w;
                        return true;
                    }
                    case Variant::COLOR: {
                        Color x = v;
                        r_out[0] = x.r, r_out[1] = x.g, r_out[2] = x.b, r_out[3] = x.a;
                        return true;
                    }
                    case Variant::VECTOR3:
                        if (p_accept_vec3) {
                            Vector3 x = v;
                            r_out[0] = x.x, r_out[1] = x.y, r_out[2] = x.z, r_out[3] = 0.0;
                            r_had_w = false;
                            return true;
                        }
                        return reject(i, v.get_type());
                    default:
                        return reject(i, v.get_type());
                }
            }
            default:
                return reject(i, Variant::NIL);
        }
    }

    bool number(int64_t i, double &r_out) {
        switch (kind) {
            case FLOAT32_ARRAY:
                r_out = static_cast<const float *>(data)[i];
                return true;
            case FLOAT64_ARRAY:
                r_out = static_cast<const double *>(data)[i];
                return true;
            case INT32_ARRAY:
                r_out = static_cast<const int32_t *>(data)[i];
                return true;
            case INT64_ARRAY:
                r_out = double(static_cast<const int64_t *>(data)[i]);
                return true;
            case VARIANT_ARRAY: {
                const Variant &v = variant(i);
                switch (v.get_type()) {
                    case Variant::NIL:
                        return false;
                    case Variant::FLOAT:
                        r_out = double(v);
                        return true;
                    case Variant::INT:
                        r_out = double(int64_t(v));
                        return true;
                    case Variant::BOOL:
                        r_out = bool(v) ? 1.0 : 0.0;
                        return true;
                    default:
                        return reject(i, v.get_type());
                }
            }
            default:
                return reject(i, Variant::NIL);
        }
    }

    // A scale: a Vector3, or a number for all three axes.
    bool scale(int64_t i, double r_out[3]) {
        if (kind == VECTOR3_ARRAY || (kind == VARIANT_ARRAY && (variant(i).get_type() == Variant::VECTOR3 || variant(i).get_type() == Variant::VECTOR3I))) {
            return vec3(i, r_out);
        }
        double value;
        if (!number(i, value)) {
            return false;
        }
        r_out[0] = r_out[1] = r_out[2] = value;
        return true;
    }

    // A String (or StringName); nullptr for a missing value.
    const String *string(int64_t i, String &r_storage) {
        switch (kind) {
            case STRING_ARRAY:
                return static_cast<const String *>(data) + i;
            case VARIANT_ARRAY: {
                const Variant &v = variant(i);
                if (v.get_type() == Variant::STRING || v.get_type() == Variant::STRING_NAME) {
                    r_storage = v;
                    return &r_storage;
                }
                if (v.get_type() != Variant::NIL) {
                    reject(i, v.get_type());
                }
                return nullptr;
            }
            default:
                reject(i, Variant::NIL);
                return nullptr;
        }
    }

    void report(PackedStringArray &r_errors) const {
        if (bad > 0) {
            r_errors.push_back("attribute \"" + name + "\": " + String::num_int64(bad) + " values of a type it does not take (first at point " +
                    String::num_int64(first_bad) + ": " + type_name(bad_type) + "); read as missing");
        }
    }
};

struct StringHash {
    size_t operator()(const String &p_value) const { return size_t(p_value.hash()); }
};

// Strings to table indices, in order of first appearance.
struct Table {
    std::unordered_map<String, int32_t, StringHash> ids;
    PackedStringArray names;
    int32_t id(const String &p_value) {
        auto found = ids.find(p_value);
        if (found != ids.end()) {
            return found->second;
        }
        int32_t id = int32_t(names.size());
        ids.emplace(p_value, id);
        names.push_back(p_value);
        return id;
    }
};

inline double length3(const double v[3]) {
    return std::sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
}

inline void normalize3(double v[3]) {
    double length = length3(v);
    if (length > 0.0) {
        v[0] /= length, v[1] /= length, v[2] /= length;
    } else {
        v[0] = v[1] = v[2] = 0.0;
    }
}

inline void cross3(const double a[3], const double b[3], double r_out[3]) {
    r_out[0] = a[1] * b[2] - a[2] * b[1];
    r_out[1] = a[2] * b[0] - a[0] * b[2];
    r_out[2] = a[0] * b[1] - a[1] * b[0];
}

// The number of values of an array Variant, or -1 for anything else.
int64_t array_size(const Variant &p_value) {
    switch (p_value.get_type()) {
        case Variant::ARRAY: return Array(p_value).size();
        case Variant::PACKED_BYTE_ARRAY: return PackedByteArray(p_value).size();
        case Variant::PACKED_INT32_ARRAY: return PackedInt32Array(p_value).size();
        case Variant::PACKED_INT64_ARRAY: return PackedInt64Array(p_value).size();
        case Variant::PACKED_FLOAT32_ARRAY: return PackedFloat32Array(p_value).size();
        case Variant::PACKED_FLOAT64_ARRAY: return PackedFloat64Array(p_value).size();
        case Variant::PACKED_STRING_ARRAY: return PackedStringArray(p_value).size();
        case Variant::PACKED_VECTOR2_ARRAY: return PackedVector2Array(p_value).size();
        case Variant::PACKED_VECTOR3_ARRAY: return PackedVector3Array(p_value).size();
        case Variant::PACKED_VECTOR4_ARRAY: return PackedVector4Array(p_value).size();
        case Variant::PACKED_COLOR_ARRAY: return PackedColorArray(p_value).size();
        default: return -1;
    }
}

template <typename T>
Variant take_packed(const T &p_values, const std::vector<int32_t> &p_rows) {
    T out;
    out.resize(int64_t(p_rows.size()));
    const auto *src = p_values.ptr();
    auto *dst = out.ptrw();
    for (size_t i = 0; i < p_rows.size(); i++) {
        dst[i] = src[p_rows[i]];
    }
    return out;
}

// The rows p_rows of an array Variant, in its own type.
Variant take_rows(const Variant &p_value, const std::vector<int32_t> &p_rows) {
    switch (p_value.get_type()) {
        case Variant::ARRAY: {
            const Array values = p_value;
            const Variant *src = values.is_empty() ? nullptr : &values[0];
            Array out;
            out.resize(int64_t(p_rows.size()));
            for (size_t i = 0; i < p_rows.size(); i++) {
                out[int64_t(i)] = src[p_rows[i]];
            }
            return out;
        }
        case Variant::PACKED_BYTE_ARRAY: return take_packed(PackedByteArray(p_value), p_rows);
        case Variant::PACKED_INT32_ARRAY: return take_packed(PackedInt32Array(p_value), p_rows);
        case Variant::PACKED_INT64_ARRAY: return take_packed(PackedInt64Array(p_value), p_rows);
        case Variant::PACKED_FLOAT32_ARRAY: return take_packed(PackedFloat32Array(p_value), p_rows);
        case Variant::PACKED_FLOAT64_ARRAY: return take_packed(PackedFloat64Array(p_value), p_rows);
        case Variant::PACKED_STRING_ARRAY: return take_packed(PackedStringArray(p_value), p_rows);
        case Variant::PACKED_VECTOR2_ARRAY: return take_packed(PackedVector2Array(p_value), p_rows);
        case Variant::PACKED_VECTOR3_ARRAY: return take_packed(PackedVector3Array(p_value), p_rows);
        case Variant::PACKED_VECTOR4_ARRAY: return take_packed(PackedVector4Array(p_value), p_rows);
        case Variant::PACKED_COLOR_ARRAY: return take_packed(PackedColorArray(p_value), p_rows);
        default: return p_value;
    }
}

// A split key: a String as it is, null as "", anything else as text.
String key_text(const Variant &p_value) {
    switch (p_value.get_type()) {
        case Variant::NIL: return String();
        case Variant::STRING: return String(p_value);
        default: return p_value.stringify();
    }
}

bool parse_cell(const String &p_text, Vector2i &r_cell) {
    int32_t cx, cz;
    // parse_cell_name wants an extension; give it an empty one by appending a marker.
    if (!parse_cell_name(to_std(p_text) + "#", "#", cx, cz)) {
        return false;
    }
    r_cell = Vector2i(cx, cz);
    return true;
}

} // namespace

Dictionary CopiaPoints::from_attributes(const Dictionary &p_attributes, const Dictionary &p_names, const PackedStringArray &p_extra) {
    Dictionary result;
    PackedStringArray errors;
    Array clears;
    Dictionary points;
    result["points"] = points;
    result["clears"] = clears;
    result["point_count"] = 0;
    result["clear_count"] = 0;
    result["skipped_count"] = 0;
    result["errors"] = errors;

    enum { P, ORIENT, NORMAL, UP, SCALE, PSCALE, OBJECT, SET, CD, CUSTOM, CUSTOM_W, KEEP, CLEAR, CELL, COUNT };
    String names[COUNT];
    for (int k = 0; k < COUNT; k++) {
        names[k] = name_of(p_names, DEFAULT_NAMES[k]);
    }
    // The point count: the position attribute, else the clear flag, else the object attribute.
    int64_t n = -1;
    for (int k : { P, CLEAR, OBJECT }) {
        if (p_attributes.has(names[k])) {
            Variant value = p_attributes[names[k]];
            switch (value.get_type()) {
                case Variant::ARRAY: n = Array(value).size(); break;
                case Variant::PACKED_VECTOR3_ARRAY: n = PackedVector3Array(value).size(); break;
                case Variant::PACKED_INT32_ARRAY: n = PackedInt32Array(value).size(); break;
                case Variant::PACKED_INT64_ARRAY: n = PackedInt64Array(value).size(); break;
                case Variant::PACKED_FLOAT32_ARRAY: n = PackedFloat32Array(value).size(); break;
                case Variant::PACKED_FLOAT64_ARRAY: n = PackedFloat64Array(value).size(); break;
                case Variant::PACKED_STRING_ARRAY: n = PackedStringArray(value).size(); break;
                default: break;
            }
            if (n >= 0) {
                break;
            }
        }
    }
    if (n < 0) {
        errors.push_back("no position, clear or object attribute (\"" + names[P] + "\", \"" + names[CLEAR] + "\", \"" + names[OBJECT] + "\")");
        result["errors"] = errors;
        return result;
    }
    Column column[COUNT];
    for (int k = 0; k < COUNT; k++) {
        column[k].bind(p_attributes, names[k], n, errors);
    }
    std::vector<Column> extra_columns;
    for (int64_t e = 0; e < p_extra.size(); e++) {
        Column extra;
        if (extra.bind(p_attributes, p_extra[e], n, errors)) {
            extra_columns.push_back(extra);
        } else if (!p_attributes.has(p_extra[e])) {
            errors.push_back("extra attribute \"" + p_extra[e] + "\" is missing; ignored");
        }
    }
    // Each extra column's type: int, float or Vector3, from the packed type or the first value.
    enum ExtraKind { EXTRA_INT, EXTRA_FLOAT, EXTRA_VEC3, EXTRA_SKIP };
    std::vector<ExtraKind> extra_kind;
    for (Column &extra : extra_columns) {
        ExtraKind kind = EXTRA_SKIP;
        switch (extra.kind) {
            case Column::INT32_ARRAY:
            case Column::INT64_ARRAY: kind = EXTRA_INT; break;
            case Column::FLOAT32_ARRAY:
            case Column::FLOAT64_ARRAY: kind = EXTRA_FLOAT; break;
            case Column::VECTOR3_ARRAY: kind = EXTRA_VEC3; break;
            case Column::VARIANT_ARRAY:
                for (int64_t i = 0; i < n && kind == EXTRA_SKIP; i++) {
                    switch (extra.variant(i).get_type()) {
                        case Variant::INT:
                        case Variant::BOOL: kind = EXTRA_INT; break;
                        case Variant::FLOAT: kind = EXTRA_FLOAT; break;
                        case Variant::VECTOR3:
                        case Variant::VECTOR3I: kind = EXTRA_VEC3; break;
                        default: break;
                    }
                }
                if (kind == EXTRA_SKIP) {
                    kind = EXTRA_FLOAT; // all missing: zeros
                }
                break;
            default: break;
        }
        if (kind == EXTRA_SKIP) {
            errors.push_back("extra attribute \"" + extra.name + "\" is not an int, float or Vector3 attribute; ignored");
        }
        extra_kind.push_back(kind);
    }
    if (!column[P].present() && (column[OBJECT].present())) {
        errors.push_back("no position attribute \"" + names[P] + "\": no point can be an instance");
    }

    const bool has_orient = column[ORIENT].present();
    const bool has_frame = column[NORMAL].present() || column[UP].present();
    PackedFloat32Array transform, color, custom, keep;
    PackedInt32Array object, set;
    transform.resize(n * 12);
    object.resize(n);
    set.resize(n);
    if (column[CD].present()) {
        color.resize(n * 4);
    }
    if (column[CUSTOM].present()) {
        custom.resize(n * 4);
    }
    if (column[KEEP].present()) {
        keep.resize(n);
    }
    std::vector<PackedInt32Array> extra_int(extra_columns.size());
    std::vector<PackedFloat32Array> extra_float(extra_columns.size());
    std::vector<PackedVector3Array> extra_vec3(extra_columns.size());
    for (size_t e = 0; e < extra_columns.size(); e++) {
        if (extra_kind[e] == EXTRA_INT) {
            extra_int[e].resize(n);
        } else if (extra_kind[e] == EXTRA_FLOAT) {
            extra_float[e].resize(n);
        } else if (extra_kind[e] == EXTRA_VEC3) {
            extra_vec3[e].resize(n);
        }
    }
    float *out_transform = transform.ptrw();
    int32_t *out_object = object.ptrw();
    int32_t *out_set = set.ptrw();
    float *out_color = color.size() ? color.ptrw() : nullptr;
    float *out_custom = custom.size() ? custom.ptrw() : nullptr;
    float *out_keep = keep.size() ? keep.ptrw() : nullptr;

    Table objects, sets, seen_sets;
    std::vector<int8_t> set_valid; // per seen set name: 0 invalid, 1 valid
    std::vector<int32_t> set_out; // per seen set name: its index in sets (the output table), or -1
    const String default_set = "default";
    std::set<std::pair<std::string, std::pair<int32_t, int32_t>>> clear_keys;
    int64_t written = 0, skipped = 0, bad_cells = 0, bad_sets = 0, bad_transforms = 0, no_position = 0;
    String storage, set_storage, cell_storage;
    float none;
    std::memcpy(&none, &NONE_BITS, 4);

    for (int64_t i = 0; i < n; i++) {
        double flag = 0.0;
        if (column[CLEAR].present()) {
            column[CLEAR].number(i, flag);
        }
        const String *set_name = column[SET].present() ? column[SET].string(i, set_storage) : nullptr;
        if (!set_name || set_name->is_empty()) {
            set_name = &default_set;
        }
        if (flag == 1.0) {
            const String *cell_text = column[CELL].present() ? column[CELL].string(i, cell_storage) : nullptr;
            Vector2i cell;
            std::string set_text = to_std(*set_name);
            if (!cell_text || !parse_cell(*cell_text, cell)) {
                bad_cells++;
                skipped++;
            } else if (!valid_set_name(set_text)) {
                bad_sets++;
                skipped++;
            } else {
                clear_keys.insert({ set_text, { cell.x, cell.y } });
            }
            continue;
        }
        const String *object_name = column[OBJECT].present() ? column[OBJECT].string(i, storage) : nullptr;
        if (!object_name || object_name->is_empty()) {
            skipped++;
            continue;
        }
        double origin[3];
        if (!column[P].present() || !column[P].vec3(i, origin)) {
            no_position++;
            skipped++;
            continue;
        }
        const int32_t seen = seen_sets.id(*set_name);
        if (size_t(seen) >= set_valid.size()) {
            set_valid.push_back(valid_set_name(to_std(*set_name)) ? 1 : 0);
            set_out.push_back(-1);
        }
        if (!set_valid[size_t(seen)]) {
            bad_sets++;
            skipped++;
            continue;
        }

        // Basis columns x, y, z.
        double basis[3][3] = { { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } };
        double q[4];
        bool had_w;
        if (has_orient && column[ORIENT].vec4(i, q, false, had_w)) {
            double length = std::sqrt(q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3]);
            if (length > 0.0) {
                const double x = q[0] / length, y = q[1] / length, z = q[2] / length, w = q[3] / length;
                basis[0][0] = 1 - 2 * (y * y + z * z), basis[0][1] = 2 * (x * y + w * z), basis[0][2] = 2 * (x * z - w * y);
                basis[1][0] = 2 * (x * y - w * z), basis[1][1] = 1 - 2 * (x * x + z * z), basis[1][2] = 2 * (y * z + w * x);
                basis[2][0] = 2 * (x * z + w * y), basis[2][1] = 2 * (y * z - w * x), basis[2][2] = 1 - 2 * (x * x + y * y);
            }
        } else if (has_frame) {
            double normal[3] = { 0, 0, 1 }, up[3] = { 0, 1, 0 }, right[3];
            if (column[NORMAL].present() && !column[NORMAL].vec3(i, normal)) {
                normal[0] = 0, normal[1] = 0, normal[2] = 1;
            }
            if (column[UP].present() && !column[UP].vec3(i, up)) {
                up[0] = 0, up[1] = 1, up[2] = 0;
            }
            normalize3(normal);
            normalize3(up);
            cross3(up, normal, right);
            if (length3(right) > 1e-12) {
                normalize3(right);
                double y_axis[3];
                cross3(normal, right, y_axis);
                normalize3(y_axis);
                for (int k = 0; k < 3; k++) {
                    basis[0][k] = right[k], basis[1][k] = y_axis[k], basis[2][k] = normal[k];
                }
            }
        }
        double scale[3] = { 1, 1, 1 };
        if (column[SCALE].present() && !column[SCALE].scale(i, scale)) {
            scale[0] = scale[1] = scale[2] = 1.0;
        }
        double pscale = 1.0;
        if (column[PSCALE].present() && !column[PSCALE].number(i, pscale)) {
            pscale = 1.0;
        }
        float t[12];
        bool finite = true;
        for (int c = 0; c < 3; c++) {
            for (int k = 0; k < 3; k++) {
                t[c * 3 + k] = float(basis[c][k] * scale[c] * pscale);
            }
        }
        for (int k = 0; k < 3; k++) {
            t[9 + k] = float(origin[k]);
        }
        for (float value : t) {
            finite = finite && std::isfinite(value);
        }
        if (!finite) {
            bad_transforms++;
            skipped++;
            continue;
        }
        std::memcpy(out_transform + written * 12, t, 48);
        out_object[written] = objects.id(*object_name);
        if (set_out[size_t(seen)] < 0) {
            set_out[size_t(seen)] = sets.id(*set_name);
        }
        out_set[written] = set_out[size_t(seen)];
        if (out_color) {
            double c[4];
            bool ok = false;
            if (column[CD].kind == Column::VECTOR4_ARRAY || column[CD].kind == Column::COLOR_ARRAY ||
                    (column[CD].kind == Column::VARIANT_ARRAY && (column[CD].variant(i).get_type() == Variant::COLOR || column[CD].variant(i).get_type() == Variant::VECTOR4))) {
                ok = column[CD].vec4(i, c, false, had_w);
            } else if (column[CD].vec3(i, c, true)) {
                c[3] = 1.0;
                ok = true;
            }
            float *row = out_color + written * 4;
            if (ok && !std::isnan(c[0])) {
                for (int k = 0; k < 4; k++) {
                    row[k] = float(c[k]);
                }
            } else {
                row[0] = row[1] = row[2] = row[3] = none;
            }
        }
        if (out_custom) {
            double c[4];
            float *row = out_custom + written * 4;
            if (column[CUSTOM].vec4(i, c, true, had_w) && !std::isnan(c[0])) {
                if (!had_w && column[CUSTOM_W].present() && !column[CUSTOM_W].number(i, c[3])) {
                    c[3] = 0.0;
                }
                for (int k = 0; k < 4; k++) {
                    row[k] = float(c[k]);
                }
            } else {
                row[0] = row[1] = row[2] = row[3] = none;
            }
        }
        if (out_keep) {
            double value = 1.0;
            if (!column[KEEP].number(i, value)) {
                value = 1.0;
            }
            out_keep[written] = float(value);
        }
        for (size_t e = 0; e < extra_columns.size(); e++) {
            Column &extra = extra_columns[e];
            if (extra_kind[e] == EXTRA_INT) {
                double value = 0.0;
                extra.number(i, value);
                extra_int[e].ptrw()[written] = int32_t(value);
            } else if (extra_kind[e] == EXTRA_FLOAT) {
                double value = 0.0;
                extra.number(i, value);
                extra_float[e].ptrw()[written] = float(value);
            } else if (extra_kind[e] == EXTRA_VEC3) {
                double value[3] = { 0, 0, 0 };
                if (!extra.vec3(i, value)) {
                    value[0] = value[1] = value[2] = 0.0;
                }
                extra_vec3[e].ptrw()[written] = Vector3(real_t(value[0]), real_t(value[1]), real_t(value[2]));
            }
        }
        written++;
    }

    transform.resize(written * 12);
    object.resize(written);
    set.resize(written);
    points["transform"] = transform;
    points["object"] = object;
    points["object_paths"] = objects.names;
    points["set"] = set;
    points["set_names"] = sets.names;
    if (out_color) {
        color.resize(written * 4);
        points["color"] = color;
    }
    if (out_custom) {
        custom.resize(written * 4);
        points["custom"] = custom;
    }
    if (out_keep) {
        keep.resize(written);
        points["keep"] = keep;
    }
    if (!extra_columns.empty()) {
        Dictionary extras;
        for (size_t e = 0; e < extra_columns.size(); e++) {
            if (extra_kind[e] == EXTRA_INT) {
                extra_int[e].resize(written);
                extras[extra_columns[e].name] = extra_int[e];
            } else if (extra_kind[e] == EXTRA_FLOAT) {
                extra_float[e].resize(written);
                extras[extra_columns[e].name] = extra_float[e];
            } else if (extra_kind[e] == EXTRA_VEC3) {
                extra_vec3[e].resize(written);
                extras[extra_columns[e].name] = extra_vec3[e];
            }
        }
        if (!extras.is_empty()) {
            points["extra"] = extras;
        }
    }
    for (const auto &key : clear_keys) {
        Dictionary clear;
        clear["set"] = to_godot(key.first);
        clear["cell"] = Vector2i(key.second.first, key.second.second);
        clears.push_back(clear);
    }
    for (int k = 0; k < COUNT; k++) {
        column[k].report(errors);
    }
    for (const Column &extra : extra_columns) {
        extra.report(errors);
    }
    if (no_position > 0 && column[P].present()) {
        errors.push_back(String::num_int64(no_position) + " points with an object have no position; skipped");
    }
    if (bad_cells > 0) {
        errors.push_back(String::num_int64(bad_cells) + " clear points have no valid cell id (\"cx_cz\"); skipped");
    }
    if (bad_sets > 0) {
        errors.push_back(String::num_int64(bad_sets) + " points name an invalid set (use 1 to 64 of a-z, 0-9, _); skipped");
    }
    if (bad_transforms > 0) {
        errors.push_back(String::num_int64(bad_transforms) + " points have a transform that is not finite; skipped");
    }
    result["points"] = points;
    result["clears"] = clears;
    result["point_count"] = written;
    result["clear_count"] = clears.size();
    result["skipped_count"] = skipped;
    result["errors"] = errors;
    return result;
}

Dictionary CopiaPoints::to_attributes(const Dictionary &p_points, const Dictionary &p_names) {
    Dictionary result;
    Variant transform_value = p_points.get("transform", Variant());
    ERR_FAIL_COND_V_MSG(transform_value.get_type() != Variant::PACKED_FLOAT32_ARRAY || PackedFloat32Array(transform_value).size() % 12 != 0,
            result, "CopiaPoints: points.transform must be a PackedFloat32Array with 12 floats per point.");
    const PackedFloat32Array transform = transform_value;
    const int64_t n = transform.size() / 12;
    const PackedInt32Array object = p_points.get("object", PackedInt32Array());
    const PackedStringArray object_paths = p_points.get("object_paths", PackedStringArray());
    const PackedInt32Array set = p_points.get("set", PackedInt32Array());
    const PackedStringArray set_names = p_points.get("set_names", PackedStringArray());
    const PackedFloat32Array color = p_points.get("color", PackedFloat32Array());
    const PackedFloat32Array custom = p_points.get("custom", PackedFloat32Array());
    const PackedFloat32Array keep = p_points.get("keep", PackedFloat32Array());

    PackedVector3Array position, normal, up, scale, cd, custom_xyz;
    PackedFloat32Array keep_out, custom_w;
    PackedStringArray object_out, set_out;
    position.resize(n);
    normal.resize(n);
    up.resize(n);
    scale.resize(n);
    keep_out.resize(n);
    object_out.resize(n);
    set_out.resize(n);
    const bool has_color = color.size() == n * 4 && n > 0;
    const bool has_custom = custom.size() == n * 4 && n > 0;
    if (has_color) {
        cd.resize(n);
    }
    if (has_custom) {
        custom_xyz.resize(n);
        custom_w.resize(n);
    }
    const float *t = transform.ptr();
    const String default_set = "default";
    for (int64_t i = 0; i < n; i++, t += 12) {
        double columns[3][3];
        double lengths[3];
        for (int c = 0; c < 3; c++) {
            for (int k = 0; k < 3; k++) {
                columns[c][k] = t[c * 3 + k];
            }
            lengths[c] = length3(columns[c]);
            normalize3(columns[c]);
        }
        position.set(i, Vector3(t[9], t[10], t[11]));
        normal.set(i, Vector3(real_t(columns[2][0]), real_t(columns[2][1]), real_t(columns[2][2])));
        up.set(i, Vector3(real_t(columns[1][0]), real_t(columns[1][1]), real_t(columns[1][2])));
        scale.set(i, Vector3(real_t(lengths[0]), real_t(lengths[1]), real_t(lengths[2])));
        const int32_t o = i < object.size() ? object[i] : -1;
        object_out.set(i, o >= 0 && o < object_paths.size() ? object_paths[o] : String());
        const int32_t s = i < set.size() ? set[i] : -1;
        set_out.set(i, s >= 0 && s < set_names.size() ? set_names[s] : default_set);
        keep_out.set(i, i < keep.size() ? keep[i] : 1.0f);
        if (has_color) {
            cd.set(i, Vector3(color[i * 4], color[i * 4 + 1], color[i * 4 + 2]));
        }
        if (has_custom) {
            custom_xyz.set(i, Vector3(custom[i * 4], custom[i * 4 + 1], custom[i * 4 + 2]));
            custom_w.set(i, custom[i * 4 + 3]);
        }
    }
    // Extra columns first, so a core attribute of the same name wins.
    Variant extra_value = p_points.get("extra", Variant());
    if (extra_value.get_type() == Variant::DICTIONARY) {
        Dictionary extra = extra_value;
        Array keys = extra.keys();
        for (int64_t k = 0; k < keys.size(); k++) {
            Variant value = extra[keys[k]];
            if (value.get_type() == Variant::PACKED_FLOAT32_ARRAY && PackedFloat32Array(value).size() == n * 3 && n > 0) {
                PackedFloat32Array floats = value;
                PackedVector3Array vectors;
                vectors.resize(n);
                for (int64_t i = 0; i < n; i++) {
                    vectors.set(i, Vector3(floats[i * 3], floats[i * 3 + 1], floats[i * 3 + 2]));
                }
                result[keys[k]] = vectors;
            } else {
                result[keys[k]] = value;
            }
        }
    }
    result[name_of(p_names, "P")] = position;
    result[name_of(p_names, "N")] = normal;
    result[name_of(p_names, "up")] = up;
    result[name_of(p_names, "scale")] = scale;
    result[name_of(p_names, "object")] = object_out;
    result[name_of(p_names, "set")] = set_out;
    result[name_of(p_names, "keep")] = keep_out;
    if (has_color) {
        result[name_of(p_names, "Cd")] = cd;
    }
    if (has_custom) {
        result[name_of(p_names, "custom")] = custom_xyz;
        result[name_of(p_names, "custom_w")] = custom_w;
    }
    return result;
}

Dictionary CopiaPoints::split_by(const Dictionary &p_attributes, const String &p_name) {
    Dictionary groups;
    const Variant column = p_attributes.get(p_name, Variant());
    const int64_t n = array_size(column);
    if (n <= 0) {
        // No such column (or an empty one): every point has no value.
        groups[String()] = p_attributes;
        return groups;
    }
    // Each row's group, groups in order of first appearance.
    std::vector<int32_t> group_of(size_t(n), 0);
    std::vector<String> keys;
    std::unordered_map<String, int32_t, StringHash> ids;
    String last;
    int32_t last_id = -1;
    const Array values = column.get_type() == Variant::ARRAY ? Array(column) : Array();
    const PackedStringArray strings = column.get_type() == Variant::PACKED_STRING_ARRAY ? PackedStringArray(column) : PackedStringArray();
    for (int64_t i = 0; i < n; i++) {
        String key;
        if (column.get_type() == Variant::ARRAY) {
            key = key_text(values[i]);
        } else if (column.get_type() == Variant::PACKED_STRING_ARRAY) {
            key = strings[i];
        } else {
            key = key_text(column.get(i));
        }
        if (last_id < 0 || key != last) {
            auto found = ids.find(key);
            if (found == ids.end()) {
                last_id = int32_t(keys.size());
                ids.emplace(key, last_id);
                keys.push_back(key);
            } else {
                last_id = found->second;
            }
            last = key;
        }
        group_of[size_t(i)] = last_id;
    }
    if (keys.size() == 1) {
        groups[keys[0]] = p_attributes;
        return groups;
    }
    std::vector<std::vector<int32_t>> rows(keys.size());
    for (int64_t i = 0; i < n; i++) {
        rows[size_t(group_of[size_t(i)])].push_back(int32_t(i));
    }
    const Array names = p_attributes.keys();
    for (size_t g = 0; g < keys.size(); g++) {
        Dictionary part;
        for (int64_t k = 0; k < names.size(); k++) {
            const Variant value = p_attributes[names[k]];
            part[names[k]] = array_size(value) == n ? take_rows(value, rows[g]) : value;
        }
        groups[keys[g]] = part;
    }
    return groups;
}

void CopiaPoints::_bind_methods() {
    ClassDB::bind_static_method("CopiaPoints", D_METHOD("split_by", "attributes", "name"), &CopiaPoints::split_by);
    ClassDB::bind_static_method("CopiaPoints", D_METHOD("from_attributes", "attributes", "names", "extra"), &CopiaPoints::from_attributes,
            DEFVAL(Dictionary()), DEFVAL(PackedStringArray()));
    ClassDB::bind_static_method("CopiaPoints", D_METHOD("to_attributes", "points", "names"), &CopiaPoints::to_attributes,
            DEFVAL(Dictionary()));
}

} // namespace Copia
