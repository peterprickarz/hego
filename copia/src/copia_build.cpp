#include "copia_build.h"

#include "copia_cells.h"
#include "copia_format.h"
#include "copia_index.h"
#include "copia_sets.h"

#include <godot_cpp/classes/dir_access.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/aabb.hpp>
#include <godot_cpp/variant/color.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/vector2i.hpp>
#include <godot_cpp/variant/vector4.hpp>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <map>
#include <set>
#include <tuple>

using namespace godot;

namespace Copia {

namespace {

const char *CELL_EXTENSION = ".copiacell";

struct Descriptor {
    bool multimesh = true;
    double aabb_position[3] = { 0, 0, 0 };
    double aabb_size[3] = { 0, 0, 0 };
    double batch_size = 0.0;
    int batches_per_cell = 1;
    float color[4] = { 1, 1, 1, 1 };
    float custom[4] = { 0, 0, 0, 0 };
    bool collider = false;
    double collider_min_scale = 0.0;
    bool impostor = false;
    double impostor_cell_size = 0.0;
    double impostor_min_scale = 0.0;
    std::string hash;
    bool defaulted = false;
};

struct Descriptors {
    std::map<std::string, Descriptor> objects;
    Descriptor fallback;
    double far_size = 0.0; // 0: no object has an impostor
    int64_t cells_per_far = 0;

