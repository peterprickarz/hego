#ifndef COPIA_FILE_H
#define COPIA_FILE_H

#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/classes/resource_format_loader.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/vector2i.hpp>

namespace Copia {

// What loading a ".copiaset", ".copiacell" or ".copiaindex" file returns: its header data only.
// It exists so the editor lists the files and an export includes them; Copia reads the files
// themselves through FileAccess, never through this resource.
// kind: "set", "cell", "far" or "index". counts: {points} for a set file; {objects, instances,
// batches, colliders, impostors} for a built file; {files, index ("sets" | "cells")} for an index.
// hash: a set file's content hash; for a built file the SHA-256 of its header, inputs and
// directory (it changes when its inputs or content do); for an index the SHA-256 of its
// uncompressed content.
class CopiaFile : public godot::Resource {
    GDCLASS(CopiaFile, godot::Resource)

public:
    godot::String path;
    godot::String kind;
    godot::Vector2i cell;
    double cell_size = 0.0;
    godot::Dictionary counts;
    godot::String hash;

    godot::String get_file_path() const { return path; }
    godot::String get_kind() const { return kind; }
    godot::Vector2i get_cell() const { return cell; }
    double get_cell_size() const { return cell_size; }
    godot::Dictionary get_counts() const { return counts; }
    godot::String get_hash() const { return hash; }

protected:
    static void _bind_methods();
};

class CopiaFileLoader : public godot::ResourceFormatLoader {
    GDCLASS(CopiaFileLoader, godot::ResourceFormatLoader)

public:
    godot::PackedStringArray _get_recognized_extensions() const override;
    bool _handles_type(const godot::StringName &p_type) const override;
    godot::String _get_resource_type(const godot::String &p_path) const override;
    godot::Variant _load(const godot::String &p_path, const godot::String &p_original_path, bool p_use_sub_threads,
            int32_t p_cache_mode) const override;

protected:
    static void _bind_methods() {}
};

} // namespace Copia

#endif // COPIA_FILE_H
