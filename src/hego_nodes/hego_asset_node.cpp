#include "hego_nodes/hego_asset_node.h"

#include "hego_api.h"
#include "hego_asset_node.h"
#include "util/geo/fetch_points.h"
#include "util/geo/fetch_surfaces.h"
#include "util/geo/output.h"
#include "util/log/log.h"
#include "util/node/create_nodes.h"
#include "util/parm/set_parms.h"

namespace HEGo
{
HEGoAssetNode::HEGoAssetNode() {}

HEGoAssetNode::~HEGoAssetNode() {}

void HEGoAssetNode::instantiate()
{
	if (op_name == "")
	{
		HEGo::Util::Log::error("Operator name not set, call set_op_name(name) first!");
	}
	else
	{
		node_id = HEGo::Util::Node::instantiate_hda_from_name(get_session_manager(), op_name, node_id);
	}
}

void HEGoAssetNode::set_parm(godot::String parm_name, godot::Variant value)
{
	HEGo::Util::Parm::set_parm(get_session_manager(), node_id, parm_name, &value);
}

godot::Array HEGoAssetNode::fetch_output()
{
	return godot::Array();
	// return HEGo::Util::Geo::fetch_surface_array(
	//		get_session_manager()->get_session(), node_id, get_session_manager()->get_cook_options());
}

godot::Dictionary HEGoAssetNode::fetch_points(godot::Ref<godot::Resource> fetch_point_config)
{
	if (fetch_point_config.is_valid() && fetch_point_config->is_class("Resource"))
	{
		return HEGo::Util::Geo::fetch_points(get_session_manager(), node_id, fetch_point_config);
	}
	else
	{
		HEGo::Util::Log::error("Invalid config!");
		return godot::Dictionary();
	}
}
godot::Dictionary HEGoAssetNode::fetch_surfaces(godot::Ref<godot::Resource> fetch_surface_config)
{
	if (fetch_surface_config.is_valid() && fetch_surface_config->is_class("Resource"))
	{
		return HEGo::Util::Geo::fetch_surfaces(get_session_manager(), node_id, fetch_surface_config);
	}
	else
	{
		HEGo::Util::Log::error("Invalid config!");
		return godot::Dictionary();
	}
}
void HEGoAssetNode::set_op_name(godot::String name) { op_name = name; }

godot::String HEGoAssetNode::get_op_name() const { return op_name; }

void HEGoAssetNode::_bind_methods()
{
	godot::ClassDB::bind_method(godot::D_METHOD("set_parm", "parm_name", "value"), &HEGoAssetNode::set_parm);
	godot::ClassDB::bind_method(godot::D_METHOD("fetch_output"), &HEGoAssetNode::fetch_output);
	godot::ClassDB::bind_method(godot::D_METHOD("set_op_name", "name"), &HEGoAssetNode::set_op_name);
	godot::ClassDB::bind_method(godot::D_METHOD("get_op_name"), &HEGoAssetNode::get_op_name);
	godot::ClassDB::bind_method(godot::D_METHOD("fetch_points", "fetch_point_config"), &HEGoAssetNode::fetch_points);
	godot::ClassDB::bind_method(
			godot::D_METHOD("fetch_surfaces", "fetch_surface_config"), &HEGoAssetNode::fetch_surfaces);
	// godot::ClassDB::add_property("HEGoAssetNode", godot::PropertyInfo(godot::Variant::STRING, "op_name"),
	// "set_op_name", "get_op_name");
	ADD_PROPERTY(godot::PropertyInfo(godot::Variant::STRING, "op_name"), "set_op_name", "get_op_name");
}

} // namespace HEGo
