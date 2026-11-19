#ifndef COPIA_BUILD_H
#define COPIA_BUILD_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>

namespace Copia {

// The build: turns a cell's set files into "<directory>/cells/<cx>_<cz>.copiacell" and the
// impostors of the cells inside an impostor-grid cell into "<directory>/far/<fx>_<fz>.copiacell".
// Static methods; cells and far cells are built in parallel on the WorkerThreadPool.
//
// build_cells(directory, cell_size, cells, objects, force = false)
// - cells: Array of Vector2i (a cell; its far cell is rebuilt too) or of the dictionaries
//   stale_cells() returns ({cell: Vector2i, kind: "cell" | "far"}), so its result can be passed
//   in unchanged.
// - objects: {object_path: descriptor}. Descriptor fields and defaults: draw ("multimesh" |
//   "instance", "multimesh"), mesh_aabb (AABB, empty at the origin), batch_size (cell_size; must
//   divide the cell size), default_color (Color(1, 1, 1, 1)), default_custom (Color or Vector4,
//   zero), collider (false), collider_min_scale (0), impostor (false), impostor_cell_size (a
//   multiple of the cell size; every object with an impostor must give the same one: the store
//   has one far grid), impostor_min_scale (0), hash (String or int; when absent, a SHA-256 of
//   the fields above). An object path in the sets with no descriptor is built with the
//   defaults and listed in "defaulted".
// Returns {ok, error, written, unchanged, deleted (paths relative to the directory, sorted),
// defaulted (PackedStringArray), cell_count, far_count, instance_count, threads, profile (wall
// microseconds of the cell and far passes, per-phase microseconds summed over threads)}. A rebuilt file
// whose bytes equal the file on disk is not rewritten and is listed in "unchanged". Unless force,
// a cell whose built file records the current set file hashes (headers only) and descriptor
// hashes is not rebuilt at all, nor a far cell that records the union of the current inputs of
// the built cells inside it; both are listed in "unchanged" and in "skipped". An invalid
// argument or an unreadable set file returns ok = false and writes nothing for that cell; other
// cells are still built.
//
// stale_cells(directory, cell_size, objects) -> Array of {cell: Vector2i, kind: "cell" | "far",
// reason: String}, sorted (cells first). Reasons: "missing" (set files but no built file, or a far
// cell a built cell's impostors need), "orphan" (a built file without set files, or a far file
// no built cell needs), "sets" (the set files or their hashes differ from those recorded),
// "objects" (a recorded descriptor hash differs from the current one), "grid" (a far file of
// another far grid size), "format" (unreadable, another version or another cell size). Invalid
// descriptors give one entry {kind: "error", error: String}.
//
// Both read the sets index and the cells index (see copia_index.h) instead of the files'
// headers; build_cells updates the cells index in the same call. verify re-reads every header
// first and repairs the indexes.
class CopiaBuild : public godot::RefCounted {
    GDCLASS(CopiaBuild, godot::RefCounted)

public:
    static godot::Dictionary build_cells(const godot::String &p_directory, double p_cell_size, const godot::Array &p_cells,
            const godot::Dictionary &p_objects, bool p_force = false, bool p_verify = false);
    static godot::Array stale_cells(const godot::String &p_directory, double p_cell_size, const godot::Dictionary &p_objects,
            bool p_verify = false);
    // Rebuilds cells/index.copiaindex from the header, inputs and directory of every built and far
    // file: {ok, error, files, unreadable}.
    static godot::Dictionary reindex(const godot::String &p_directory);

protected:
    static void _bind_methods();
};

} // namespace Copia

#endif // COPIA_BUILD_H
