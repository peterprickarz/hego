#include "fetch_points.h"

#include "util/attrib/fetch_attribs.h"
#include "util/geo/output.h"
#include "util/hego_util.h"
#include "util/log/log.h"

#include <godot_cpp/variant/utility_functions.hpp>

namespace HEGo
{
namespace Util
{
namespace Geo
{
godot::Dictionary HEGo::Util::Geo::fetch_points(HEGoSessionManager *session_mgr, HAPI_NodeId node_id, godot::Ref<godot::Resource> fetch_point_config)
{
	bool only_loose_points = fetch_point_config->get("only_loose_points");
	godot::PackedStringArray read_attribs = fetch_point_config->get("read_attribs");
	godot::PackedStringArray filter_attribs = fetch_point_config->get("filter_attribs");
	godot::Array filter_attrib_values = fetch_point_config->get("filter_attrib_values");
	godot::PackedStringArray split_attribs = fetch_point_config->get("split_attribs");

	HOUDINI_CHECK_ERROR(HoudiniApi::CookNode(session_mgr->get_session(), node_id, session_mgr->get_cook_options()));
	session_mgr->wait_for_cook();
	HAPI_GeoInfo mesh_geo_info;
	HOUDINI_CHECK_ERROR(HoudiniApi::GetDisplayGeoInfo(session_mgr->get_session(), node_id, &mesh_geo_info));
	HAPI_PartInfo mesh_part_info;
	HOUDINI_CHECK_ERROR(HoudiniApi::GetPartInfo(session_mgr->get_session(), mesh_geo_info.nodeId, 0, &mesh_part_info));
	if (mesh_part_info.type != HAPI_PARTTYPE_MESH)
	{
		HEGo::Util::Log::error("Requested points(HAPI_PARTTYPE_MESH) but received something else instead!");
		return godot::Dictionary();
	}
	// always fetch positions
	godot::Array positions = HEGo::Util::Attribs::fetch_vector3(session_mgr->get_session(), mesh_geo_info, mesh_part_info, HAPI_ATTROWNER_POINT, "P");

	// get read, split and filter attrs
	godot::Dictionary read_attribs_dict;
	read_attribs_dict["P"] = positions;
	for (int i = 0; i < read_attribs.size(); i++)
	{
		godot::String attr_name = read_attribs[i];
		godot::Array values = HEGo::Util::Attribs::fetch_by_name(
				session_mgr->get_session(), mesh_geo_info, mesh_part_info, HAPI_ATTROWNER_POINT, attr_name.utf8().get_data());
		read_attribs_dict[attr_name] = values;
	}
	godot::Dictionary filter_attribs_dict;
	for (int i = 0; i < filter_attribs.size(); i++)
	{
		godot::String attr_name = filter_attribs[i];
		godot::Array values = HEGo::Util::Attribs::fetch_by_name(
				session_mgr->get_session(), mesh_geo_info, mesh_part_info, HAPI_ATTROWNER_POINT, attr_name.utf8().get_data());
		filter_attribs_dict[attr_name] = values;
	}
	godot::Dictionary split_attribs_dict;
	for (int i = 0; i < split_attribs.size(); i++)
	{
		godot::String attr_name = split_attribs[i];
		godot::Array values = HEGo::Util::Attribs::fetch_by_name(
				session_mgr->get_session(), mesh_geo_info, mesh_part_info, HAPI_ATTROWNER_POINT, attr_name.utf8().get_data());
		split_attribs_dict[attr_name] = values;
	}

	// filter points
	godot::Array filtered_indices;
	std::vector<int> vertex_point_indices(mesh_part_info.vertexCount);
	if (mesh_part_info.vertexCount > 0)
	{
		HOUDINI_CHECK_ERROR(HoudiniApi::GetVertexList(session_mgr->get_session(), node_id, 0, vertex_point_indices.data(), 0, mesh_part_info.vertexCount));
	}

	for (int i = 0; i < positions.size(); i++)
	{
		if (only_loose_points && mesh_part_info.vertexCount > 0)
		{
			if (std::find(vertex_point_indices.begin(), vertex_point_indices.end(), i) != vertex_point_indices.end())
			{
				continue;
			}
		}

		for (int j = 0; j < filter_attribs.size(); j++)
		{
			godot::Array values = filter_attribs_dict[filter_attribs[j]];
			godot::Variant attr_value = values[i];
			if (attr_value != filter_attrib_values[j])
			{
				continue;
			}
		}

		filtered_indices.append(i);
	}
	godot::Dictionary split_point_dictionary =
			HEGo::Util::Geo::build_nested_dictionary(split_attribs, split_attribs_dict, filtered_indices, read_attribs_dict, 0);

	return split_point_dictionary;
}

} // namespace Geo
} // namespace Util
} // namespace HEGo