    const Descriptor &get(const std::string &p_path) const {
        auto found = objects.find(p_path);
        return found == objects.end() ? fallback : found->second;
    }
};

// Integer n with p_whole = n * p_part, or 0.
int64_t whole_multiple(double p_whole, double p_part) {
    if (!(p_part > 0.0) || !std::isfinite(p_part)) {
        return 0;
    }
    double ratio = p_whole / p_part;
    double rounded = std::round(ratio);
    if (rounded < 1.0 || std::abs(rounded * p_part - p_whole) > 1e-4 * std::max(1.0, p_whole)) {
        return 0;
    }
    return int64_t(rounded);
}

std::string bits(double p_value) {
    float value = float(p_value);
    uint32_t raw;
    std::memcpy(&raw, &value, 4);
    char text[16];
    snprintf(text, sizeof(text), "%08x", raw);
    return text;
}

std::string computed_hash(const Descriptor &p_descriptor) {
    std::string text = "copia-descriptor-1|";
    text += p_descriptor.multimesh ? "multimesh|" : "instance|";
    for (int i = 0; i < 3; i++) {
        text += bits(p_descriptor.aabb_position[i]) + "," + bits(p_descriptor.aabb_size[i]) + ",";
    }
    text += "|" + bits(p_descriptor.batch_size) + "|";
    for (int i = 0; i < 4; i++) {
        text += bits(p_descriptor.color[i]) + "," + bits(p_descriptor.custom[i]) + ",";
    }
    text += p_descriptor.collider ? "|collider|" : "|-|";
    text += bits(p_descriptor.collider_min_scale);
    text += p_descriptor.impostor ? "|impostor|" : "|-|";
    text += bits(p_descriptor.impostor_cell_size) + "|" + bits(p_descriptor.impostor_min_scale);
    return hash_hex(sha256(reinterpret_cast<const uint8_t *>(text.data()), text.size()));
}

bool number(const Dictionary &p_source, const char *p_key, double &r_value, std::string &r_error) {
    Variant value = p_source.get(p_key, Variant());
    if (value.get_type() == Variant::NIL) {
        return true;
    }
    if (value.get_type() != Variant::FLOAT && value.get_type() != Variant::INT) {
        r_error = std::string(p_key) + " must be a number";
        return false;
    }
    r_value = double(value);
    if (!std::isfinite(r_value)) {
        r_error = std::string(p_key) + " must be finite";
        return false;
    }
    return true;
}

bool four(const Dictionary &p_source, const char *p_key, float *r_value, std::string &r_error) {
    Variant value = p_source.get(p_key, Variant());
    if (value.get_type() == Variant::NIL) {
        return true;
    }
    if (value.get_type() == Variant::COLOR) {
        Color color = value;
        r_value[0] = color.r;
        r_value[1] = color.g;
        r_value[2] = color.b;
        r_value[3] = color.a;
    } else if (value.get_type() == Variant::VECTOR4) {
        Vector4 vector = value;
        r_value[0] = float(vector.x);
        r_value[1] = float(vector.y);
        r_value[2] = float(vector.z);
        r_value[3] = float(vector.w);
    } else {
        r_error = std::string(p_key) + " must be a Color or a Vector4";
        return false;
    }
    return true;
}

bool parse_descriptor(const Dictionary &p_source, double p_cell_size, Descriptor &r_descriptor, std::string &r_error) {
    r_descriptor.batch_size = p_cell_size;
    Variant draw = p_source.get("draw", Variant());
    if (draw.get_type() != Variant::NIL) {
        String mode = draw;
        if (mode == "multimesh") {
            r_descriptor.multimesh = true;
        } else if (mode == "instance") {
            r_descriptor.multimesh = false;
        } else {
            r_error = "draw must be \"multimesh\" or \"instance\"";
            return false;
        }
    }
    Variant aabb = p_source.get("mesh_aabb", Variant());
    if (aabb.get_type() != Variant::NIL) {
        if (aabb.get_type() != Variant::AABB) {
            r_error = "mesh_aabb must be an AABB";
            return false;
        }
        AABB box = AABB(aabb).abs();
        for (int i = 0; i < 3; i++) {
            r_descriptor.aabb_position[i] = box.position[i];
            r_descriptor.aabb_size[i] = box.size[i];
        }
    }
    if (!number(p_source, "batch_size", r_descriptor.batch_size, r_error) ||
            !number(p_source, "collider_min_scale", r_descriptor.collider_min_scale, r_error) ||
            !number(p_source, "impostor_cell_size", r_descriptor.impostor_cell_size, r_error) ||
            !number(p_source, "impostor_min_scale", r_descriptor.impostor_min_scale, r_error) ||
            !four(p_source, "default_color", r_descriptor.color, r_error) ||
            !four(p_source, "default_custom", r_descriptor.custom, r_error)) {
        return false;
    }
    r_descriptor.collider = bool(p_source.get("collider", false));
    r_descriptor.impostor = bool(p_source.get("impostor", false));
    r_descriptor.batches_per_cell = int(whole_multiple(p_cell_size, r_descriptor.batch_size));
    if (r_descriptor.batches_per_cell < 1) {
        r_error = "batch_size must divide the cell size";
        return false;
    }
    if (r_descriptor.impostor && whole_multiple(r_descriptor.impostor_cell_size, p_cell_size) < 1) {
        r_error = "impostor_cell_size must be a multiple of the cell size";
        return false;
    }
    Variant hash = p_source.get("hash", Variant());
    if (hash.get_type() == Variant::STRING || hash.get_type() == Variant::STRING_NAME) {
        r_descriptor.hash = to_std(String(hash));
    } else if (hash.get_type() == Variant::INT) {
        r_descriptor.hash = std::to_string(int64_t(hash));
    } else if (hash.get_type() != Variant::NIL) {
        r_error = "hash must be a String or an int";
        return false;
    }
    if (r_descriptor.hash.empty()) {
        r_descriptor.hash = computed_hash(r_descriptor);
    }
    return true;
}

bool parse_descriptors(const Dictionary &p_objects, double p_cell_size, Descriptors &r_descriptors, std::string &r_error) {
    r_descriptors.fallback.batch_size = p_cell_size;
    r_descriptors.fallback.defaulted = true;
    r_descriptors.fallback.hash = computed_hash(r_descriptors.fallback);
    Array keys = p_objects.keys();
    for (int64_t i = 0; i < keys.size(); i++) {
        std::string path = to_std(String(keys[i]));
        Variant value = p_objects[keys[i]];
        if (value.get_type() != Variant::DICTIONARY) {
            r_error = "descriptor of " + path + " must be a Dictionary";
            return false;
        }
        Descriptor descriptor;
        if (!parse_descriptor(value, p_cell_size, descriptor, r_error)) {
            r_error = path + ": " + r_error;
            return false;
        }
        if (descriptor.impostor) {
            if (r_descriptors.far_size == 0.0) {
                r_descriptors.far_size = descriptor.impostor_cell_size;
            } else if (std::abs(r_descriptors.far_size - descriptor.impostor_cell_size) > 1e-4) {
                r_error = path + ": impostor_cell_size differs from another object's (one far grid per store)";
                return false;
            }
        }
        r_descriptors.objects[path] = descriptor;
    }
    if (r_descriptors.far_size > 0.0) {
        r_descriptors.cells_per_far = whole_multiple(r_descriptors.far_size, p_cell_size);
    }
    return true;
}

String cell_path(const String &p_directory, int32_t p_cx, int32_t p_cz) {
    return cell_file_path(p_directory, false, p_cx, p_cz);
}

String far_path(const String &p_directory, int32_t p_fx, int32_t p_fz) {
    return cell_file_path(p_directory, true, p_fx, p_fz);
}

enum Outcome {
    OUTCOME_NONE,
    OUTCOME_WRITTEN,
    OUTCOME_UNCHANGED,
    OUTCOME_DELETED,
    OUTCOME_FAILED,
};

struct Job {
    bool far = false;
    int32_t cx = 0;
    int32_t cz = 0;
    Outcome outcome = OUTCOME_NONE;
    bool skipped = false; // unchanged inputs: not rebuilt
    std::string error;
    uint64_t instances = 0;
    std::set<std::string> defaulted;
    // The directory of the file as written or found unchanged (have_directory), for the index.
    CellDirectory directory;
    bool have_directory = false;
    // Set files whose content differs from the sets index (changed outside Copia).
    std::vector<std::pair<SetKey, SetSummary>> set_repairs;
    // Microseconds per phase: read (set files or built cells), shape (merge, sort, batches,
    // sections), encode (compression), write (compare with the file on disk and write).
    int64_t phase_usec[4] = { 0, 0, 0, 0 };
};

enum Phase {
    PHASE_READ,
    PHASE_SHAPE,
    PHASE_ENCODE,
    PHASE_WRITE,
};

int64_t now_usec() {
    return std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now().time_since_epoch()).count();
}

const float *row_floats(const Bytes &p_rows, uint32_t p_index) {
    return reinterpret_cast<const float *>(p_rows.data() + size_t(p_index) * ROW_FIXED);
}

double row_scale(const float *p_row) {
    return std::sqrt(double(p_row[3]) * p_row[3] + double(p_row[4]) * p_row[4] + double(p_row[5]) * p_row[5]);
}

// One batch from p_indices (canonical order): keep order, bounds, origin and instance buffer.
void make_batch(const Bytes &p_rows, std::vector<uint32_t> p_indices, const Descriptor &p_descriptor, int32_t p_bx,
        int32_t p_bz, std::vector<BatchRecord> &r_batches, std::vector<float> &r_buffer) {
    std::stable_sort(p_indices.begin(), p_indices.end(), [&](uint32_t a, uint32_t b) {
        return row_floats(p_rows, a)[ROW_KEEP / 4] > row_floats(p_rows, b)[ROW_KEEP / 4];
    });
    double low[3] = { INFINITY, INFINITY, INFINITY };
    double high[3] = { -INFINITY, -INFINITY, -INFINITY };
    double half[3], centre[3];
    for (int k = 0; k < 3; k++) {
        half[k] = p_descriptor.aabb_size[k] * 0.5;
        centre[k] = p_descriptor.aabb_position[k] + half[k];
    }
    for (uint32_t index : p_indices) {
        const float *t = row_floats(p_rows, index);
        for (int j = 0; j < 3; j++) {
            double c = double(t[j]) * centre[0] + double(t[3 + j]) * centre[1] + double(t[6 + j]) * centre[2] + double(t[9 + j]);
            double e = std::abs(double(t[j])) * half[0] + std::abs(double(t[3 + j])) * half[1] + std::abs(double(t[6 + j])) * half[2];
            low[j] = std::min(low[j], c - e);
            high[j] = std::max(high[j], c + e);
        }
    }
    BatchRecord batch;
    batch.bx = p_bx;
    batch.bz = p_bz;
    batch.first = uint32_t(r_buffer.size() / FLOATS_PER_INSTANCE);
    batch.count = uint32_t(p_indices.size());
    for (int j = 0; j < 3; j++) {
        batch.origin[j] = float((low[j] + high[j]) * 0.5);
        batch.position[j] = float(low[j] - double(batch.origin[j]));
        batch.size[j] = float(high[j] - low[j]);
    }
    static const float thresholds[5] = { 1.0f, 0.75f, 0.5f, 0.25f, 0.0f };
    r_buffer.reserve(r_buffer.size() + p_indices.size() * FLOATS_PER_INSTANCE);
    for (uint32_t index : p_indices) {
        const float *t = row_floats(p_rows, index);
        float keep = t[ROW_KEEP / 4];
        for (int k = 0; k < 5; k++) {
            if (keep >= thresholds[k]) {
                batch.keep_counts[k]++;
            }
        }
        // MultiMesh 3D transform layout: the rows of the 3x4 matrix [basis | origin].
        for (int j = 0; j < 3; j++) {
            r_buffer.push_back(t[j]);
            r_buffer.push_back(t[3 + j]);
            r_buffer.push_back(t[6 + j]);
            r_buffer.push_back(float(double(t[9 + j]) - double(batch.origin[j])));
        }
        const uint8_t *row = p_rows.data() + size_t(index) * ROW_FIXED;
        const float *color = row_has_none(row, ROW_COLOR) ? p_descriptor.color : t + ROW_COLOR / 4;
        const float *custom = row_has_none(row, ROW_CUSTOM) ? p_descriptor.custom : t + ROW_CUSTOM / 4;
        r_buffer.insert(r_buffer.end(), color, color + 4);
        r_buffer.insert(r_buffer.end(), custom, custom + 4);
    }
    r_batches.push_back(batch);
}

void write_outcome(const String &p_path, CellDirectory &p_directory, const std::vector<std::array<Bytes, SECTION_COUNT>> &p_raw,
        Job &r_job) {
    if (p_directory.entries.empty()) {
        if (file_exists(p_path)) {
            r_job.outcome = remove_file(p_path) ? OUTCOME_DELETED : OUTCOME_FAILED;
            if (r_job.outcome == OUTCOME_FAILED) {
                r_job.error = "cannot delete " + to_std(p_path);
            }
        }
        return;
    }
    Bytes bytes;
    int64_t started = now_usec();
    if (!encode_cell_file(p_directory, p_raw, bytes)) {
        r_job.outcome = OUTCOME_FAILED;
        r_job.error = "compression failed";
        return;
    }
    int64_t encoded = now_usec();
    r_job.phase_usec[PHASE_ENCODE] += encoded - started;
    struct WriteTimer {
        Job &job;
        int64_t start;
        ~WriteTimer() { job.phase_usec[PHASE_WRITE] += now_usec() - start; }
    } timer{ r_job, encoded };
    Bytes existing;
    if (file_exists(p_path) && read_file(p_path, existing) && existing == bytes) {
        r_job.outcome = OUTCOME_UNCHANGED;
    } else {
        r_job.outcome = write_file_atomic(p_path, bytes, r_job.error) ? OUTCOME_WRITTEN : OUTCOME_FAILED;
    }
    if (r_job.outcome != OUTCOME_FAILED) {
        r_job.directory = std::move(p_directory);
        r_job.have_directory = true;
    }
}

// The build's view of the indexes: the current set files of each cell (sets index) and the
// recorded inputs and directories of the built and far files (cells index).
struct State {
    std::map<std::pair<int32_t, int32_t>, std::vector<CellInputSet>> current; // set name order
    std::set<std::pair<int32_t, int32_t>> unusable; // a set file that is unreadable or of another cell size
    CellIndex cells;
    std::vector<uint32_t> descriptor_hash; // see descriptor_hash_ids()
};

// For every string of the cells index: the id of the current descriptor hash of the object path
// it names (UINT32_MAX when that hash is in no entry), so comparing a recorded hash is one
// integer comparison.
std::vector<uint32_t> descriptor_hash_ids(const CellIndex &p_cells, const Descriptors &p_descriptors) {
    std::vector<uint32_t> ids(p_cells.strings.names.size());
    for (size_t i = 0; i < ids.size(); i++) {
        ids[i] = p_cells.strings.find(p_descriptors.get(p_cells.strings.get(uint32_t(i))).hash);
    }
    return ids;
}

bool objects_current(const CellIndexFile &p_file, const std::vector<uint32_t> &p_descriptor_hash) {
    for (const CellIndexObject &object : p_file.objects) {
        if (p_descriptor_hash[object.path] != object.hash) {
            return false;
        }
    }
    return true;
}

// True when the built cell on disk was made from the current set files (hashes in the sets index)
// and the current descriptors (inputs in the cells index); fills the job as an unchanged,
// skipped cell. Opens no file.
bool cell_is_current(const State &p_state, double p_cell_size, const Descriptors &p_descriptors, Job &r_job) {
    const std::pair<int32_t, int32_t> cell(r_job.cx, r_job.cz);
    auto found = p_state.cells.files.find(CellKey(0, r_job.cx, r_job.cz));
    auto current = p_state.current.find(cell);
    if (found == p_state.cells.files.end() || current == p_state.current.end() || p_state.unusable.count(cell)) {
        return false;
    }
    const CellIndexFile &existing = found->second;
    if (!existing.ok || existing.kind != CELL_KIND_CELL || existing.cell_size != float(p_cell_size) ||
            existing.store_cell_size != float(p_cell_size) || p_state.cells.input_sets(existing) != current->second ||
            !objects_current(existing, p_state.descriptor_hash)) {
        return false;
    }
    for (const CellIndexEntry &entry : existing.entries) {
        const Descriptor &descriptor = p_descriptors.get(p_state.cells.strings.get(entry.path));
        if (((entry.flags & ENTRY_DEFAULTED) != 0) != descriptor.defaulted ||
                (entry.draw == DRAW_MULTIMESH) != descriptor.multimesh) {
            return false;
        }
    }
    for (const CellIndexEntry &entry : existing.entries) {
        if (entry.flags & ENTRY_DEFAULTED) {
            r_job.defaulted.insert(p_state.cells.strings.get(entry.path));
        }
        r_job.instances += entry.instances;
    }
    r_job.outcome = OUTCOME_UNCHANGED;
    r_job.skipped = true;
    return true;
}

void build_cell(const String &p_directory, double p_cell_size, const State &p_state, const Descriptors &p_descriptors,
        bool p_force, Job &r_job) {
    CellDirectory directory;
    directory.kind = CELL_KIND_CELL;
    directory.cx = r_job.cx;
    directory.cz = r_job.cz;
    directory.cell_size = float(p_cell_size);
    directory.store_cell_size = float(p_cell_size);
    int64_t started = now_usec();
    if (!p_force && cell_is_current(p_state, p_cell_size, p_descriptors, r_job)) {
        r_job.phase_usec[PHASE_READ] += now_usec() - started;
        return;
    }
    std::map<std::string, std::pair<Bytes, uint32_t>> merged;
    static const std::vector<CellInputSet> none;
    auto listed = p_state.current.find({ r_job.cx, r_job.cz });
    for (const CellInputSet &indexed : listed == p_state.current.end() ? none : listed->second) {
        const std::string &set = indexed.set;
        String path = set_file_path(p_directory, set, r_job.cx, r_job.cz);
        Bytes data;
        SetFile file;
        std::string error;
        if (!read_file(path, data) || !decode_set_file(data, file, false, error)) {
            r_job.outcome = OUTCOME_FAILED;
            r_job.error = "sets/" + set + "/" + cell_name(r_job.cx, r_job.cz) + ": " + (error.empty() ? "cannot read" : error);
            return;
        }
        if (file.cell_size != float(p_cell_size) || file.cx != r_job.cx || file.cz != r_job.cz) {
            r_job.outcome = OUTCOME_FAILED;
            r_job.error = "sets/" + set + "/" + cell_name(r_job.cx, r_job.cz) + ": cell or cell size differs from the store's";
            return;
        }
        CellInputSet input;
        input.set = set;
        input.cx = r_job.cx;
        input.cz = r_job.cz;
        input.hash = file.hash;
        directory.sets.push_back(input);
        if (file.hash != indexed.hash) {
            SetSummary summary;
            summary.ok = true;
            summary.cell_size = file.cell_size;
            summary.point_count = file.point_count;
            summary.hash = file.hash;
            for (const ObjectRows &object : file.objects) {
                summary.objects.push_back(object.path);
            }
            r_job.set_repairs.emplace_back(SetKey(set, r_job.cx, r_job.cz), std::move(summary));
        }
        size_t stride = row_stride(file.extras);
        for (const ObjectRows &object : file.objects) {
            std::pair<Bytes, uint32_t> &target = merged[object.path];
            for (uint32_t r = 0; r < object.count; r++) {
                const uint8_t *row = object.rows.data() + size_t(r) * stride;
                target.first.insert(target.first.end(), row, row + ROW_FIXED);
            }
            target.second += object.count;
        }
    }
    int64_t shaped = now_usec();
    r_job.phase_usec[PHASE_READ] += shaped - started;
    std::vector<std::array<Bytes, SECTION_COUNT>> raw;
    for (auto &entry : merged) {
        const std::string &path = entry.first;
        Bytes &rows = entry.second.first;
        const uint32_t count = entry.second.second;
        const Descriptor &descriptor = p_descriptors.get(path);
        if (descriptor.defaulted) {
            r_job.defaulted.insert(path);
        }
        canonical_sort(rows, count, ROW_FIXED);
        CellEntry cell_entry;
        cell_entry.path = path;
        cell_entry.draw = descriptor.multimesh ? DRAW_MULTIMESH : DRAW_INSTANCE;
        cell_entry.flags = descriptor.defaulted ? ENTRY_DEFAULTED : 0;
        cell_entry.instances = count;
        std::array<Bytes, SECTION_COUNT> sections;
        if (descriptor.multimesh) {
            const int64_t per_cell = descriptor.batches_per_cell;
            std::map<std::pair<int32_t, int32_t>, std::vector<uint32_t>> groups;
            for (uint32_t i = 0; i < count; i++) {
                const float *t = row_floats(rows, i);
                int64_t bx = int64_t(std::floor(double(t[9]) / descriptor.batch_size));
                int64_t bz = int64_t(std::floor(double(t[11]) / descriptor.batch_size));
                // A batch lies inside its cell even where rounding puts a point on the far edge.
                bx = std::min(std::max(bx, int64_t(r_job.cx) * per_cell), int64_t(r_job.cx) * per_cell + per_cell - 1);
                bz = std::min(std::max(bz, int64_t(r_job.cz) * per_cell), int64_t(r_job.cz) * per_cell + per_cell - 1);
                groups[{ int32_t(bx), int32_t(bz) }].push_back(i);
            }
            std::vector<BatchRecord> batches;
            std::vector<float> buffer;
            for (auto &group : groups) {
                make_batch(rows, group.second, descriptor, group.first.first, group.first.second, batches, buffer);
            }
            cell_entry.batches = uint32_t(batches.size());
            encode_batch_section(batches, buffer, sections[SECTION_DRAW]);
        } else {
            std::vector<float> transforms(size_t(count) * 12);
            for (uint32_t i = 0; i < count; i++) {
                std::memcpy(transforms.data() + size_t(i) * 12, row_floats(rows, i), 48);
            }
            encode_transform_section(transforms, sections[SECTION_DRAW]);
        }
        if (descriptor.collider) {
            std::vector<float> transforms;
            for (uint32_t i = 0; i < count; i++) {
                const float *t = row_floats(rows, i);
                if (row_scale(t) >= descriptor.collider_min_scale) {
                    transforms.insert(transforms.end(), t, t + 12);
                }
            }
            cell_entry.colliders = uint32_t(transforms.size() / 12);
            if (cell_entry.colliders) {
                encode_transform_section(transforms, sections[SECTION_COLLIDER]);
            }
        }
        if (descriptor.impostor) {
            std::vector<uint32_t> chosen;
            for (uint32_t i = 0; i < count; i++) {
                if (row_scale(row_floats(rows, i)) >= descriptor.impostor_min_scale) {
                    chosen.push_back(i);
                }
            }
            if (!chosen.empty()) {
                std::vector<BatchRecord> batches;
                std::vector<float> buffer;
                make_batch(rows, chosen, descriptor, r_job.cx, r_job.cz, batches, buffer);
                cell_entry.impostors = uint32_t(chosen.size());
                cell_entry.impostor_batches = 1;
                encode_batch_section(batches, buffer, sections[SECTION_IMPOSTOR]);
            }
        }
        CellInputObject input;
        input.path = path;
        input.hash = descriptor.hash;
        directory.objects.push_back(input);
        directory.entries.push_back(cell_entry);
        raw.push_back(std::move(sections));
        r_job.instances += count;
        rows = Bytes();
    }
    r_job.phase_usec[PHASE_SHAPE] += now_usec() - shaped;
    write_outcome(cell_path(p_directory, r_job.cx, r_job.cz), directory, raw, r_job);
}

// True when the far file on disk records exactly the union of the inputs of the built cells
// inside it and one of them has impostors (all from the cells index, which the cell pass has
// brought up to date). The built cells are current at this point, so equal inputs mean equal
// content.
bool far_is_current(double p_cell_size, const Descriptors &p_descriptors, const CellIndex &p_cells, Job &r_job) {
    auto found = p_cells.files.find(CellKey(1, r_job.cx, r_job.cz));
    if (found == p_cells.files.end()) {
        return false;
    }
    const CellIndexFile &existing = found->second;
    if (!existing.ok || existing.kind != CELL_KIND_FAR || existing.cell_size != float(p_descriptors.far_size) ||
            existing.store_cell_size != float(p_cell_size)) {
        return false;
    }
    const int64_t k = p_descriptors.cells_per_far;
    std::set<CellInputSet> sets;
    std::set<CellInputObject> objects;
    bool impostors = false;
    for (auto it = p_cells.files.lower_bound(CellKey(0, int32_t(int64_t(r_job.cx) * k), INT32_MIN));
            it != p_cells.files.end() && std::get<0>(it->first) == 0 && int64_t(std::get<1>(it->first)) < int64_t(r_job.cx) * k + k; ++it) {
        const int64_t cz = std::get<2>(it->first);
        if (cz < int64_t(r_job.cz) * k || cz >= int64_t(r_job.cz) * k + k) {
            continue;
        }
        const CellIndexFile &cell = it->second;
        if (!cell.ok) {
            return false;
        }
        for (const CellInputSet &set : p_cells.input_sets(cell)) {
            sets.insert(set);
        }
        for (const CellIndexObject &object : cell.objects) {
            CellInputObject value;
            value.path = p_cells.strings.get(object.path);
            value.hash = p_cells.strings.get(object.hash);
            objects.insert(value);
        }
        for (const CellIndexEntry &entry : cell.entries) {
            impostors = impostors || entry.impostors != 0;
        }
    }
    std::vector<CellInputObject> recorded;
    for (const CellIndexObject &object : existing.objects) {
        CellInputObject value;
        value.path = p_cells.strings.get(object.path);
        value.hash = p_cells.strings.get(object.hash);
        recorded.push_back(value);
    }
    if (!impostors || std::vector<CellInputSet>(sets.begin(), sets.end()) != p_cells.input_sets(existing) ||
            std::vector<CellInputObject>(objects.begin(), objects.end()) != recorded) {
        return false;
    }
    for (const CellIndexEntry &entry : existing.entries) {
        r_job.instances += entry.instances;
    }
    r_job.outcome = OUTCOME_UNCHANGED;
    r_job.skipped = true;
    return true;
}

void build_far(const String &p_directory, double p_cell_size, const Descriptors &p_descriptors,
        const std::set<std::pair<int32_t, int32_t>> &p_built, const CellIndex &p_cells, bool p_force, Job &r_job) {
    CellDirectory directory;
    directory.kind = CELL_KIND_FAR;
    directory.cx = r_job.cx;
    directory.cz = r_job.cz;
    directory.cell_size = float(p_descriptors.far_size);
    directory.store_cell_size = float(p_cell_size);
    std::vector<std::array<Bytes, SECTION_COUNT>> raw;
    int64_t started = now_usec();
    const int64_t k = p_descriptors.cells_per_far;
    if (!p_force && k > 0 && far_is_current(p_cell_size, p_descriptors, p_cells, r_job)) {
        r_job.phase_usec[PHASE_READ] += now_usec() - started;
        return;
    }
    if (k > 0) {
        std::set<CellInputSet> sets;
        std::set<CellInputObject> objects;
        std::map<std::string, std::pair<std::vector<BatchRecord>, std::vector<float>>> gathered;
        auto low = p_built.lower_bound({ int32_t(int64_t(r_job.cx) * k), INT32_MIN });
        for (auto it = low; it != p_built.end() && int64_t(it->first) < int64_t(r_job.cx) * k + k; ++it) {
            if (int64_t(it->second) < int64_t(r_job.cz) * k || int64_t(it->second) >= int64_t(r_job.cz) * k + k) {
                continue;
            }
            String path = cell_path(p_directory, it->first, it->second);
            CellDirectory cell;
            Bytes file;
            std::string error;
            if (!read_file(path, file) || !decode_cell_file(file, cell, error)) {
                r_job.outcome = OUTCOME_FAILED;
                r_job.error = "cells/" + cell_name(it->first, it->second) + ": " + error;
                return;
            }
            sets.insert(cell.sets.begin(), cell.sets.end());
            objects.insert(cell.objects.begin(), cell.objects.end());
            for (const CellEntry &entry : cell.entries) {
                if (entry.sections[SECTION_IMPOSTOR].size == 0) {
                    continue;
                }
                Bytes section;
                std::vector<BatchRecord> batches;
                const float *buffer = nullptr;
                size_t instances = 0;
                if (!cell_section_from_file(file, entry.sections[SECTION_IMPOSTOR], section, error) ||
                        !decode_batch_section(section, batches, buffer, instances, error)) {
                    r_job.outcome = OUTCOME_FAILED;
                    r_job.error = "cells/" + cell_name(it->first, it->second) + ": " + error;
                    return;
                }
                auto &target = gathered[entry.path];
                for (BatchRecord batch : batches) {
                    const float *from = buffer + size_t(batch.first) * FLOATS_PER_INSTANCE;
                    batch.first = uint32_t(target.second.size() / FLOATS_PER_INSTANCE);
                    target.second.insert(target.second.end(), from, from + size_t(batch.count) * FLOATS_PER_INSTANCE);
                    target.first.push_back(batch);
                }
            }
        }
        if (!gathered.empty()) {
            directory.sets.assign(sets.begin(), sets.end());
            directory.objects.assign(objects.begin(), objects.end());
        }
        for (auto &object : gathered) {
            CellEntry entry;
            entry.path = object.first;
            entry.draw = DRAW_MULTIMESH;
            entry.instances = uint32_t(object.second.second.size() / FLOATS_PER_INSTANCE);
            entry.batches = uint32_t(object.second.first.size());
            std::array<Bytes, SECTION_COUNT> sections;
            encode_batch_section(object.second.first, object.second.second, sections[SECTION_DRAW]);
            directory.entries.push_back(entry);
            raw.push_back(std::move(sections));
            r_job.instances += entry.instances;
        }
    }
    r_job.phase_usec[PHASE_READ] += now_usec() - started;
    write_outcome(far_path(p_directory, r_job.cx, r_job.cz), directory, raw, r_job);
}

} // namespace

