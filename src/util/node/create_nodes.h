#ifndef CREATE_NODES_H
#define CREATE_NODES_H

#include "hapi/houdini_api.h"
#include "hego_session_manager.h"
#include <godot_cpp/core/class_db.hpp>
#include <string>

namespace HEGo
{
namespace Util
{
namespace Node
{
// Load a new HDA asset
bool load_asset(HEGoSessionManager *session_mgr, const char *otl_path, HAPI_AssetLibraryId &asset_library_id, std::string &asset_name);

// Instantiate and asynchronously cook the given node

// Query and list the parameters of the given node
bool get_parms(HEGoSessionManager *session_mgr, HAPI_NodeId node_id);

// Query and list the point, vertex, prim and detail attributes of the given node
bool get_attribs(HEGoSessionManager *session_mgr, HAPI_NodeId node_id, HAPI_PartId part_id);

// Instantiate HDA from name
HAPI_NodeId instantiate_hda_from_name(HEGoSessionManager *session_mgr, const godot::String &name, HAPI_NodeId node_id);

// Instantiate HDA from path
HAPI_NodeId instantiate_hda_from_path(HEGoSessionManager *session_mgr, const godot::String &path, HAPI_NodeId node_id);

HAPI_NodeId instantiate_hda(HEGoSessionManager *session_mgr, const std::string *asset_name, HAPI_NodeId node_id);
HAPI_NodeId create_and_cook_node(HEGoSessionManager *session_mgr, const char *operator_name, HAPI_NodeId node_id);
HAPI_NodeId create_and_cook_input_node(HEGoSessionManager *session_mgr, const godot::String &name, HAPI_NodeId node_id);

HAPI_NodeId create_and_cook_input_curve_node(HEGoSessionManager *session_mgr, const godot::String &name, HAPI_NodeId node_id);

} // namespace Node
} // namespace Util
} // namespace HEGo

#endif // CREATE_NODES_H
