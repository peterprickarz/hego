#include "copia_index.h"

#include "copia_sets.h"

#include <godot_cpp/classes/dir_access.hpp>
#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>

#include <algorithm>
#include <set>

using namespace godot;

namespace Copia {

namespace {

const char *SET_EXTENSION = ".copiaset";
const char *CELL_EXTENSION = ".copiacell";
const size_t INDEX_HEADER_SIZE = 20;

// Remaps a table's ids to the used strings in sorted order, so the file does not depend on the
// order strings were interned in.
struct Compact {
    std::vector<uint32_t> map; // old id -> new id
    std::vector<std::string> names; // new id -> string
    Compact(const StringTable &p_table, const std::vector<char> &p_used) {
        std::vector<uint32_t> order;
        for (uint32_t i = 0; i < p_used.size(); i++) {
            if (p_used[i]) {
                order.push_back(i);
            }
        }
        std::sort(order.begin(), order.end(), [&](uint32_t a, uint32_t b) { return p_table.get(a) < p_table.get(b); });
        map.assign(p_table.names.size(), UINT32_MAX);
        for (uint32_t i = 0; i < order.size(); i++) {
            map[order[i]] = i;
            names.push_back(p_table.get(order[i]));
        }
    }
};

bool write_index(const String &p_path, uint32_t p_kind, const Bytes &p_body, std::string &r_error) {
    Bytes compressed;
    if (!compress_block(p_body.data(), p_body.size(), compressed)) {
        r_error = "index compression failed";
        return false;
    }
    ByteWriter out;
    out.raw("CPIX", 4);
    out.u32(INDEX_FORMAT_VERSION);
    out.u32(p_kind);
    out.u32(uint32_t(p_body.size()));
    out.u32(uint32_t(compressed.size()));
    out.raw(compressed.data(), compressed.size());
    return write_file_atomic(p_path, out.data, r_error);
}

bool read_index(const String &p_path, uint32_t p_kind, Bytes &r_body) {
    Bytes file;
    if (!file_exists(p_path) || !read_file(p_path, file) || file.size() < INDEX_HEADER_SIZE) {
        return false;
    }
    ByteReader in(file.data(), file.size());
    char magic[4];
    in.raw(magic, 4);
    uint32_t version = in.u32();
    uint32_t kind = in.u32();
    uint32_t raw_size = in.u32();
    uint32_t compressed_size = in.u32();
    if (!in.ok() || std::memcmp(magic, "CPIX", 4) != 0 || version != INDEX_FORMAT_VERSION || kind != p_kind ||
            compressed_size != file.size() - INDEX_HEADER_SIZE) {
        return false;
    }
    return decompress_block(file.data() + INDEX_HEADER_SIZE, compressed_size, raw_size, r_body);
}

bool read_strings(ByteReader &r_in, size_t p_size, std::vector<std::string> &r_names) {
    uint32_t count = r_in.u32();
    if (!r_in.ok() || count > p_size) {
        return false;
    }
    r_names.resize(count);
    for (std::string &name : r_names) {
        name = r_in.str();
    }
    return r_in.ok();
}

void load_table(StringTable &r_table, std::vector<std::string> &p_names) {
    r_table.names = std::move(p_names);
    r_table.ids.clear();
    r_table.ids.reserve(r_table.names.size());
    for (uint32_t i = 0; i < r_table.names.size(); i++) {
        r_table.ids.emplace(r_table.names[i], i);
    }
}

template <typename T>
bool read_array(ByteReader &r_in, size_t p_size, std::vector<T> &r_out, size_t p_record) {
    uint32_t count = r_in.u32();
    if (!r_in.ok() || size_t(count) * p_record > p_size) {
        return false;
    }
    r_out.resize(count);
    return true;
}

// Names of the set files on disk: (set, cx, cz).
std::set<SetKey> set_files_on_disk(const String &p_directory) {
    std::set<SetKey> files;
    String root = p_directory.path_join("sets");
    if (!DirAccess::dir_exists_absolute(root)) {
        return files;
    }
    PackedStringArray folders = DirAccess::get_directories_at(root);
    for (int64_t i = 0; i < folders.size(); i++) {
        std::string set = to_std(folders[i]);
        if (!valid_set_name(set)) {
            continue;
        }
        PackedStringArray names = DirAccess::get_files_at(root.path_join(folders[i]));
        for (int64_t f = 0; f < names.size(); f++) {
            int32_t cx, cz;
            if (parse_cell_name(to_std(names[f]), SET_EXTENSION, cx, cz)) {
                files.insert(SetKey(set, cx, cz));
            }
        }
    }
    return files;
}

std::set<CellKey> cell_files_on_disk(const String &p_directory) {
    std::set<CellKey> files;
    for (int folder = 0; folder < 2; folder++) {
        String path = p_directory.path_join(folder ? "far" : "cells");
        if (!DirAccess::dir_exists_absolute(path)) {
            continue;
        }
        PackedStringArray names = DirAccess::get_files_at(path);
        for (int64_t i = 0; i < names.size(); i++) {
            int32_t cx, cz;
            if (parse_cell_name(to_std(names[i]), CELL_EXTENSION, cx, cz)) {
                files.insert(CellKey(folder, cx, cz));
            }
        }
    }
    return files;
}

bool same_entry(const SetIndexEntry &a, const SetIndexEntry &b, const StringTable &p_ta, const StringTable &p_tb) {
    if (a.ok != b.ok || a.cell_size != b.cell_size || a.point_count != b.point_count || a.hash != b.hash ||
            a.objects.size() != b.objects.size()) {
        return false;
    }
    for (size_t i = 0; i < a.objects.size(); i++) {
        if (p_ta.get(a.objects[i]) != p_tb.get(b.objects[i])) {
            return false;
        }
    }
    return true;
}

// Removes an index file that would list nothing; writes the others.
template <typename Encode>
bool save_or_remove(const String &p_path, bool p_empty, uint32_t p_kind, Encode p_encode, std::string &r_error) {
    if (p_empty) {
        if (file_exists(p_path) && !remove_file(p_path)) {
            r_error = "cannot delete " + to_std(p_path);
            return false;
        }
        return true;
    }
    Bytes body;
    p_encode(body);
    return write_index(p_path, p_kind, body, r_error);
}

} // namespace

std::mutex &index_mutex() {
    static std::mutex mutex;
    return mutex;
}

uint32_t StringTable::intern(const std::string &p_name) {
    auto found = ids.find(p_name);
    if (found != ids.end()) {
        return found->second;
    }
    uint32_t id = uint32_t(names.size());
    names.push_back(p_name);
    ids.emplace(p_name, id);
    return id;
}

uint32_t StringTable::find(const std::string &p_name) const {
    auto found = ids.find(p_name);
    return found == ids.end() ? UINT32_MAX : found->second;
}

// --- Set files ---------------------------------------------------------------------------------

String set_index_path(const String &p_directory) {
    return p_directory.path_join("sets").path_join(INDEX_FILE_NAME);
}

void SetIndex::put(const SetKey &p_key, const SetSummary &p_summary) {
    SetIndexEntry &entry = entries[p_key];
    entry.ok = p_summary.ok;
    entry.cell_size = p_summary.cell_size;
    entry.point_count = p_summary.point_count;
    entry.hash = p_summary.hash;
    entry.objects.clear();
    for (const std::string &path : p_summary.objects) {
        entry.objects.push_back(strings.intern(path));
    }
}

bool read_set_summary(const String &p_path, int32_t p_cx, int32_t p_cz, SetSummary &r_summary) {
    r_summary = SetSummary();
    Ref<FileAccess> file = FileAccess::open(p_path, FileAccess::READ);
    if (file.is_null()) {
        return false;
    }
    const uint64_t length = file->get_length();
    // The object table follows the header; 64 KiB holds it for any ordinary file.
    Bytes data(size_t(std::min<uint64_t>(length, 65536)));
    if (!data.empty() && file->get_buffer(data.data(), data.size()) != data.size()) {
        return false;
    }
    for (int attempt = 0; attempt < 2; attempt++) {
        SetFile header;
        std::string error;
        if (!decode_set_file(data, header, true, error) || header.cx != p_cx || header.cz != p_cz) {
            return false;
        }
        ByteReader in(data.data() + SET_HEADER_SIZE, data.size() - SET_HEADER_SIZE);
        uint32_t count = in.u32();
        std::vector<std::string> objects;
        if (in.ok() && count <= length) {
            objects.reserve(count);
            for (uint32_t i = 0; i < count && in.ok(); i++) {
                objects.push_back(in.str());
            }
        }
        if (in.ok()) {
            r_summary.ok = true;
            r_summary.cell_size = header.cell_size;
            r_summary.point_count = header.point_count;
            r_summary.hash = header.hash;
            r_summary.objects = std::move(objects);
            return true;
        }
        if (data.size() == length) {
            return false;
        }
        // A table longer than the first read: read the whole file once.
        data.resize(size_t(length));
        file->seek(0);
        if (file->get_buffer(data.data(), data.size()) != data.size()) {
            return false;
        }
    }
    return false;
}

bool decode_set_index_file(const String &p_directory, SetIndex &r_index) {
    r_index = SetIndex();
    Bytes body;
    if (!read_index(set_index_path(p_directory), INDEX_SETS, body)) {
        return false;
    }
    ByteReader in(body.data(), body.size());
    std::vector<std::string> names;
    if (!read_strings(in, body.size(), names)) {
        return false;
    }
    load_table(r_index.strings, names);
    const uint32_t string_count = uint32_t(r_index.strings.names.size());
    uint32_t count = in.u32();
    if (!in.ok() || count > body.size()) {
        return false;
    }
    for (uint32_t i = 0; i < count; i++) {
        uint32_t set = in.u32();
        int32_t cx = in.i32();
        int32_t cz = in.i32();
        SetIndexEntry entry;
        entry.ok = in.u8() != 0;
        entry.cell_size = in.f32();
        entry.point_count = in.u32();
        in.raw(entry.hash.data(), 32);
        uint32_t objects = in.u32();
        if (!in.ok() || set >= string_count || size_t(objects) * 4 > body.size()) {
            r_index = SetIndex();
            return false;
        }
        entry.objects.resize(objects);
        bool valid = true;
        for (uint32_t &object : entry.objects) {
            object = in.u32();
            valid = valid && object < string_count;
        }
        if (!in.ok() || !valid) {
            r_index = SetIndex();
            return false;
        }
        r_index.entries.emplace(SetKey(r_index.strings.get(set), cx, cz), std::move(entry));
    }
    if (in.position() != body.size()) {
        r_index = SetIndex();
        return false;
    }
    return true;
}

bool reconcile_set_index(const String &p_directory, SetIndex &r_index, bool p_rebuild, bool p_verify, int64_t &r_read) {
    const std::set<SetKey> on_disk = set_files_on_disk(p_directory);
    bool changed = p_rebuild;
    for (auto it = r_index.entries.begin(); it != r_index.entries.end();) {
        if (!on_disk.count(it->first)) {
            it = r_index.entries.erase(it);
            changed = true;
        } else {
            ++it;
        }
    }
    std::vector<SetKey> to_read;
    for (const SetKey &key : on_disk) {
        auto found = r_index.entries.find(key);
        if (p_rebuild || p_verify || found == r_index.entries.end() || !found->second.ok) {
            to_read.push_back(key);
        }
    }
    std::vector<SetSummary> summaries(to_read.size());
    parallel_for(int64_t(to_read.size()), [&](int64_t i) {
        const SetKey &key = to_read[size_t(i)];
        read_set_summary(set_file_path(p_directory, std::get<0>(key), std::get<1>(key), std::get<2>(key)),
                std::get<1>(key), std::get<2>(key), summaries[size_t(i)]);
    });
    r_read = int64_t(to_read.size());
    for (size_t i = 0; i < to_read.size(); i++) {
        auto found = r_index.entries.find(to_read[i]);
        if (found != r_index.entries.end()) {
            SetIndex probe;
            probe.put(to_read[i], summaries[i]);
            if (same_entry(found->second, probe.entries.begin()->second, r_index.strings, probe.strings)) {
                continue;
            }
        }
        r_index.put(to_read[i], summaries[i]);
        changed = true;
    }
    return changed;
}

bool save_set_index(const String &p_directory, const SetIndex &p_index, std::string &r_error) {
    return save_or_remove(set_index_path(p_directory), p_index.entries.empty(), INDEX_SETS, [&](Bytes &r_body) {
        StringTable table = p_index.strings;
        std::vector<uint32_t> set_ids;
        for (const auto &entry : p_index.entries) {
            set_ids.push_back(table.intern(std::get<0>(entry.first)));
        }
        std::vector<char> used(table.names.size(), 0);
        for (uint32_t id : set_ids) {
            used[id] = 1;
        }
        for (const auto &entry : p_index.entries) {
            for (uint32_t id : entry.second.objects) {
                used[id] = 1;
            }
        }
        Compact compact(table, used);
        ByteWriter out;
        out.u32(uint32_t(compact.names.size()));
        for (const std::string &name : compact.names) {
            out.str(name);
        }
        out.u32(uint32_t(p_index.entries.size()));
        size_t i = 0;
        for (const auto &item : p_index.entries) {
            const SetIndexEntry &entry = item.second;
            out.u32(compact.map[set_ids[i++]]);
            out.i32(std::get<1>(item.first));
            out.i32(std::get<2>(item.first));
            out.u8(entry.ok ? 1 : 0);
            out.f32(entry.cell_size);
            out.u32(entry.point_count);
            out.raw(entry.hash.data(), 32);
            out.u32(uint32_t(entry.objects.size()));
            for (uint32_t id : entry.objects) {
                out.u32(compact.map[id]);
            }
        }
        r_body.swap(out.data);
    }, r_error);
}

int64_t load_set_index(const String &p_directory, SetIndex &r_index, bool p_verify) {
    const bool decoded = decode_set_index_file(p_directory, r_index);
    int64_t read = 0;
    bool changed = reconcile_set_index(p_directory, r_index, !decoded, p_verify, read);
    if (changed && DirAccess::dir_exists_absolute(p_directory.path_join("sets"))) {
        std::string error;
        save_set_index(p_directory, r_index, error); // read-only data keeps the index in memory
    }
    return read;
}

// --- Built and far files ----------------------------------------------------------------------

String cell_index_path(const String &p_directory) {
    return p_directory.path_join("cells").path_join(INDEX_FILE_NAME);
}

String cell_file_path(const String &p_directory, bool p_far, int32_t p_cx, int32_t p_cz) {
    return p_directory.path_join(p_far ? "far" : "cells").path_join(to_godot(cell_name(p_cx, p_cz) + CELL_EXTENSION));
}

void CellIndex::put(const CellKey &p_key, bool p_ok, const CellDirectory &p_directory) {
    CellIndexFile &file = files[p_key];
    file = CellIndexFile();
    file.ok = p_ok;
    if (!p_ok) {
        return;
    }
    file.kind = p_directory.kind;
    file.cell_size = p_directory.cell_size;
    file.store_cell_size = p_directory.store_cell_size;
    file.sets.reserve(p_directory.sets.size());
    for (const CellInputSet &set : p_directory.sets) {
        CellIndexSet value;
        value.set = strings.intern(set.set);
        value.cx = set.cx;
        value.cz = set.cz;
        value.hash = set.hash;
        file.sets.push_back(value);
    }
    file.objects.reserve(p_directory.objects.size());
    for (const CellInputObject &object : p_directory.objects) {
        CellIndexObject value;
        value.path = strings.intern(object.path);
        value.hash = strings.intern(object.hash);
        file.objects.push_back(value);
    }
    file.entries.reserve(p_directory.entries.size());
    for (const CellEntry &entry : p_directory.entries) {
        CellIndexEntry value;
        value.path = strings.intern(entry.path);
        value.draw = entry.draw;
        value.flags = entry.flags;
        value.instances = entry.instances;
        value.batches = entry.batches;
        value.colliders = entry.colliders;
        value.impostors = entry.impostors;
        value.impostor_batches = entry.impostor_batches;
        file.entries.push_back(value);
    }
}

std::vector<CellInputSet> CellIndex::input_sets(const CellIndexFile &p_file) const {
    std::vector<CellInputSet> sets;
    sets.reserve(p_file.sets.size());
    for (const CellIndexSet &set : p_file.sets) {
        CellInputSet value;
        value.set = strings.get(set.set);
        value.cx = set.cx;
        value.cz = set.cz;
        value.hash = set.hash;
        sets.push_back(value);
    }
    return sets;
}

bool decode_cell_index_file(const String &p_directory, CellIndex &r_index) {
    r_index = CellIndex();
    Bytes body;
    if (!read_index(cell_index_path(p_directory), INDEX_CELLS, body)) {
        return false;
    }
    ByteReader in(body.data(), body.size());
    std::vector<std::string> names;
    if (!read_strings(in, body.size(), names)) {
        return false;
    }
    load_table(r_index.strings, names);
    const uint32_t n = uint32_t(r_index.strings.names.size());
    auto fail = [&]() {
        r_index = CellIndex();
        return false;
    };
    uint32_t count = in.u32();
    if (!in.ok() || count > body.size()) {
        return fail();
    }
    for (uint32_t i = 0; i < count; i++) {
        int folder = in.u8();
        int32_t cx = in.i32();
        int32_t cz = in.i32();
        CellIndexFile file;
        file.ok = in.u8() != 0;
        file.kind = in.u32();
        file.cell_size = in.f32();
        file.store_cell_size = in.f32();
        if (!in.ok() || folder > 1 || !read_array(in, body.size(), file.sets, 44)) {
            return fail();
        }
        for (CellIndexSet &set : file.sets) {
            set.set = in.u32();
            set.cx = in.i32();
            set.cz = in.i32();
            in.raw(set.hash.data(), 32);
            if (set.set >= n) {
                return fail();
            }
        }
        if (!read_array(in, body.size(), file.objects, 8)) {
            return fail();
        }
        for (CellIndexObject &object : file.objects) {
            object.path = in.u32();
            object.hash = in.u32();
            if (object.path >= n || object.hash >= n) {
                return fail();
            }
        }
        if (!read_array(in, body.size(), file.entries, 26)) {
            return fail();
        }
        for (CellIndexEntry &entry : file.entries) {
            entry.path = in.u32();
            entry.draw = in.u8();
            entry.flags = in.u8();
            entry.instances = in.u32();
            entry.batches = in.u32();
            entry.colliders = in.u32();
            entry.impostors = in.u32();
            entry.impostor_batches = in.u32();
            if (entry.path >= n) {
                return fail();
            }
        }
        if (!in.ok()) {
            return fail();
        }
        r_index.files.emplace(CellKey(folder, cx, cz), std::move(file));
    }
    if (in.position() != body.size()) {
        return fail();
    }
    return true;
}

static bool same_cell_file(const CellIndexFile &a, const StringTable &p_ta, const CellIndexFile &b, const StringTable &p_tb) {
    if (a.ok != b.ok || a.kind != b.kind || a.cell_size != b.cell_size || a.store_cell_size != b.store_cell_size ||
            a.sets.size() != b.sets.size() || a.objects.size() != b.objects.size() || a.entries.size() != b.entries.size()) {
        return false;
    }
    for (size_t i = 0; i < a.sets.size(); i++) {
        if (p_ta.get(a.sets[i].set) != p_tb.get(b.sets[i].set) || a.sets[i].cx != b.sets[i].cx || a.sets[i].cz != b.sets[i].cz ||
                a.sets[i].hash != b.sets[i].hash) {
            return false;
        }
    }
    for (size_t i = 0; i < a.objects.size(); i++) {
        if (p_ta.get(a.objects[i].path) != p_tb.get(b.objects[i].path) || p_ta.get(a.objects[i].hash) != p_tb.get(b.objects[i].hash)) {
            return false;
        }
    }
    for (size_t i = 0; i < a.entries.size(); i++) {
        const CellIndexEntry &x = a.entries[i];
        const CellIndexEntry &y = b.entries[i];
        if (p_ta.get(x.path) != p_tb.get(y.path) || x.draw != y.draw || x.flags != y.flags || x.instances != y.instances ||
                x.batches != y.batches || x.colliders != y.colliders || x.impostors != y.impostors ||
                x.impostor_batches != y.impostor_batches) {
            return false;
        }
    }
    return true;
}

bool reconcile_cell_index(const String &p_directory, CellIndex &r_index, bool p_rebuild, bool p_verify, int64_t &r_read) {
    const std::set<CellKey> on_disk = cell_files_on_disk(p_directory);
    bool changed = p_rebuild;
    for (auto it = r_index.files.begin(); it != r_index.files.end();) {
        if (!on_disk.count(it->first)) {
            it = r_index.files.erase(it);
            changed = true;
        } else {
            ++it;
        }
    }
    std::vector<CellKey> to_read;
    for (const CellKey &key : on_disk) {
        auto found = r_index.files.find(key);
        if (p_rebuild || p_verify || found == r_index.files.end() || !found->second.ok) {
            to_read.push_back(key);
        }
    }
    std::vector<CellDirectory> directories(to_read.size());
    std::vector<char> ok(to_read.size(), 0);
    parallel_for(int64_t(to_read.size()), [&](int64_t i) {
        const CellKey &key = to_read[size_t(i)];
        std::string error;
        CellDirectory &directory = directories[size_t(i)];
        ok[size_t(i)] = read_cell_directory(cell_file_path(p_directory, std::get<0>(key) == 1, std::get<1>(key), std::get<2>(key)), directory, error) &&
                directory.cx == std::get<1>(key) && directory.cz == std::get<2>(key);
    });
    r_read = int64_t(to_read.size());
    for (size_t i = 0; i < to_read.size(); i++) {
        auto found = r_index.files.find(to_read[i]);
        if (found != r_index.files.end()) {
            CellIndex probe;
            probe.put(to_read[i], ok[i] != 0, directories[i]);
            if (same_cell_file(found->second, r_index.strings, probe.files.begin()->second, probe.strings)) {
                continue;
            }
        }
        r_index.put(to_read[i], ok[i] != 0, directories[i]);
        changed = true;
    }
    return changed;
}

bool save_cell_index(const String &p_directory, const CellIndex &p_index, std::string &r_error) {
    return save_or_remove(cell_index_path(p_directory), p_index.files.empty(), INDEX_CELLS, [&](Bytes &r_body) {
        std::vector<char> used(p_index.strings.names.size(), 0);
        for (const auto &item : p_index.files) {
            for (const CellIndexSet &set : item.second.sets) {
                used[set.set] = 1;
            }
            for (const CellIndexObject &object : item.second.objects) {
                used[object.path] = 1;
                used[object.hash] = 1;
            }
            for (const CellIndexEntry &entry : item.second.entries) {
                used[entry.path] = 1;
            }
        }
        Compact compact(p_index.strings, used);
        ByteWriter out;
        out.u32(uint32_t(compact.names.size()));
        for (const std::string &name : compact.names) {
            out.str(name);
        }
        out.u32(uint32_t(p_index.files.size()));
        for (const auto &item : p_index.files) {
            const CellIndexFile &file = item.second;
            out.u8(uint8_t(std::get<0>(item.first)));
            out.i32(std::get<1>(item.first));
            out.i32(std::get<2>(item.first));
            out.u8(file.ok ? 1 : 0);
            out.u32(file.kind);
            out.f32(file.cell_size);
            out.f32(file.store_cell_size);
            out.u32(uint32_t(file.sets.size()));
            for (const CellIndexSet &set : file.sets) {
                out.u32(compact.map[set.set]);
                out.i32(set.cx);
                out.i32(set.cz);
                out.raw(set.hash.data(), 32);
            }
            out.u32(uint32_t(file.objects.size()));
            for (const CellIndexObject &object : file.objects) {
                out.u32(compact.map[object.path]);
                out.u32(compact.map[object.hash]);
            }
            out.u32(uint32_t(file.entries.size()));
            for (const CellIndexEntry &entry : file.entries) {
                out.u32(compact.map[entry.path]);
                out.u8(entry.draw);
                out.u8(entry.flags);
                out.u32(entry.instances);
                out.u32(entry.batches);
                out.u32(entry.colliders);
                out.u32(entry.impostors);
                out.u32(entry.impostor_batches);
            }
        }
        r_body.swap(out.data);
    }, r_error);
}

int64_t load_cell_index(const String &p_directory, CellIndex &r_index, bool p_verify) {
    const bool decoded = decode_cell_index_file(p_directory, r_index);
    int64_t read = 0;
    bool changed = reconcile_cell_index(p_directory, r_index, !decoded, p_verify, read);
    if (changed && (!r_index.files.empty() || DirAccess::dir_exists_absolute(p_directory.path_join("cells")))) {
        std::string error;
        save_cell_index(p_directory, r_index, error); // read-only data keeps the index in memory
    }
    return read;
}

bool read_index_info(const String &p_path, uint32_t &r_kind, int64_t &r_entries, Hash &r_hash) {
    Bytes head;
    if (!read_file_prefix(p_path, INDEX_HEADER_SIZE, head) || head.size() != INDEX_HEADER_SIZE) {
        return false;
    }
    uint32_t kind;
    std::memcpy(&kind, head.data() + 8, 4);
    Bytes body;
    if (kind > INDEX_CELLS || !read_index(p_path, kind, body)) {
        return false;
    }
    ByteReader in(body.data(), body.size());
    std::vector<std::string> names;
    if (!read_strings(in, body.size(), names)) {
        return false;
    }
    r_kind = kind;
    r_entries = in.u32();
    r_hash = sha256(body.data(), body.size());
    return in.ok();
}

} // namespace Copia
