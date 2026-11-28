#include "copia_sets.h"

#include "copia_format.h"
#include "copia_index.h"

#include <godot_cpp/classes/dir_access.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/variant/vector2i.hpp>

#include <algorithm>
#include <cmath>
#include <map>
#include <mutex>
#include <set>
#include <unordered_map>

using namespace godot;

namespace Copia {

static const char *SET_EXTENSION = ".copiaset";
static const char *MANIFEST_FILE = "manifest.json";

struct SetMeta {
    std::string kind = "generated";
    bool locked = false;
};

static bool valid_set_kind(const std::string &p_kind) {
    return p_kind == "generated" || p_kind == "authored";
}

static bool valid_intent(const std::string &p_intent) {
    return p_intent == "any" || p_intent == "generated" || p_intent == "authored";
}

static String manifest_path(const String &p_directory) {
    return p_directory.path_join("sets").path_join(MANIFEST_FILE);
}

static std::string escape_json_string(const std::string &p_value) {
    std::string out;
    out.reserve(p_value.size() + 2);
    out.push_back('"');
    for (unsigned char c : p_value) {
        if (c == '"' || c == '\\') {
            out.push_back('\\');
            out.push_back(char(c));
        } else if (c >= 0x20) {
            out.push_back(char(c));
        }
    }
    out.push_back('"');
    return out;
}

// Minimal, thread-safe parser for sets/manifest.json:
//   {"version": 1, "sets": {"name": {"kind": "authored", "locked": false}}}
class ManifestParser {
public:
    ManifestParser(const char *p_data, size_t p_size) : data(p_data), size(p_size) {}

    bool parse(std::map<std::string, SetMeta> &r_sets) {
        skip_ws();
        if (!consume('{')) {
            return false;
        }
        skip_ws();
        if (peek() == '}') {
            pos++;
            return true;
        }
        while (pos < size) {
            std::string key;
            if (!read_string(key)) {
                return false;
            }
            skip_ws();
            if (!consume(':')) {
                return false;
            }
            skip_ws();
            if (key == "sets") {
                if (!parse_sets_object(r_sets)) {
                    return false;
                }
            } else {
                if (!skip_value()) {
                    return false;
                }
            }
            skip_ws();
            if (consume(',')) {
                skip_ws();
                continue;
            }
            return consume('}');
        }
        return false;
    }

private:
    const char *data;
    size_t size;
    size_t pos = 0;

