#include "util/geo/input.h"

#include "hapi/houdini_api.h"
#include "util/geo/transform.h"
#include "util/hego_util.h"
#include "util/log/log.h"
#include "util/node/create_nodes.h"

#include "input.h"
#include <godot_cpp/classes/mesh.hpp>
#include <godot_cpp/core/math.hpp>
#include <godot_cpp/variant/quaternion.hpp>
#include <vector>

namespace HEGo
{
namespace Util
{
namespace Geo
{
godot::PackedStringArray get_input_names(HEGoSessionManager *session_mgr, HAPI_NodeId node_id)
{
	godot::PackedStringArray result;
	// Validate inputs
	if (!session_mgr || node_id < 0)
	{
		return result; // Return empty array on invalid input
	}

	HAPI_Session *session = session_mgr->get_session();
	if (!session)
	{
		return result; // Return empty array if session is invalid
	}

	// Get node info
	HAPI_NodeInfo node_info;
	if (HoudiniApi::GetNodeInfo(session, node_id, &node_info) != HAPI_RESULT_SUCCESS)
	{
		return result; // Return empty array on failure
	}

	// Iterate over inputs
	for (int i = 0; i < node_info.inputCount; ++i)
	{
		// Get input name handle
		HAPI_StringHandle name_handle;
		if (HoudiniApi::GetNodeInputName(session, node_id, i, &name_handle) != HAPI_RESULT_SUCCESS)
		{
			continue; // Skip on failure
		}

		// Get input name using HEGoUtil::get_string
		std::string input_name = HEGoUtil::get_string(session, name_handle);

		result.append(godot::String(input_name.c_str()));
	}

	return result;
}

HAPI_NodeId create_input_from_mesh_instance_3d(HEGoSessionManager *session_mgr, godot::MeshInstance3D *mesh_instance_3d, HAPI_NodeId node_id)
{
	HEGo::Util::Log::message("Creating Input node");
	if (mesh_instance_3d == nullptr)
	{
		HEGo::Util::Log::warning("Mesh instance 3D is null, can't send to Houdini!");
		return -1;
	}
	godot::Ref<godot::Mesh> mesh = mesh_instance_3d->get_mesh();
	if (mesh.is_null() || !mesh.is_valid())
	{
		HEGo::Util::Log::warning("Mesh is null or invalid, can't send to Houdini!");
		return -1;
	}

	godot::Transform3D transform = mesh_instance_3d->get_global_transform();

	node_id = create_input_from_mesh(session_mgr, mesh, node_id);

	set_object_transform(session_mgr, node_id, transform);

	return node_id;
}

HAPI_NodeId create_input_from_path_3d(HEGoSessionManager *session_mgr, godot::Path3D *path_3d, HAPI_NodeId node_id, float target_length)
{
	HEGo::Util::Log::message("Setting input curve");
	if (path_3d == nullptr)
	{
		HEGo::Util::Log::warning("Path3D is null, can't send to Houdini!");
		return -1;
	}
	godot::Ref<godot::Curve3D> curve3d = path_3d->get_curve();
	if (curve3d.is_null() || !curve3d.is_valid())
	{
		HEGo::Util::Log::warning("Curve3D is null or invalid, can't send to Houdini!");
		return -1;
	}

	godot::Transform3D transform = path_3d->get_global_transform();

	node_id = create_input_from_curve3d(session_mgr, curve3d, node_id, target_length);
	session_mgr->wait_for_ready();

	set_object_transform(session_mgr, node_id, transform);

	return node_id;
}

HAPI_NodeId create_merge_sop(HEGoSessionManager *session_mgr, HAPI_NodeId node_id)
{
	return HEGo::Util::Node::instantiate_hda_from_name(session_mgr, "Sop/merge", node_id);
}

void connect_node_input(HEGoSessionManager *session_mgr, HAPI_NodeId target_node_id, int input_index, HAPI_NodeId source_node_id, int output_index)
{
	HOUDINI_CHECK_ERROR(HoudiniApi::ConnectNodeInput(session_mgr->get_session(), target_node_id, input_index, source_node_id, output_index));
}

void disconnect_node_inputs(HEGoSessionManager *session_mgr, HAPI_NodeId target_node_id)
{
	HAPI_NodeInfo node_info = HoudiniApi::NodeInfo_Create();
	HOUDINI_CHECK_ERROR(HoudiniApi::GetNodeInfo(session_mgr->get_session(), target_node_id, &node_info));
	for (int i = 0; i < node_info.inputCount; i++)
	{
		HEGo::Util::Log::message("Disconnecting node slot " + godot::String::num(i));
		HAPI_NodeId input_id = -1;
		HOUDINI_CHECK_ERROR(HoudiniApi::QueryNodeInput(session_mgr->get_session(), target_node_id, i, &input_id));
		if (input_id == -1)
		{
			break;
		}
		HEGo::Util::Log::message("disconnecting node id " + godot::String::num(input_id));
		HOUDINI_CHECK_ERROR(HoudiniApi::DisconnectNodeInput(session_mgr->get_session(), target_node_id, i));
	}
}

void connect_to_merge(HEGoSessionManager *session_mgr, HAPI_NodeId merge_node_id, godot::PackedInt32Array sources)
{
	disconnect_node_inputs(session_mgr, merge_node_id);
	for (int i = 0; i < sources.size(); i++)
	{
		connect_node_input(session_mgr, merge_node_id, i, sources[i], 0);
	}
}

void connect_merge_to_input(HEGoSessionManager *session_mgr, HAPI_NodeId target_node_id, int input_index, HAPI_NodeId merge_node_id)
{
	connect_node_input(session_mgr, target_node_id, input_index, merge_node_id, 0);
}

HAPI_NodeId create_input_from_curve3d(HEGoSessionManager *session_mgr, godot::Ref<godot::Curve3D> curve3d, HAPI_NodeId node_id, float target_length)
{
	const HAPI_CookOptions *cook_options = session_mgr->get_cook_options();
	const HAPI_Session *session = session_mgr->get_session();

	godot::PackedVector3Array tessellated_curve = curve3d->tessellate_even_length(10, target_length);

	// Prepare a std::vector to hold the float values
	std::vector<float> positions_array;
	positions_array.reserve(tessellated_curve.size() * 3); // Each Vector3 has 3 components

	// Flatten the Vector3 data into the float array
	for (int i = 0; i < tessellated_curve.size(); ++i)
	{
		godot::Vector3 point = tessellated_curve[i];
		positions_array.push_back(point.x);
		positions_array.push_back(point.y);
		positions_array.push_back(point.z);
	}

	HOUDINI_CHECK_ERROR(HoudiniApi::SetInputCurvePositions(session, node_id, 0, positions_array.data(), 0, tessellated_curve.size() * 3));
	return node_id;
}

HAPI_NodeId create_input_from_mesh(HEGoSessionManager *session_mgr, godot::Ref<godot::Mesh> mesh, HAPI_NodeId node_id)
{
	const HAPI_CookOptions *cook_options = session_mgr->get_cook_options();
	const HAPI_Session *session = session_mgr->get_session();

	HEGo::Util::Log::message("Loading Godot mesh arrays into vectors");

	int surface_count = mesh->get_surface_count();

	int npoints = 0;
	int nvertices = 0;
	for (int i = 0; i < surface_count; i++)
	{
		godot::Array surface_array = mesh->surface_get_arrays(i);
		godot::PackedVector3Array positions = surface_array[0];
		godot::PackedInt32Array indices = surface_array[12];
		npoints += positions.size();
		nvertices += indices.size();
	}

	std::vector<float> positions;
	std::vector<int> surface_ids;
	std::vector<int> vertices;
	std::vector<int> face_counts;

	positions.reserve(npoints * 3);
	surface_ids.reserve(npoints);
	vertices.reserve(nvertices);
	face_counts.reserve(nvertices / 3);

	for (int i = 0; i < surface_count; i++)
	{
		godot::Array surface_array = mesh->surface_get_arrays(i);
		godot::PackedVector3Array vector_positions = surface_array[0];
		godot::PackedInt32Array indices = surface_array[12];

		for (int j = 0; j < vector_positions.size(); j++)
		{
			positions.push_back(vector_positions[j].x);
			positions.push_back(vector_positions[j].y);
			positions.push_back(vector_positions[j].z);
			surface_ids.push_back(i);
		}
		for (int j = 0; j < indices.size(); j++)
		{
			vertices.push_back(indices[j]);
		}
	}

	for (int i = 0; i < nvertices / 3; i++)
	{
		face_counts.push_back(3);
	}

	godot::String name = mesh->get_name();

	node_id = HEGo::Util::Node::create_and_cook_input_node(session_mgr, name, node_id);

	HEGo::Util::Log::message("Setting mesh");
	HAPI_PartInfo node_part = HoudiniApi::PartInfo_Create();
	node_part.type = HAPI_PARTTYPE_MESH;
	node_part.faceCount = nvertices / 3;
	node_part.vertexCount = nvertices;
	node_part.pointCount = npoints;

	HOUDINI_CHECK_ERROR(HoudiniApi::SetPartInfo(session, node_id, 0, &node_part));

	HAPI_AttributeInfo node_point_info_P = HoudiniApi::AttributeInfo_Create();
	node_point_info_P.count = npoints;
	node_point_info_P.tupleSize = 3;
	node_point_info_P.exists = true;
	node_point_info_P.storage = HAPI_STORAGETYPE_FLOAT;
	node_point_info_P.owner = HAPI_ATTROWNER_POINT;

	HOUDINI_CHECK_ERROR(HoudiniApi::AddAttribute(session, node_id, 0, "P", &node_point_info_P));

	HOUDINI_CHECK_ERROR(HoudiniApi::SetAttributeFloatData(session, node_id, 0, "P", &node_point_info_P, positions.data(), 0, npoints));

	HOUDINI_CHECK_ERROR(HoudiniApi::SetVertexList(session, node_id, 0, vertices.data(), 0, nvertices));

	HOUDINI_CHECK_ERROR(HoudiniApi::SetFaceCounts(session, node_id, 0, face_counts.data(), 0, nvertices / 3));

	HOUDINI_CHECK_ERROR(HoudiniApi::CommitGeo(session, node_id));

	HEGo::Util::Log::message("Finished creating input node");

	return node_id;
}

} // namespace Geo
} // namespace Util
} // namespace HEGo
