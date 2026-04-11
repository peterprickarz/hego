#include "hego_nodes/hego_base_node.h"

#include "hego_api.h"
#include "hego_base_node.h"
#include "util/geo/input.h"
#include "util/geo/transform.h"
#include "util/task/task_helpers.h"

using HEGo::Util::Task::submit;

namespace HEGo
{

HEGoBaseNode::HEGoBaseNode() : node_id(-1) {}

HEGoBaseNode::~HEGoBaseNode() {}

HAPI_NodeId HEGoBaseNode::get_id() const { return node_id; }

void HEGoBaseNode::reset_node_id() { node_id = -1; }

HEGoSessionManager *HEGoBaseNode::get_session_manager() { return HEGo::HEGoAPI::get_singleton()->get_session_manager(); }

godot::Ref<HEGoTask> HEGoBaseNode::instantiate()
{
	// Virtual method — default returns a no-op completed task
	godot::Ref<HEGoTask> task;
	task.instantiate();
	task->description = "Instantiate (base)";
	task->status.store(HEGoTask::COMPLETED, std::memory_order_release);
	return task;
}

void HEGoBaseNode::_bind_methods() { godot::ClassDB::bind_method(godot::D_METHOD("instantiate"), &HEGoBaseNode::instantiate); }

// HEGoInputReceiverNode
HEGoInputReceiverNode::HEGoInputReceiverNode() {}

HEGoInputReceiverNode::~HEGoInputReceiverNode() {}

godot::Ref<HEGoTask> HEGoInputReceiverNode::connect_input(const HEGoBaseNode *other_node, int input_index)
{
	HAPI_NodeId target_nid = node_id;
	HAPI_NodeId source_nid = other_node->get_id();

	return submit("Connect input", target_nid, [target_nid, input_index, source_nid](HEGoSessionManager *mgr) -> godot::Variant {
		HEGo::Util::Geo::connect_merge_to_input(mgr, target_nid, input_index, source_nid);
		return 0;
	});
}

void HEGoInputReceiverNode::_bind_methods()
{
	godot::ClassDB::bind_method(godot::D_METHOD("connect_input", "other_node", "input_index"), &HEGoInputReceiverNode::connect_input);
}

// HEGoTransformableNode
HEGoTransformableNode::HEGoTransformableNode() {}

HEGoTransformableNode::~HEGoTransformableNode() {}

godot::Ref<HEGoTask> HEGoTransformableNode::set_transform(godot::Transform3D xform)
{
	HAPI_NodeId nid = node_id;

	return submit("Set transform", nid, [nid, xform](HEGoSessionManager *mgr) -> godot::Variant {
		HEGo::Util::Geo::set_object_transform(mgr, nid, xform);
		return 0;
	});
}

void HEGoTransformableNode::_bind_methods()
{
	godot::ClassDB::bind_method(godot::D_METHOD("set_transform", "xform"), &HEGoTransformableNode::set_transform);
}

// HEGoTransformableInputReceiverNode
HEGoTransformableInputReceiverNode::HEGoTransformableInputReceiverNode() {}

HEGoTransformableInputReceiverNode::~HEGoTransformableInputReceiverNode() {}

godot::Ref<HEGoTask> HEGoTransformableInputReceiverNode::connect_input(const HEGoBaseNode *other_node, int input_index)
{
	HAPI_NodeId target_nid = node_id;
	HAPI_NodeId source_nid = other_node->get_id();

	return submit("Connect input", target_nid, [target_nid, input_index, source_nid](HEGoSessionManager *mgr) -> godot::Variant {
		HEGo::Util::Geo::connect_merge_to_input(mgr, target_nid, input_index, source_nid);
		return 0;
	});
}

void HEGoTransformableInputReceiverNode::_bind_methods()
{
	godot::ClassDB::bind_method(
			godot::D_METHOD("connect_input", "other_node", "input_index"), &HEGoTransformableInputReceiverNode::connect_input);
}

// HEGoTransformableNamedNode
HEGoTransformableNamedNode::HEGoTransformableNamedNode() {}

HEGoTransformableNamedNode::~HEGoTransformableNamedNode() {}

void HEGoTransformableNamedNode::set_node_name(godot::String name) { node_name = name; }

godot::String HEGoTransformableNamedNode::get_node_name() const { return node_name; }

void HEGoTransformableNamedNode::_bind_methods() {}

// HEGoBaseInputNode
HEGoBaseInputNode::HEGoBaseInputNode() {}

HEGoBaseInputNode::~HEGoBaseInputNode() {}

void HEGoBaseInputNode::set_prim_attr(godot::String name, godot::Variant value) {}

void HEGoBaseInputNode::_bind_methods()
{
	godot::ClassDB::bind_method(godot::D_METHOD("set_prim_attr", "name", "value"), &HEGoBaseInputNode::set_prim_attr);
}

} // namespace HEGo
