#include "hego_nodes/hego_base_node.h"

#include "hego_api.h"
#include "hego_base_node.h"
#include "util/geo/input.h"
#include "util/geo/transform.h"

namespace HEGo
{
HEGoBaseNode::HEGoBaseNode() : node_id(-1)
{
	// Constructor code, if any
}

HEGoBaseNode::~HEGoBaseNode()
{
	// Destructor code, if any
}

HAPI_NodeId HEGoBaseNode::get_id() const { return node_id; }

void HEGoBaseNode::reset_node_id() { node_id = -1; }

HEGoSessionManager *HEGoBaseNode::get_session_manager() { return HEGo::HEGoAPI::get_singleton()->get_session_manager(); }

void HEGoBaseNode::instantiate()
{
	// Virtual method, does nothing by default
}

void HEGoBaseNode::_bind_methods() { godot::ClassDB::bind_method(godot::D_METHOD("instantiate"), &HEGoBaseNode::instantiate); }

// Implementation of HEGoInputReceiverNode
HEGoInputReceiverNode::HEGoInputReceiverNode()
{
	// Constructor code, if any
}

HEGoInputReceiverNode::~HEGoInputReceiverNode()
{
	// Destructor code, if any
}

void HEGoInputReceiverNode::connect_input(const HEGoBaseNode *other_node, int input_index)
{
	HEGo::Util::Geo::connect_merge_to_input(get_session_manager(), node_id, input_index, other_node->get_id());
}

void HEGoInputReceiverNode::_bind_methods()
{
	godot::ClassDB::bind_method(godot::D_METHOD("connect_input", "other_node", "input_index"), &HEGoInputReceiverNode::connect_input);
}

// Implementation of HEGoTransformableNode
HEGoTransformableNode::HEGoTransformableNode()
{
	// Constructor code, if any
}

HEGoTransformableNode::~HEGoTransformableNode()
{
	// Destructor code, if any
}

void HEGoTransformableNode::set_transform(godot::Transform3D xform) { HEGo::Util::Geo::set_object_transform(get_session_manager(), node_id, xform); }

void HEGoTransformableNode::_bind_methods() { godot::ClassDB::bind_method(godot::D_METHOD("set_transform", "xform"), &HEGoTransformableNode::set_transform); }

HEGoTransformableInputReceiverNode::HEGoTransformableInputReceiverNode() {}

HEGoTransformableInputReceiverNode::~HEGoTransformableInputReceiverNode() {}

void HEGoTransformableInputReceiverNode::connect_input(const HEGoBaseNode *other_node, int input_index)
{
	HEGo::Util::Geo::connect_merge_to_input(get_session_manager(), node_id, input_index, other_node->get_id());
}

void HEGoTransformableInputReceiverNode::_bind_methods()
{
	// godot::ClassDB::bind_method(godot::D_METHOD("set_transform", "xform"), &HEGoTransformableInputReceiverNode::set_transform);
	godot::ClassDB::bind_method(godot::D_METHOD("connect_input", "other_node", "input_index"), &HEGoTransformableInputReceiverNode::connect_input);
}

HEGoTransformableNamedNode::HEGoTransformableNamedNode() {}

HEGoTransformableNamedNode::~HEGoTransformableNamedNode() {}

void HEGoTransformableNamedNode::set_node_name(godot::String name) { node_name = name; }

godot::String HEGoTransformableNamedNode::get_node_name() const { return node_name; }

void HEGoTransformableNamedNode::_bind_methods() {}

} // namespace HEGo
