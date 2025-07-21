#include "util/hego_util.h"
#include "util/node/create_nodes.h"

namespace HEGo
{
namespace Util
{
namespace Node
{
// Load a new HDA asset
bool load_asset(HEGoSessionManager *session_mgr, const char *otl_path, HAPI_AssetLibraryId &asset_library_id, std::string &asset_name)
{
	// Implementation goes here
	return true;
}

// Query and list the parameters of the given node
bool get_parms(HEGoSessionManager *session_mgr, HAPI_NodeId node_id)
{
	// Implementation goes here
	return true;
}

// Query and list the point, vertex, prim and detail attributes of the given node
bool get_attribs(HEGoSessionManager *session_mgr, HAPI_NodeId node_id, HAPI_PartId part_id)
{
	// Implementation goes here
	return true;
}

HAPI_NodeId instantiate_hda_from_name(HEGoSessionManager *session_mgr, const godot::String &name, HAPI_NodeId node_id)
{
	HEGo::Util::Log::line();

	std::string asset_name = name.utf8();

	node_id = instantiate_hda(session_mgr, &asset_name, node_id);

	if (node_id < 0)
	{
		HEGo::Util::Log::error("Couldn't instantiate asset. Make sure your name is correct, e.g. Sop/hego_example_hda");
		HEGo::Util::Log::error("Check https://www.sidefx.com/docs/hengine/group___nodes.html#ga805b9d498cfd0b8709b1a05f59a538a6 for "
							   "reference");
	}

	return node_id;
}

HAPI_NodeId instantiate_hda_from_path(HEGoSessionManager *session_mgr, const godot::String &path, HAPI_NodeId node_id)
{
	HEGo::Util::Log::line();
	HEGo::Util::Log::message("Loading asset");

	std::string otl_path = path.utf8();
	HAPI_AssetLibraryId asset_id = -1;
	std::string asset_name;

	if (!load_asset(session_mgr, otl_path.c_str(), asset_id, asset_name))
	{
		HEGo::Util::Log::error("Can't load asset!");
	}

	HEGo::Util::Log::message("Loaded asset");
	return instantiate_hda(session_mgr, &asset_name, node_id);
}

HAPI_NodeId instantiate_hda(HEGoSessionManager *session_mgr, const std::string *asset_name, HAPI_NodeId node_id)
{
	RETURN_IF_VALID_NODE_ID(node_id, session_mgr->get_session());
	HEGo::Util::Log::message("Instantiating op: " + godot::String(asset_name->c_str()));
	return create_and_cook_node(session_mgr, asset_name->c_str(), node_id);
}

HAPI_NodeId create_and_cook_node(HEGoSessionManager *session_mgr, const char *operator_name, HAPI_NodeId node_id)
{
	RETURN_IF_VALID_NODE_ID(node_id, session_mgr->get_session());
	HEGo::Util::Log::message("Creating and cooking node: " + godot::String(operator_name) + "...");
	
	// Use HOUDINI_CHECK_ERROR_RETURN to gracefully handle license failures and return invalid node
	HOUDINI_CHECK_ERROR_RETURN(HoudiniApi::CreateNode(session_mgr->get_session(), -1, operator_name, "", false, &node_id), -1);
	HOUDINI_CHECK_ERROR_RETURN(HoudiniApi::CookNode(session_mgr->get_session(), node_id, session_mgr->get_cook_options()), -1);

	session_mgr->wait_for_ready();
	return node_id;
}

HAPI_NodeId create_and_cook_input_node(HEGoSessionManager *session_mgr, const godot::String &name, HAPI_NodeId node_id)
{
	RETURN_IF_VALID_NODE_ID(node_id, session_mgr->get_session());
	HEGo::Util::Log::message("Creating input node");

	HOUDINI_CHECK_ERROR(HoudiniApi::CreateInputNode(session_mgr->get_session(), -1, &node_id, name.utf8()));
	HOUDINI_CHECK_ERROR(HoudiniApi::CookNode(session_mgr->get_session(), node_id, session_mgr->get_cook_options()));
	session_mgr->wait_for_ready();
	return node_id;
}

HAPI_NodeId create_and_cook_input_curve_node(HEGoSessionManager *session_mgr, const godot::String &name, HAPI_NodeId node_id)
{
	RETURN_IF_VALID_NODE_ID(node_id, session_mgr->get_session());
	HEGo::Util::Log::message("Creating input curve node");
	HOUDINI_CHECK_ERROR(HoudiniApi::CreateInputCurveNode(session_mgr->get_session(), -1, &node_id, name.utf8()));
	session_mgr->wait_for_ready();
	return node_id;
}

} // namespace Node
} // namespace Util
} // namespace HEGo
