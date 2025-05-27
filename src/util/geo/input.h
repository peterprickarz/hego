#ifndef INPUT_H
#define INPUT_H

#include "hego_session_manager.h"

#include <godot_cpp/classes/curve3d.hpp>
#include <godot_cpp/classes/mesh.hpp>
#include <godot_cpp/classes/mesh_instance3d.hpp>
#include <godot_cpp/classes/path3d.hpp>
#include <godot_cpp/variant/string.hpp>

namespace HEGo
{
namespace Util
{
namespace Geo
{
godot::PackedStringArray get_input_names(HEGoSessionManager *session_mgr, HAPI_NodeId node_id);
HAPI_NodeId create_input_from_mesh_instance_3d(HEGoSessionManager *hego_session_manager, godot::MeshInstance3D *mesh_instance_3d, HAPI_NodeId node_id);
HAPI_NodeId create_input_from_path_3d(HEGoSessionManager *session_mgr, godot::Path3D *path_3d, HAPI_NodeId node_id, float target_length);
HAPI_NodeId create_input_from_mesh(HEGoSessionManager *hego_session_manager, godot::Ref<godot::Mesh> mesh, HAPI_NodeId node_id);
HAPI_NodeId create_merge_sop(HEGoSessionManager *session_mgr, HAPI_NodeId node_id);
void disconnect_node_inputs(HEGoSessionManager *session_mgr, HAPI_NodeId target_node_id);
void connect_to_merge(HEGoSessionManager *session_mgr, HAPI_NodeId merge_node_id, godot::PackedInt32Array sources);
void connect_merge_to_input(HEGoSessionManager *session_mgr, HAPI_NodeId target_node_id, int input_index, HAPI_NodeId merge_node_id);

HAPI_NodeId create_input_from_curve3d(HEGoSessionManager *session_mgr, godot::Ref<godot::Curve3D> curve3d, HAPI_NodeId node_id, float target_length);

} // namespace Geo
} // namespace Util
} // namespace HEGo

#endif // INPUT_H