    char peek() const { return pos < size ? data[pos] : '\0'; }
    void skip_ws() {
        while (pos < size && (data[pos] == ' ' || data[pos] == '\t' || data[pos] == '\r' || data[pos] == '\n')) {
            pos++;
        }
    }
    bool consume(char p_ch) {
        if (pos < size && data[pos] == p_ch) {
            pos++;
            return true;
        }
        return false;
    }
    bool read_string(std::string &r_out) {
        r_out.clear();
        if (!consume('"')) {
            return false;
        }
        while (pos < size) {
            char c = data[pos++];
            if (c == '"') {
                return true;
            }
            if (c == '\\') {
                if (pos >= size) {
                    return false;
                }
                char esc = data[pos++];
                switch (esc) {
                    case '"': r_out.push_back('"'); break;
                    case '\\': r_out.push_back('\\'); break;
                    case '/': r_out.push_back('/'); break;
                    case 'b': r_out.push_back('\b'); break;
                    case 'f': r_out.push_back('\f'); break;
                    case 'n': r_out.push_back('\n'); break;
                    case 'r': r_out.push_back('\r'); break;
                    case 't': r_out.push_back('\t'); break;
                    default: r_out.push_back(esc); break;
                }
            } else {
                r_out.push_back(c);
            }
        }
        return false;
    }
    bool read_bool(bool &r_out) {
        if (pos + 4 <= size && std::memcmp(data + pos, "true", 4) == 0) {
            pos += 4;
            r_out = true;
            return true;
        }
        if (pos + 5 <= size && std::memcmp(data + pos, "false", 5) == 0) {
            pos += 5;
            r_out = false;
            return true;
        }
        return false;
    }
    bool skip_value() {
        skip_ws();
        char c = peek();
        if (c == '"') {
            std::string dummy;
            return read_string(dummy);
        }
        if (c == '{') {
            pos++;
            skip_ws();
            if (consume('}')) {
                return true;
            }
            while (pos < size) {
                std::string k;
                if (!read_string(k)) {
                    return false;
                }
                skip_ws();
                if (!consume(':')) {
                    return false;
                }
                if (!skip_value()) {
                    return false;
                }
                skip_ws();
                if (consume(',')) {
                    skip_ws();
                    continue;
                }
                return consume('}');
            }
            return false;
        }
        if (c == '[') {
            pos++;
            skip_ws();
            if (consume(']')) {
                return true;
            }
            while (pos < size) {
                if (!skip_value()) {
                    return false;
                }
                skip_ws();
                if (consume(',')) {
                    skip_ws();
                    continue;
                }
                return consume(']');
            }
            return false;
        }
        size_t start = pos;
        while (pos < size && data[pos] != ',' && data[pos] != '}' && data[pos] != ']' &&
                data[pos] != ' ' && data[pos] != '\t' && data[pos] != '\r' && data[pos] != '\n') {
            pos++;
        }
        return pos > start;
    }
    bool parse_sets_object(std::map<std::string, SetMeta> &r_sets) {
        if (!consume('{')) {
            return false;
        }
        skip_ws();
        if (consume('}')) {
            return true;
        }
        while (pos < size) {
            std::string name;
            if (!read_string(name)) {
                return false;
            }
            skip_ws();
            if (!consume(':')) {
                return false;
            }
            skip_ws();
            SetMeta meta;
            if (!parse_set_meta(meta)) {
                return false;
            }
            if (valid_set_name(name) && valid_set_kind(meta.kind)) {
                r_sets[name] = meta;
            }
            skip_ws();
            if (consume(',')) {
                skip_ws();
                continue;
            }
            return consume('}');
        }
        return false;
    }
    bool parse_set_meta(SetMeta &r_meta) {
        if (!consume('{')) {
            return false;
        }
        skip_ws();
        if (consume('}')) {
            return true;
        }
        while (pos < size) {
            std::string key;
            if (!read_string(key)) {
                return false;
            }
            skip_ws();
            if (!consume(':')) {
                return false;
            }
            skip_ws();
            if (key == "kind") {
                std::string value;
                if (!read_string(value)) {
                    return false;
                }
                r_meta.kind = value;
            } else if (key == "locked") {
                bool value = false;
                if (!read_bool(value)) {
                    return false;
                }
                r_meta.locked = value;
            } else if (!skip_value()) {
                return false;
            }
            skip_ws();
            if (consume(',')) {
                skip_ws();
                continue;
            }
            return consume('}');
        }
        return false;
    }
};

// Must be called with index_mutex() held.
static std::map<std::string, SetMeta> load_manifest_locked(const String &p_directory) {
    std::map<std::string, SetMeta> sets;
    String path = manifest_path(p_directory);
    if (!file_exists(path)) {
        return sets;
    }
    Bytes raw;
    if (!read_file(path, raw) || raw.empty()) {
        return sets;
    }
    ManifestParser parser(reinterpret_cast<const char *>(raw.data()), raw.size());
    std::map<std::string, SetMeta> parsed;
    if (parser.parse(parsed)) {
        sets = std::move(parsed);
    } else {
        UtilityFunctions::push_warning("Copia: unreadable sets/manifest.json in ", p_directory);
    }
    return sets;
}

// Must be called with index_mutex() held.
static bool save_manifest_locked(const String &p_directory, const std::map<std::string, SetMeta> &p_sets, std::string &r_error) {
    std::string out = "{\n  \"version\": 1,\n  \"sets\": {\n";
    bool first = true;
    for (const auto &entry : p_sets) {
        if (!first) {
            out += ",\n";
        }
        first = false;
        out += "    " + escape_json_string(entry.first) + ": {\"kind\": " + escape_json_string(entry.second.kind) +
                ", \"locked\": " + (entry.second.locked ? "true" : "false") + "}";
    }
    out += "\n  }\n}\n";
    Bytes bytes(out.begin(), out.end());
    return write_file_atomic(manifest_path(p_directory), bytes, r_error);
}

// Validates access for a set of names against sets/manifest.json and on-disk sets.
// When intent is "authored" and a target set is brand-new (absent from manifest and disk), records
// it into r_auto_register so the caller persists it as authored after validation succeeds.
static bool check_sets_access(const String &p_directory, const std::set<std::string> &p_target_sets,
        const std::string &p_intent, std::vector<std::string> &r_auto_register, String &r_error) {
    if (!valid_intent(p_intent)) {
        r_error = "invalid write intent \"" + to_godot(p_intent) + "\" (use \"any\", \"generated\" or \"authored\")";
        return false;
    }
    if (p_target_sets.empty()) {
        return true;
    }
    std::lock_guard<std::mutex> lock(index_mutex());
    std::map<std::string, SetMeta> manifest = load_manifest_locked(p_directory);
    std::set<std::string> on_disk;
    for (const std::string &name : set_names_on_disk(p_directory)) {
        on_disk.insert(name);
    }
    for (const std::string &name : p_target_sets) {
        auto it = manifest.find(name);
        bool known_in_manifest = it != manifest.end();
        bool exists_on_disk = on_disk.count(name) > 0;
        SetMeta meta = known_in_manifest ? it->second : SetMeta{};
        if (meta.locked) {
            r_error = "set \"" + to_godot(name) + "\" is locked";
            return false;
        }
        if (p_intent == "generated") {
            if (known_in_manifest && meta.kind == "authored") {
                r_error = "set \"" + to_godot(name) + "\" is authored and cannot be modified by generated writes";
                return false;
            }
        } else if (p_intent == "authored") {
            if (known_in_manifest) {
                if (meta.kind != "authored") {
                    r_error = "set \"" + to_godot(name) + "\" is generated and cannot be modified by authored writes";
                    return false;
                }
            } else if (exists_on_disk) {
                r_error = "set \"" + to_godot(name) + "\" is generated (unregistered on disk) and cannot be modified by authored writes";
                return false;
            } else {
                r_auto_register.push_back(name);
            }
        }
    }
    return true;
}

static bool register_authored_sets(const String &p_directory, const std::vector<std::string> &p_sets, String &r_error) {
    if (p_sets.empty()) {
        return true;
    }
    std::lock_guard<std::mutex> lock(index_mutex());
    std::map<std::string, SetMeta> manifest = load_manifest_locked(p_directory);
    bool changed = false;
    for (const std::string &name : p_sets) {
        if (manifest.find(name) == manifest.end()) {
            SetMeta meta;
            meta.kind = "authored";
            meta.locked = false;
            manifest[name] = meta;
            changed = true;
        }
    }
    if (!changed) {
        return true;
    }
    std::string io_error;
    if (!save_manifest_locked(p_directory, manifest, io_error)) {
        r_error = to_godot("manifest: " + io_error);
        return false;
    }
    return true;
}

String set_file_path(const String &p_directory, const std::string &p_set, int32_t p_cx, int32_t p_cz) {
    return p_directory.path_join("sets").path_join(to_godot(p_set)).path_join(to_godot(cell_name(p_cx, p_cz) + SET_EXTENSION));
}

static std::string relative_set_path(const std::string &p_set, int32_t p_cx, int32_t p_cz) {
    return "sets/" + p_set + "/" + cell_name(p_cx, p_cz) + SET_EXTENSION;
}

static std::vector<std::pair<int32_t, int32_t>> set_cells_on_disk(const String &p_directory, const std::string &p_set) {
    std::vector<std::pair<int32_t, int32_t>> cells;
    String folder = p_directory.path_join("sets").path_join(to_godot(p_set));
    if (!DirAccess::dir_exists_absolute(folder)) {
        return cells;
    }
    PackedStringArray files = DirAccess::get_files_at(folder);
    for (int64_t i = 0; i < files.size(); i++) {
        int32_t cx, cz;
        if (parse_cell_name(to_std(files[i]), SET_EXTENSION, cx, cz)) {
            cells.emplace_back(cx, cz);
        }
    }
    std::sort(cells.begin(), cells.end());
    return cells;
}

std::vector<std::string> set_names_on_disk(const String &p_directory) {
    std::vector<std::string> names;
    String root = p_directory.path_join("sets");
    if (!DirAccess::dir_exists_absolute(root)) {
        return names;
    }
    PackedStringArray directories = DirAccess::get_directories_at(root);
    for (int64_t i = 0; i < directories.size(); i++) {
        std::string name = to_std(directories[i]);
        if (valid_set_name(name) && !set_cells_on_disk(p_directory, name).empty()) {
            names.push_back(name);
        }
    }
    std::sort(names.begin(), names.end());
    return names;
}

namespace {

struct ExtraInput {
    ExtraColumn column;
    const uint8_t *data = nullptr;
};

// The validated columns of one apply() call. The packed arrays are held so their pointers stay
// valid.
struct PointColumns {
    int64_t count = 0;
    PackedFloat32Array transform_array, color_array, custom_array, keep_array;
    PackedInt32Array object_array, set_array;
    std::vector<Variant> extra_arrays;
    const float *transform = nullptr;
    const int32_t *object = nullptr;
    const int32_t *set = nullptr;
    const float *color = nullptr;
    const float *custom = nullptr;
    const float *keep = nullptr;
    int64_t object_table_size = 0;
    std::vector<int32_t> path_id; // object table entry -> unique path id
    std::vector<std::string> paths; // unique paths, sorted
    std::vector<int32_t> set_id; // set table entry -> unique set id
    std::vector<std::string> sets; // unique set names, sorted
    std::vector<ExtraInput> extras; // sorted by name
};

bool fail(String &r_error, const String &p_message) {
    r_error = p_message;
    return false;
}

bool parse_columns(const Dictionary &p_points, PointColumns &r_columns, String &r_error) {
    if (p_points.is_empty()) {
        r_columns.sets.push_back("default");
        r_columns.count = 0;
        return true;
    }
    Variant transform = p_points.get("transform", Variant());
    if (transform.get_type() != Variant::PACKED_FLOAT32_ARRAY) {
        return fail(r_error, "points.transform must be a PackedFloat32Array");
    }
    r_columns.transform_array = transform;
    if (r_columns.transform_array.size() % 12 != 0) {
        return fail(r_error, "points.transform must hold 12 floats per point");
    }
    const int64_t n = r_columns.transform_array.size() / 12;
    r_columns.count = n;
    if (n > int64_t(UINT32_MAX / 2)) {
        return fail(r_error, "too many points in one call");
    }
    Variant object = p_points.get("object", Variant());
    if (object.get_type() != Variant::PACKED_INT32_ARRAY || PackedInt32Array(object).size() != n) {
        return fail(r_error, "points.object must be a PackedInt32Array with one entry per point");
    }
    r_columns.object_array = object;
    Variant object_paths = p_points.get("object_paths", Variant());
    if (object_paths.get_type() != Variant::PACKED_STRING_ARRAY) {
        return fail(r_error, "points.object_paths must be a PackedStringArray");
    }
    PackedStringArray paths = object_paths;
    r_columns.object_table_size = paths.size();
    {
        std::vector<std::string> table;
        for (int64_t i = 0; i < paths.size(); i++) {
            table.push_back(to_std(paths[i]));
        }
        r_columns.paths = table;
        std::sort(r_columns.paths.begin(), r_columns.paths.end());
        r_columns.paths.erase(std::unique(r_columns.paths.begin(), r_columns.paths.end()), r_columns.paths.end());
        for (const std::string &path : table) {
            r_columns.path_id.push_back(int32_t(std::lower_bound(r_columns.paths.begin(), r_columns.paths.end(), path) - r_columns.paths.begin()));
        }
    }
    Variant set = p_points.get("set", Variant());
    if (set.get_type() != Variant::NIL) {
        if (set.get_type() != Variant::PACKED_INT32_ARRAY || PackedInt32Array(set).size() != n) {
            return fail(r_error, "points.set must be a PackedInt32Array with one entry per point");
        }
        Variant set_names = p_points.get("set_names", Variant());
        if (set_names.get_type() != Variant::PACKED_STRING_ARRAY) {
            return fail(r_error, "points.set_names must be a PackedStringArray when points.set is given");
        }
        r_columns.set_array = set;
        PackedStringArray names = set_names;
        std::vector<std::string> table;
        for (int64_t i = 0; i < names.size(); i++) {
            std::string name = to_std(names[i]);
            if (!valid_set_name(name)) {
                return fail(r_error, "invalid set name \"" + names[i] + "\" (use 1 to 64 of a-z, 0-9, _)");
            }
            table.push_back(name);
        }
        r_columns.sets = table;
        std::sort(r_columns.sets.begin(), r_columns.sets.end());
        r_columns.sets.erase(std::unique(r_columns.sets.begin(), r_columns.sets.end()), r_columns.sets.end());
        for (const std::string &name : table) {
            r_columns.set_id.push_back(int32_t(std::lower_bound(r_columns.sets.begin(), r_columns.sets.end(), name) - r_columns.sets.begin()));
        }
    } else {
        r_columns.sets.push_back("default");
    }
    auto optional_floats = [&](const char *p_name, int64_t p_width, PackedFloat32Array &r_array) -> bool {
        Variant value = p_points.get(p_name, Variant());
        if (value.get_type() == Variant::NIL) {
            return true;
        }
        if (value.get_type() != Variant::PACKED_FLOAT32_ARRAY || PackedFloat32Array(value).size() != n * p_width) {
            return fail(r_error, String("points.") + p_name + " must be a PackedFloat32Array with " + String::num_int64(p_width) + " floats per point");
        }
        r_array = value;
        return true;
    };
    if (!optional_floats("color", 4, r_columns.color_array) || !optional_floats("custom", 4, r_columns.custom_array) ||
            !optional_floats("keep", 1, r_columns.keep_array)) {
        return false;
    }
    Variant extra = p_points.get("extra", Variant());
    if (extra.get_type() != Variant::NIL) {
        if (extra.get_type() != Variant::DICTIONARY) {
            return fail(r_error, "points.extra must be a Dictionary of packed arrays");
        }
        Dictionary extras = extra;
        Array keys = extras.keys();
        for (int64_t i = 0; i < keys.size(); i++) {
            if (keys[i].get_type() != Variant::STRING && keys[i].get_type() != Variant::STRING_NAME) {
                return fail(r_error, "points.extra keys must be strings");
            }
            String name = keys[i];
            std::string key = to_std(name);
            if (key.empty() || key.size() > 255) {
                return fail(r_error, "extra column names must be 1 to 255 bytes");
            }
            Variant value = extras[keys[i]];
            ExtraInput input;
            input.column.name = key;
            // The Variant held in extra_arrays keeps the array's buffer alive; the typed copies
            // below share that buffer, so their data pointers stay valid.
            r_columns.extra_arrays.push_back(value);
            const Variant &held = r_columns.extra_arrays.back();
            if (held.get_type() == Variant::PACKED_INT32_ARRAY && PackedInt32Array(held).size() == n) {
                input.column.type = EXTRA_INT32;
                input.column.width = 1;
                input.data = reinterpret_cast<const uint8_t *>(PackedInt32Array(held).ptr());
            } else if (held.get_type() == Variant::PACKED_FLOAT32_ARRAY && PackedFloat32Array(held).size() == n) {
                input.column.type = EXTRA_FLOAT32;
                input.column.width = 1;
                input.data = reinterpret_cast<const uint8_t *>(PackedFloat32Array(held).ptr());
            } else if (held.get_type() == Variant::PACKED_FLOAT32_ARRAY && PackedFloat32Array(held).size() == 3 * n) {
                input.column.type = EXTRA_FLOAT32;
                input.column.width = 3;
                input.data = reinterpret_cast<const uint8_t *>(PackedFloat32Array(held).ptr());
            } else if (held.get_type() == Variant::PACKED_VECTOR3_ARRAY && PackedVector3Array(held).size() == n && sizeof(Vector3) == 12) {
                input.column.type = EXTRA_FLOAT32;
                input.column.width = 3;
                input.data = reinterpret_cast<const uint8_t *>(PackedVector3Array(held).ptr());
            } else {
                return fail(r_error, "extra column \"" + name + "\" must be a PackedInt32Array (1 per point), PackedFloat32Array (1 or 3 per point) or PackedVector3Array");
            }
            r_columns.extras.push_back(input);
        }
        std::sort(r_columns.extras.begin(), r_columns.extras.end(),
                [](const ExtraInput &a, const ExtraInput &b) { return a.column.name < b.column.name; });
        for (size_t i = 1; i < r_columns.extras.size(); i++) {
            if (r_columns.extras[i].column.name == r_columns.extras[i - 1].column.name) {
                return fail(r_error, "extra column \"" + to_godot(r_columns.extras[i].column.name) + "\" is given twice");
            }
        }
    }
    // Pointers last: the arrays above are no longer copied.
    r_columns.transform = r_columns.transform_array.ptr();
    r_columns.object = r_columns.object_array.ptr();
    r_columns.set = r_columns.set_array.size() ? r_columns.set_array.ptr() : nullptr;
    r_columns.color = r_columns.color_array.size() ? r_columns.color_array.ptr() : nullptr;
    r_columns.custom = r_columns.custom_array.size() ? r_columns.custom_array.ptr() : nullptr;
    r_columns.keep = r_columns.keep_array.size() ? r_columns.keep_array.ptr() : nullptr;
    return true;
}

struct FileKey {
    std::string set;
    int32_t cx = 0;
    int32_t cz = 0;
    bool operator<(const FileKey &p_other) const {
        if (set != p_other.set) {
            return set < p_other.set;
        }
        if (cx != p_other.cx) {
            return cx < p_other.cx;
        }
        return cz < p_other.cz;
    }
};

enum Outcome {
    OUTCOME_NONE,
    OUTCOME_WRITE,
    OUTCOME_DELETE,
    OUTCOME_UNCHANGED,
};

struct FileJob {
    FileKey key;
    bool clear = false;
    std::vector<uint32_t> points;
    Outcome outcome = OUTCOME_NONE;
    Bytes bytes;
    std::string error;
    SetSummary summary; // of the file after the call, for the index
};

} // namespace

Dictionary CopiaSets::apply(const String &p_directory, double p_cell_size, const Array &p_clears, const Dictionary &p_points, const String &p_intent) {
    Dictionary result;
    result["ok"] = false;
    result["error"] = String();
    result["written"] = PackedStringArray();
    result["deleted"] = PackedStringArray();
    result["unchanged"] = PackedStringArray();
    result["cells"] = Array();
    result["point_count"] = 0;
    auto reject = [&](const String &p_message) {
        result["error"] = p_message;
        return result;
    };
    if (!std::isfinite(p_cell_size) || p_cell_size <= 0.0) {
        return reject("cell_size must be a positive number");
    }
    if (p_directory.is_empty()) {
        return reject("directory is empty");
    }
    const std::string intent = to_std(p_intent);
    if (!valid_intent(intent)) {
        return reject("invalid write intent \"" + p_intent + "\" (use \"any\", \"generated\" or \"authored\")");
    }

    std::map<FileKey, FileJob> jobs;
    std::set<std::string> touched_sets;
    for (int64_t i = 0; i < p_clears.size(); i++) {
        if (p_clears[i].get_type() != Variant::DICTIONARY) {
            return reject("clears must hold {set: String, cell: Vector2i} dictionaries");
        }
        Dictionary clear = p_clears[i];
        Variant set = clear.get("set", Variant());
        Variant cell = clear.get("cell", Variant());
        if ((set.get_type() != Variant::STRING && set.get_type() != Variant::STRING_NAME) || cell.get_type() != Variant::VECTOR2I) {
            return reject("clears must hold {set: String, cell: Vector2i} dictionaries");
        }
        std::string name = to_std(String(set));
        if (!valid_set_name(name)) {
            return reject("invalid set name \"" + String(set) + "\" in clears");
        }
        touched_sets.insert(name);
        Vector2i c = cell;
        FileKey key{ name, c.x, c.y };
        FileJob &job = jobs[key];
        job.key = key;
        job.clear = true;
    }

    PointColumns columns;
    String error;
    if (!parse_columns(p_points, columns, error)) {
        return reject(error);
    }
    const int64_t n = columns.count;
    if (n > 0) {
        if (columns.set) {
            for (int64_t i = 0; i < n; i++) {
                if (columns.set[i] >= 0 && size_t(columns.set[i]) < columns.set_id.size()) {
                    touched_sets.insert(columns.sets[size_t(columns.set_id[size_t(columns.set[i])])]);
                }
            }
        } else {
            touched_sets.insert("default");
        }
    }
    std::vector<std::string> auto_register;
    if (!check_sets_access(p_directory, touched_sets, intent, auto_register, error)) {
        return reject(error);
    }

    // Validate every point and find its cell, in parallel chunks.
    std::vector<int32_t> point_cx(static_cast<size_t>(n)), point_cz(static_cast<size_t>(n));
    const int64_t chunk = 65536;
    const int64_t chunks = (n + chunk - 1) / chunk;
    std::vector<int64_t> bad_point(size_t(chunks), -1);
    std::vector<std::string> bad_reason(static_cast<size_t>(chunks));
    parallel_for(chunks, [&](int64_t c) {
        int64_t end = std::min(n, (c + 1) * chunk);
        for (int64_t i = c * chunk; i < end; i++) {
            const float *t = columns.transform + i * 12;
            const char *reason = nullptr;
            for (int k = 0; k < 12 && !reason; k++) {
                if (!std::isfinite(t[k])) {
                    reason = "transform is not finite";
                }
            }
            int32_t object = columns.object[i];
            if (!reason && (object < 0 || object >= columns.object_table_size || columns.paths[size_t(columns.path_id[size_t(object)])].empty())) {
                reason = "object index out of range or empty object path";
            }
            if (!reason && columns.set && (columns.set[i] < 0 || size_t(columns.set[i]) >= columns.set_id.size())) {
                reason = "set index out of range";
            }
            for (const float *data : { columns.color, columns.custom }) {
                if (!reason && data && !std::isnan(data[i * 4])) {
                    for (int k = 0; k < 4; k++) {
                        if (!std::isfinite(data[i * 4 + k])) {
                            reason = "color or custom value is not finite";
                        }
                    }
                }
            }
            if (!reason && columns.keep && !std::isfinite(columns.keep[i])) {
                reason = "keep is not finite";
            }
            if (!reason && (!cell_index(double(t[9]), p_cell_size, point_cx[size_t(i)]) || !cell_index(double(t[11]), p_cell_size, point_cz[size_t(i)]))) {
                reason = "origin is outside the cell grid's range";
            }
            if (reason) {
                bad_point[size_t(c)] = i;
                bad_reason[size_t(c)] = reason;
                return;
            }
        }
    });
    for (int64_t c = 0; c < chunks; c++) {
        if (bad_point[size_t(c)] >= 0) {
            return reject("point " + String::num_int64(bad_point[size_t(c)]) + ": " + to_godot(bad_reason[size_t(c)]));
        }
    }

    // Partition points by set and cell.
    {
        std::vector<std::unordered_map<uint64_t, FileJob *>> groups(columns.sets.size());
        int32_t last_set = -1;
        uint64_t last_key = 0;
        FileJob *last_job = nullptr;
        for (int64_t i = 0; i < n; i++) {
            int32_t set = columns.set ? columns.set_id[size_t(columns.set[i])] : 0;
            uint64_t key = (uint64_t(uint32_t(point_cx[size_t(i)])) << 32) | uint64_t(uint32_t(point_cz[size_t(i)]));
            if (!last_job || set != last_set || key != last_key) {
                FileJob *&slot = groups[size_t(set)][key];
                if (!slot) {
                    FileKey file_key{ columns.sets[size_t(set)], point_cx[size_t(i)], point_cz[size_t(i)] };
                    slot = &jobs[file_key];
                    slot->key = file_key;
                }
                last_set = set;
                last_key = key;
                last_job = slot;
            }
            last_job->points.push_back(uint32_t(i));
        }
    }

    std::vector<FileJob *> job_list;
    for (auto &entry : jobs) {
        job_list.push_back(&entry.second);
    }

    // Read, merge and encode every affected file. Nothing is written in this pass.
    const float cell_size_f = float(p_cell_size);
    parallel_for(int64_t(job_list.size()), [&](int64_t index) {
        FileJob &job = *job_list[size_t(index)];
        String path = set_file_path(p_directory, job.key.set, job.key.cx, job.key.cz);
        SetFile old;
        bool have_old = false;
        if (file_exists(path)) {
            Bytes data;
            std::string decode_error;
            bool read = job.clear ? read_file_prefix(path, SET_HEADER_SIZE, data) : read_file(path, data);
            if (!read || !decode_set_file(data, old, job.clear, decode_error)) {
                job.error = relative_set_path(job.key.set, job.key.cx, job.key.cz) + ": " + (read ? decode_error : "cannot read");
                return;
            }
            if (old.cell_size != cell_size_f) {
                job.error = relative_set_path(job.key.set, job.key.cx, job.key.cz) + ": stored cell size " + std::to_string(old.cell_size) + " differs from " + std::to_string(cell_size_f);
                return;
            }
            have_old = true;
        }
        SetFile next;
        next.cx = job.key.cx;
        next.cz = job.key.cz;
        next.cell_size = cell_size_f;
        if (have_old && !job.clear) {
            next.extras = old.extras;
        }
        if (!job.points.empty()) {
            for (const ExtraInput &input : columns.extras) {
                auto found = std::find_if(next.extras.begin(), next.extras.end(),
                        [&](const ExtraColumn &c) { return c.name == input.column.name; });
                if (found == next.extras.end()) {
                    next.extras.push_back(input.column);
                } else if (!found->same_kind(input.column)) {
                    job.error = relative_set_path(job.key.set, job.key.cx, job.key.cz) + ": extra column \"" + input.column.name + "\" is stored with another type or width";
                    return;
                }
            }
            std::sort(next.extras.begin(), next.extras.end(), [](const ExtraColumn &a, const ExtraColumn &b) { return a.name < b.name; });
        }
        const size_t stride = row_stride(next.extras);
        std::map<std::string, ObjectRows> merged;
        if (have_old && !job.clear) {
            for (ObjectRows &object : old.objects) {
                ObjectRows &target = merged[object.path];
                target.path = object.path;
                target.rows = old.extras.size() == next.extras.size() && row_stride(old.extras) == stride ? std::move(object.rows) : relayout_rows(object.rows, object.count, old.extras, next.extras);
                target.count = object.count;
            }
        }
        if (!job.points.empty()) {
            // Each target extra column's source in this call, or -1.
            std::vector<int> source(next.extras.size(), -1);
            std::vector<size_t> offset(next.extras.size());
            size_t at = ROW_FIXED;
            for (size_t e = 0; e < next.extras.size(); e++) {
                offset[e] = at;
                at += next.extras[e].bytes();
                for (size_t s = 0; s < columns.extras.size(); s++) {
                    if (columns.extras[s].column.name == next.extras[e].name) {
                        source[e] = int(s);
                    }
                }
            }
            std::vector<ObjectRows *> by_path(columns.paths.size(), nullptr);
            Bytes row(stride);
            for (uint32_t i : job.points) {
                int32_t path = columns.path_id[size_t(columns.object[i])];
                ObjectRows *&target = by_path[size_t(path)];
                if (!target) {
                    target = &merged[columns.paths[size_t(path)]];
                    target->path = columns.paths[size_t(path)];
                }
                std::fill(row.begin(), row.end(), 0);
                std::memcpy(row.data() + ROW_TRANSFORM, columns.transform + size_t(i) * 12, 48);
                for (int k = 0; k < 2; k++) {
                    const float *data = k == 0 ? columns.color : columns.custom;
                    size_t offset_bytes = k == 0 ? ROW_COLOR : ROW_CUSTOM;
                    if (data && !std::isnan(data[size_t(i) * 4])) {
                        std::memcpy(row.data() + offset_bytes, data + size_t(i) * 4, 16);
                    } else {
                        for (int c = 0; c < 4; c++) {
                            std::memcpy(row.data() + offset_bytes + c * 4, &NONE_BITS, 4);
                        }
                    }
                }
                float keep = columns.keep ? std::min(1.0f, std::max(0.0f, columns.keep[i])) : 1.0f;
                std::memcpy(row.data() + ROW_KEEP, &keep, 4);
                for (size_t e = 0; e < next.extras.size(); e++) {
                    if (source[e] >= 0) {
                        const ExtraInput &input = columns.extras[size_t(source[e])];
                        std::memcpy(row.data() + offset[e], input.data + size_t(i) * input.column.bytes(), input.column.bytes());
                    }
                }
                target->rows.insert(target->rows.end(), row.begin(), row.end());
                target->count++;
            }
        }
        for (auto &entry : merged) {
            canonical_sort(entry.second.rows, entry.second.count, stride);
            next.objects.push_back(std::move(entry.second));
        }
        if (next.objects.empty()) {
            job.outcome = have_old ? OUTCOME_DELETE : OUTCOME_NONE;
            return;
        }
        if (!encode_set_file(next, job.bytes)) {
            job.error = relative_set_path(job.key.set, job.key.cx, job.key.cz) + ": compression failed";
            return;
        }
        job.outcome = have_old && old.hash == next.hash ? OUTCOME_UNCHANGED : OUTCOME_WRITE;
        job.summary.ok = true;
        job.summary.cell_size = next.cell_size;
        job.summary.point_count = next.point_count;
        job.summary.hash = next.hash;
        for (const ObjectRows &object : next.objects) {
            job.summary.objects.push_back(object.path);
        }
        if (job.outcome == OUTCOME_UNCHANGED) {
            job.bytes.clear();
        }
    });
    for (FileJob *job : job_list) {
        if (!job->error.empty()) {
            return reject(to_godot(job->error));
        }
    }

    // Write and delete.
    std::vector<std::string> write_errors(job_list.size());
    std::vector<char> done(job_list.size(), 0);
    parallel_for(int64_t(job_list.size()), [&](int64_t index) {
        FileJob &job = *job_list[size_t(index)];
        String path = set_file_path(p_directory, job.key.set, job.key.cx, job.key.cz);
        if (job.outcome == OUTCOME_WRITE) {
            done[size_t(index)] = write_file_atomic(path, job.bytes, write_errors[size_t(index)]) ? 1 : 0;
        } else if (job.outcome == OUTCOME_DELETE) {
            done[size_t(index)] = remove_file(path) ? 1 : 0;
            if (!done[size_t(index)]) {
                write_errors[size_t(index)] = "cannot delete " + to_std(path);
            }
        }
    });

    PackedStringArray written, deleted, unchanged;
    std::set<std::pair<int32_t, int32_t>> cells;
    std::set<std::string> emptied_sets;
    String first_error;
    for (size_t i = 0; i < job_list.size(); i++) {
        const FileJob &job = *job_list[i];
        String relative = to_godot(relative_set_path(job.key.set, job.key.cx, job.key.cz));
        if (!write_errors[i].empty() && first_error.is_empty()) {
            first_error = to_godot(write_errors[i]);
        }
        if (job.outcome == OUTCOME_UNCHANGED) {
            unchanged.push_back(relative);
        } else if (done[i] && job.outcome == OUTCOME_WRITE) {
            written.push_back(relative);
            cells.insert({ job.key.cx, job.key.cz });
        } else if (done[i] && job.outcome == OUTCOME_DELETE) {
            deleted.push_back(relative);
            cells.insert({ job.key.cx, job.key.cz });
            emptied_sets.insert(job.key.set);
        }
    }
    // The index follows in the same call: what was written or deleted, then the files it lacks.
    if (!job_list.empty()) {
        std::lock_guard<std::mutex> lock(index_mutex());
        SetIndex index;
        const bool decoded = decode_set_index_file(p_directory, index);
        bool changed = !decoded;
        for (size_t i = 0; i < job_list.size(); i++) {
            const FileJob &job = *job_list[i];
            SetKey key(job.key.set, job.key.cx, job.key.cz);
            if ((job.outcome == OUTCOME_WRITE && done[i]) || job.outcome == OUTCOME_UNCHANGED) {
                index.put(key, job.summary);
                changed = changed || job.outcome == OUTCOME_WRITE;
            } else if (job.outcome == OUTCOME_DELETE && done[i]) {
                changed = index.entries.erase(key) > 0 || changed;
            }
        }
        int64_t read = 0;
        changed = reconcile_set_index(p_directory, index, false, false, read) || changed;
        std::string index_error;
        if (changed && !save_set_index(p_directory, index, index_error) && first_error.is_empty()) {
            first_error = to_godot("index: " + index_error);
        }
    }
    for (const std::string &set : emptied_sets) {
        String folder = p_directory.path_join("sets").path_join(to_godot(set));
        if (DirAccess::get_files_at(folder).is_empty() && DirAccess::get_directories_at(folder).is_empty()) {
            DirAccess::remove_absolute(folder);
        }
    }
    if (first_error.is_empty() && !auto_register.empty()) {
        String reg_error;
        if (!register_authored_sets(p_directory, auto_register, reg_error)) {
            first_error = reg_error;
        }
    }
    Array cell_list;
    for (const auto &cell : cells) {
        cell_list.push_back(Vector2i(cell.first, cell.second));
    }
    result["written"] = written;
    result["deleted"] = deleted;
    result["unchanged"] = unchanged;
    result["cells"] = cell_list;
    result["point_count"] = n;
    result["ok"] = first_error.is_empty();
    result["error"] = first_error;
    return result;
}

PackedStringArray CopiaSets::list_sets(const String &p_directory) {
    PackedStringArray names;
    for (const std::string &name : set_names_on_disk(p_directory)) {
        names.push_back(to_godot(name));
    }
    return names;
}

Array CopiaSets::list_cells(const String &p_directory, const String &p_set, bool p_verify) {
    Array cells;
    std::string set = to_std(p_set);
    if (!valid_set_name(set)) {
        return cells;
    }
    std::lock_guard<std::mutex> lock(index_mutex());
    SetIndex index;
    load_set_index(p_directory, index, p_verify);
    for (auto it = index.entries.lower_bound(SetKey(set, INT32_MIN, INT32_MIN)); it != index.entries.end() && std::get<0>(it->first) == set; ++it) {
        if (!it->second.ok) {
            continue;
        }
        Dictionary entry;
        entry["cell"] = Vector2i(std::get<1>(it->first), std::get<2>(it->first));
        entry["count"] = int64_t(it->second.point_count);
        entry["hash"] = to_godot(hash_hex(it->second.hash));
        cells.push_back(entry);
    }
    return cells;
}

PackedStringArray CopiaSets::list_objects(const String &p_directory, const Array &p_cells, bool p_verify) {
    std::set<std::pair<int32_t, int32_t>> wanted;
    for (int64_t i = 0; i < p_cells.size(); i++) {
        if (p_cells[i].get_type() == Variant::VECTOR2I) {
            Vector2i cell = p_cells[i];
            wanted.insert({ cell.x, cell.y });
        }
    }
    std::lock_guard<std::mutex> lock(index_mutex());
    SetIndex index;
    load_set_index(p_directory, index, p_verify);
    std::vector<char> used(index.strings.names.size(), 0);
    for (const auto &item : index.entries) {
        if (item.second.ok && (wanted.empty() || wanted.count({ std::get<1>(item.first), std::get<2>(item.first) }))) {
            for (uint32_t id : item.second.objects) {
                used[id] = 1;
            }
        }
    }
    std::vector<std::string> paths;
    for (size_t id = 0; id < used.size(); id++) {
        if (used[id]) {
            paths.push_back(index.strings.get(uint32_t(id)));
        }
    }
    std::sort(paths.begin(), paths.end());
    PackedStringArray result;
    for (const std::string &path : paths) {
        result.push_back(to_godot(path));
    }
    return result;
}

Dictionary CopiaSets::cell_points(const String &p_directory, double p_cell_size, const Rect2 &p_rect,
        const PackedStringArray &p_sets, const PackedStringArray &p_exclude, bool p_verify) {
    std::set<std::string> wanted, excluded;
    for (int64_t i = 0; i < p_sets.size(); i++) {
        wanted.insert(to_std(p_sets[i]));
    }
    for (int64_t i = 0; i < p_exclude.size(); i++) {
        excluded.insert(to_std(p_exclude[i]));
    }
    const Rect2 rect = p_rect.abs();
    const bool everywhere = !(rect.size.x > 0.0f && rect.size.y > 0.0f);
    const double x0 = rect.position.x, z0 = rect.position.y;
    const double x1 = x0 + double(rect.size.x), z1 = z0 + double(rect.size.y);
    // (cx, cz, set) -> points, so rows are ordered by cell, then set name.
    std::map<std::tuple<int32_t, int32_t, std::string>, int64_t> rows;
    if (std::isfinite(p_cell_size) && p_cell_size > 0.0) {
        std::lock_guard<std::mutex> lock(index_mutex());
        SetIndex index;
        load_set_index(p_directory, index, p_verify);
        for (const auto &item : index.entries) {
            const std::string &set = std::get<0>(item.first);
            if (!item.second.ok || item.second.point_count == 0 || (!wanted.empty() && !wanted.count(set)) || excluded.count(set)) {
                continue;
            }
            const int32_t cx = std::get<1>(item.first), cz = std::get<2>(item.first);
            const double cx0 = double(cx) * p_cell_size, cz0 = double(cz) * p_cell_size;
            if (everywhere || (cx0 < x1 && cx0 + p_cell_size > x0 && cz0 < z1 && cz0 + p_cell_size > z0)) {
                rows[{ cx, cz, set }] += int64_t(item.second.point_count);
            }
        }
    }
    PackedVector3Array position, cell_min, cell_max;
    PackedStringArray cell, set;
    PackedInt32Array count;
    for (const auto &row : rows) {
        const double cx = std::get<0>(row.first), cz = std::get<1>(row.first);
        position.push_back(Vector3(real_t((cx + 0.5) * p_cell_size), 0, real_t((cz + 0.5) * p_cell_size)));
        cell_min.push_back(Vector3(real_t(cx * p_cell_size), 0, real_t(cz * p_cell_size)));
        cell_max.push_back(Vector3(real_t((cx + 1.0) * p_cell_size), 0, real_t((cz + 1.0) * p_cell_size)));
        cell.push_back(to_godot(cell_name(std::get<0>(row.first), std::get<1>(row.first))));
        set.push_back(to_godot(std::get<2>(row.first)));
        count.push_back(int32_t(std::min<int64_t>(row.second, INT32_MAX)));
    }
    Dictionary result;
    result["P"] = position;
    result["cell"] = cell;
    result["set"] = set;
    result["count"] = count;
    result["cell_min"] = cell_min;
    result["cell_max"] = cell_max;
    return result;
}

Dictionary CopiaSets::reindex(const String &p_directory) {
    std::lock_guard<std::mutex> lock(index_mutex());
    SetIndex index;
    int64_t read = 0;
    reconcile_set_index(p_directory, index, true, true, read);
    int64_t unreadable = 0;
    for (const auto &item : index.entries) {
        unreadable += item.second.ok ? 0 : 1;
    }
    std::string error;
    bool ok = save_set_index(p_directory, index, error);
    Dictionary result;
    result["ok"] = ok;
    result["error"] = to_godot(error);
    result["files"] = int64_t(index.entries.size());
    result["unreadable"] = unreadable;
    return result;
}

Dictionary CopiaSets::read_points(const String &p_directory, double p_cell_size, const Rect2 &p_rect,
        const PackedStringArray &p_sets, const PackedStringArray &p_exclude) {
    Dictionary result;
    Rect2 rect = p_rect.abs();
    const double x0 = rect.position.x, z0 = rect.position.y;
    const double x1 = x0 + double(rect.size.x), z1 = z0 + double(rect.size.y);
    std::set<std::string> wanted, excluded;
    for (int64_t i = 0; i < p_sets.size(); i++) {
        wanted.insert(to_std(p_sets[i]));
    }
    for (int64_t i = 0; i < p_exclude.size(); i++) {
        excluded.insert(to_std(p_exclude[i]));
    }
    struct Source {
        std::string set;
        int32_t cx, cz;
        SetFile file;
        bool ok = false;
    };
    std::vector<Source> sources;
    for (const std::string &set : set_names_on_disk(p_directory)) {
        if ((!wanted.empty() && !wanted.count(set)) || excluded.count(set)) {
            continue;
        }
        for (const auto &cell : set_cells_on_disk(p_directory, set)) {
            double cx0 = double(cell.first) * p_cell_size, cz0 = double(cell.second) * p_cell_size;
            if (cx0 < x1 && cx0 + p_cell_size > x0 && cz0 < z1 && cz0 + p_cell_size > z0) {
                Source source;
                source.set = set;
                source.cx = cell.first;
                source.cz = cell.second;
                sources.push_back(source);
            }
        }
    }
    parallel_for(int64_t(sources.size()), [&](int64_t i) {
        Source &source = sources[size_t(i)];
        Bytes data;
        std::string error;
        source.ok = read_file(set_file_path(p_directory, source.set, source.cx, source.cz), data) &&
                decode_set_file(data, source.file, false, error);
        if (!source.ok) {
            UtilityFunctions::push_warning("Copia: cannot read set file ", to_godot(source.set + "/" + cell_name(source.cx, source.cz)), ": ", to_godot(error));
        }
    });

    // Selected rows per source, and the output columns' union.
    std::vector<std::vector<std::pair<size_t, uint32_t>>> selected(sources.size());
    std::set<std::string> paths;
    std::vector<std::string> set_names;
    std::vector<ExtraColumn> extras;
    uint32_t flags = 0;
    int64_t total = 0;
    for (size_t s = 0; s < sources.size(); s++) {
        Source &source = sources[s];
        if (!source.ok) {
            continue;
        }
        size_t stride = row_stride(source.file.extras);
        for (size_t o = 0; o < source.file.objects.size(); o++) {
            const ObjectRows &object = source.file.objects[o];
            for (uint32_t r = 0; r < object.count; r++) {
                const float *t = reinterpret_cast<const float *>(object.rows.data() + size_t(r) * stride);
                double x = t[9], z = t[11];
                if (x >= x0 && x < x1 && z >= z0 && z < z1) {
                    selected[s].emplace_back(o, r);
                    paths.insert(object.path);
                }
            }
        }
        if (selected[s].empty()) {
            continue;
        }
        total += int64_t(selected[s].size());
        flags |= source.file.flags;
        if (set_names.empty() || set_names.back() != source.set) {
            set_names.push_back(source.set);
        }
        for (const ExtraColumn &column : source.file.extras) {
            auto found = std::find_if(extras.begin(), extras.end(), [&](const ExtraColumn &c) { return c.name == column.name; });
            if (found == extras.end()) {
                extras.push_back(column);
            } else if (!found->same_kind(column)) {
                UtilityFunctions::push_warning("Copia: extra column \"", to_godot(column.name), "\" has another type in set ", to_godot(source.set), "; those values read as zero");
            }
        }
    }
    std::sort(extras.begin(), extras.end(), [](const ExtraColumn &a, const ExtraColumn &b) { return a.name < b.name; });
    std::vector<std::string> path_list(paths.begin(), paths.end());

    PackedFloat32Array transform, color, custom, keep;
    PackedInt32Array object, set;
    transform.resize(total * 12);
    object.resize(total);
    set.resize(total);
    if (flags & COLUMN_COLOR) {
        color.resize(total * 4);
    }
    if (flags & COLUMN_CUSTOM) {
        custom.resize(total * 4);
    }
    if (flags & COLUMN_KEEP) {
        keep.resize(total);
    }
    std::vector<Bytes> extra_out(extras.size());
    for (size_t e = 0; e < extras.size(); e++) {
        extra_out[e].assign(size_t(total) * extras[e].bytes(), 0);
    }
    int64_t at = 0;
    for (size_t s = 0; s < sources.size(); s++) {
        if (selected[s].empty()) {
            continue;
        }
        const Source &source = sources[s];
        size_t stride = row_stride(source.file.extras);
        int32_t set_index = int32_t(std::lower_bound(set_names.begin(), set_names.end(), source.set) - set_names.begin());
        // Each output extra column's byte offset in this file's rows, or SIZE_MAX.
        std::vector<size_t> offsets(extras.size(), SIZE_MAX);
        size_t offset = ROW_FIXED;
        for (const ExtraColumn &column : source.file.extras) {
            for (size_t e = 0; e < extras.size(); e++) {
                if (extras[e].name == column.name && extras[e].same_kind(column)) {
                    offsets[e] = offset;
                }
            }
            offset += column.bytes();
        }
        std::vector<int32_t> object_index(source.file.objects.size());
        for (size_t o = 0; o < source.file.objects.size(); o++) {
            object_index[o] = int32_t(std::lower_bound(path_list.begin(), path_list.end(), source.file.objects[o].path) - path_list.begin());
        }
        for (const auto &pick : selected[s]) {
            const uint8_t *row = source.file.objects[pick.first].rows.data() + size_t(pick.second) * stride;
            std::memcpy(transform.ptrw() + at * 12, row + ROW_TRANSFORM, 48);
            object.set(at, object_index[pick.first]);
            set.set(at, set_index);
            if (flags & COLUMN_COLOR) {
                std::memcpy(color.ptrw() + at * 4, row + ROW_COLOR, 16);
            }
            if (flags & COLUMN_CUSTOM) {
                std::memcpy(custom.ptrw() + at * 4, row + ROW_CUSTOM, 16);
            }
            if (flags & COLUMN_KEEP) {
                std::memcpy(keep.ptrw() + at, row + ROW_KEEP, 4);
            }
            for (size_t e = 0; e < extras.size(); e++) {
                if (offsets[e] != SIZE_MAX) {
                    std::memcpy(extra_out[e].data() + size_t(at) * extras[e].bytes(), row + offsets[e], extras[e].bytes());
                }
            }
            at++;
        }
    }
    PackedStringArray object_paths, set_name_array;
    for (const std::string &path : path_list) {
        object_paths.push_back(to_godot(path));
    }
    for (const std::string &name : set_names) {
        set_name_array.push_back(to_godot(name));
    }
    result["count"] = total;
    result["transform"] = transform;
    result["object"] = object;
    result["object_paths"] = object_paths;
    result["set"] = set;
    result["set_names"] = set_name_array;
    if (flags & COLUMN_COLOR) {
        result["color"] = color;
    }
    if (flags & COLUMN_CUSTOM) {
        result["custom"] = custom;
    }
    if (flags & COLUMN_KEEP) {
        result["keep"] = keep;
    }
    if (!extras.empty()) {
        Dictionary extra;
        for (size_t e = 0; e < extras.size(); e++) {
            if (extras[e].type == EXTRA_INT32) {
                PackedInt32Array values;
                values.resize(total);
                if (total) {
                    std::memcpy(values.ptrw(), extra_out[e].data(), extra_out[e].size());
                }
                extra[to_godot(extras[e].name)] = values;
            } else {
                PackedFloat32Array values;
                values.resize(total * extras[e].width);
                if (total) {
                    std::memcpy(values.ptrw(), extra_out[e].data(), extra_out[e].size());
                }
                extra[to_godot(extras[e].name)] = values;
            }
        }
        result["extra"] = extra;
    }
    return result;
}

Dictionary CopiaSets::set_meta(const String &p_directory, const String &p_set, const String &p_kind, bool p_locked) {
    Dictionary result;
    result["ok"] = false;
    result["error"] = String();
    result["set"] = p_set;
    result["kind"] = p_kind;
    result["locked"] = p_locked;
    if (p_directory.is_empty()) {
        result["error"] = "directory is empty";
        return result;
    }
    std::string set = to_std(p_set);
    if (!valid_set_name(set)) {
        result["error"] = "invalid set name \"" + p_set + "\" (use 1 to 64 of a-z, 0-9, _)";
        return result;
    }
    std::string kind = to_std(p_kind);
    if (!valid_set_kind(kind)) {
        result["error"] = "invalid set kind \"" + p_kind + "\" (use \"generated\" or \"authored\")";
        return result;
    }
    std::lock_guard<std::mutex> lock(index_mutex());
    std::map<std::string, SetMeta> manifest = load_manifest_locked(p_directory);
    SetMeta meta;
    meta.kind = kind;
    meta.locked = p_locked;
    manifest[set] = meta;
    std::string io_error;
    if (!save_manifest_locked(p_directory, manifest, io_error)) {
        result["error"] = to_godot("manifest: " + io_error);
        return result;
    }
    result["ok"] = true;
    return result;
}

Dictionary CopiaSets::get_sets_meta(const String &p_directory) {
    Dictionary result;
    if (p_directory.is_empty()) {
        return result;
    }
    std::lock_guard<std::mutex> lock(index_mutex());
    std::map<std::string, SetMeta> manifest = load_manifest_locked(p_directory);
    for (const std::string &name : set_names_on_disk(p_directory)) {
        if (manifest.find(name) == manifest.end()) {
            manifest[name] = SetMeta{};
        }
    }
    for (const auto &entry : manifest) {
        Dictionary info;
        info["kind"] = to_godot(entry.second.kind);
        info["locked"] = entry.second.locked;
        result[to_godot(entry.first)] = info;
    }
    return result;
}

Dictionary CopiaSets::edit_points(const String &p_directory, double p_cell_size, const String &p_set,
        const Dictionary &p_removes, const Dictionary &p_adds, const String &p_intent) {
    Dictionary result;
    result["ok"] = false;
    result["error"] = String();
    result["written"] = PackedStringArray();
    result["deleted"] = PackedStringArray();
    result["unchanged"] = PackedStringArray();
    result["cells"] = Array();
    result["removed_count"] = 0;
    result["added_count"] = 0;
    auto reject = [&](const String &p_message) {
        result["error"] = p_message;
        return result;
    };
    if (!std::isfinite(p_cell_size) || p_cell_size <= 0.0) {
        return reject("cell_size must be a positive number");
    }
    if (p_directory.is_empty()) {
        return reject("directory is empty");
    }
    const std::string set_name = to_std(p_set);
    if (!valid_set_name(set_name)) {
        return reject("invalid set name \"" + p_set + "\" (use 1 to 64 of a-z, 0-9, _)");
    }
    const std::string intent = to_std(p_intent);
    std::vector<std::string> auto_register;
    String access_error;
    if (!check_sets_access(p_directory, { set_name }, intent, auto_register, access_error)) {
        return reject(access_error);
    }

    PointColumns removes;
    PointColumns adds;
    String error;
    if (!parse_columns(p_removes, removes, error)) {
        return reject("removes: " + error);
    }
    if (!parse_columns(p_adds, adds, error)) {
        return reject("adds: " + error);
    }
    if (removes.count == 0 && adds.count == 0) {
        result["ok"] = true;
        return result;
    }

    struct EditCellJob {
        int32_t cx = 0;
        int32_t cz = 0;
        std::vector<uint32_t> remove_indices;
        std::vector<uint32_t> add_indices;
        Outcome outcome = OUTCOME_NONE;
        Bytes bytes;
        std::string error;
        SetSummary summary;
        int64_t removed_count = 0;
    };
    std::map<std::pair<int32_t, int32_t>, EditCellJob> jobs;

    for (int64_t i = 0; i < removes.count; i++) {
        const float *t = removes.transform + i * 12;
        for (int k = 0; k < 12; k++) {
            if (!std::isfinite(t[k])) {
                return reject("remove point " + String::num_int64(i) + ": transform is not finite");
            }
        }
        int32_t obj = removes.object[i];
        if (obj < 0 || obj >= removes.object_table_size || removes.paths[size_t(removes.path_id[size_t(obj)])].empty()) {
            return reject("remove point " + String::num_int64(i) + ": invalid object index");
        }
        int32_t cx = 0, cz = 0;
        if (!cell_index(double(t[9]), p_cell_size, cx) || !cell_index(double(t[11]), p_cell_size, cz)) {
            return reject("remove point " + String::num_int64(i) + ": origin out of cell grid range");
        }
        EditCellJob &job = jobs[{ cx, cz }];
        job.cx = cx;
        job.cz = cz;
        job.remove_indices.push_back(uint32_t(i));
    }

    for (int64_t i = 0; i < adds.count; i++) {
        const float *t = adds.transform + i * 12;
        for (int k = 0; k < 12; k++) {
            if (!std::isfinite(t[k])) {
                return reject("add point " + String::num_int64(i) + ": transform is not finite");
            }
        }
        int32_t obj = adds.object[i];
        if (obj < 0 || obj >= adds.object_table_size || adds.paths[size_t(adds.path_id[size_t(obj)])].empty()) {
            return reject("add point " + String::num_int64(i) + ": invalid object index");
        }
        for (const float *data : { adds.color, adds.custom }) {
            if (data && !std::isnan(data[i * 4])) {
                for (int k = 0; k < 4; k++) {
                    if (!std::isfinite(data[i * 4 + k])) {
                        return reject("add point " + String::num_int64(i) + ": color or custom value is not finite");
                    }
                }
            }
        }
        if (adds.keep && !std::isfinite(adds.keep[i])) {
            return reject("add point " + String::num_int64(i) + ": keep is not finite");
        }
        int32_t cx = 0, cz = 0;
        if (!cell_index(double(t[9]), p_cell_size, cx) || !cell_index(double(t[11]), p_cell_size, cz)) {
            return reject("add point " + String::num_int64(i) + ": origin out of cell grid range");
        }
        EditCellJob &job = jobs[{ cx, cz }];
        job.cx = cx;
        job.cz = cz;
        job.add_indices.push_back(uint32_t(i));
    }

    std::vector<EditCellJob *> job_list;
    for (auto &entry : jobs) {
        job_list.push_back(&entry.second);
    }

    const float cell_size_f = float(p_cell_size);
    constexpr float MATCH_EPS = 1e-4f;
    parallel_for(int64_t(job_list.size()), [&](int64_t index) {
        EditCellJob &job = *job_list[size_t(index)];
        String path = set_file_path(p_directory, set_name, job.cx, job.cz);
        SetFile old;
        bool have_old = false;
        if (file_exists(path)) {
            Bytes data;
            std::string decode_error;
            bool read = read_file(path, data);
            if (!read || !decode_set_file(data, old, false, decode_error)) {
                job.error = relative_set_path(set_name, job.cx, job.cz) + ": " + (read ? decode_error : "cannot read");
                return;
            }
            if (old.cell_size != cell_size_f) {
                job.error = relative_set_path(set_name, job.cx, job.cz) + ": stored cell size differs";
                return;
            }
            have_old = true;
        }
        SetFile next;
        next.cx = job.cx;
        next.cz = job.cz;
        next.cell_size = cell_size_f;
        if (have_old) {
            next.extras = old.extras;
        }
        if (!job.add_indices.empty()) {
            for (const ExtraInput &input : adds.extras) {
                auto found = std::find_if(next.extras.begin(), next.extras.end(),
                        [&](const ExtraColumn &c) { return c.name == input.column.name; });
                if (found == next.extras.end()) {
                    next.extras.push_back(input.column);
                } else if (!found->same_kind(input.column)) {
                    job.error = relative_set_path(set_name, job.cx, job.cz) + ": extra column \"" + input.column.name + "\" type mismatch";
                    return;
                }
            }
            std::sort(next.extras.begin(), next.extras.end(), [](const ExtraColumn &a, const ExtraColumn &b) { return a.name < b.name; });
        }

        const size_t stride = row_stride(next.extras);
        std::map<std::string, ObjectRows> merged;
        if (have_old) {
            // Group remove indices by object path for fast lookup.
            std::unordered_map<std::string, std::vector<uint32_t>> removes_by_path;
            for (uint32_t ri : job.remove_indices) {
                const std::string &opath = removes.paths[size_t(removes.path_id[size_t(removes.object[ri])])];
                removes_by_path[opath].push_back(ri);
            }
            const size_t old_stride = row_stride(old.extras);
            const bool same_layout = old.extras.size() == next.extras.size() && old_stride == stride;
            for (ObjectRows &object : old.objects) {
                auto rit = removes_by_path.find(object.path);
                if (rit == removes_by_path.end()) {
                    ObjectRows &target = merged[object.path];
                    target.path = object.path;
                    target.rows = same_layout ? std::move(object.rows) : relayout_rows(object.rows, object.count, old.extras, next.extras);
                    target.count = object.count;
                    continue;
                }
                std::vector<char> drop(object.count, 0);
                for (uint32_t ri : rit->second) {
                    const float *rt = removes.transform + size_t(ri) * 12;
                    int64_t best = -1;
                    float best_err = MATCH_EPS + 1.0f;
                    for (uint32_t r = 0; r < object.count; r++) {
                        if (drop[r]) {
                            continue;
                        }
                        const float *ot = reinterpret_cast<const float *>(object.rows.data() + size_t(r) * old_stride + ROW_TRANSFORM);
                        if (std::memcmp(ot, rt, 48) == 0) {
                            best = int64_t(r);
                            best_err = 0.0f;
                            break;
                        }
                        float max_diff = 0.0f;
                        for (int k = 0; k < 12; k++) {
                            float d = std::fabs(ot[k] - rt[k]);
                            if (d > max_diff) {
                                max_diff = d;
                                if (max_diff > MATCH_EPS) {
                                    break;
                                }
                            }
                        }
                        if (max_diff <= MATCH_EPS && max_diff < best_err) {
                            best = int64_t(r);
                            best_err = max_diff;
                        }
                    }
                    if (best >= 0) {
                        drop[size_t(best)] = 1;
                        job.removed_count++;
                    }
                }
                Bytes kept;
                uint32_t kept_count = 0;
                kept.reserve(object.rows.size());
                for (uint32_t r = 0; r < object.count; r++) {
                    if (!drop[r]) {
                        const uint8_t *src = object.rows.data() + size_t(r) * old_stride;
                        kept.insert(kept.end(), src, src + old_stride);
                        kept_count++;
                    }
                }
                if (kept_count > 0) {
                    ObjectRows &target = merged[object.path];
                    target.path = object.path;
                    target.rows = same_layout ? std::move(kept) : relayout_rows(kept, kept_count, old.extras, next.extras);
                    target.count = kept_count;
                }
            }
        }

        if (!job.add_indices.empty()) {
            std::vector<int> source(next.extras.size(), -1);
            std::vector<size_t> offset(next.extras.size());
            size_t at = ROW_FIXED;
            for (size_t e = 0; e < next.extras.size(); e++) {
                offset[e] = at;
                at += next.extras[e].bytes();
                for (size_t s = 0; s < adds.extras.size(); s++) {
                    if (adds.extras[s].column.name == next.extras[e].name) {
                        source[e] = int(s);
                    }
                }
            }
            std::vector<ObjectRows *> by_path(adds.paths.size(), nullptr);
            Bytes row(stride);
            for (uint32_t i : job.add_indices) {
                int32_t pid = adds.path_id[size_t(adds.object[i])];
                ObjectRows *&target = by_path[size_t(pid)];
                if (!target) {
                    target = &merged[adds.paths[size_t(pid)]];
                    target->path = adds.paths[size_t(pid)];
                }
                std::fill(row.begin(), row.end(), 0);
                std::memcpy(row.data() + ROW_TRANSFORM, adds.transform + size_t(i) * 12, 48);
                for (int k = 0; k < 2; k++) {
                    const float *data = k == 0 ? adds.color : adds.custom;
                    size_t offset_bytes = k == 0 ? ROW_COLOR : ROW_CUSTOM;
                    if (data && !std::isnan(data[size_t(i) * 4])) {
                        std::memcpy(row.data() + offset_bytes, data + size_t(i) * 4, 16);
                    } else {
                        for (int c = 0; c < 4; c++) {
                            std::memcpy(row.data() + offset_bytes + c * 4, &NONE_BITS, 4);
                        }
                    }
                }
                float keep = adds.keep ? std::min(1.0f, std::max(0.0f, adds.keep[i])) : 1.0f;
                std::memcpy(row.data() + ROW_KEEP, &keep, 4);
                for (size_t e = 0; e < next.extras.size(); e++) {
                    if (source[e] >= 0) {
                        const ExtraInput &input = adds.extras[size_t(source[e])];
                        std::memcpy(row.data() + offset[e], input.data + size_t(i) * input.column.bytes(), input.column.bytes());
                    }
                }
                target->rows.insert(target->rows.end(), row.begin(), row.end());
                target->count++;
            }
        }

        for (auto &entry : merged) {
            canonical_sort(entry.second.rows, entry.second.count, stride);
            next.objects.push_back(std::move(entry.second));
        }
        if (next.objects.empty()) {
            job.outcome = have_old ? OUTCOME_DELETE : OUTCOME_NONE;
            return;
        }
        if (!encode_set_file(next, job.bytes)) {
            job.error = relative_set_path(set_name, job.cx, job.cz) + ": compression failed";
            return;
        }
        job.outcome = have_old && old.hash == next.hash ? OUTCOME_UNCHANGED : OUTCOME_WRITE;
        job.summary.ok = true;
        job.summary.cell_size = next.cell_size;
        job.summary.point_count = next.point_count;
        job.summary.hash = next.hash;
        for (const ObjectRows &object : next.objects) {
            job.summary.objects.push_back(object.path);
        }
        if (job.outcome == OUTCOME_UNCHANGED) {
            job.bytes.clear();
        }
    });

    for (EditCellJob *job : job_list) {
        if (!job->error.empty()) {
            return reject(to_godot(job->error));
        }
    }

    std::vector<std::string> write_errors(job_list.size());
    std::vector<char> done(job_list.size(), 0);
    parallel_for(int64_t(job_list.size()), [&](int64_t index) {
        EditCellJob &job = *job_list[size_t(index)];
        String path = set_file_path(p_directory, set_name, job.cx, job.cz);
        if (job.outcome == OUTCOME_WRITE) {
            done[size_t(index)] = write_file_atomic(path, job.bytes, write_errors[size_t(index)]) ? 1 : 0;
        } else if (job.outcome == OUTCOME_DELETE) {
            done[size_t(index)] = remove_file(path) ? 1 : 0;
            if (!done[size_t(index)]) {
                write_errors[size_t(index)] = "cannot delete " + to_std(path);
            }
        }
    });

    PackedStringArray written, deleted, unchanged;
    std::set<std::pair<int32_t, int32_t>> cells;
    bool deleted_any = false;
    int64_t removed_total = 0;
    String first_error;
    for (size_t i = 0; i < job_list.size(); i++) {
        const EditCellJob &job = *job_list[i];
        removed_total += job.removed_count;
        String relative = to_godot(relative_set_path(set_name, job.cx, job.cz));
        if (!write_errors[i].empty() && first_error.is_empty()) {
            first_error = to_godot(write_errors[i]);
        }
        if (job.outcome == OUTCOME_UNCHANGED) {
            unchanged.push_back(relative);
        } else if (done[i] && job.outcome == OUTCOME_WRITE) {
            written.push_back(relative);
            cells.insert({ job.cx, job.cz });
        } else if (done[i] && job.outcome == OUTCOME_DELETE) {
            deleted.push_back(relative);
            cells.insert({ job.cx, job.cz });
            deleted_any = true;
        }
    }

    if (!job_list.empty()) {
        std::lock_guard<std::mutex> lock(index_mutex());
        SetIndex index;
        const bool decoded = decode_set_index_file(p_directory, index);
        bool changed = !decoded;
        for (size_t i = 0; i < job_list.size(); i++) {
            const EditCellJob &job = *job_list[i];
            SetKey key(set_name, job.cx, job.cz);
            if ((job.outcome == OUTCOME_WRITE && done[i]) || job.outcome == OUTCOME_UNCHANGED) {
                index.put(key, job.summary);
                changed = changed || job.outcome == OUTCOME_WRITE;
            } else if (job.outcome == OUTCOME_DELETE && done[i]) {
                changed = index.entries.erase(key) > 0 || changed;
            }
        }
        int64_t read = 0;
        changed = reconcile_set_index(p_directory, index, false, false, read) || changed;
        std::string index_error;
        if (changed && !save_set_index(p_directory, index, index_error) && first_error.is_empty()) {
            first_error = to_godot("index: " + index_error);
        }
    }
    if (deleted_any) {
        String folder = p_directory.path_join("sets").path_join(p_set);
        if (DirAccess::dir_exists_absolute(folder) && DirAccess::get_files_at(folder).is_empty() && DirAccess::get_directories_at(folder).is_empty()) {
            DirAccess::remove_absolute(folder);
        }
    }
    if (first_error.is_empty() && !auto_register.empty() && adds.count > 0) {
        String reg_error;
        if (!register_authored_sets(p_directory, auto_register, reg_error)) {
            first_error = reg_error;
        }
    }

    Array cell_list;
    for (const auto &cell : cells) {
        cell_list.push_back(Vector2i(cell.first, cell.second));
    }
    result["written"] = written;
    result["deleted"] = deleted;
    result["unchanged"] = unchanged;
    result["cells"] = cell_list;
    result["removed_count"] = removed_total;
    result["added_count"] = adds.count;
    result["ok"] = first_error.is_empty();
    result["error"] = first_error;
    return result;
}

Dictionary CopiaSets::erase_in_sphere(const String &p_directory, double p_cell_size, const String &p_set,
        const Vector3 &p_center, double p_radius, const PackedStringArray &p_object_filter, const String &p_intent) {
    Dictionary result;
    result["ok"] = false;
    result["error"] = String();
    result["cells"] = Array();
    result["removed_count"] = 0;
    result["removed_points"] = Dictionary();
    auto reject = [&](const String &p_message) {
        result["error"] = p_message;
        return result;
    };
    if (!std::isfinite(p_cell_size) || p_cell_size <= 0.0) {
        return reject("cell_size must be a positive number");
    }
    if (!std::isfinite(p_radius) || p_radius <= 0.0) {
        return reject("radius must be a positive number");
    }
    if (!std::isfinite(p_center.x) || !std::isfinite(p_center.y) || !std::isfinite(p_center.z)) {
        return reject("center is not finite");
    }
    if (p_directory.is_empty()) {
        return reject("directory is empty");
    }
    const std::string set_name = to_std(p_set);
    if (!valid_set_name(set_name)) {
        return reject("invalid set name \"" + p_set + "\"");
    }
    std::vector<std::string> auto_register;
    String access_error;
    if (!check_sets_access(p_directory, { set_name }, to_std(p_intent), auto_register, access_error)) {
        return reject(access_error);
    }

    std::set<std::string> filter;
    for (int64_t i = 0; i < p_object_filter.size(); i++) {
        filter.insert(to_std(p_object_filter[i]));
    }
    const double x0 = double(p_center.x) - p_radius, x1 = double(p_center.x) + p_radius;
    const double z0 = double(p_center.z) - p_radius, z1 = double(p_center.z) + p_radius;
    const double r2 = p_radius * p_radius;

    struct SphereCellJob {
        int32_t cx = 0;
        int32_t cz = 0;
        SetFile removed_file;
        Outcome outcome = OUTCOME_NONE;
        Bytes bytes;
        std::string error;
        SetSummary summary;
    };
    std::vector<SphereCellJob> jobs;
    for (const auto &cell : set_cells_on_disk(p_directory, set_name)) {
        double cx0 = double(cell.first) * p_cell_size, cz0 = double(cell.second) * p_cell_size;
        if (cx0 <= x1 && cx0 + p_cell_size >= x0 && cz0 <= z1 && cz0 + p_cell_size >= z0) {
            SphereCellJob job;
            job.cx = cell.first;
            job.cz = cell.second;
            jobs.push_back(std::move(job));
        }
    }
    if (jobs.empty()) {
        result["ok"] = true;
        return result;
    }

    const float cell_size_f = float(p_cell_size);
    parallel_for(int64_t(jobs.size()), [&](int64_t index) {
        SphereCellJob &job = jobs[size_t(index)];
        String path = set_file_path(p_directory, set_name, job.cx, job.cz);
        Bytes data;
        std::string decode_error;
        SetFile old;
        if (!read_file(path, data) || !decode_set_file(data, old, false, decode_error)) {
            job.error = relative_set_path(set_name, job.cx, job.cz) + ": " + (decode_error.empty() ? "cannot read" : decode_error);
            return;
        }
        if (old.cell_size != cell_size_f) {
            job.error = relative_set_path(set_name, job.cx, job.cz) + ": stored cell size differs";
            return;
        }
        const size_t stride = row_stride(old.extras);
        SetFile next;
        next.cx = job.cx;
        next.cz = job.cz;
        next.cell_size = cell_size_f;
        next.extras = old.extras;
        job.removed_file.extras = old.extras;
        job.removed_file.flags = old.flags;

        bool removed_any = false;
        for (const ObjectRows &object : old.objects) {
            if (!filter.empty() && filter.count(object.path) == 0) {
                next.objects.push_back(object);
                continue;
            }
            ObjectRows kept, dropped;
            kept.path = object.path;
            dropped.path = object.path;
            for (uint32_t r = 0; r < object.count; r++) {
                const uint8_t *row = object.rows.data() + size_t(r) * stride;
                const float *t = reinterpret_cast<const float *>(row + ROW_TRANSFORM);
                double dx = double(t[9]) - double(p_center.x);
                double dy = double(t[10]) - double(p_center.y);
                double dz = double(t[11]) - double(p_center.z);
                if (dx * dx + dy * dy + dz * dz <= r2) {
                    dropped.rows.insert(dropped.rows.end(), row, row + stride);
                    dropped.count++;
                    removed_any = true;
                } else {
                    kept.rows.insert(kept.rows.end(), row, row + stride);
                    kept.count++;
                }
            }
            if (kept.count > 0) {
                next.objects.push_back(std::move(kept));
            }
            if (dropped.count > 0) {
                job.removed_file.point_count += dropped.count;
                job.removed_file.objects.push_back(std::move(dropped));
            }
        }
        if (!removed_any) {
            job.outcome = OUTCOME_UNCHANGED;
            return;
        }
        if (next.objects.empty()) {
            job.outcome = OUTCOME_DELETE;
            return;
        }
        if (!encode_set_file(next, job.bytes)) {
            job.error = relative_set_path(set_name, job.cx, job.cz) + ": compression failed";
            return;
        }
        job.outcome = OUTCOME_WRITE;
        job.summary.ok = true;
        job.summary.cell_size = next.cell_size;
        job.summary.point_count = next.point_count;
        job.summary.hash = next.hash;
        for (const ObjectRows &object : next.objects) {
            job.summary.objects.push_back(object.path);
        }
    });

    for (const SphereCellJob &job : jobs) {
        if (!job.error.empty()) {
            return reject(to_godot(job.error));
        }
    }

    std::vector<std::string> write_errors(jobs.size());
    std::vector<char> done(jobs.size(), 0);
    parallel_for(int64_t(jobs.size()), [&](int64_t index) {
        const SphereCellJob &job = jobs[size_t(index)];
        String path = set_file_path(p_directory, set_name, job.cx, job.cz);
        if (job.outcome == OUTCOME_WRITE) {
            done[size_t(index)] = write_file_atomic(path, job.bytes, write_errors[size_t(index)]) ? 1 : 0;
        } else if (job.outcome == OUTCOME_DELETE) {
            done[size_t(index)] = remove_file(path) ? 1 : 0;
            if (!done[size_t(index)]) {
                write_errors[size_t(index)] = "cannot delete " + to_std(path);
            }
        }
    });

    // Gather removed points for Undo and update index.
    int64_t total_removed = 0;
    std::set<std::string> removed_paths;
    std::vector<ExtraColumn> removed_extras;
    uint32_t removed_flags = 0;
    Array cells;
    bool deleted_any = false;
    String first_error;
    for (size_t i = 0; i < jobs.size(); i++) {
        const SphereCellJob &job = jobs[i];
        if (!write_errors[i].empty() && first_error.is_empty()) {
            first_error = to_godot(write_errors[i]);
        }
        if ((job.outcome == OUTCOME_WRITE || job.outcome == OUTCOME_DELETE) && done[i]) {
            cells.push_back(Vector2i(job.cx, job.cz));
            if (job.outcome == OUTCOME_DELETE) {
                deleted_any = true;
            }
            total_removed += int64_t(job.removed_file.point_count);
            removed_flags |= job.removed_file.flags;
            for (const ObjectRows &obj : job.removed_file.objects) {
                removed_paths.insert(obj.path);
            }
            for (const ExtraColumn &col : job.removed_file.extras) {
                auto it = std::find_if(removed_extras.begin(), removed_extras.end(),
                        [&](const ExtraColumn &c) { return c.name == col.name; });
                if (it == removed_extras.end()) {
                    removed_extras.push_back(col);
                }
            }
        }
    }

    if (!cells.is_empty()) {
        std::lock_guard<std::mutex> lock(index_mutex());
        SetIndex index;
        const bool decoded = decode_set_index_file(p_directory, index);
        bool changed = !decoded;
        for (size_t i = 0; i < jobs.size(); i++) {
            const SphereCellJob &job = jobs[i];
            SetKey key(set_name, job.cx, job.cz);
            if (job.outcome == OUTCOME_WRITE && done[i]) {
                index.put(key, job.summary);
                changed = true;
            } else if (job.outcome == OUTCOME_DELETE && done[i]) {
                changed = index.entries.erase(key) > 0 || changed;
            }
        }
        int64_t read = 0;
        changed = reconcile_set_index(p_directory, index, false, false, read) || changed;
        std::string index_error;
        if (changed && !save_set_index(p_directory, index, index_error) && first_error.is_empty()) {
            first_error = to_godot("index: " + index_error);
        }
    }
    if (deleted_any) {
        String folder = p_directory.path_join("sets").path_join(p_set);
        if (DirAccess::dir_exists_absolute(folder) && DirAccess::get_files_at(folder).is_empty() && DirAccess::get_directories_at(folder).is_empty()) {
            DirAccess::remove_absolute(folder);
        }
    }

    Dictionary removed_points;
    if (total_removed > 0) {
        std::sort(removed_extras.begin(), removed_extras.end(), [](const ExtraColumn &a, const ExtraColumn &b) { return a.name < b.name; });
        std::vector<std::string> path_list(removed_paths.begin(), removed_paths.end());
        PackedFloat32Array transform, color, custom, keep;
        PackedInt32Array object;
        transform.resize(total_removed * 12);
        object.resize(total_removed);
        if (removed_flags & COLUMN_COLOR) {
            color.resize(total_removed * 4);
        }
        if (removed_flags & COLUMN_CUSTOM) {
            custom.resize(total_removed * 4);
        }
        if (removed_flags & COLUMN_KEEP) {
            keep.resize(total_removed);
        }
        std::vector<Bytes> extra_out(removed_extras.size());
        for (size_t e = 0; e < removed_extras.size(); e++) {
            extra_out[e].assign(size_t(total_removed) * removed_extras[e].bytes(), 0);
        }
        int64_t at = 0;
        for (size_t i = 0; i < jobs.size(); i++) {
            const SphereCellJob &job = jobs[i];
            if (!((job.outcome == OUTCOME_WRITE || job.outcome == OUTCOME_DELETE) && done[i])) {
                continue;
            }
            const size_t stride = row_stride(job.removed_file.extras);
            std::vector<size_t> offsets(removed_extras.size(), SIZE_MAX);
            size_t offset = ROW_FIXED;
            for (const ExtraColumn &col : job.removed_file.extras) {
                for (size_t e = 0; e < removed_extras.size(); e++) {
                    if (removed_extras[e].name == col.name && removed_extras[e].same_kind(col)) {
                        offsets[e] = offset;
                    }
                }
                offset += col.bytes();
            }
            for (const ObjectRows &obj : job.removed_file.objects) {
                int32_t oid = int32_t(std::lower_bound(path_list.begin(), path_list.end(), obj.path) - path_list.begin());
                for (uint32_t r = 0; r < obj.count; r++) {
                    const uint8_t *row = obj.rows.data() + size_t(r) * stride;
                    std::memcpy(transform.ptrw() + at * 12, row + ROW_TRANSFORM, 48);
                    object.set(at, oid);
                    if (removed_flags & COLUMN_COLOR) {
                        std::memcpy(color.ptrw() + at * 4, row + ROW_COLOR, 16);
                    }
                    if (removed_flags & COLUMN_CUSTOM) {
                        std::memcpy(custom.ptrw() + at * 4, row + ROW_CUSTOM, 16);
                    }
                    if (removed_flags & COLUMN_KEEP) {
                        std::memcpy(keep.ptrw() + at, row + ROW_KEEP, 4);
                    }
                    for (size_t e = 0; e < removed_extras.size(); e++) {
                        if (offsets[e] != SIZE_MAX) {
                            std::memcpy(extra_out[e].data() + size_t(at) * removed_extras[e].bytes(), row + offsets[e], removed_extras[e].bytes());
                        }
                    }
                    at++;
                }
            }
        }
        PackedStringArray object_paths;
        for (const std::string &p : path_list) {
            object_paths.push_back(to_godot(p));
        }
        removed_points["transform"] = transform;
        removed_points["object"] = object;
        removed_points["object_paths"] = object_paths;
        if (removed_flags & COLUMN_COLOR) {
            removed_points["color"] = color;
        }
        if (removed_flags & COLUMN_CUSTOM) {
            removed_points["custom"] = custom;
        }
        if (removed_flags & COLUMN_KEEP) {
            removed_points["keep"] = keep;
        }
        if (!removed_extras.empty()) {
            Dictionary extra;
            for (size_t e = 0; e < removed_extras.size(); e++) {
                if (removed_extras[e].type == EXTRA_INT32) {
                    PackedInt32Array values;
                    values.resize(total_removed);
                    std::memcpy(values.ptrw(), extra_out[e].data(), extra_out[e].size());
                    extra[to_godot(removed_extras[e].name)] = values;
                } else {
                    PackedFloat32Array values;
                    values.resize(total_removed * removed_extras[e].width);
                    std::memcpy(values.ptrw(), extra_out[e].data(), extra_out[e].size());
                    extra[to_godot(removed_extras[e].name)] = values;
                }
            }
            removed_points["extra"] = extra;
        }
    }

    result["cells"] = cells;
    result["removed_count"] = total_removed;
    result["removed_points"] = removed_points;
    result["ok"] = first_error.is_empty();
    result["error"] = first_error;
    return result;
}

Dictionary CopiaSets::remove_set_checked(const String &p_directory, const String &p_set, const String &p_intent, bool p_remove_meta) {
    Dictionary result;
    result["ok"] = false;
    result["error"] = String();
    result["cells"] = Array();
    std::string set = to_std(p_set);
    if (!valid_set_name(set)) {
        result["error"] = "invalid set name \"" + p_set + "\"";
        return result;
    }
    std::vector<std::string> auto_register;
    String access_error;
    if (!check_sets_access(p_directory, { set }, to_std(p_intent), auto_register, access_error)) {
        result["error"] = access_error;
        return result;
    }
    Array cells;
    std::lock_guard<std::mutex> lock(index_mutex());
    SetIndex index;
    const bool decoded = decode_set_index_file(p_directory, index);
    for (const auto &cell : set_cells_on_disk(p_directory, set)) {
        if (remove_file(set_file_path(p_directory, set, cell.first, cell.second))) {
            cells.push_back(Vector2i(cell.first, cell.second));
        }
    }
    String folder = p_directory.path_join("sets").path_join(p_set);
    if (DirAccess::dir_exists_absolute(folder)) {
        PackedStringArray leftovers = DirAccess::get_files_at(folder);
        for (int64_t i = 0; i < leftovers.size(); i++) {
            if (leftovers[i].ends_with(".tmp")) {
                DirAccess::remove_absolute(folder.path_join(leftovers[i]));
            }
        }
        DirAccess::remove_absolute(folder);
    }
    int64_t read = 0;
    if (reconcile_set_index(p_directory, index, false, false, read) || !decoded) {
        std::string error;
        save_set_index(p_directory, index, error);
    }
    if (p_remove_meta) {
        std::map<std::string, SetMeta> manifest = load_manifest_locked(p_directory);
        if (manifest.erase(set) > 0) {
            std::string error;
            save_manifest_locked(p_directory, manifest, error);
        }
    }
    result["cells"] = cells;
    result["ok"] = true;
    return result;
}

Array CopiaSets::remove_set(const String &p_directory, const String &p_set) {
    Dictionary res = remove_set_checked(p_directory, p_set, "any", false);
    if (!bool(res["ok"])) {
        UtilityFunctions::push_warning("CopiaSets.remove_set: ", String(res["error"]));
        return Array();
    }
    return res["cells"];
}

void CopiaSets::_bind_methods() {
    using namespace godot;
    ClassDB::bind_static_method("CopiaSets", D_METHOD("apply", "directory", "cell_size", "clears", "points", "intent"),
            &CopiaSets::apply, DEFVAL(String("any")));
    ClassDB::bind_static_method("CopiaSets", D_METHOD("set_meta", "directory", "set", "kind", "locked"),
            &CopiaSets::set_meta, DEFVAL(false));
    ClassDB::bind_static_method("CopiaSets", D_METHOD("get_sets_meta", "directory"), &CopiaSets::get_sets_meta);
    ClassDB::bind_static_method("CopiaSets", D_METHOD("edit_points", "directory", "cell_size", "set", "removes", "adds", "intent"),
            &CopiaSets::edit_points, DEFVAL(String("authored")));
    ClassDB::bind_static_method("CopiaSets", D_METHOD("erase_in_sphere", "directory", "cell_size", "set", "center", "radius", "object_filter", "intent"),
            &CopiaSets::erase_in_sphere, DEFVAL(PackedStringArray()), DEFVAL(String("authored")));
    ClassDB::bind_static_method("CopiaSets", D_METHOD("list_sets", "directory"), &CopiaSets::list_sets);
    ClassDB::bind_static_method("CopiaSets", D_METHOD("list_cells", "directory", "set", "verify"), &CopiaSets::list_cells, DEFVAL(false));
    ClassDB::bind_static_method("CopiaSets", D_METHOD("list_objects", "directory", "cells", "verify"), &CopiaSets::list_objects,
            DEFVAL(Array()), DEFVAL(false));
    ClassDB::bind_static_method("CopiaSets", D_METHOD("cell_points", "directory", "cell_size", "rect", "sets", "exclude", "verify"),
            &CopiaSets::cell_points, DEFVAL(Rect2()), DEFVAL(PackedStringArray()), DEFVAL(PackedStringArray()), DEFVAL(false));
    ClassDB::bind_static_method("CopiaSets", D_METHOD("reindex", "directory"), &CopiaSets::reindex);
    ClassDB::bind_static_method("CopiaSets", D_METHOD("read_points", "directory", "cell_size", "rect", "sets", "exclude"),
            &CopiaSets::read_points, DEFVAL(PackedStringArray()), DEFVAL(PackedStringArray()));
    ClassDB::bind_static_method("CopiaSets", D_METHOD("remove_set", "directory", "set"), &CopiaSets::remove_set);
    ClassDB::bind_static_method("CopiaSets", D_METHOD("remove_set_checked", "directory", "set", "intent", "remove_meta"),
            &CopiaSets::remove_set_checked, DEFVAL(String("any")), DEFVAL(false));
}

} // namespace Copia