Dictionary CopiaBuild::build_cells(const String &p_directory, double p_cell_size, const Array &p_cells, const Dictionary &p_objects,
        bool p_force, bool p_verify) {
    Dictionary result;
    result["ok"] = false;
    result["error"] = String();
    result["written"] = PackedStringArray();
    result["unchanged"] = PackedStringArray();
    result["deleted"] = PackedStringArray();
    result["defaulted"] = PackedStringArray();
    result["skipped"] = PackedStringArray();
    result["cell_count"] = 0;
    result["far_count"] = 0;
    result["instance_count"] = 0;
    result["threads"] = worker_thread_count();
    if (!std::isfinite(p_cell_size) || p_cell_size <= 0.0) {
        result["error"] = "cell_size must be a positive number";
        return result;
    }
    Descriptors descriptors;
    std::string error;
    if (!parse_descriptors(p_objects, p_cell_size, descriptors, error)) {
        result["error"] = to_godot(error);
        return result;
    }
    std::set<std::pair<int32_t, int32_t>> cells, fars;
    for (int64_t i = 0; i < p_cells.size(); i++) {
        Variant value = p_cells[i];
        bool far = false;
        if (value.get_type() == Variant::DICTIONARY) {
            Dictionary entry = value;
            String kind = entry.get("kind", "cell");
            if (kind != "cell" && kind != "far") {
                result["error"] = "cells: kind must be \"cell\" or \"far\"";
                return result;
            }
            far = kind == "far";
            value = entry.get("cell", Variant());
        }
        if (value.get_type() != Variant::VECTOR2I) {
            result["error"] = "cells must hold Vector2i or {cell: Vector2i, kind: String}";
            return result;
        }
        Vector2i cell = value;
        (far ? fars : cells).insert({ cell.x, cell.y });
    }
    if (descriptors.cells_per_far > 0) {
        for (const auto &cell : cells) {
            fars.insert({ int32_t(floor_div(cell.first, descriptors.cells_per_far)), int32_t(floor_div(cell.second, descriptors.cells_per_far)) });
        }
    }

    State state;
    {
        std::lock_guard<std::mutex> lock(index_mutex());
        SetIndex set_index;
        load_set_index(p_directory, set_index, p_verify);
        load_cell_index(p_directory, state.cells, p_verify);
        for (const auto &item : set_index.entries) {
            const std::pair<int32_t, int32_t> cell(std::get<1>(item.first), std::get<2>(item.first));
            CellInputSet input;
            input.set = std::get<0>(item.first);
            input.cx = cell.first;
            input.cz = cell.second;
            input.hash = item.second.hash;
            state.current[cell].push_back(input);
            if (!item.second.ok || item.second.cell_size != float(p_cell_size)) {
                state.unusable.insert(cell);
            }
        }
    }
    state.descriptor_hash = descriptor_hash_ids(state.cells, descriptors);
    std::vector<Job> cell_jobs, far_jobs;
    for (const auto &cell : cells) {
        Job job;
        job.cx = cell.first;
        job.cz = cell.second;
        cell_jobs.push_back(job);
    }
    for (const auto &cell : fars) {
        Job job;
        job.far = true;
        job.cx = cell.first;
        job.cz = cell.second;
        far_jobs.push_back(job);
    }
    int64_t cells_started = now_usec();
    parallel_for(int64_t(cell_jobs.size()), [&](int64_t i) {
        build_cell(p_directory, p_cell_size, state, descriptors, p_force, cell_jobs[size_t(i)]);
    });
    // The cells index follows the cell pass, so the far pass reads the new inputs from it.
    auto record = [&](std::vector<Job> &p_jobs) {
        for (Job &job : p_jobs) {
            const CellKey key(job.far ? 1 : 0, job.cx, job.cz);
            if (job.outcome == OUTCOME_DELETED) {
                state.cells.files.erase(key);
            } else if (job.have_directory) {
                state.cells.put(key, true, job.directory);
                job.directory = CellDirectory();
            }
        }
    };
    record(cell_jobs);
    std::set<std::pair<int32_t, int32_t>> built;
    for (const auto &item : state.cells.files) {
        if (std::get<0>(item.first) == 0) {
            built.insert({ std::get<1>(item.first), std::get<2>(item.first) });
        }
    }
    int64_t far_started = now_usec();
    parallel_for(int64_t(far_jobs.size()), [&](int64_t i) {
        build_far(p_directory, p_cell_size, descriptors, built, state.cells, p_force, far_jobs[size_t(i)]);
    });
    int64_t far_finished = now_usec();
    record(far_jobs);
    String index_error;
    {
        std::lock_guard<std::mutex> lock(index_mutex());
        int64_t read = 0;
        reconcile_cell_index(p_directory, state.cells, false, false, read);
        std::string error;
        if (!save_cell_index(p_directory, state.cells, error)) {
            index_error = to_godot("cells/index.copiaindex: " + error);
        }
        // Set files the build found changed outside Copia: their index entries are repaired.
        bool repairs = false;
        for (const Job &job : cell_jobs) {
            repairs = repairs || !job.set_repairs.empty();
        }
        if (repairs) {
            SetIndex set_index;
            load_set_index(p_directory, set_index, false);
            for (const Job &job : cell_jobs) {
                for (const auto &repair : job.set_repairs) {
                    set_index.put(repair.first, repair.second);
                }
            }
            save_set_index(p_directory, set_index, error);
        }
    }

    PackedStringArray written, unchanged, deleted, defaulted, skipped;
    std::set<std::string> defaulted_paths;
    String first_error;
    uint64_t instances = 0;
    int64_t phase_usec[4] = { 0, 0, 0, 0 };
    for (std::vector<Job> *jobs : { &cell_jobs, &far_jobs }) {
        for (const Job &job : *jobs) {
            for (int p = 0; p < 4; p++) {
                phase_usec[p] += job.phase_usec[p];
            }
            String relative = to_godot(std::string(job.far ? "far/" : "cells/") + cell_name(job.cx, job.cz) + CELL_EXTENSION);
            switch (job.outcome) {
                case OUTCOME_WRITTEN:
                    written.push_back(relative);
                    break;
                case OUTCOME_UNCHANGED:
                    unchanged.push_back(relative);
                    if (job.skipped) {
                        skipped.push_back(relative);
                    }
                    break;
                case OUTCOME_DELETED:
                    deleted.push_back(relative);
                    break;
                case OUTCOME_FAILED:
                    if (first_error.is_empty()) {
                        first_error = relative + ": " + to_godot(job.error);
                    }
                    break;
                default:
                    break;
            }
            if (!job.far) {
                instances += job.instances;
            }
            defaulted_paths.insert(job.defaulted.begin(), job.defaulted.end());
        }
    }
    for (const std::string &path : defaulted_paths) {
        defaulted.push_back(to_godot(path));
    }
    if (first_error.is_empty()) {
        first_error = index_error;
    }
    result["ok"] = first_error.is_empty();
    result["error"] = first_error;
    result["written"] = written;
    result["unchanged"] = unchanged;
    result["deleted"] = deleted;
    result["defaulted"] = defaulted;
    result["skipped"] = skipped;
    result["cell_count"] = int64_t(cell_jobs.size());
    result["far_count"] = int64_t(far_jobs.size());
    result["instance_count"] = int64_t(instances);
    Dictionary profile;
    profile["cells_usec"] = far_started - cells_started;
    profile["far_usec"] = far_finished - far_started;
    profile["read_usec"] = phase_usec[PHASE_READ];
    profile["shape_usec"] = phase_usec[PHASE_SHAPE];
    profile["encode_usec"] = phase_usec[PHASE_ENCODE];
    profile["write_usec"] = phase_usec[PHASE_WRITE];
    result["profile"] = profile;
    return result;
}

