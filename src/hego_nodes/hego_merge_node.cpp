#include "hego_nodes/hego_merge_node.h"

#include "hego_api.h"
#include "hego_merge_node.h"
#include "util/geo/input.h"
#include "util/log/log.h"
#include "util/node/create_nodes.h"

namespace HEGo
{
HEGoMergeNode::HEGoMergeNode()
{
	// Constructor code, if any
}

HEGoMergeNode::~HEGoMergeNode()
{
	// Destructor code, if any
}

void HEGoMergeNode::instantiate()
{
	// Always instantiate merge sop
	node_id = HEGo::Util::Geo::create_merge_sop(get_session_manager(), node_id);
	get_session_manager()->register_node(this);
}

void HEGoMergeNode::connect_inputs(godot::Array inputs)
{
	// Convert from node objects to node ids array
	godot::Array node_ids;
	node_ids.resize(inputs.size());
	for (int i = 0; i < inputs.size(); ++i)
	{
		HEGoBaseNode *input_node = Object::cast_to<HEGoBaseNode>(inputs[i]);
		if (input_node)
		{
			node_ids[i] = input_node->get_id();
		}
	}
	HEGo::Util::Geo::connect_to_merge(get_session_manager(), node_id, node_ids);
}

void HEGoMergeNode::_bind_methods() { godot::ClassDB::bind_method(godot::D_METHOD("connect_inputs", "inputs"), &HEGoMergeNode::connect_inputs); }

} // namespace HEGo