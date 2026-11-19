#include "copia_cells.h"

#include "copia_index.h"

#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/aabb.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/vector2i.hpp>

#include <algorithm>
#include <tuple>

using namespace godot;

namespace Copia {

bool CellInputSet::operator<(const CellInputSet &p_other) const {
    return std::tie(set, cx, cz, hash) < std::tie(p_other.set, p_other.cx, p_other.cz, p_other.hash);
}

bool CellInputSet::operator==(const CellInputSet &p_other) const {
    return set == p_other.set && cx == p_other.cx && cz == p_other.cz && hash == p_other.hash;
}

bool CellInputObject::operator<(const CellInputObject &p_other) const {
    return std::tie(path, hash) < std::tie(p_other.path, p_other.hash);
}

bool CellInputObject::operator==(const CellInputObject &p_other) const {
    return path == p_other.path && hash == p_other.hash;
}

static void write_head(ByteWriter &r_out, const CellDirectory &p_directory, uint32_t p_head_size) {
    r_out.raw("CPCL", 4);
    r_out.u32(CELL_FORMAT_VERSION);
    r_out.u32(p_directory.kind);
    r_out.i32(p_directory.cx);
    r_out.i32(p_directory.cz);
    r_out.f32(p_directory.cell_size);
    r_out.f32(p_directory.store_cell_size);
    r_out.u32(p_head_size);
    r_out.u32(uint32_t(p_directory.sets.size()));
    for (const CellInputSet &set : p_directory.sets) {
        r_out.str(set.set);
        r_out.i32(set.cx);
        r_out.i32(set.cz);
        r_out.raw(set.hash.data(), 32);
    }
    r_out.u32(uint32_t(p_directory.objects.size()));
    for (const CellInputObject &object : p_directory.objects) {
        r_out.str(object.path);
        r_out.str(object.hash);
    }
    r_out.u32(uint32_t(p_directory.entries.size()));
    for (const CellEntry &entry : p_directory.entries) {
        r_out.str(entry.path);
        r_out.u8(entry.draw);
        r_out.u8(entry.flags);
        r_out.u32(entry.instances);
        r_out.u32(entry.batches);
        r_out.u32(entry.colliders);
        r_out.u32(entry.impostors);
        r_out.u32(entry.impostor_batches);
        for (const CellSection &section : entry.sections) {
            r_out.u64(section.offset);
            r_out.u32(section.size);
            r_out.u32(section.compressed);
        }
    }
}

bool encode_cell_file(CellDirectory &r_directory, const std::vector<std::array<Bytes, SECTION_COUNT>> &p_raw, Bytes &r_out) {
    std::vector<std::array<Bytes, SECTION_COUNT>> compressed(p_raw.size());
    for (size_t i = 0; i < p_raw.size(); i++) {
        for (int s = 0; s < SECTION_COUNT; s++) {
            if (!p_raw[i][s].empty() && !compress_block(p_raw[i][s].data(), p_raw[i][s].size(), compressed[i][s])) {
                return false;
            }
        }
    }
    ByteWriter probe;
    write_head(probe, r_directory, 0);
    const uint64_t head_size = probe.data.size();
    uint64_t offset = head_size;
    for (size_t i = 0; i < r_directory.entries.size(); i++) {
        for (int s = 0; s < SECTION_COUNT; s++) {
            CellSection &section = r_directory.entries[i].sections[s];
            section.size = uint32_t(p_raw[i][s].size());
            section.compressed = uint32_t(compressed[i][s].size());
            section.offset = section.size ? offset : 0;
            offset += section.compressed;
        }
    }
    ByteWriter out;
    write_head(out, r_directory, uint32_t(head_size));
    for (size_t i = 0; i < r_directory.entries.size(); i++) {
        for (int s = 0; s < SECTION_COUNT; s++) {
            out.raw(compressed[i][s].data(), compressed[i][s].size());
        }
    }
    r_out.swap(out.data);
    return true;
}

// Parses the header, inputs and directory from the first bytes of a built file (at least
// head_size of them).
static bool parse_cell_head(const uint8_t *p_data, size_t p_size, CellDirectory &r_directory, uint32_t &r_head_size,
        std::string &r_error) {
    ByteReader in(p_data, std::min(p_size, CELL_HEADER_SIZE));
    char magic[4];
    in.raw(magic, 4);
    if (!in.ok() || std::memcmp(magic, "CPCL", 4) != 0) {
        r_error = "not a Copia built cell";
        return false;
    }
    r_directory.version = in.u32();
    if (r_directory.version != CELL_FORMAT_VERSION) {
        r_error = "unsupported built cell version " + std::to_string(r_directory.version);
        return false;
    }
    r_directory.kind = in.u32();
    r_directory.cx = in.i32();
    r_directory.cz = in.i32();
    r_directory.cell_size = in.f32();
    r_directory.store_cell_size = in.f32();
    r_head_size = in.u32();
    if (!in.ok() || r_head_size < CELL_HEADER_SIZE) {
        r_error = "corrupt header";
        return false;
    }
    if (p_size < r_head_size) {
        return true; // header only; the caller reads the rest
    }
    const size_t rest = r_head_size - CELL_HEADER_SIZE;
    ByteReader body(p_data + CELL_HEADER_SIZE, rest);
    uint32_t set_count = body.u32();
    if (set_count > rest) {
        r_error = "corrupt inputs";
        return false;
    }
    r_directory.sets.assign(set_count, CellInputSet());
    for (CellInputSet &set : r_directory.sets) {
        set.set = body.str();
        set.cx = body.i32();
        set.cz = body.i32();
        body.raw(set.hash.data(), 32);
    }
    uint32_t object_count = body.u32();
    if (object_count > rest) {
        r_error = "corrupt inputs";
        return false;
    }
    r_directory.objects.assign(object_count, CellInputObject());
    for (CellInputObject &object : r_directory.objects) {
        object.path = body.str();
        object.hash = body.str();
    }
    uint32_t entry_count = body.u32();
    if (entry_count > rest) {
        r_error = "corrupt directory";
        return false;
    }
    r_directory.entries.assign(entry_count, CellEntry());
    for (CellEntry &entry : r_directory.entries) {
        entry.path = body.str();
        entry.draw = body.u8();
        entry.flags = body.u8();
        entry.instances = body.u32();
        entry.batches = body.u32();
        entry.colliders = body.u32();
        entry.impostors = body.u32();
        entry.impostor_batches = body.u32();
        for (CellSection &section : entry.sections) {
            section.offset = body.u64();
            section.size = body.u32();
            section.compressed = body.u32();
        }
    }
    if (!body.ok()) {
        r_error = "truncated directory";
        return false;
    }
    return true;
}

bool read_cell_directory(const String &p_path, CellDirectory &r_directory, std::string &r_error) {
    Ref<FileAccess> file = FileAccess::open(p_path, FileAccess::READ);
    if (file.is_null()) {
        r_error = "cannot open " + to_std(p_path);
        return false;
    }
    Bytes head(CELL_HEADER_SIZE);
    if (file->get_buffer(head.data(), CELL_HEADER_SIZE) != CELL_HEADER_SIZE) {
        r_error = "truncated header";
        return false;
    }
    uint32_t head_size = 0;
    if (!parse_cell_head(head.data(), head.size(), r_directory, head_size, r_error)) {
        return false;
    }
    if (head_size > file->get_length()) {
        r_error = "corrupt head size";
        return false;
    }
    head.resize(head_size);
    uint64_t rest = head_size - CELL_HEADER_SIZE;
    if (rest && file->get_buffer(head.data() + CELL_HEADER_SIZE, rest) != rest) {
        r_error = "truncated directory";
        return false;
    }
    return parse_cell_head(head.data(), head.size(), r_directory, head_size, r_error);
}

bool decode_cell_file(const Bytes &p_file, CellDirectory &r_directory, std::string &r_error) {
    uint32_t head_size = 0;
    if (!parse_cell_head(p_file.data(), p_file.size(), r_directory, head_size, r_error)) {
        return false;
    }
    if (head_size > p_file.size()) {
        r_error = "truncated directory";
        return false;
    }
    return true;
}

bool cell_section_from_file(const Bytes &p_file, const CellSection &p_section, Bytes &r_raw, std::string &r_error) {
    r_raw.clear();
    if (p_section.size == 0) {
        r_error = "section is absent";
        return false;
    }
    if (p_section.offset > p_file.size() || p_section.compressed > p_file.size() - p_section.offset ||
            !decompress_block(p_file.data() + p_section.offset, p_section.compressed, p_section.size, r_raw)) {
        r_error = "cannot decompress section";
        return false;
    }
    return true;
}

bool read_cell_section(const String &p_path, const CellSection &p_section, Bytes &r_raw, std::string &r_error) {
    r_raw.clear();
    if (p_section.size == 0) {
        r_error = "section is absent";
        return false;
    }
    Ref<FileAccess> file = FileAccess::open(p_path, FileAccess::READ);
    if (file.is_null()) {
        r_error = "cannot open " + to_std(p_path);
        return false;
    }
    if (p_section.offset + p_section.compressed > file->get_length()) {
        r_error = "section lies outside the file";
        return false;
    }
    Bytes compressed(p_section.compressed);
    file->seek(p_section.offset);
    if (file->get_buffer(compressed.data(), compressed.size()) != compressed.size() ||
            !decompress_block(compressed.data(), compressed.size(), p_section.size, r_raw)) {
        r_error = "cannot decompress section";
        return false;
    }
    return true;
}

void encode_batch_section(const std::vector<BatchRecord> &p_batches, const std::vector<float> &p_buffer, Bytes &r_raw) {
    ByteWriter out;
    out.u32(uint32_t(p_batches.size()));
    for (const BatchRecord &batch : p_batches) {
        out.i32(batch.bx);
        out.i32(batch.bz);
        out.raw(batch.origin, 12);
        out.raw(batch.position, 12);
        out.raw(batch.size, 12);
        out.u32(batch.first);
        out.u32(batch.count);
        out.raw(batch.keep_counts, 20);
    }
    out.raw(p_buffer.data(), p_buffer.size() * sizeof(float));
    r_raw.swap(out.data);
}

void encode_transform_section(const std::vector<float> &p_transforms, Bytes &r_raw) {
    ByteWriter out;
    out.u32(uint32_t(p_transforms.size() / 12));
    out.raw(p_transforms.data(), p_transforms.size() * sizeof(float));
    r_raw.swap(out.data);
}

bool decode_batch_section(const Bytes &p_raw, std::vector<BatchRecord> &r_batches, const float *&r_buffer,
        size_t &r_instances, std::string &r_error) {
    ByteReader in(p_raw.data(), p_raw.size());
    uint32_t count = in.u32();
    if (!in.ok() || size_t(count) * BATCH_RECORD_SIZE > p_raw.size()) {
        r_error = "corrupt batch table";
        return false;
    }
    r_batches.assign(count, BatchRecord());
    size_t instances = 0;
    for (BatchRecord &batch : r_batches) {
        batch.bx = in.i32();
        batch.bz = in.i32();
        in.raw(batch.origin, 12);
        in.raw(batch.position, 12);
        in.raw(batch.size, 12);
        batch.first = in.u32();
        batch.count = in.u32();
        in.raw(batch.keep_counts, 20);
        if (batch.first != instances) {
            r_error = "batches are not contiguous";
            return false;
        }
        instances += batch.count;
    }
    size_t buffer_bytes = instances * FLOATS_PER_INSTANCE * sizeof(float);
    if (!in.ok() || p_raw.size() - in.position() != buffer_bytes) {
        r_error = "instance buffer size does not match the batch table";
        return false;
    }
    r_buffer = reinterpret_cast<const float *>(p_raw.data() + in.position());
    r_instances = instances;
    return true;
}

static String hex_string(const Hash &p_hash) {
    return to_godot(hash_hex(p_hash));
}

Dictionary CopiaCells::read_directory(const String &p_path) {
    Dictionary result;
    CellDirectory directory;
    std::string error;
    if (!read_cell_directory(p_path, directory, error)) {
        result["ok"] = false;
        result["error"] = to_godot(error);
        return result;
    }
    result["ok"] = true;
    result["error"] = String();
    result["version"] = int64_t(directory.version);
    result["kind"] = directory.kind == CELL_KIND_FAR ? "far" : "cell";
    result["cell"] = Vector2i(directory.cx, directory.cz);
    result["cell_size"] = directory.cell_size;
    result["store_cell_size"] = directory.store_cell_size;
    Array sets, objects;
    for (const CellInputSet &set : directory.sets) {
        Dictionary entry;
        entry["set"] = to_godot(set.set);
        entry["cell"] = Vector2i(set.cx, set.cz);
        entry["hash"] = hex_string(set.hash);
        sets.push_back(entry);
    }
    for (const CellInputObject &object : directory.objects) {
        Dictionary entry;
        entry["path"] = to_godot(object.path);
        entry["hash"] = to_godot(object.hash);
        objects.push_back(entry);
    }
    Dictionary inputs;
    inputs["sets"] = sets;
    inputs["objects"] = objects;
    result["inputs"] = inputs;
    Dictionary entries;
    for (const CellEntry &entry : directory.entries) {
        Dictionary value;
        value["draw"] = entry.draw == DRAW_INSTANCE ? "instance" : "multimesh";
        value["defaulted"] = (entry.flags & ENTRY_DEFAULTED) != 0;
        value["instance_count"] = int64_t(entry.instances);
        value["batch_count"] = int64_t(entry.batches);
        value["collider_count"] = int64_t(entry.colliders);
        value["impostor_count"] = int64_t(entry.impostors);
        value["impostor_batch_count"] = int64_t(entry.impostor_batches);
        entries[to_godot(entry.path)] = value;
    }
    result["objects"] = entries;
    return result;
}

Dictionary CopiaCells::read_section(const String &p_path, const String &p_object_path, const String &p_section) {
    Dictionary result;
    result["ok"] = false;
    auto failed = [&](const std::string &p_error) {
        result["error"] = to_godot(p_error);
        return result;
    };
    int slot;
    if (p_section == "draw") {
        slot = SECTION_DRAW;
    } else if (p_section == "collider") {
        slot = SECTION_COLLIDER;
    } else if (p_section == "impostor") {
        slot = SECTION_IMPOSTOR;
    } else {
        return failed("section must be \"draw\", \"collider\" or \"impostor\"");
    }
    CellDirectory directory;
    std::string error;
    if (!read_cell_directory(p_path, directory, error)) {
        return failed(error);
    }
    std::string object_path = to_std(p_object_path);
    const CellEntry *entry = nullptr;
    for (const CellEntry &candidate : directory.entries) {
        if (candidate.path == object_path) {
            entry = &candidate;
            break;
        }
    }
    if (!entry) {
        return failed("object is not in this cell");
    }
    Bytes raw;
    if (!read_cell_section(p_path, entry->sections[slot], raw, error)) {
        return failed(error);
    }
    bool batches = slot == SECTION_IMPOSTOR || (slot == SECTION_DRAW && entry->draw == DRAW_MULTIMESH);
    if (!batches) {
        ByteReader in(raw.data(), raw.size());
        uint32_t count = in.u32();
        if (!in.ok() || raw.size() != 4 + size_t(count) * 48) {
            return failed("corrupt transform section");
        }
        PackedFloat32Array transforms;
        transforms.resize(int64_t(count) * 12);
        if (count) {
            std::memcpy(transforms.ptrw(), raw.data() + 4, size_t(count) * 48);
        }
        result["ok"] = true;
        result["kind"] = "transforms";
        result["count"] = int64_t(count);
        result["transforms"] = transforms;
        return result;
    }
    std::vector<BatchRecord> records;
    const float *buffer = nullptr;
    size_t instances = 0;
    if (!decode_batch_section(raw, records, buffer, instances, error)) {
        return failed(error);
    }
    PackedInt32Array batch_cells, first, counts, keep_counts;
    PackedVector3Array origins;
    Array bounds, buffers;
    for (const BatchRecord &batch : records) {
        batch_cells.push_back(batch.bx);
        batch_cells.push_back(batch.bz);
        origins.push_back(Vector3(batch.origin[0], batch.origin[1], batch.origin[2]));
        bounds.push_back(AABB(Vector3(batch.position[0], batch.position[1], batch.position[2]), Vector3(batch.size[0], batch.size[1], batch.size[2])));
        first.push_back(int32_t(batch.first));
        counts.push_back(int32_t(batch.count));
        for (uint32_t keep : batch.keep_counts) {
            keep_counts.push_back(int32_t(keep));
        }
        PackedFloat32Array values;
        values.resize(int64_t(batch.count) * FLOATS_PER_INSTANCE);
        if (batch.count) {
            std::memcpy(values.ptrw(), buffer + size_t(batch.first) * FLOATS_PER_INSTANCE, size_t(batch.count) * FLOATS_PER_INSTANCE * sizeof(float));
        }
        buffers.push_back(values);
    }
    result["ok"] = true;
    result["kind"] = "multimesh";
    result["batch_count"] = int64_t(records.size());
    result["batch_cells"] = batch_cells;
    result["origins"] = origins;
    result["bounds"] = bounds;
    result["first"] = first;
    result["counts"] = counts;
    result["keep_counts"] = keep_counts;
    result["buffers"] = buffers;
    return result;
}

Array CopiaCells::list_cells(const String &p_directory, bool p_verify) {
    CellIndex index;
    {
        std::lock_guard<std::mutex> lock(index_mutex());
        load_cell_index(p_directory, index, p_verify);
    }
    // Strings converted once; the per-object summary is columnar, so a store of thousands of
    // cells with hundreds of objects each costs no per-object Dictionary.
    std::vector<String> names(index.strings.names.size());
    std::vector<char> converted(names.size(), 0);
    Array result;
    for (const auto &item : index.files) {
        const CellIndexFile &file = item.second;
        Dictionary cell;
        cell["cell"] = Vector2i(std::get<1>(item.first), std::get<2>(item.first));
        cell["kind"] = std::get<0>(item.first) == 1 ? "far" : "cell";
        cell["ok"] = file.ok;
        cell["cell_size"] = file.cell_size;
        cell["store_cell_size"] = file.store_cell_size;
        const int64_t n = int64_t(file.entries.size());
        PackedStringArray objects;
        PackedByteArray draw, defaulted;
        PackedInt32Array instances, batches, colliders, impostors, impostor_batches;
        objects.resize(n);
        draw.resize(n);
        defaulted.resize(n);
        instances.resize(n);
        batches.resize(n);
        colliders.resize(n);
        impostors.resize(n);
        impostor_batches.resize(n);
        for (int64_t i = 0; i < n; i++) {
            const CellIndexEntry &entry = file.entries[size_t(i)];
            if (!converted[entry.path]) {
                names[entry.path] = to_godot(index.strings.get(entry.path));
                converted[entry.path] = 1;
            }
            objects.set(i, names[entry.path]);
            draw.set(i, entry.draw == DRAW_INSTANCE ? 1 : 0);
            defaulted.set(i, (entry.flags & ENTRY_DEFAULTED) ? 1 : 0);
            instances.set(i, int32_t(entry.instances));
            batches.set(i, int32_t(entry.batches));
            colliders.set(i, int32_t(entry.colliders));
            impostors.set(i, int32_t(entry.impostors));
            impostor_batches.set(i, int32_t(entry.impostor_batches));
        }
        cell["objects"] = objects;
        cell["draw"] = draw;
        cell["defaulted"] = defaulted;
        cell["instance_count"] = instances;
        cell["batch_count"] = batches;
        cell["collider_count"] = colliders;
        cell["impostor_count"] = impostors;
        cell["impostor_batch_count"] = impostor_batches;
        result.push_back(cell);
    }
    return result;
}

PackedFloat32Array CopiaCells::transforms_to_buffer(const PackedFloat32Array &p_transforms, bool p_with_color, bool p_with_custom) {
    PackedFloat32Array buffer;
    ERR_FAIL_COND_V_MSG(p_transforms.size() % 12 != 0, buffer, "CopiaCells: transforms must hold 12 floats per instance.");
    const int64_t count = p_transforms.size() / 12;
    const int64_t stride = 12 + (p_with_color ? 4 : 0) + (p_with_custom ? 4 : 0);
    buffer.resize(count * stride);
    const float *in = p_transforms.ptr();
    float *out = buffer.ptrw();
    for (int64_t i = 0; i < count; i++, in += 12, out += stride) {
        // Columns (basis x, y, z, origin) to the rows of the 3 x 4 matrix.
        for (int row = 0; row < 3; row++) {
            out[row * 4 + 0] = in[row];
            out[row * 4 + 1] = in[3 + row];
            out[row * 4 + 2] = in[6 + row];
            out[row * 4 + 3] = in[9 + row];
        }
        float *extra = out + 12;
        if (p_with_color) {
            extra[0] = extra[1] = extra[2] = extra[3] = 1.0f;
            extra += 4;
        }
        if (p_with_custom) {
            extra[0] = extra[1] = extra[2] = extra[3] = 0.0f;
        }
    }
    return buffer;
}

void CopiaCells::_bind_methods() {
    ClassDB::bind_static_method("CopiaCells", D_METHOD("list_cells", "directory", "verify"), &CopiaCells::list_cells, DEFVAL(false));
    ClassDB::bind_static_method("CopiaCells", D_METHOD("transforms_to_buffer", "transforms", "with_color", "with_custom"),
            &CopiaCells::transforms_to_buffer, DEFVAL(false), DEFVAL(false));
    ClassDB::bind_static_method("CopiaCells", D_METHOD("read_directory", "path"), &CopiaCells::read_directory);
    ClassDB::bind_static_method("CopiaCells", D_METHOD("read_section", "path", "object_path", "section"),
            &CopiaCells::read_section, DEFVAL("draw"));
}

} // namespace Copia
