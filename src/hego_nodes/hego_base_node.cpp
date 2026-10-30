#include "hego_nodes/hego_base_node.h"

#include "hego_api.h"
#include "hego_base_node.h"
#include "util/geo/input.h"
#include "util/geo/transform.h"
#include "util/task/task_helpers.h"

using HEGo::Util::Task::make_noop;
using HEGo::Util::Task::submit;
using HEGo::Util::Task::make_failed;
using HEGo::Util::Task::submit_failable;
using HEGo::Util::Task::fail;

namespace HEGo
{

HEGoBaseNode::HEGoBaseNode() : node_id(-1) {}

HEGoBaseNode::~HEGoBaseNode() {}

HAPI_NodeId HEGoBaseNode::get_id() const { return node_id; }
uint64_t HEGoBaseNode::get_generation() const { return node_generation.load(std::memory_order_acquire); }

void HEGoBaseNode::reset_node_id()
{
	node_generation.fetch_add(1, std::memory_order_acq_rel);
	node_id = -1;
}

namespace
{
bool live_node(HEGoSessionManager *mgr, HAPI_NodeId id, HAPI_NodeInfo *result = nullptr)
{
	if (!mgr || !mgr->get_session() || id < 0 || HoudiniApi::IsSessionValid(mgr->get_session()) != HAPI_RESULT_SUCCESS)
	{
		return false;
	}
	HAPI_NodeInfo info = HoudiniApi::NodeInfo_Create();
	if (HoudiniApi::GetNodeInfo(mgr->get_session(), id, &info) != HAPI_RESULT_SUCCESS) return false;
	if (result) *result = info;
	return true;
}
}

HEGoSessionManager *HEGoBaseNode::get_session_manager() { return HEGo::HEGoAPI::get_singleton()->get_session_manager(); }

bool HEGoBaseNode::current_session(int64_t &session_id, int &session_type)
{
	HEGoSessionManager *mgr = get_session_manager();
	if (!mgr || !mgr->get_session()) return false;
	session_id = mgr->get_session()->id;
	session_type = static_cast<int>(mgr->get_session()->type);
	return true;
}

// Main-thread check: the connection was made in this session to this exact source generation
// and nothing has reset this node since. The worker still verifies the live Houdini nodes
// before actually rewiring; this only decides whether rewiring is needed at all.
bool cached_connection_matches(const godot::HashMap<int, InputConnection> &cache, std::mutex &mutex, int input_index, const InputConnection &wanted, int64_t session_id, int session_type)
{
	std::lock_guard<std::mutex> lock(mutex);
	const InputConnection *cached = cache.getptr(input_index);
	return cached && cached->source_node_id == wanted.source_node_id && cached->output_index == wanted.output_index &&
			cached->source_generation == wanted.source_generation && cached->session_id == session_id && cached->session_type == session_type;
}

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

void HEGoInputReceiverNode::reset_node_id()
{
	HEGoBaseNode::reset_node_id();
	std::lock_guard<std::mutex> lock(connection_cache_mutex);
	cached_connections.clear();
}

bool HEGoInputReceiverNode::cached_connection_current(int input_index, const InputConnection &wanted, uint64_t generation)
{
	int64_t session_id = 0;
	int session_type = -1;
	return get_generation() == generation && current_session(session_id, session_type) &&
			cached_connection_matches(cached_connections, connection_cache_mutex, input_index, wanted, session_id, session_type);
}

godot::Ref<HEGoTask> HEGoInputReceiverNode::connect_input(const HEGoBaseNode *other_node, int input_index, int output_index, bool force)
{
	HAPI_NodeId target_nid = node_id;
	if (!other_node || target_nid < 0 || other_node->get_id() < 0 || input_index < 0 || output_index < 0)
	{
		return make_failed("Connect input requires live instantiated source/target nodes and nonnegative indices", "Connect input", target_nid);
	}
	const InputConnection wanted{other_node->get_id(), output_index, other_node->get_generation()};
	const uint64_t generation = get_generation();
	if (!force && cached_connection_current(input_index, wanted, generation))
	{
		return make_noop("Connect input (cached)", target_nid);
	}
	godot::Ref<HEGoInputReceiverNode> self = this;
	godot::Ref<HEGoBaseNode> source = const_cast<HEGoBaseNode *>(other_node);
	return submit_failable("Connect input", target_nid, [self, source, target_nid, input_index, wanted, generation, force](HEGoSessionManager *mgr, HEGoTask *task) -> godot::Variant {
		HAPI_NodeInfo target_info = HoudiniApi::NodeInfo_Create();
		HAPI_NodeInfo source_info = HoudiniApi::NodeInfo_Create();
		if (self->get_generation() != generation || source->get_generation() != wanted.source_generation || !live_node(mgr, target_nid, &target_info) || !live_node(mgr, wanted.source_node_id, &source_info))
		{
			fail(task, "Connection source/target was reset or is no longer live"); return {};
		}
		InputConnection checked = wanted;
		checked.source_unique_id = source_info.uniqueHoudiniNodeId;
		checked.target_unique_id = target_info.uniqueHoudiniNodeId;
		checked.session_id = mgr->get_session()->id;
		checked.session_type = static_cast<int>(mgr->get_session()->type);
		{
			std::lock_guard<std::mutex> lock(self->connection_cache_mutex);
			if (self->get_generation() != generation || source->get_generation() != wanted.source_generation)
			{
				fail(task, "Connection source/target was reset during validation"); return {};
			}
			if (!force && self->cached_connections.has(input_index) && self->cached_connections[input_index] == checked)
			{
				return {};
			}
			self->cached_connections.erase(input_index);
		}
		if (!HEGo::Util::Geo::connect_node_input(mgr, target_nid, input_index, wanted.source_node_id, wanted.output_index))
		{
			fail(task, "HAPI failed to connect the requested input"); return {};
		}
		{
			std::lock_guard<std::mutex> lock(self->connection_cache_mutex);
			if (self->get_generation() != generation || source->get_generation() != wanted.source_generation)
			{
				fail(task, "Connection source/target was reset during the request"); return {};
			}
			self->cached_connections[input_index] = checked;
		}
		return 0;
	});
}

void HEGoInputReceiverNode::_bind_methods()
{
	godot::ClassDB::bind_method(godot::D_METHOD("connect_input", "other_node", "input_index", "output_index", "force"), &HEGoInputReceiverNode::connect_input,
			DEFVAL(0), DEFVAL(false));
}

// HEGoTransformableNode
HEGoTransformableNode::HEGoTransformableNode() {}

HEGoTransformableNode::~HEGoTransformableNode() {}

void HEGoTransformableNode::reset_node_id()
{
	HEGoBaseNode::reset_node_id();
	std::lock_guard<std::mutex> lock(transform_cache_mutex);
	has_cached_transform = false;
}

bool HEGoTransformableNode::cached_transform_current(const godot::Transform3D &xform, uint64_t generation)
{
	int64_t session_id = 0;
	int session_type = -1;
	if (get_generation() != generation || !current_session(session_id, session_type)) return false;
	std::lock_guard<std::mutex> lock(transform_cache_mutex);
	return has_cached_transform && last_transform == xform && transform_session_id == session_id && transform_session_type == session_type;
}

godot::Ref<HEGoTask> HEGoTransformableNode::set_transform(godot::Transform3D xform, bool force)
{
	HAPI_NodeId nid = node_id;
	if (nid < 0 || !xform.origin.is_finite() || !xform.basis.get_column(0).is_finite() || !xform.basis.get_column(1).is_finite() || !xform.basis.get_column(2).is_finite())
	{
		return make_failed("Set transform requires an instantiated node and a finite transform", "Set transform", nid);
	}
	const uint64_t generation = get_generation();
	if (!force && cached_transform_current(xform, generation))
	{
		return make_noop("Set transform (cached)", nid);
	}
	godot::Ref<HEGoTransformableNode> self = this;
	return submit_failable("Set transform", nid, [self, nid, xform, generation, force](HEGoSessionManager *mgr, HEGoTask *task) -> godot::Variant {
		HAPI_NodeInfo info = HoudiniApi::NodeInfo_Create();
		if (self->get_generation() != generation || !live_node(mgr, nid, &info))
		{
			fail(task, "Transform target was reset or is no longer live"); return {};
		}
		{
			std::lock_guard<std::mutex> lock(self->transform_cache_mutex);
			if (!force && self->has_cached_transform && self->last_transform == xform && self->get_generation() == generation &&
					self->transform_unique_id == info.uniqueHoudiniNodeId && self->transform_session_id == mgr->get_session()->id &&
					self->transform_session_type == static_cast<int>(mgr->get_session()->type))
			{
				return {};
			}
			self->has_cached_transform = false;
		}
		if (!HEGo::Util::Geo::set_object_transform(mgr, nid, xform))
		{
			fail(task, "HAPI failed to apply the object transform"); return {};
		}
		{
			std::lock_guard<std::mutex> lock(self->transform_cache_mutex);
			if (self->get_generation() != generation)
			{
				fail(task, "Transform target was reset during the request"); return {};
			}
			self->last_transform = xform;
			self->transform_unique_id = info.uniqueHoudiniNodeId;
			self->transform_session_id = mgr->get_session()->id;
			self->transform_session_type = static_cast<int>(mgr->get_session()->type);
			self->has_cached_transform = true;
		}
		return 0;
	});
}

void HEGoTransformableNode::_bind_methods()
{
	godot::ClassDB::bind_method(godot::D_METHOD("set_transform", "xform", "force"), &HEGoTransformableNode::set_transform, DEFVAL(false));
}

// HEGoTransformableInputReceiverNode
HEGoTransformableInputReceiverNode::HEGoTransformableInputReceiverNode() {}

HEGoTransformableInputReceiverNode::~HEGoTransformableInputReceiverNode() {}

void HEGoTransformableInputReceiverNode::reset_node_id()
{
	HEGoTransformableNode::reset_node_id();
	std::lock_guard<std::mutex> lock(connection_cache_mutex);
	cached_connections.clear();
}

bool HEGoTransformableInputReceiverNode::cached_connection_current(int input_index, const InputConnection &wanted, uint64_t generation)
{
	int64_t session_id = 0;
	int session_type = -1;
	return get_generation() == generation && current_session(session_id, session_type) &&
			cached_connection_matches(cached_connections, connection_cache_mutex, input_index, wanted, session_id, session_type);
}

godot::Ref<HEGoTask> HEGoTransformableInputReceiverNode::connect_input(const HEGoBaseNode *other_node, int input_index, int output_index, bool force)
{
	HAPI_NodeId target_nid = node_id;
	if (!other_node || target_nid < 0 || other_node->get_id() < 0 || input_index < 0 || output_index < 0)
	{
		return make_failed("Connect input requires live instantiated source/target nodes and nonnegative indices", "Connect input", target_nid);
	}
	const InputConnection wanted{other_node->get_id(), output_index, other_node->get_generation()};
	const uint64_t generation = get_generation();
	if (!force && cached_connection_current(input_index, wanted, generation))
	{
		return make_noop("Connect input (cached)", target_nid);
	}
	godot::Ref<HEGoTransformableInputReceiverNode> self = this;
	godot::Ref<HEGoBaseNode> source = const_cast<HEGoBaseNode *>(other_node);
	return submit_failable("Connect input", target_nid, [self, source, target_nid, input_index, wanted, generation, force](HEGoSessionManager *mgr, HEGoTask *task) -> godot::Variant {
		HAPI_NodeInfo target_info = HoudiniApi::NodeInfo_Create();
		HAPI_NodeInfo source_info = HoudiniApi::NodeInfo_Create();
		if (self->get_generation() != generation || source->get_generation() != wanted.source_generation || !live_node(mgr, target_nid, &target_info) || !live_node(mgr, wanted.source_node_id, &source_info))
		{
			fail(task, "Connection source/target was reset or is no longer live"); return {};
		}
		InputConnection checked = wanted;
		checked.source_unique_id = source_info.uniqueHoudiniNodeId;
		checked.target_unique_id = target_info.uniqueHoudiniNodeId;
		checked.session_id = mgr->get_session()->id;
		checked.session_type = static_cast<int>(mgr->get_session()->type);
		{
			std::lock_guard<std::mutex> lock(self->connection_cache_mutex);
			if (self->get_generation() != generation || source->get_generation() != wanted.source_generation)
			{
				fail(task, "Connection source/target was reset during validation"); return {};
			}
			if (!force && self->cached_connections.has(input_index) && self->cached_connections[input_index] == checked)
			{
				return {};
			}
			self->cached_connections.erase(input_index);
		}
		if (!HEGo::Util::Geo::connect_node_input(mgr, target_nid, input_index, wanted.source_node_id, wanted.output_index))
		{
			fail(task, "HAPI failed to connect the requested input"); return {};
		}
		{
			std::lock_guard<std::mutex> lock(self->connection_cache_mutex);
			if (self->get_generation() != generation || source->get_generation() != wanted.source_generation)
			{
				fail(task, "Connection source/target was reset during the request"); return {};
			}
			self->cached_connections[input_index] = checked;
		}
		return 0;
	});
}

void HEGoTransformableInputReceiverNode::_bind_methods()
{
	godot::ClassDB::bind_method(
			godot::D_METHOD("connect_input", "other_node", "input_index", "output_index", "force"), &HEGoTransformableInputReceiverNode::connect_input, DEFVAL(0),
			DEFVAL(false));
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
