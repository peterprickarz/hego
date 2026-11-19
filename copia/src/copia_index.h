#ifndef COPIA_INDEX_H
#define COPIA_INDEX_H

#include "copia_cells.h"
#include "copia_format.h"

#include <godot_cpp/variant/string.hpp>

#include <map>
#include <mutex>
#include <string>
#include <tuple>
#include <unordered_map>
#include <vector>

// Index files: one per data directory ("sets/index.copiaindex" for the set files,
// "cells/index.copiaindex" for the built and far files), so that listing a store's cells, sets
// and objects, finding stale cells and skipping unchanged cells never opens a per-cell file.
// The index is derived data: the code that writes a directory updates it in the same call
// (temporary file and rename), a missing or unreadable index is rebuilt from the file headers,
// and every load reconciles it with the file names on disk (a file the index lacks has its header
// read; an entry whose file is gone is dropped). A load with verify re-reads every header, for
// files changed in place outside Copia. A load that changed the index writes it back; a failed
// write (read-only data) is ignored.
//
// Callers hold index_mutex() while they load, change and save an index, so read-modify-write
// cycles in one process do not interleave.

namespace Copia {

constexpr uint32_t INDEX_FORMAT_VERSION = 1;
constexpr const char *INDEX_FILE_NAME = "index.copiaindex";

enum IndexKind : uint32_t {
    INDEX_SETS = 0,
    INDEX_CELLS = 1,
};

std::mutex &index_mutex();

struct StringTable {
    std::vector<std::string> names;
    std::unordered_map<std::string, uint32_t> ids;
    uint32_t intern(const std::string &p_name);
    const std::string &get(uint32_t p_id) const { return names[p_id]; }
    // The id of p_name, or UINT32_MAX when it is not in the table.
    uint32_t find(const std::string &p_name) const;
};

// --- Set files ---------------------------------------------------------------------------------

// What the index keeps of a set file: its header and object table.
struct SetSummary {
    bool ok = false;
    float cell_size = 0.0f;
    uint32_t point_count = 0;
    Hash hash{};
    std::vector<std::string> objects; // sorted
};

struct SetIndexEntry {
    bool ok = false; // false: the file is unreadable or its header names another cell
    float cell_size = 0.0f;
    uint32_t point_count = 0;
    Hash hash{};
    std::vector<uint32_t> objects; // string ids, in path order
};

using SetKey = std::tuple<std::string, int32_t, int32_t>; // set, cx, cz

struct SetIndex {
    StringTable strings;
    std::map<SetKey, SetIndexEntry> entries;
    void put(const SetKey &p_key, const SetSummary &p_summary);
};

godot::String set_index_path(const godot::String &p_directory);
// Reads a set file's header and object table; false when it is not a readable set file of the
// cell its name gives.
bool read_set_summary(const godot::String &p_path, int32_t p_cx, int32_t p_cz, SetSummary &r_summary);
// Loads the sets index: decodes the file (rebuilding it when missing or unreadable), reconciles
// it with the files on disk (re-reading every header when p_verify) and saves it when that
// changed it. Returns the number of headers read. The caller holds index_mutex().
int64_t load_set_index(const godot::String &p_directory, SetIndex &r_index, bool p_verify);
// The parts of load_set_index, for writers that change the index before reconciling it.
bool decode_set_index_file(const godot::String &p_directory, SetIndex &r_index);
// Returns true when the index changed; r_read counts the headers read.
bool reconcile_set_index(const godot::String &p_directory, SetIndex &r_index, bool p_rebuild, bool p_verify, int64_t &r_read);
bool save_set_index(const godot::String &p_directory, const SetIndex &p_index, std::string &r_error);

// --- Built and far files ----------------------------------------------------------------------

struct CellIndexSet {
    uint32_t set = 0; // string id
    int32_t cx = 0;
    int32_t cz = 0;
    Hash hash{};
};

struct CellIndexObject {
    uint32_t path = 0; // string id
    uint32_t hash = 0; // string id of the descriptor hash
};

struct CellIndexEntry {
    uint32_t path = 0;
    uint8_t draw = DRAW_MULTIMESH;
    uint8_t flags = 0;
    uint32_t instances = 0;
    uint32_t batches = 0;
    uint32_t colliders = 0;
    uint32_t impostors = 0;
    uint32_t impostor_batches = 0;
};

// The header, inputs and directory of a built file, without the section offsets.
struct CellIndexFile {
    bool ok = false; // false: unreadable, another version, or a header naming another cell
    uint32_t kind = CELL_KIND_CELL;
    float cell_size = 0.0f;
    float store_cell_size = 0.0f;
    std::vector<CellIndexSet> sets;
    std::vector<CellIndexObject> objects;
    std::vector<CellIndexEntry> entries;
};

using CellKey = std::tuple<int, int32_t, int32_t>; // folder (0 cells, 1 far), cx, cz

struct CellIndex {
    StringTable strings;
    std::map<CellKey, CellIndexFile> files;
    void put(const CellKey &p_key, bool p_ok, const CellDirectory &p_directory);
    // The recorded set inputs with their names, sorted as a CellDirectory's.
    std::vector<CellInputSet> input_sets(const CellIndexFile &p_file) const;
};

godot::String cell_index_path(const godot::String &p_directory);
godot::String cell_file_path(const godot::String &p_directory, bool p_far, int32_t p_cx, int32_t p_cz);
int64_t load_cell_index(const godot::String &p_directory, CellIndex &r_index, bool p_verify);
bool decode_cell_index_file(const godot::String &p_directory, CellIndex &r_index);
bool reconcile_cell_index(const godot::String &p_directory, CellIndex &r_index, bool p_rebuild, bool p_verify, int64_t &r_read);
bool save_cell_index(const godot::String &p_directory, const CellIndex &p_index, std::string &r_error);

// For the resource loader: kind, entry count and the SHA-256 of the uncompressed content.
bool read_index_info(const godot::String &p_path, uint32_t &r_kind, int64_t &r_entries, Hash &r_hash);

} // namespace Copia

#endif // COPIA_INDEX_H
