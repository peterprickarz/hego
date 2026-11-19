#ifndef COPIA_SETS_H
#define COPIA_SETS_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/rect2.hpp>
#include <godot_cpp/variant/string.hpp>

#include "copia_format.h"

#include <string>
#include <vector>

namespace Copia {

// Set files: the editor-side source of a store's points, one file per set and cell under
// "<directory>/sets/<set>/<cx>_<cz>.copiaset". All methods are static and may run on any
// thread; one directory must have one writer at a time.
//
// apply(directory, cell_size, clears, points) applies clears first, then adds points to the
// set file of the cell their origin falls in. Columns and their rules:
// - transform: PackedFloat32Array, 12 per point (basis x, y, z, origin), all finite.
// - object: PackedInt32Array indexing object_paths (PackedStringArray, non-empty paths).
// - set / set_names: optional; names are 1 to 64 characters of a-z, 0-9 and '_'.
// - color, custom: optional PackedFloat32Array, 4 per point. A point whose first component
//   is NaN carries none (stored as NaN in all four, the object's default applies at build);
//   any other non-finite component is invalid.
// - keep: optional PackedFloat32Array, finite; clamped to 0..1.
// - extra: optional {name: PackedInt32Array (1 per point) | PackedFloat32Array (1 or 3 per
//   point) | PackedVector3Array}. Names are 1 to 255 bytes. Stored as given (NaN included).
//   A set file keeps the union of the extra columns written into it; points written without a
//   column read back zero in it. A name stored with another type or width is invalid.
// Validation, and reading every affected file, happen before anything is written. Invalid
// input, a corrupt set file or a cell size that differs from the files' returns
// {ok = false, error = "..."} and writes nothing. An I/O failure while writing returns
// ok = false and lists what was already written; every file on disk is still complete (temp
// file + rename).
// The result: ok, error, written, deleted, unchanged (paths relative to the directory, such as
// "sets/default/0_-1.copiaset", sorted), cells (Array of Vector2i whose set files were written
// or deleted, sorted) and point_count (points added).
class CopiaSets : public godot::RefCounted {
    GDCLASS(CopiaSets, godot::RefCounted)

public:
    static godot::Dictionary apply(const godot::String &p_directory, double p_cell_size, const godot::Array &p_clears,
            const godot::Dictionary &p_points);
    // Set names with at least one set file, sorted.
    static godot::PackedStringArray list_sets(const godot::String &p_directory);
    // [{cell: Vector2i, count: int, hash: String (64 hex digits)}] from the sets index, sorted by
    // cell. The readers of the index take verify: re-read every header and repair the index.
    static godot::Array list_cells(const godot::String &p_directory, const godot::String &p_set, bool p_verify = false);
    // The object paths of the set files in p_cells (Vector2i; all cells when empty), sorted.
    static godot::PackedStringArray list_objects(const godot::String &p_directory, const godot::Array &p_cells,
            bool p_verify = false);
    // One row per cell and set that holds points, from the index: P (cell centre, y 0), cell
    // ("cx_cz"), set, count, cell_min, cell_max. An empty rect (no area) means every cell.
    static godot::Dictionary cell_points(const godot::String &p_directory, double p_cell_size, const godot::Rect2 &p_rect,
            const godot::PackedStringArray &p_sets, const godot::PackedStringArray &p_exclude, bool p_verify = false);
    // Rebuilds sets/index.copiaindex from every set file's header: {ok, error, files, unreadable}.
    static godot::Dictionary reindex(const godot::String &p_directory);
    // Points whose origin lies in p_rect (x and y of the Rect2 are local X and Z; start
    // inclusive, end exclusive) from the sets named in p_sets (all when empty) minus p_exclude.
    // Returns the apply() columns plus set / set_names and count. color and custom are present
    // when a file read stores them (NaN rows carry none), keep when a file read stores it, and
    // extra holds the union of the files' extra columns. Order: set name, cell, canonical.
    static godot::Dictionary read_points(const godot::String &p_directory, double p_cell_size,
            const godot::Rect2 &p_rect, const godot::PackedStringArray &p_sets,
            const godot::PackedStringArray &p_exclude);
    // Deletes a set's files and directory; returns the cells (Vector2i) it had points in.
    static godot::Array remove_set(const godot::String &p_directory, const godot::String &p_set);

protected:
    static void _bind_methods();
};

// Shared with the build.
godot::String set_file_path(const godot::String &p_directory, const std::string &p_set, int32_t p_cx, int32_t p_cz);
std::vector<std::string> set_names_on_disk(const godot::String &p_directory);

} // namespace Copia

#endif // COPIA_SETS_H
