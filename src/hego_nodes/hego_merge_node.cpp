#include "hego_nodes/hego_merge_node.h"

#include "hego_api.h"
#include "hego_merge_node.h"
#include "util/geo/input.h"
#include "util/log/log.h"
#include "util/node/create_nodes.h"
#include "util/task/task_helpers.h"

using HEGo::Util::Task::make_noop;
using HEGo::Util::Task::submit;

namespace HEGo
{

HEGoMergeNode::HEGoMergeNode() {}

HEGoMergeNode::~HEGoMergeNode() {}

void HEGoMergeNode::reset_node_id()
{
	HEGoInputReceiverNode::reset_node_id();
	cached_source_ids.clear();
}

godot::Ref<HEGoTask> HEGoMergeNode::instantiate()
{
	HAPI_NodeId nid = node_id;
	HEGoMergeNode *self = this;

	return submit("Instantiate merge node", nid, [self, nid](HEGoSessionManager *mgr) -> godot::Variant {
		self->node_id = HEGo::Util::Geo::create_merge_sop(mgr, nid);
		mgr->register_node(self);
		return self->node_id;
	});
}

godot::Ref<HEGoTask> HEGoMergeNode::connect_inputs(godot::Array inputs, bool force)
{
	// Extract node IDs on main thread (accessing Godot objects)
	godot::PackedInt32Array source_ids;
	source_ids.resize(inputs.size());
	for (int i = 0; i < inputs.size(); ++i)
	{
		HEGoBaseNode *input_node = Object::cast_to<HEGoBaseNode>(inputs[i]);
		if (input_node)
		{
			source_ids[i] = input_node->get_id();
		}
	}

	HAPI_NodeId nid = node_id;

	if (!force && source_ids == cached_source_ids)
	{
		return make_noop("Connect merge inputs (cached)", nid);
	}

	cached_source_ids = source_ids;

	return submit("Connect merge inputs", nid, [nid, source_ids](HEGoSessionManager *mgr) -> godot::Variant {
		HEGo::Util::Geo::connect_to_merge(mgr, nid, source_ids);
		return 0;
	});
}

void HEGoMergeNode::_bind_methods()
{
	godot::ClassDB::bind_method(godot::D_METHOD("connect_inputs", "inputs", "force"), &HEGoMergeNode::connect_inputs, DEFVAL(false));
}

} // namespace HEGo
