#ifndef COPIA_CELLS_H
#define COPIA_CELLS_H

#include "copia_format.h"

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/string.hpp>

#include <string>
#include <vector>

namespace Copia {

enum CellKind : uint32_t {
    CELL_KIND_CELL = 0,
    CELL_KIND_FAR = 1,
};

enum DrawMode : uint8_t {
    DRAW_MULTIMESH = 0,
    DRAW_INSTANCE = 1,
};

enum SectionSlot {
    SECTION_DRAW = 0,
    SECTION_COLLIDER = 1,
    SECTION_IMPOSTOR = 2,
    SECTION_COUNT = 3,
};

// Entry flags.
constexpr uint8_t ENTRY_DEFAULTED = 1; // built without a descriptor

struct CellInputSet {
    std::string set;
    int32_t cx = 0;
    int32_t cz = 0;
    Hash hash{};
    bool operator<(const CellInputSet &p_other) const;
    bool operator==(const CellInputSet &p_other) const;
};

struct CellInputObject {
    std::string path;
    std::string hash;
    bool operator<(const CellInputObject &p_other) const;
    bool operator==(const CellInputObject &p_other) const;
};

struct CellSection {
    uint64_t offset = 0;
    uint32_t size = 0;
    uint32_t compressed = 0;
};

struct CellEntry {
    std::string path;
    uint8_t draw = DRAW_MULTIMESH;
    uint8_t flags = 0;
    uint32_t instances = 0;
    uint32_t batches = 0;
    uint32_t colliders = 0;
    uint32_t impostors = 0;
    uint32_t impostor_batches = 0;
    CellSection sections[SECTION_COUNT];
};

struct CellDirectory {
    uint32_t version = CELL_FORMAT_VERSION;
    uint32_t kind = CELL_KIND_CELL;
    int32_t cx = 0;
    int32_t cz = 0;
    float cell_size = 0.0f;
    float store_cell_size = 0.0f;
    std::vector<CellInputSet> sets;
    std::vector<CellInputObject> objects;
    std::vector<CellEntry> entries;
};

// One decoded multimesh section: the batch table and the instance buffer.
struct BatchRecord {
    int32_t bx = 0;
    int32_t bz = 0;
    float origin[3] = { 0, 0, 0 };
    float position[3] = { 0, 0, 0 };
    float size[3] = { 0, 0, 0 };
    uint32_t first = 0;
    uint32_t count = 0;
    uint32_t keep_counts[5] = { 0, 0, 0, 0, 0 };
};

// Encodes a built file. p_raw[i][slot] is the uncompressed section of entry i (empty when
// absent); offsets and sizes in p_directory are filled in.
bool encode_cell_file(CellDirectory &r_directory, const std::vector<std::array<Bytes, SECTION_COUNT>> &p_raw, Bytes &r_out);
bool read_cell_directory(const godot::String &p_path, CellDirectory &r_directory, std::string &r_error);
bool read_cell_section(const godot::String &p_path, const CellSection &p_section, Bytes &r_raw, std::string &r_error);
// The same from a whole built file already in memory.
bool decode_cell_file(const Bytes &p_file, CellDirectory &r_directory, std::string &r_error);
bool cell_section_from_file(const Bytes &p_file, const CellSection &p_section, Bytes &r_raw, std::string &r_error);
bool decode_batch_section(const Bytes &p_raw, std::vector<BatchRecord> &r_batches, const float *&r_buffer,
        size_t &r_instances, std::string &r_error);
void encode_batch_section(const std::vector<BatchRecord> &p_batches, const std::vector<float> &p_buffer, Bytes &r_raw);
void encode_transform_section(const std::vector<float> &p_transforms, Bytes &r_raw);

// Reads built cells (".copiacell", both kinds) for the run-time side. Static methods; safe to
// call from worker threads; each call opens its own FileAccess.
//
// read_directory(path) -> {ok, error, version, kind ("cell" | "far"), cell (Vector2i),
//   cell_size, store_cell_size, inputs: {sets: [{set, cell, hash}], objects: [{path, hash}]},
//   objects: {object_path: {draw ("multimesh" | "instance"), defaulted, instance_count,
//   batch_count, collider_count, impostor_count, impostor_batch_count}}}
// read_section(path, object_path, section = "draw") with section "draw", "collider" or
//   "impostor" ->
//   multimesh sections (draw of a multimesh object, impostor, every far cell section):
//     {ok, kind: "multimesh", batch_count, batch_cells (PackedInt32Array, x and z per batch),
//      origins (PackedVector3Array), bounds (Array of AABB relative to the origin),
//      first, counts (PackedInt32Array), keep_counts (PackedInt32Array, 5 per batch),
//      buffers (Array of PackedFloat32Array, one per batch, 20 floats per instance)}
//   transform sections (draw of an instance object, collider):
//     {ok, kind: "transforms", count, transforms (PackedFloat32Array, 12 per instance: basis
//      x, y, z, origin)}
//   An object or section that is absent returns {ok = false, error}.
class CopiaCells : public godot::RefCounted {
    GDCLASS(CopiaCells, godot::RefCounted)

public:
    // Every built and far file of a store from cells/index.copiaindex, without opening them:
    // [{cell, kind ("cell" | "far", by folder), ok, cell_size, store_cell_size, and the object
    // summary as parallel columns: objects (PackedStringArray, path order), draw
    // (PackedByteArray: 0 multimesh, 1 instance), defaulted (PackedByteArray), instance_count,
    // batch_count, collider_count, impostor_count, impostor_batch_count (PackedInt32Array)}],
    // cells first, each sorted by cell. verify re-reads every file's head and repairs the index.
    static godot::Array list_cells(const godot::String &p_directory, bool p_verify = false);
    // A single-instance section's transforms (12 floats per instance: basis x, y, z, origin) as a
    // MultiMesh 3D buffer: the 3 x 4 matrix row by row, then white colour and zero custom data
    // when asked for.
    static godot::PackedFloat32Array transforms_to_buffer(const godot::PackedFloat32Array &p_transforms, bool p_with_color = false,
            bool p_with_custom = false);
    static godot::Dictionary read_directory(const godot::String &p_path);
    static godot::Dictionary read_section(const godot::String &p_path, const godot::String &p_object_path,
            const godot::String &p_section = "draw");

protected:
    static void _bind_methods();
};

} // namespace Copia

#endif // COPIA_CELLS_H
