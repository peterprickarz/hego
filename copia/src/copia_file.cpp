#include "copia_file.h"

#include "copia_cells.h"
#include "copia_format.h"
#include "copia_index.h"

#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/core/class_db.hpp>

using namespace godot;

namespace Copia {

void CopiaFile::_bind_methods() {
    ClassDB::bind_method(D_METHOD("get_file_path"), &CopiaFile::get_file_path);
    ClassDB::bind_method(D_METHOD("get_kind"), &CopiaFile::get_kind);
    ClassDB::bind_method(D_METHOD("get_cell"), &CopiaFile::get_cell);
    ClassDB::bind_method(D_METHOD("get_cell_size"), &CopiaFile::get_cell_size);
    ClassDB::bind_method(D_METHOD("get_counts"), &CopiaFile::get_counts);
    ClassDB::bind_method(D_METHOD("get_hash"), &CopiaFile::get_hash);
    ADD_PROPERTY(PropertyInfo(Variant::STRING, "file_path", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY), "", "get_file_path");
    ADD_PROPERTY(PropertyInfo(Variant::STRING, "kind", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY), "", "get_kind");
    ADD_PROPERTY(PropertyInfo(Variant::VECTOR2I, "cell", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY), "", "get_cell");
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "cell_size", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY), "", "get_cell_size");
    ADD_PROPERTY(PropertyInfo(Variant::DICTIONARY, "counts", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY), "", "get_counts");
    ADD_PROPERTY(PropertyInfo(Variant::STRING, "hash", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY), "", "get_hash");
}

PackedStringArray CopiaFileLoader::_get_recognized_extensions() const {
    PackedStringArray extensions;
    extensions.push_back("copiaset");
    extensions.push_back("copiacell");
    extensions.push_back("copiaindex");
    return extensions;
}

bool CopiaFileLoader::_handles_type(const StringName &p_type) const {
    return p_type == StringName("CopiaFile") || p_type == StringName("Resource");
}

String CopiaFileLoader::_get_resource_type(const String &p_path) const {
    String extension = p_path.get_extension().to_lower();
    return extension == "copiaset" || extension == "copiacell" || extension == "copiaindex" ? String("CopiaFile") : String();
}

Variant CopiaFileLoader::_load(const String &p_path, const String &p_original_path, bool p_use_sub_threads,
        int32_t p_cache_mode) const {
    Ref<CopiaFile> file;
    file.instantiate();
    file->path = p_original_path.is_empty() ? p_path : p_original_path;
    std::string error;
    if (p_path.get_extension().to_lower() == "copiaset") {
        Bytes data;
        SetFile set;
        if (!read_file_prefix(p_path, SET_HEADER_SIZE, data) || !decode_set_file(data, set, true, error)) {
            return int64_t(ERR_FILE_CORRUPT);
        }
        file->kind = "set";
        file->cell = Vector2i(set.cx, set.cz);
        file->cell_size = set.cell_size;
        file->counts["points"] = int64_t(set.point_count);
        file->hash = to_godot(hash_hex(set.hash));
        return file;
    }
    if (p_path.get_extension().to_lower() == "copiaindex") {
        uint32_t kind = 0;
        int64_t entries = 0;
        Hash hash{};
        if (!read_index_info(p_path, kind, entries, hash)) {
            return int64_t(ERR_FILE_CORRUPT);
        }
        file->kind = "index";
        file->counts["files"] = entries;
        file->counts["index"] = kind == INDEX_SETS ? "sets" : "cells";
        file->hash = to_godot(hash_hex(hash));
        return file;
    }
    CellDirectory directory;
    if (!read_cell_directory(p_path, directory, error)) {
        return int64_t(ERR_FILE_CORRUPT);
    }
    file->kind = directory.kind == CELL_KIND_FAR ? "far" : "cell";
    file->cell = Vector2i(directory.cx, directory.cz);
    file->cell_size = directory.cell_size;
    int64_t instances = 0, batches = 0, colliders = 0, impostors = 0;
    for (const CellEntry &entry : directory.entries) {
        instances += entry.instances;
        batches += entry.batches;
        colliders += entry.colliders;
        impostors += entry.impostors;
    }
    file->counts["objects"] = int64_t(directory.entries.size());
    file->counts["instances"] = instances;
    file->counts["batches"] = batches;
    file->counts["colliders"] = colliders;
    file->counts["impostors"] = impostors;
    Bytes head;
    // The head size is the last u32 of the 32-byte header.
    if (read_file_prefix(p_path, CELL_HEADER_SIZE, head) && head.size() == CELL_HEADER_SIZE) {
        uint32_t head_size;
        std::memcpy(&head_size, head.data() + 28, 4);
        if (read_file_prefix(p_path, head_size, head)) {
            file->hash = to_godot(hash_hex(sha256(head.data(), head.size())));
        }
    }
    return file;
}

} // namespace Copia
