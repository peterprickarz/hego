#include "hego_nodes/hego_merge_node.h"

#include "hego_api.h"
#include "hego_merge_node.h"
#include "util/geo/input.h"
#include "util/log/log.h"
#include "util/node/create_nodes.h"
#include "util/task/task_helpers.h"

using HEGo::Util::Task::make_noop;
using HEGo::Util::Task::submit;
using HEGo::Util::Task::submit_failable;
using HEGo::Util::Task::make_failed;
using HEGo::Util::Task::fail;

namespace HEGo
{

HEGoMergeNode::HEGoMergeNode() {}

HEGoMergeNode::~HEGoMergeNode() {}

void HEGoMergeNode::reset_node_id()
{
	HEGoInputReceiverNode::reset_node_id();
	std::lock_guard<std::mutex> lock(inputs_cache_mutex);
	cached_source_ids.clear();
	cached_source_generations.clear();
	cached_source_unique_ids.clear();
	has_cached_sources = false;
}

godot::Ref<HEGoTask> HEGoMergeNode::instantiate()
{
	HAPI_NodeId nid = node_id;
	// A reference, not a raw pointer: the task runs on the worker thread and must not
	// find this node destroyed underneath it if the owning script is freed meanwhile.
	godot::Ref<HEGoMergeNode> self = this;

	const uint64_t generation = get_generation();
	return submit_failable("Instantiate merge node", nid, [self, nid, generation](HEGoSessionManager *mgr, HEGoTask *task) -> godot::Variant {
		if (self->get_generation() != generation)
		{
			fail(task, "Merge node was reset before instantiation"); return {};
		}
		const HAPI_NodeId created = HEGo::Util::Geo::create_merge_sop(mgr, nid);
		if (created < 0 || self->get_generation() != generation)
		{
			fail(task, "HAPI could not instantiate the merge node"); return {};
		}
		if (created != nid) self->reset_node_id();
		self->node_id = created;
		mgr->register_node(self.ptr());
		return self->node_id;
	});
}

godot::Ref<HEGoTask> HEGoMergeNode::connect_inputs(godot::Array inputs, bool force)
{
	// Extract node IDs on main thread (accessing Godot objects)
	godot::PackedInt32Array source_ids;
	std::vector<uint64_t> source_generations;
	std::vector<godot::Ref<HEGoBaseNode>> source_refs;
	if (node_id < 0)
	{
		return make_failed("Merge node must be instantiated before connecting inputs", "Connect merge inputs", node_id);
	}
	source_ids.resize(inputs.size());
	for (int i = 0; i < inputs.size(); ++i)
	{
		if (godot::Variant(inputs[i]).get_type() != godot::Variant::OBJECT)
		{
			return make_failed("Merge inputs cannot contain null or non-node references", "Connect merge inputs", node_id);
		}
		HEGoBaseNode *input_node = Object::cast_to<HEGoBaseNode>(inputs[i]);
		if (!input_node || input_node->get_id() < 0)
		{
			return make_failed("Every merge source must be an instantiated HEGo node", "Connect merge inputs", node_id);
		}
		source_ids[i] = input_node->get_id();
		source_generations.push_back(input_node->get_generation());
		source_refs.push_back(godot::Ref<HEGoBaseNode>(input_node));
	}

	HAPI_NodeId nid = node_id;
	const uint64_t generation = get_generation();
	{
		int64_t session_id = 0;
		int session_type = -1;
		std::lock_guard<std::mutex> lock(inputs_cache_mutex);
		if (!force && has_cached_sources && current_session(session_id, session_type) && source_ids == cached_source_ids && source_generations == cached_source_generations &&
				session_id == cached_session_id && session_type == cached_session_type)
		{
			return make_noop("Connect merge inputs (cached)", nid);
		}
	}
	godot::Ref<HEGoMergeNode> self = this;
	return submit_failable("Connect merge inputs", nid, [self, nid, source_ids, source_generations, source_refs, generation, force](HEGoSessionManager *mgr, HEGoTask *task) -> godot::Variant {
		if (!mgr || !mgr->get_session() || HoudiniApi::IsSessionValid(mgr->get_session()) != HAPI_RESULT_SUCCESS || self->get_generation() != generation)
		{
			fail(task, "Merge target session or identity is no longer live"); return {};
		}
		HAPI_NodeInfo info = HoudiniApi::NodeInfo_Create();
		if (HoudiniApi::GetNodeInfo(mgr->get_session(), nid, &info) != HAPI_RESULT_SUCCESS)
		{
			fail(task, "Merge target no longer exists in Houdini"); return {};
		}
		const int target_unique_id = info.uniqueHoudiniNodeId;
		std::vector<int> source_unique_ids;
		for (size_t i = 0; i < source_refs.size(); ++i)
		{
			if (source_refs[i]->get_generation() != source_generations[i] || HoudiniApi::GetNodeInfo(mgr->get_session(), source_ids[i], &info) != HAPI_RESULT_SUCCESS)
			{
				fail(task, "A merge source was reset or no longer exists"); return {};
			}
			source_unique_ids.push_back(info.uniqueHoudiniNodeId);
		}
		{
			std::lock_guard<std::mutex> lock(self->inputs_cache_mutex);
			if (self->get_generation() != generation)
			{
				fail(task, "Merge target was reset during validation"); return {};
			}
			for (size_t i = 0; i < source_refs.size(); ++i)
			{
				if (source_refs[i]->get_generation() != source_generations[i])
				{
					fail(task, "A merge source was reset during validation"); return {};
				}
			}
			if (!force && self->has_cached_sources && source_ids == self->cached_source_ids && source_generations == self->cached_source_generations &&
					source_unique_ids == self->cached_source_unique_ids && target_unique_id == self->cached_target_unique_id &&
					mgr->get_session()->id == self->cached_session_id && static_cast<int>(mgr->get_session()->type) == self->cached_session_type)
			{
				return {};
			}
			// Rewiring can partially mutate Houdini before a later HAPI call fails.
			// No previous source list remains a valid cache hit after this point.
			self->has_cached_sources = false;
		}
		if (!HEGo::Util::Geo::connect_to_merge(mgr, nid, source_ids))
		{
			fail(task, "HAPI failed to rebuild merge connections"); return {};
		}
		{
			std::lock_guard<std::mutex> lock(self->inputs_cache_mutex);
			if (self->get_generation() != generation)
			{
				fail(task, "Merge target was reset during connection"); return {};
			}
			for (size_t i = 0; i < source_refs.size(); ++i)
			{
				if (source_refs[i]->get_generation() != source_generations[i])
				{
					fail(task, "A merge source was reset during connection"); return {};
				}
			}
			self->cached_source_ids = source_ids;
			self->cached_source_generations = source_generations;
			self->cached_source_unique_ids = source_unique_ids;
			self->cached_target_unique_id = target_unique_id;
			self->cached_session_id = mgr->get_session()->id;
			self->cached_session_type = static_cast<int>(mgr->get_session()->type);
			self->has_cached_sources = true;
		}
		return 0;
	});
}

void HEGoMergeNode::_bind_methods()
{
	godot::ClassDB::bind_method(godot::D_METHOD("connect_inputs", "inputs", "force"), &HEGoMergeNode::connect_inputs, DEFVAL(false));
}

} // namespace HEGo