Array CopiaBuild::stale_cells(const String &p_directory, double p_cell_size, const Dictionary &p_objects, bool p_verify) {
    Array stale;
    Descriptors descriptors;
    std::string error;
    if (!std::isfinite(p_cell_size) || p_cell_size <= 0.0) {
        error = "cell_size must be a positive number";
    }
    if (error.empty() && !parse_descriptors(p_objects, p_cell_size, descriptors, error)) {
        // error set
    }
    if (!error.empty()) {
        Dictionary entry;
        entry["kind"] = "error";
        entry["error"] = to_godot(error);
        stale.push_back(entry);
        return stale;
    }
    // The set file hashes and the recorded inputs come from the two indexes; no per-cell file is
    // opened unless an index is missing, lacks a file or verify is set.
    SetIndex set_index;
    CellIndex cell_index;
    {
        std::lock_guard<std::mutex> lock(index_mutex());
        load_set_index(p_directory, set_index, p_verify);
        load_cell_index(p_directory, cell_index, p_verify);
    }
    std::map<std::pair<int32_t, int32_t>, std::vector<CellInputSet>> current;
    for (const auto &item : set_index.entries) {
        if (item.second.ok) {
            CellInputSet input;
            input.set = std::get<0>(item.first);
            input.cx = std::get<1>(item.first);
            input.cz = std::get<2>(item.first);
            input.hash = item.second.hash;
            current[{ input.cx, input.cz }].push_back(input);
        }
    }
    std::map<std::pair<int32_t, int32_t>, const CellIndexFile *> built, far;
    for (const auto &item : cell_index.files) {
        (std::get<0>(item.first) == 0 ? built : far)[{ std::get<1>(item.first), std::get<2>(item.first) }] = &item.second;
    }
    const std::vector<uint32_t> descriptor_hash = descriptor_hash_ids(cell_index, descriptors);
    auto object_stale = [&](const CellIndexFile &p_file) {
        return !objects_current(p_file, descriptor_hash);
    };
    auto add = [&](const std::pair<int32_t, int32_t> &p_cell, const char *p_kind, const char *p_reason) {
        Dictionary entry;
        entry["cell"] = Vector2i(p_cell.first, p_cell.second);
        entry["kind"] = p_kind;
        entry["reason"] = p_reason;
        stale.push_back(entry);
    };

    std::set<std::pair<int32_t, int32_t>> all_cells;
    for (const auto &entry : current) {
        all_cells.insert(entry.first);
    }
    for (const auto &entry : built) {
        all_cells.insert(entry.first);
    }
    std::set<std::pair<int32_t, int32_t>> needed_far;
    for (const auto &cell : all_cells) {
        auto set_entry = current.find(cell);
        auto built_entry = built.find(cell);
        if (built_entry == built.end()) {
            add(cell, "cell", "missing");
            continue;
        }
        const CellIndexFile &directory = *built_entry->second;
        if (directory.ok && descriptors.cells_per_far > 0) {
            for (const CellIndexEntry &entry : directory.entries) {
                if (entry.impostors > 0) {
                    needed_far.insert({ int32_t(floor_div(cell.first, descriptors.cells_per_far)), int32_t(floor_div(cell.second, descriptors.cells_per_far)) });
                    break;
                }
            }
        }
        if (set_entry == current.end()) {
            add(cell, "cell", "orphan");
        } else if (!directory.ok || directory.kind != CELL_KIND_CELL || directory.cell_size != float(p_cell_size)) {
            add(cell, "cell", "format");
        } else if (cell_index.input_sets(directory) != set_entry->second) {
            add(cell, "cell", "sets");
        } else if (object_stale(directory)) {
            add(cell, "cell", "objects");
        }
    }

    std::set<std::pair<int32_t, int32_t>> all_far = needed_far;
    for (const auto &entry : far) {
        all_far.insert(entry.first);
    }
    const int64_t k = descriptors.cells_per_far;
    for (const auto &cell : all_far) {
        auto far_entry = far.find(cell);
        if (far_entry == far.end()) {
            add(cell, "far", "missing");
            continue;
        }
        const CellIndexFile &directory = *far_entry->second;
        if (!directory.ok || directory.kind != CELL_KIND_FAR || directory.store_cell_size != float(p_cell_size)) {
            add(cell, "far", "format");
            continue;
        }
        if (k == 0 || directory.cell_size != float(descriptors.far_size)) {
            add(cell, "far", k == 0 ? "orphan" : "grid");
            continue;
        }
        if (!needed_far.count(cell)) {
            add(cell, "far", "orphan");
            continue;
        }
        std::vector<CellInputSet> sets;
        for (const auto &entry : current) {
            if (floor_div(entry.first.first, k) == cell.first && floor_div(entry.first.second, k) == cell.second) {
                sets.insert(sets.end(), entry.second.begin(), entry.second.end());
            }
        }
        std::sort(sets.begin(), sets.end());
        if (cell_index.input_sets(directory) != sets) {
            add(cell, "far", "sets");
        } else if (object_stale(directory)) {
            add(cell, "far", "objects");
        }
    }
    return stale;
}

