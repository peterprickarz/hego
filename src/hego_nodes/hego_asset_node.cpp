#include "hego_nodes/hego_asset_node.h"

#include "hego_api.h"
#include "hego_asset_node.h"
#include "util/geo/fetch_heightfields.h"
#include "util/geo/fetch_points.h"
#include "util/geo/fetch_surfaces.h"
#include "util/geo/input.h"
#include "util/geo/output.h"
#include "util/log/log.h"
#include "util/node/create_nodes.h"
#include "util/parm/get_parms.h"
#include "util/parm/presets.h"
#include "util/parm/set_parms.h"
#include "util/task/task_helpers.h"

using HEGo::Util::Task::make_failed;
using HEGo::Util::Task::submit;

namespace HEGo
{

HEGoAssetNode::HEGoAssetNode() {}

HEGoAssetNode::~HEGoAssetNode() {}

godot::Ref<HEGoTask> HEGoAssetNode::instantiate()
{
	if (op_name == "")
	{
		return make_failed("Operator name not set, call set_op_name(name) first!", "Instantiate");
	}

	godot::String op = op_name;
	HAPI_NodeId nid = node_id;
	HEGoAssetNode *self = this;

	return submit("Instantiate " + op_name, nid, [self, op, nid](HEGoSessionManager *mgr) -> godot::Variant {
		HAPI_NodeId result_id = HEGo::Util::Node::instantiate_hda_from_name(mgr, op, nid);
		self->node_id = result_id;

		if (result_id >= 0)
		{
			mgr->register_node(self);
			HEGo::Util::Log::message("Successfully instantiated HDA: " + op);
		}
		else
		{
			HEGo::Util::Log::error("Failed to instantiate HDA: " + op + " (License issue? Check if Houdini Engine has a valid license)");
		}

		return result_id;
	});
}

godot::Ref<HEGoTask> HEGoAssetNode::set_parm(godot::String parm_name, godot::Variant value)
{
	if (get_id() < 0)
	{
		return make_failed("Cannot set parameter - HDA not instantiated or license issue", "Set parm");
	}

	HAPI_NodeId nid = node_id;

	return submit("Set parm " + parm_name, nid, [nid, parm_name, value](HEGoSessionManager *mgr) -> godot::Variant {
		godot::Variant val = value;
		HEGo::Util::Parm::set_parm(mgr, nid, parm_name, &val);
		return 0;
	});
}

godot::Ref<HEGoTask> HEGoAssetNode::set_parms_batch(godot::Dictionary parms)
{
	if (get_id() < 0)
	{
		return make_failed("Cannot set parameters - HDA not instantiated or license issue", "Set parms batch");
	}

	HAPI_NodeId nid = node_id;

	return submit("Set parms batch", nid, [nid, parms](HEGoSessionManager *mgr) -> godot::Variant {
		godot::Array keys = parms.keys();
		for (int i = 0; i < keys.size(); i++)
		{
			godot::String name = keys[i];
			godot::Variant val = parms[keys[i]];
			HEGo::Util::Parm::set_parm_no_wait(mgr, nid, name, &val);
		}
		mgr->wait_for_ready();
		return 0;
	});
}

godot::Ref<HEGoTask> HEGoAssetNode::set_preset(godot::PackedByteArray preset)
{
	if (get_id() < 0)
	{
		return make_failed("Cannot set preset - HDA not instantiated or license issue", "Set preset");
	}

	HAPI_NodeId nid = node_id;

	return submit("Set preset", nid, [nid, preset](HEGoSessionManager *mgr) -> godot::Variant {
		HEGo::Util::Parm::set_preset(mgr, nid, preset);
		return 0;
	});
}

godot::Ref<HEGoTask> HEGoAssetNode::insert_multiparm_instance(int parm_id, int index)
{
	HAPI_NodeId nid = node_id;

	return submit("Insert multiparm", nid, [nid, parm_id, index](HEGoSessionManager *mgr) -> godot::Variant {
		HEGo::Util::Parm::insert_multiparm_instance(mgr, nid, parm_id, index);
		return 0;
	});
}

godot::Ref<HEGoTask> HEGoAssetNode::remove_multiparm_instance(int parm_id, int index)
{
	HAPI_NodeId nid = node_id;

	return submit("Remove multiparm", nid, [nid, parm_id, index](HEGoSessionManager *mgr) -> godot::Variant {
		HEGo::Util::Parm::remove_multiparm_instance(mgr, nid, parm_id, index);
		return 0;
	});
}

godot::Ref<HEGoTask> HEGoAssetNode::get_preset()
{
	if (get_id() < 0)
	{
		return make_failed("Cannot get preset - HDA not instantiated or license issue", "Get preset");
	}

	HAPI_NodeId nid = node_id;

	return submit("Get preset", nid, [nid](HEGoSessionManager *mgr) -> godot::Variant {
		return HEGo::Util::Parm::get_preset(mgr, nid);
	});
}

godot::Ref<HEGoTask> HEGoAssetNode::get_parms_dict()
{
	if (get_id() < 0)
	{
		return make_failed("Cannot get parameters - HDA not instantiated or license issue", "Get parms dict");
	}

	HAPI_NodeId nid = node_id;

	return submit("Get parms dict", nid, [nid](HEGoSessionManager *mgr) -> godot::Variant {
		return HEGo::Util::Parm::get_parm_dict(mgr, nid);
	});
}

godot::Ref<HEGoTask> HEGoAssetNode::get_input_names()
{
	if (get_id() < 0)
	{
		return make_failed("Cannot get input names - HDA not instantiated or license issue", "Get input names");
	}

	HAPI_NodeId nid = node_id;

	return submit("Get input names", nid, [nid](HEGoSessionManager *mgr) -> godot::Variant {
		return HEGo::Util::Geo::get_input_names(mgr, nid);
	});
}

godot::Ref<HEGoTask> HEGoAssetNode::cook()
{
	if (get_id() < 0)
	{
		return make_failed("Cannot cook node - HDA not instantiated or license issue", "Cook");
	}

	HAPI_NodeId nid = node_id;

	return submit("Cook", nid, [nid](HEGoSessionManager *mgr) -> godot::Variant {
		if (HoudiniApi::CookNode(mgr->get_session(), nid, mgr->get_cook_options()) != HAPI_RESULT_SUCCESS)
		{
			HEGo::Util::Log::error("Failed to cook node.");
			return -1;
		}
		mgr->wait_for_cook(nid);
		return 0;
	});
}

godot::Ref<HEGoTask> HEGoAssetNode::fetch_points(godot::Ref<godot::Resource> fetch_point_config)
{
	if (get_id() < 0)
	{
		return make_failed("Cannot fetch points - HDA not instantiated or license issue", "Fetch points");
	}

	if (!fetch_point_config.is_valid() || !fetch_point_config->is_class("Resource"))
	{
		return make_failed("Invalid fetch_point_config!", "Fetch points", node_id);
	}

	HAPI_NodeId nid = node_id;

	return submit("Fetch points", nid, [nid, fetch_point_config](HEGoSessionManager *mgr) -> godot::Variant {
		return HEGo::Util::Geo::fetch_points(mgr, nid, fetch_point_config, false);
	});
}

godot::Ref<HEGoTask> HEGoAssetNode::fetch_surfaces(godot::Ref<godot::Resource> fetch_surface_config)
{
	if (get_id() < 0)
	{
		return make_failed("Cannot fetch surfaces - HDA not instantiated or license issue", "Fetch surfaces");
	}

	if (!fetch_surface_config.is_valid() || !fetch_surface_config->is_class("Resource"))
	{
		return make_failed("Invalid fetch_surface_config!", "Fetch surfaces", node_id);
	}

	HAPI_NodeId nid = node_id;

	return submit("Fetch surfaces", nid, [nid, fetch_surface_config](HEGoSessionManager *mgr) -> godot::Variant {
		return HEGo::Util::Geo::fetch_surfaces(mgr, nid, fetch_surface_config, false);
	});
}

godot::Ref<HEGoTask> HEGoAssetNode::get_heightfield_layers(godot::PackedStringArray read_prim_attribs)
{
	if (get_id() < 0)
	{
		return make_failed("Cannot get heightfield layers - HDA not instantiated or license issue", "Get heightfield layers");
	}

	HAPI_NodeId nid = node_id;

	return submit("Get heightfield layers", nid, [nid, read_prim_attribs](HEGoSessionManager *mgr) -> godot::Variant {
		return HEGo::Util::Geo::get_heightfield_layers(mgr, nid, read_prim_attribs, false);
	});
}

godot::Ref<HEGoTask> HEGoAssetNode::fetch_heightfield_layer_image(int part_id)
{
	if (get_id() < 0)
	{
		return make_failed("Cannot fetch heightfield layer - HDA not instantiated or license issue", "Fetch heightfield layer image");
	}

	HAPI_NodeId nid = node_id;

	return submit("Fetch heightfield layer image", nid, [nid, part_id](HEGoSessionManager *mgr) -> godot::Variant {
		return HEGo::Util::Geo::fetch_heightfield_layer_image(mgr, nid, part_id, false);
	});
}

void HEGoAssetNode::set_op_name(godot::String name) { op_name = name; }

godot::String HEGoAssetNode::get_op_name() const { return op_name; }

void HEGoAssetNode::_bind_methods()
{
	godot::ClassDB::bind_method(godot::D_METHOD("set_parm", "parm_name", "value"), &HEGoAssetNode::set_parm);
	godot::ClassDB::bind_method(godot::D_METHOD("set_parms_batch", "parms"), &HEGoAssetNode::set_parms_batch);
	godot::ClassDB::bind_method(godot::D_METHOD("insert_multiparm_instance", "parm_id", "index"), &HEGoAssetNode::insert_multiparm_instance);
	godot::ClassDB::bind_method(godot::D_METHOD("remove_multiparm_instance", "parm_id", "index"), &HEGoAssetNode::remove_multiparm_instance);
	godot::ClassDB::bind_method(godot::D_METHOD("get_preset"), &HEGoAssetNode::get_preset);
	godot::ClassDB::bind_method(godot::D_METHOD("set_preset", "preset"), &HEGoAssetNode::set_preset);
	godot::ClassDB::bind_method(godot::D_METHOD("get_id"), &HEGoAssetNode::get_id);
	godot::ClassDB::bind_method(godot::D_METHOD("get_input_names"), &HEGoAssetNode::get_input_names);
	godot::ClassDB::bind_method(godot::D_METHOD("get_parms_dict"), &HEGoAssetNode::get_parms_dict);
	godot::ClassDB::bind_method(godot::D_METHOD("set_op_name", "name"), &HEGoAssetNode::set_op_name);
	godot::ClassDB::bind_method(godot::D_METHOD("get_op_name"), &HEGoAssetNode::get_op_name);
	godot::ClassDB::bind_method(godot::D_METHOD("cook"), &HEGoAssetNode::cook);
	godot::ClassDB::bind_method(godot::D_METHOD("fetch_points", "fetch_point_config"), &HEGoAssetNode::fetch_points);
	godot::ClassDB::bind_method(godot::D_METHOD("fetch_surfaces", "fetch_surface_config"), &HEGoAssetNode::fetch_surfaces);
	godot::ClassDB::bind_method(
			godot::D_METHOD("get_heightfield_layers", "read_prim_attribs"), &HEGoAssetNode::get_heightfield_layers, DEFVAL(godot::PackedStringArray()));
	godot::ClassDB::bind_method(godot::D_METHOD("fetch_heightfield_layer_image", "part_id"), &HEGoAssetNode::fetch_heightfield_layer_image);
	godot::ClassDB::bind_method(godot::D_METHOD("reset_node_id"), &HEGoAssetNode::reset_node_id);
	ADD_PROPERTY(godot::PropertyInfo(godot::Variant::STRING, "op_name"), "set_op_name", "get_op_name");
}

} // namespace HEGo
