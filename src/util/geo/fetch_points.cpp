#include "fetch_points.h"

#include "util/attrib/fetch_attribs.h"
#include "util/geo/output.h"
#include "util/geo/part_selection.h"
#include "util/hego_util.h"
#include "util/log/log.h"

#include <godot_cpp/variant/utility_functions.hpp>

namespace HEGo
{
namespace Util
{
namespace Geo
{
godot::Dictionary fetch_points(HEGoSessionManager *session_mgr, HAPI_NodeId node_id, godot::Ref<godot::Resource> fetch_point_config, bool auto_cook)
{
	godot::PackedStringArray read_attribs = fetch_point_config->get("read_attribs");
	godot::PackedStringArray filter_attribs = fetch_point_config->get("filter_attribs");
	godot::Array filter_attrib_values = fetch_point_config->get("filter_attrib_values");
	godot::PackedStringArray split_attribs = fetch_point_config->get("split_attribs");

	HAPI_GeoInfo mesh_geo_info;
	if (!get_display_geo_info(session_mgr, node_id, mesh_geo_info, auto_cook))
	{
		return godot::Dictionary();
	}
	HEGo::Util::Log::message("fetch_points: display geo part count = " + godot::String::num_int64(static_cast<int64_t>(mesh_geo_info.partCount)));
	for (int part_index = 0; part_index < mesh_geo_info.partCount; ++part_index)
	{
		HAPI_PartInfo candidate;
		if (HoudiniApi::GetPartInfo(session_mgr->get_session(), mesh_geo_info.nodeId, part_index, &candidate) != HAPI_RESULT_SUCCESS)
		{
			HEGo::Util::Log::warning("fetch_points: failed to read part info at index " + godot::String::num_int64(static_cast<int64_t>(part_index)));
			continue;
		}

		HEGo::Util::Log::message("fetch_points: part[" + godot::String::num_int64(static_cast<int64_t>(part_index)) + "]" + " type=" +
				godot::String::num_int64(static_cast<int64_t>(candidate.type)) + " id=" + godot::String::num_int64(static_cast<int64_t>(candidate.id)) +
				" points=" + godot::String::num_int64(static_cast<int64_t>(candidate.pointCount)) +
				" vertices=" + godot::String::num_int64(static_cast<int64_t>(candidate.vertexCount)) +
				" faces=" + godot::String::num_int64(static_cast<int64_t>(candidate.faceCount)));
	}
	std::vector<HAPI_PartInfo> mesh_parts = get_parts_by_type(session_mgr->get_session(), mesh_geo_info, HAPI_PARTTYPE_MESH);
	if (mesh_parts.empty())
	{
		HEGo::Util::Log::error("Requested points(HAPI_PARTTYPE_MESH) but no mesh part was found.");
		return godot::Dictionary();
	}

	HAPI_PartInfo mesh_part_info;
	bool found_loose_points_part = false;
	for (const HAPI_PartInfo &part : mesh_parts)
	{
		if (part.vertexCount == 0)
		{
			mesh_part_info = part;
			found_loose_points_part = true;
			break;
		}
	}

	if (!found_loose_points_part)
	{
		HEGo::Util::Log::message("fetch_points: no loose-point mesh part found (all mesh parts have vertices).");
		return godot::Dictionary();
	}

	HEGo::Util::Log::message("fetch_points: selected mesh part id=" + godot::String::num_int64(static_cast<int64_t>(mesh_part_info.id)) +
			" points=" + godot::String::num_int64(static_cast<int64_t>(mesh_part_info.pointCount)) +
			" vertices=" + godot::String::num_int64(static_cast<int64_t>(mesh_part_info.vertexCount)) +
			" faces=" + godot::String::num_int64(static_cast<int64_t>(mesh_part_info.faceCount)));
	// fetch filter attrs first so we can return early before loading other point attributes.
	godot::Dictionary filter_attribs_dict;
	for (int i = 0; i < filter_attribs.size(); i++)
	{
		godot::String attr_name = filter_attribs[i];
		godot::Array values = HEGo::Util::Attribs::fetch_by_name(
				session_mgr->get_session(), mesh_geo_info, mesh_part_info, HAPI_ATTROWNER_POINT, attr_name.utf8().get_data());
		filter_attribs_dict[attr_name] = values;
	}

	// filter points
	godot::Array filtered_indices;
	for (int i = 0; i < mesh_part_info.pointCount; i++)
	{
		bool all_filters_pass = true;
		for (int j = 0; j < filter_attribs.size(); j++)
		{
			godot::Array values = filter_attribs_dict[filter_attribs[j]];
			godot::Variant attr_value = values[i];
			if (attr_value != filter_attrib_values[j])
			{
				all_filters_pass = false;
				break;
			}
		}
		if (all_filters_pass)
		{
			filtered_indices.append(i);
		}
	}
	if (filtered_indices.is_empty())
	{
		return godot::Dictionary();
	}

	// Fetch the remaining attributes only after we know we have points to return.
	godot::Array positions = HEGo::Util::Attribs::fetch_vector3(session_mgr->get_session(), mesh_geo_info, mesh_part_info, HAPI_ATTROWNER_POINT, "P");
	godot::Dictionary read_attribs_dict;
	read_attribs_dict["P"] = positions;
	for (int i = 0; i < read_attribs.size(); i++)
	{
		godot::String attr_name = read_attribs[i];
		godot::Array values = HEGo::Util::Attribs::fetch_by_name(
				session_mgr->get_session(), mesh_geo_info, mesh_part_info, HAPI_ATTROWNER_POINT, attr_name.utf8().get_data());
		read_attribs_dict[attr_name] = values;
	}
	godot::Dictionary split_attribs_dict;
	for (int i = 0; i < split_attribs.size(); i++)
	{
		godot::String attr_name = split_attribs[i];
		godot::Array values = HEGo::Util::Attribs::fetch_by_name(
				session_mgr->get_session(), mesh_geo_info, mesh_part_info, HAPI_ATTROWNER_POINT, attr_name.utf8().get_data());
		split_attribs_dict[attr_name] = values;
	}
	godot::Dictionary split_point_dictionary =
			HEGo::Util::Geo::build_nested_dictionary(split_attribs, split_attribs_dict, filtered_indices, read_attribs_dict, 0);

	return split_point_dictionary;
}

} // namespace Geo
} // namespace Util
} // namespace HEGo