Dictionary CopiaBuild::reindex(const String &p_directory) {
    std::lock_guard<std::mutex> lock(index_mutex());
    CellIndex index;
    int64_t read = 0;
    reconcile_cell_index(p_directory, index, true, true, read);
    int64_t unreadable = 0;
    for (const auto &item : index.files) {
        unreadable += item.second.ok ? 0 : 1;
    }
    std::string error;
    bool ok = save_cell_index(p_directory, index, error);
    Dictionary result;
    result["ok"] = ok;
    result["error"] = to_godot(error);
    result["files"] = int64_t(index.files.size());
    result["unreadable"] = unreadable;
    return result;
}

void CopiaBuild::_bind_methods() {
    ClassDB::bind_static_method("CopiaBuild", D_METHOD("build_cells", "directory", "cell_size", "cells", "objects", "force", "verify"),
            &CopiaBuild::build_cells, DEFVAL(false), DEFVAL(false));
    ClassDB::bind_static_method("CopiaBuild", D_METHOD("stale_cells", "directory", "cell_size", "objects", "verify"),
            &CopiaBuild::stale_cells, DEFVAL(false));
    ClassDB::bind_static_method("CopiaBuild", D_METHOD("reindex", "directory"), &CopiaBuild::reindex);
}

} // namespace Copia
