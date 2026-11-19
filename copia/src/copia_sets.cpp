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

Dictionary CopiaSets::apply(const String &p_directory, double p_cell_size, const Array &p_clears, const Dictionary &p_points) {
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

    std::map<FileKey, FileJob> jobs;
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

Array CopiaSets::remove_set(const String &p_directory, const String &p_set) {
    Array cells;
    std::string set = to_std(p_set);
    if (!valid_set_name(set)) {
        return cells;
    }
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
    return cells;
}

void CopiaSets::_bind_methods() {
    using namespace godot;
    ClassDB::bind_static_method("CopiaSets", D_METHOD("apply", "directory", "cell_size", "clears", "points"), &CopiaSets::apply);
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
}

} // namespace Copia
