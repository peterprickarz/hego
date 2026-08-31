#include "hapi/houdini_api.h"
#include "hego_session_manager.h"
#include "util/geo/geo_cache.h"

#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/dictionary.hpp>
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

// Everything a surface build needs from Houdini for the display mesh part: the
// per-face vertex ranges, the vertex list and the point attributes.
// vertex_attribs names which of N, Cd, uv, uv2 and tangents to include; P is always
// read. Returns false when the geo has no mesh part with faces.
bool prepare_surface_data(HEGo::Util::Geo::GeoCache &cache, const godot::PackedStringArray &vertex_attribs, HAPI_PartInfo &out_part, godot::Array &out_prims,
		godot::Array &out_vertex_point_indices, godot::Dictionary &out_point_attrs);

// Compacts point_attrs down to the points id_arr's primitives use, and returns the
// old point index -> compacted index mapping (-1 for points this group does not use).
godot::PackedInt32Array filter_and_update_dictionary(
		godot::Dictionary &point_attrs, const godot::Array &id_arr, const godot::Array &vertex_point_indices);
void modify_base_entries(
		godot::Dictionary &nested_dict, const godot::Array &vertex_point_indices, const godot::Dictionary &point_attrs, const godot::Array &filtered_prims);
} // namespace Geo
} // namespace Util
} // namespace HEGo