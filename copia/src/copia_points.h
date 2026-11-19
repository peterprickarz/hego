#ifndef COPIA_POINTS_H
#define COPIA_POINTS_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>

namespace Copia {

// Converts per-point attribute arrays, as any point-producing tool delivers them, to the columns
// CopiaSets.apply() takes, and store points back to attribute arrays. Static methods; safe on any
// thread. See docs/development/copia_design.md, "Point attributes".
//
// from_attributes(attributes, names = {}, extra = []) -> {points, clears, point_count,
//   clear_count, skipped_count, errors}
//   attributes: {name: one value per point}, each a packed array or a plain Array of Variants
//   (null for a missing value). names: {default name: name used}, to read other attribute names.
//   Defaults: P, orient, N, up, scale, pscale, object, set, Cd, custom (custom_w), keep, clear,
//   cell. extra: attribute names copied as pass-through columns (int, float or Vector3).
// to_attributes(points, names = {}) -> {P, N, up, scale, object, set, keep, Cd, custom, custom_w,
//   and the extra columns}: the reverse, as int32, float32, Vector3 and String arrays only.
// split_by(attributes, name) -> {value: attributes}: the points grouped by the String value of
//   one column, in order of first appearance; null (and a missing column) is "", other values are
//   turned into text. Every column of the same length is split, in its own type; others are
//   passed on as they are. When all points share one value, attributes itself is the only group
//   (nothing is copied). Linear in the point count.
class CopiaPoints : public godot::RefCounted {
    GDCLASS(CopiaPoints, godot::RefCounted)

public:
    static godot::Dictionary from_attributes(const godot::Dictionary &p_attributes, const godot::Dictionary &p_names,
            const godot::PackedStringArray &p_extra);
    static godot::Dictionary to_attributes(const godot::Dictionary &p_points, const godot::Dictionary &p_names);
    static godot::Dictionary split_by(const godot::Dictionary &p_attributes, const godot::String &p_name);

protected:
    static void _bind_methods();
};

} // namespace Copia

#endif // COPIA_POINTS_H
