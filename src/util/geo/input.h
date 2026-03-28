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
/**
 * Return the display names of all input slots on a Houdini node.
 *
 * @param session_mgr Active session manager used to query the Houdini session.
 * @param node_id Houdini node whose input labels should be returned.
 * @return Packed array of input names. Returns an empty array if the session
 * manager, session, or node id is invalid, or if the node info query fails.
 */
godot::PackedStringArray get_input_names(HEGoSessionManager *session_mgr, HAPI_NodeId node_id);

/**
 * Create or update a Houdini input node from a Godot MeshInstance3D.
 *
 * The mesh resource is converted with create_input_from_mesh() and the source
 * node's global transform is applied to the Houdini object.
 *
 * @param hego_session_manager Active session manager used to create and populate
 * the Houdini input node.
 * @param mesh_instance_3d Source mesh instance. Its mesh resource and global
 * transform are exported to Houdini.
 * @param node_id Existing input node id to reuse, or the parent node id used to
 * create a new input node depending on caller flow.
 * @param attributes Additional custom attributes to apply after geometry upload.
 * @return The Houdini input node id on success, or -1 if the mesh instance or
 * mesh is invalid.
 */
HAPI_NodeId create_input_from_mesh_instance_3d(HEGoSessionManager *hego_session_manager, godot::MeshInstance3D *mesh_instance_3d, HAPI_NodeId node_id,
		const godot::Array &attributes = godot::Array());

/**
 * Create or update a Houdini curve input from a Godot Path3D.
 *
 * The path is tessellated from its Curve3D using the provided target segment length,
 * then the path's global transform is applied to the Houdini object.
 *
 * @param session_mgr Active session manager used to populate the Houdini input.
 * @param path_3d Source path whose curve and global transform are exported.
 * @param node_id Existing curve input node id to reuse.
 * @param target_length Desired segment length used when tessellating the curve.
 * @return The Houdini input node id on success, or -1 if the path or curve is invalid.
 */
HAPI_NodeId create_input_from_path_3d(HEGoSessionManager *session_mgr, godot::Path3D *path_3d, HAPI_NodeId node_id, float target_length);

/**
 * Create or update a Houdini mesh input from a Godot Mesh resource.
 *
 * Point positions and colors are written as point attributes, while per-face
 * surface id and material path are written as primitive attributes. Both indexed
 * and non-indexed surfaces are supported, including meshes produced by
 * CSGShape3D::bake_static_mesh().
 *
 * @param hego_session_manager Active session manager used to create and populate
 * the Houdini input node.
 * @param mesh Source mesh resource to translate into Houdini geometry.
 * @param node_id Existing input node id to reuse, or the parent node id used to
 * create a new input node depending on caller flow.
 * @param attributes Additional custom attributes to apply after geometry upload.
 * @return The Houdini input node id on success.
 */
HAPI_NodeId create_input_from_mesh(
		HEGoSessionManager *hego_session_manager, godot::Ref<godot::Mesh> mesh, HAPI_NodeId node_id, const godot::Array &attributes = godot::Array());

/**
 * Create a Houdini SOP merge node under the given parent node.
 *
 * @param session_mgr Active session manager used to instantiate the SOP node.
 * @param node_id Parent node id under which the merge node is created.
 * @return The created merge node id.
 */
HAPI_NodeId create_merge_sop(HEGoSessionManager *session_mgr, HAPI_NodeId node_id);

/**
 * Disconnect every currently connected input on the target node.
 *
 * @param session_mgr Active session manager used to access the Houdini session.
 * @param target_node_id Node whose input slots should be disconnected.
 */
void disconnect_node_inputs(HEGoSessionManager *session_mgr, HAPI_NodeId target_node_id);

/**
 * Rebuild all inputs on a merge node from the provided source node ids.
 *
 * Existing merge inputs are disconnected before the new source list is connected
 * in array order.
 *
 * @param session_mgr Active session manager used to access the Houdini session.
 * @param merge_node_id Merge node that will receive the source connections.
 * @param sources Source node ids to connect to the merge inputs in order.
 */
void connect_to_merge(HEGoSessionManager *session_mgr, HAPI_NodeId merge_node_id, godot::PackedInt32Array sources);

/**
 * Connect the output of a merge node to a specific input slot on a target node.
 *
 * @param session_mgr Active session manager used to access the Houdini session.
 * @param target_node_id Destination node that receives the merge output.
 * @param input_index Input slot on the destination node to connect.
 * @param merge_node_id Merge node whose first output is connected.
 */
void connect_merge_to_input(HEGoSessionManager *session_mgr, HAPI_NodeId target_node_id, int input_index, HAPI_NodeId merge_node_id);

/**
 * Populate a Houdini curve input from a Godot Curve3D.
 *
 * The curve is tessellated to evenly spaced points before the resulting positions
 * are sent to Houdini.
 *
 * @param session_mgr Active session manager used to access the Houdini session.
 * @param curve3d Source curve resource to tessellate and upload.
 * @param node_id Existing curve input node id to reuse.
 * @param target_length Desired segment length used when tessellating the curve.
 * @return The Houdini input node id.
 */
HAPI_NodeId create_input_from_curve3d(HEGoSessionManager *session_mgr, godot::Ref<godot::Curve3D> curve3d, HAPI_NodeId node_id, float target_length);

} // namespace Geo
} // namespace Util
} // namespace HEGo

#endif // INPUT_H
