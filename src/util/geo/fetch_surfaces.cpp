#include "fetch_surfaces.h"

#include "util/attrib/fetch_attribs.h"
#include "util/geo/output.h"
#include "util/hego_util.h"
#include "util/log/log.h"

#include <godot_cpp/classes/array_mesh.hpp>
#include <godot_cpp/classes/mesh.hpp>

namespace HEGo
{
namespace Util
{
namespace Geo
{
godot::Array convert_face_counts_to_array(const std::vector<int> &face_counts)
{
	godot::Array prims; // This will hold the final output
	int accumulated = 0; // To keep track of the accumulated face count

	// Iterate through the face_counts vector
	for (int count : face_counts)
	{
		// Create a Vector2i where x = accumulated count, y = current face count
		godot::Vector2i prim(accumulated, count);
		// Add this Vector2i to the Array
		prims.append(prim);
		// Update the accumulated count by adding the current face count
		accumulated += count;
	}

	return prims;
}
godot::Dictionary HEGo::Util::Geo::fetch_surfaces(HEGoSessionManager *session_mgr, HAPI_NodeId node_id, godot::Ref<godot::Resource> fetch_surfaces_config)
{
	HEGo::Util::Log::line();
	HEGo::Util::Log::message("Fetching Surface Dictionary");
	HAPI_Result session_valid = HoudiniApi::IsSessionValid(session_mgr->get_session());
	if (session_valid != HAPI_RESULT_SUCCESS)
	{
		return godot::Dictionary();
	}
	bool normal = fetch_surfaces_config->get("normal");
	bool color = fetch_surfaces_config->get("color");

	bool uv = fetch_surfaces_config->get("uv");
	bool uv2 = fetch_surfaces_config->get("uv2");

	bool tangents = fetch_surfaces_config->get("tangents");

	godot::PackedStringArray read_attribs = fetch_surfaces_config->get("read_attribs");
	godot::PackedStringArray filter_attribs = fetch_surfaces_config->get("filter_attribs");
	godot::Array filter_attrib_values = fetch_surfaces_config->get("filter_attrib_values");
	godot::PackedStringArray split_attribs = fetch_surfaces_config->get("split_attribs");

	HOUDINI_CHECK_ERROR(HoudiniApi::CookNode(session_mgr->get_session(), node_id, session_mgr->get_cook_options()));
	session_mgr->wait_for_cook(node_id);
	HAPI_GeoInfo mesh_geo_info;
	HOUDINI_CHECK_ERROR(HoudiniApi::GetDisplayGeoInfo(session_mgr->get_session(), node_id, &mesh_geo_info));
	HAPI_PartInfo mesh_part_info;
	HOUDINI_CHECK_ERROR(HoudiniApi::GetPartInfo(session_mgr->get_session(), mesh_geo_info.nodeId, 0, &mesh_part_info));
	std::vector<int> face_counts(mesh_part_info.faceCount);
	HOUDINI_CHECK_ERROR(HoudiniApi::GetFaceCounts(session_mgr->get_session(), node_id, 0, face_counts.data(), 0, mesh_part_info.faceCount));
	std::vector<int> vertex_point_indices(mesh_part_info.vertexCount);
	HOUDINI_CHECK_ERROR(HoudiniApi::GetVertexList(session_mgr->get_session(), node_id, 0, vertex_point_indices.data(), 0, mesh_part_info.vertexCount));

	if (mesh_part_info.type != HAPI_PARTTYPE_MESH)
	{
		HEGo::Util::Log::error("Requested mesh(HAPI_PARTTYPE_MESH) but "
							   "received something else instead!");
		return godot::Dictionary();
	}

	godot::Array prims = convert_face_counts_to_array(face_counts);

	// get read, split and filter attrs
	godot::Dictionary read_attribs_dict;

	godot::Dictionary point_attrs;
	point_attrs["P"] = HEGo::Util::Attribs::fetch_vector3(session_mgr->get_session(), mesh_geo_info, mesh_part_info, HAPI_ATTROWNER_POINT, "P");

	if (normal)
	{
		point_attrs["N"] = HEGo::Util::Attribs::fetch_vector3(session_mgr->get_session(), mesh_geo_info, mesh_part_info, HAPI_ATTROWNER_POINT, "N");
	}
	if (color)
	{
		point_attrs["Cd"] = HEGo::Util::Attribs::fetch_vector3(session_mgr->get_session(), mesh_geo_info, mesh_part_info, HAPI_ATTROWNER_POINT, "Cd");
	}
	if (uv)
	{
		point_attrs["uv"] = HEGo::Util::Attribs::fetch_vector3(session_mgr->get_session(), mesh_geo_info, mesh_part_info, HAPI_ATTROWNER_POINT, "uv");
	}
	if (uv2)
	{
		point_attrs["uv2"] = HEGo::Util::Attribs::fetch_vector3(session_mgr->get_session(), mesh_geo_info, mesh_part_info, HAPI_ATTROWNER_POINT, "uv2");
	}
	if (tangents)
	{
		HEGo::Util::Log::message("getting tangent attrs");
		point_attrs["tangentu"] =
				HEGo::Util::Attribs::fetch_vector3(session_mgr->get_session(), mesh_geo_info, mesh_part_info, HAPI_ATTROWNER_POINT, "tangentu");
		point_attrs["tangentv"] =
				HEGo::Util::Attribs::fetch_vector3(session_mgr->get_session(), mesh_geo_info, mesh_part_info, HAPI_ATTROWNER_POINT, "tangentv");
	}
	else
	{
		HEGo::Util::Log::message("Getting tangents disabled");
	}

	for (int i = 0; i < read_attribs.size(); i++)
	{
		godot::String attr_name = read_attribs[i];
		HAPI_AttributeInfo attrib_info;
		HOUDINI_CHECK_ERROR(HoudiniApi::GetAttributeInfo(
				session_mgr->get_session(), mesh_geo_info.nodeId, mesh_part_info.id, attr_name.utf8(), HAPI_ATTROWNER_PRIM, &attrib_info));
		godot::Array values =
				HEGo::Util::Attribs::fetch_by_name(session_mgr->get_session(), mesh_geo_info, mesh_part_info, HAPI_ATTROWNER_PRIM, attr_name.utf8().get_data());

		read_attribs_dict[attr_name] = values;
	}
	godot::Dictionary filter_attribs_dict;
	for (int i = 0; i < filter_attribs.size(); i++)
	{
		godot::String attr_name = filter_attribs[i];
		godot::Array values =
				HEGo::Util::Attribs::fetch_by_name(session_mgr->get_session(), mesh_geo_info, mesh_part_info, HAPI_ATTROWNER_PRIM, attr_name.utf8().get_data());
		filter_attribs_dict[attr_name] = values;
	}
	godot::Dictionary split_attribs_dict;
	for (int i = 0; i < split_attribs.size(); i++)
	{
		godot::String attr_name = split_attribs[i];
		godot::Array values =
				HEGo::Util::Attribs::fetch_by_name(session_mgr->get_session(), mesh_geo_info, mesh_part_info, HAPI_ATTROWNER_PRIM, attr_name.utf8().get_data());
		split_attribs_dict[attr_name] = values;
	}

	// filter prims
	godot::Array filtered_prims;

	for (int i = 0; i < prims.size(); i++)
	{
		bool matches_all = true;

		for (int j = 0; j < filter_attribs.size(); j++)
		{
			godot::Array values = filter_attribs_dict[filter_attribs[j]];
			godot::Variant attr_value = values[i];
			if (attr_value != filter_attrib_values[j])
			{
				matches_all = false;
				break;
			}
		}

		if (matches_all)
		{
			filtered_prims.append(prims[i]);
		}
	}

	godot::Array int_ids;
	for (int i = 0; i < filtered_prims.size(); i++)
	{
		int_ids.append(i);
	}

	godot::Dictionary split_prim_dictionary = HEGo::Util::Geo::build_nested_dictionary(split_attribs, split_attribs_dict, int_ids, read_attribs_dict, 0);
	godot::Array vt_pt_indices;
	for (int i = 0; i < vertex_point_indices.size(); i++)
	{
		vt_pt_indices.append(vertex_point_indices[i]);
	}
	modify_base_entries(split_prim_dictionary, vt_pt_indices, point_attrs, filtered_prims);
	HEGo::Util::Log::message("Finished fetching surfaces");
	HEGo::Util::Log::line();
	return split_prim_dictionary;
}

void modify_base_entries(godot::Dictionary &nested_dict, godot::Array &vertex_point_indices, godot::Dictionary point_attrs, godot::Array filtered_prims)
{
	// Check if we are at the base level by looking for the "ids" key
	if (nested_dict.has("ids"))
	{
		// godot::Array id_arr = nested_dict["ids"];
		godot::Array int_ids = nested_dict["ids"];
		godot::Array id_arr;
		for (int i = 0; i < int_ids.size(); i++)
		{
			id_arr.append(filtered_prims[int_ids[i]]);
		}

		filter_and_update_dictionary(point_attrs, id_arr, vertex_point_indices);
		godot::Array surface_array;
		surface_array.resize(godot::Mesh::ARRAY_MAX);
		surface_array[godot::Mesh::ARRAY_VERTEX] = godot::PackedVector3Array(point_attrs["P"]);
		if (point_attrs.has("N"))
		{
			godot::Array normal_attr = point_attrs["N"];
			if (normal_attr.size() > 0)
			{
				surface_array[godot::Mesh::ARRAY_NORMAL] = godot::PackedVector3Array(normal_attr);
			}
		}
		if (point_attrs.has("Cd"))
		{
			godot::Array color_attr = point_attrs["Cd"];
			if (color_attr.size() > 0)
			{
				godot::PackedColorArray packed_colors;
				godot::Array colors = color_attr;
				packed_colors.resize(colors.size());
				for (int i = 0; i < colors.size(); i++)
				{
					godot::Vector3 vec = colors[i];
					godot::Color color(vec.x, vec.y, vec.z);
					packed_colors[i] = color;
				}
				surface_array[godot::Mesh::ARRAY_COLOR] = packed_colors;
			}
		}
		if (point_attrs.has("uv"))
		{
			godot::Array uv_attr = point_attrs["uv"];
			if (uv_attr.size() > 0)
			{
				surface_array[godot::Mesh::ARRAY_TEX_UV] = godot::PackedVector3Array(uv_attr);
			}
		}
		if (point_attrs.has("uv2"))
		{
			godot::Array uv2_attr = point_attrs["uv2"];

			if (uv2_attr.size() > 0)
			{
				surface_array[godot::Mesh::ARRAY_TEX_UV2] = godot::PackedVector3Array(uv2_attr);
			}
		}
		// Tangent calculation
		if (point_attrs.has("tangentu") && point_attrs.has("tangentv") && point_attrs.has("N"))
		{
			godot::Array tangentu_attr = point_attrs["tangentu"];
			godot::Array tangentv_attr = point_attrs["tangentv"];
			godot::Array normal_attr = point_attrs["N"];

			if (tangentu_attr.size() > 0 && tangentv_attr.size() > 0 && normal_attr.size() > 0)
			{
				// Ensure all arrays have the same size
				int vertex_count = tangentu_attr.size();
				if (tangentv_attr.size() != vertex_count || normal_attr.size() != vertex_count)
				{
					HEGo::Util::Log::error("Tangent arrays and normal array size mismatch!");
				}
				else
				{
					HEGo::Util::Log::message("Calculating tangents");
					godot::PackedFloat32Array tangent_array;
					tangent_array.resize(vertex_count * 4); // 4 floats per vertex: [tangent.x, tangent.y, tangent.z, bitangent_sign]

					for (int i = 0; i < vertex_count; i++)
					{
						godot::Vector3 tangent = tangentu_attr[i];
						godot::Vector3 bitangent = tangentv_attr[i];
						godot::Vector3 normal = normal_attr[i];

						// Compute expected bitangent: cross(normal, tangent)
						godot::Vector3 expected_bitangent = normal.cross(tangent).normalized();

						// Compute bitangent sign: dot(cross(normal, tangent), tangentv)
						float bitangent_sign = expected_bitangent.dot(bitangent) >= 0.0f ? 1.0f : -1.0f;

						// Godot tangent format: [tangent.x, tangent.y, tangent.z, bitangent_sign]
						int idx = i * 4;
						tangent_array[idx + 0] = tangent.x;
						tangent_array[idx + 1] = tangent.y;
						tangent_array[idx + 2] = tangent.z;
						tangent_array[idx + 3] = bitangent_sign;
					}

					surface_array[godot::Mesh::ARRAY_TANGENT] = tangent_array;
				}
			}
		}

		godot::PackedInt32Array indices;

		for (int i = 0; i < id_arr.size(); i++)
		{
			godot::Vector2i id_range = id_arr[i];
			int start = id_range.x;
			for (int j = 0; j < id_range.y; j++)
			{
				indices.append(vertex_point_indices[start + j]);
			}
		}

		surface_array[godot::Mesh::ARRAY_INDEX] = indices;

		nested_dict["surface_array"] = surface_array;

		return;
	}

	// Otherwise, recurse into each nested dictionary
	godot::Array keys = nested_dict.keys();
	for (int i = 0; i < keys.size(); i++)
	{
		godot::Variant key = keys[i];
		godot::Dictionary child_dict = nested_dict[key];

		// Recurse into the child dictionary
		modify_base_entries(child_dict, vertex_point_indices, point_attrs, filtered_prims);

		// Assign the modified dictionary back to the parent (in case it was
		// modified)
		nested_dict[key] = child_dict;
	}
}

void filter_and_update_dictionary(godot::Dictionary &point_attrs, const godot::Array &id_arr, godot::Array &vertex_point_indices)
{
	// Get the keys from the point_attrs dictionary
	godot::Array keys = point_attrs.keys();
	godot::Array first_attr = point_attrs[keys[0]];

	// Step 1: Mark which indices in point_attrs are being used
	godot::Array is_index_used;
	is_index_used.resize(first_attr.size());

	// Initialize all indices to false (unused)
	for (int i = 0; i < is_index_used.size(); ++i)
	{
		is_index_used[i] = false;
	}

	// Iterate through id_arr to mark the relevant ranges of
	// vertex_point_indices as used
	for (int i = 0; i < id_arr.size(); ++i)
	{
		godot::Vector2i range = id_arr[i];
		int start = range.x; // Start of the range
		int length = range.y; // Length of the range

		for (int j = start; j < start + length; ++j)
		{
			// Mark the vertex_point_indices within this range as used
			int vertex_index = vertex_point_indices[j];
			if (vertex_index < is_index_used.size())
			{
				is_index_used[vertex_index] = true;
			}
		}
	}

	// Step 2: Create a mapping from old indices to new indices (compact the
	// used indices)
	godot::Array index_mapping; // Maps old indices to new indices
	index_mapping.resize(vertex_point_indices.size());

	// Initialize the mapping with invalid values (-1)
	for (int i = 0; i < index_mapping.size(); ++i)
	{
		index_mapping[i] = -1;
	}

	// Assign new indices for only the used entries
	int next_available_index = 0;
	for (int i = 0; i < is_index_used.size(); ++i)
	{
		if (is_index_used[i])
		{
			index_mapping[i] = next_available_index++;
		}
	}

	// Step 3: Filter point_attrs arrays based on the used indices
	godot::Dictionary filtered_point_attrs;

	// Iterate through each key in point_attrs (like "P")
	for (int key_index = 0; key_index < keys.size(); ++key_index)
	{
		godot::Variant key = keys[key_index];
		godot::Array original_array = point_attrs[key];
		godot::Array filtered_array;

		// Only append used entries to the filtered array
		for (int i = 0; i < original_array.size(); ++i)
		{
			if (is_index_used[i])
			{
				filtered_array.append(original_array[i]);
			}
		}

		// Store the filtered array in the new dictionary
		filtered_point_attrs[key] = filtered_array;
	}

	// Step 4: Update vertex_point_indices to reflect the new compacted indices
	for (int i = 0; i < vertex_point_indices.size(); ++i)
	{
		int old_index = vertex_point_indices[i];
		if (old_index < index_mapping.size() && int(index_mapping[old_index]) != -1)
		{
			vertex_point_indices[i] = index_mapping[old_index];
		}
	}

	// Step 5: Replace the original point_attrs with the filtered version
	point_attrs = filtered_point_attrs;
}

} // namespace Geo
} // namespace Util
} // namespace HEGo