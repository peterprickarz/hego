#include "hapi/houdini_api.h"
#include "hego_session_manager.h"
#include "util/geo/geo_cache.h"

#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>

namespace HEGo
{
namespace Util
{
namespace Geo
{
godot::Dictionary fetch_surfaces(
		HEGoSessionManager *session_mgr, HAPI_NodeId node_id, godot::Ref<godot::Resource> fetch_surfaces_config, bool auto_cook = true);

// Custom vertex channels exported per surface: ARRAY_CUSTOM0..3.
constexpr int MAX_CUSTOM_CHANNELS = 4;

// Everything a surface build needs from Houdini for the display mesh part: the
// per-primitive vertex ranges, the vertex list mapping each vertex to its point,
// and the point attributes.
// point_attribs names which of N, Cd, uv, uv2 and tangents to include; P is always
// read. custom_attribs names up to four point attributes for ARRAY_CUSTOM0..3, in
// channel order; a blank or missing name skips that channel. Each is packed to RGBA
// float per vertex (float or int, tuple size 1-4; missing components are 0).
// Returns false when the geo has no mesh part with faces.
bool prepare_surface_data(HEGo::Util::Geo::GeoCache &cache, const godot::PackedStringArray &point_attribs, HAPI_PartInfo &out_part, godot::Array &out_prims,
		godot::Array &out_vertex_point_indices, godot::Dictionary &out_point_attrs,
		const godot::PackedStringArray &custom_attribs = godot::PackedStringArray());

// One attribute's values (one Variant per point) as a flat RGBA float array.
godot::PackedFloat32Array pack_custom_channel(const godot::Array &values);

// Compacts point_attrs down to the points id_arr's primitives use, and returns the
// old point index -> compacted index mapping (-1 for points this group does not use).
godot::PackedInt32Array filter_and_update_dictionary(
		godot::Dictionary &point_attrs, const godot::Array &id_arr, const godot::Array &vertex_point_indices);
void modify_base_entries(
		godot::Dictionary &nested_dict, const godot::Array &vertex_point_indices, const godot::Dictionary &point_attrs, const godot::Array &filtered_prims);
} // namespace Geo
} // namespace Util
} // namespace HEGo