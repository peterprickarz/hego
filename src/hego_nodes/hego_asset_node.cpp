#include "hego_nodes/hego_asset_node.h"

#include "hego_api.h"
#include "hego_asset_node.h"
#include "util/geo/fetch_points.h"
#include "util/geo/fetch_surfaces.h"
#include "util/geo/input.h"
#include "util/geo/output.h"
#include "util/log/log.h"
#include "util/node/create_nodes.h"
#include "util/parm/get_parms.h"
#include "util/parm/presets.h"
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
		
		// Only register the node if instantiation was successful
		if (node_id >= 0)
		{
			get_session_manager()->register_node(this);
			HEGo::Util::Log::message("Successfully instantiated HDA: " + op_name);
		}
		else
		{
			HEGo::Util::Log::error("Failed to instantiate HDA: " + op_name + " (License issue? Check if Houdini Engine has a valid license)");
		}
	}
}

void HEGoAssetNode::set_parm(godot::String parm_name, godot::Variant value) 
{ 
	if (get_id() < 0) {
		HEGo::Util::Log::error("Cannot set parameter - HDA not instantiated or license issue");
		return;
	}
	HEGo::Util::Parm::set_parm(get_session_manager(), node_id, parm_name, &value); 
}

void HEGoAssetNode::set_preset(godot::PackedByteArray preset) 
{ 
	if (get_id() < 0) {
		HEGo::Util::Log::error("Cannot set preset - HDA not instantiated or license issue");
		return;
	}
	HEGo::Util::Parm::set_preset(get_session_manager(), node_id, preset); 
}

void HEGoAssetNode::insert_multiparm_instance(int parm_id, int index)
{
	HEGo::Util::Parm::insert_multiparm_instance(get_session_manager(), node_id, parm_id, index);
}

void HEGoAssetNode::remove_multiparm_instance(int parm_id, int index)
{
	HEGo::Util::Parm::remove_multiparm_instance(get_session_manager(), node_id, parm_id, index);
}

godot::PackedByteArray HEGoAssetNode::get_preset() 
{ 
	if (get_id() < 0) {
		HEGo::Util::Log::error("Cannot get preset - HDA not instantiated or license issue");
		return godot::PackedByteArray();
	}
	return HEGo::Util::Parm::get_preset(get_session_manager(), node_id); 
}

godot::Dictionary HEGoAssetNode::get_parms_dict() 
{ 
	if (get_id() < 0) {
		HEGo::Util::Log::error("Cannot get parameters - HDA not instantiated or license issue");
		return godot::Dictionary();
	}
	return HEGo::Util::Parm::get_parm_dict(get_session_manager(), node_id); 
}

godot::PackedStringArray HEGoAssetNode::get_input_names() 
{ 
	if (get_id() < 0) {
		HEGo::Util::Log::error("Cannot get input names - HDA not instantiated or license issue");
		return godot::PackedStringArray();
	}
	return HEGo::Util::Geo::get_input_names(get_session_manager(), node_id); 
}

godot::Array HEGoAssetNode::fetch_output()
{
	return godot::Array();
	// return HEGo::Util::Geo::fetch_surface_array(
	//		get_session_manager()->get_session(), node_id, get_session_manager()->get_cook_options());
}

godot::Dictionary HEGoAssetNode::fetch_points(godot::Ref<godot::Resource> fetch_point_config)
{
	if (get_id() < 0) {
		HEGo::Util::Log::error("Cannot fetch points - HDA not instantiated or license issue");
		return godot::Dictionary();
	}
	
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
	if (get_id() < 0) {
		HEGo::Util::Log::error("Cannot fetch surfaces - HDA not instantiated or license issue");
		return godot::Dictionary();
	}
	
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
	godot::ClassDB::bind_method(godot::D_METHOD("insert_multiparm_instance", "parm_id", "index"), &HEGoAssetNode::insert_multiparm_instance);
	godot::ClassDB::bind_method(godot::D_METHOD("remove_multiparm_instance", "parm_id", "index"), &HEGoAssetNode::remove_multiparm_instance);
	godot::ClassDB::bind_method(godot::D_METHOD("get_preset"), &HEGoAssetNode::get_preset);
	godot::ClassDB::bind_method(godot::D_METHOD("set_preset", "preset"), &HEGoAssetNode::set_preset);
	godot::ClassDB::bind_method(godot::D_METHOD("get_id"), &HEGoAssetNode::get_id);
	godot::ClassDB::bind_method(godot::D_METHOD("get_input_names"), &HEGoAssetNode::get_input_names);
	godot::ClassDB::bind_method(godot::D_METHOD("get_parms_dict"), &HEGoAssetNode::get_parms_dict);
	godot::ClassDB::bind_method(godot::D_METHOD("fetch_output"), &HEGoAssetNode::fetch_output);
	godot::ClassDB::bind_method(godot::D_METHOD("set_op_name", "name"), &HEGoAssetNode::set_op_name);
	godot::ClassDB::bind_method(godot::D_METHOD("get_op_name"), &HEGoAssetNode::get_op_name);
	godot::ClassDB::bind_method(godot::D_METHOD("fetch_points", "fetch_point_config"), &HEGoAssetNode::fetch_points);
	godot::ClassDB::bind_method(godot::D_METHOD("fetch_surfaces", "fetch_surface_config"), &HEGoAssetNode::fetch_surfaces);
	godot::ClassDB::bind_method(godot::D_METHOD("reset_node_id"), &HEGoAssetNode::reset_node_id);
	// godot::ClassDB::add_property("HEGoAssetNode", godot::PropertyInfo(godot::Variant::STRING, "op_name"),
	// "set_op_name", "get_op_name");
	ADD_PROPERTY(godot::PropertyInfo(godot::Variant::STRING, "op_name"), "set_op_name", "get_op_name");
}

} // namespace HEGo
