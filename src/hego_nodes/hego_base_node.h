#ifndef HEGO_BASE_NODE_H
#define HEGO_BASE_NODE_H

#include "hapi/houdini_api.h"

#include "hego_nodes/hego_trackable_node.h"
#include "hego_session_manager.h"
#include "hego_task.h"

#include <godot_cpp/classes/ref.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/godot.hpp>
#include <godot_cpp/templates/hash_map.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <atomic>
#include <cstdint>
#include <mutex>

namespace HEGo
{
class HEGoBaseNode : public HEGoTrackableNode
{
	GDCLASS(HEGoBaseNode, HEGoTrackableNode)
protected:
	HAPI_NodeId node_id;
	std::atomic<uint64_t> node_generation{0};

	HEGoSessionManager *get_session_manager();
	// The current session's identity, for cache checks on the main thread.
	bool current_session(int64_t &session_id, int &session_type);

public:
	HEGoBaseNode();
	~HEGoBaseNode();

	HAPI_NodeId get_id() const;
	uint64_t get_generation() const;

	void reset_node_id() override;

	virtual godot::Ref<HEGoTask> instantiate();

	static void _bind_methods();
};

/**
 * What one input slot is currently wired to.
 *
 * Both the source node and which of its outputs, because an HDA can have several and
 * caching on the node alone would skip a call that moves an input from one to another.
 */
struct InputConnection
{
	HAPI_NodeId source_node_id = -1;
	int output_index = 0;
	uint64_t source_generation = 0;
	int source_unique_id = -1;
	int target_unique_id = -1;
	int64_t session_id = 0;
	int session_type = -1;

	bool operator==(const InputConnection &other) const
	{
		return source_node_id == other.source_node_id && output_index == other.output_index && source_generation == other.source_generation &&
				source_unique_id == other.source_unique_id && target_unique_id == other.target_unique_id && session_id == other.session_id && session_type == other.session_type;
	}
};

class HEGoInputReceiverNode : public HEGoBaseNode
{
	GDCLASS(HEGoInputReceiverNode, HEGoBaseNode)

protected:
	godot::HashMap<int, InputConnection> cached_connections;
	std::mutex connection_cache_mutex;
	bool cached_connection_current(int input_index, const InputConnection &wanted, uint64_t generation);

public:
	HEGoInputReceiverNode();
	~HEGoInputReceiverNode();

	void reset_node_id() override;
	godot::Ref<HEGoTask> connect_input(const HEGoBaseNode *other_node, int input_index, int output_index = 0, bool force = false);

	static void _bind_methods();
};

class HEGoTransformableNode : public HEGoBaseNode
{
	GDCLASS(HEGoTransformableNode, HEGoBaseNode)

protected:
	godot::Transform3D last_transform;
	bool has_cached_transform = false;
	std::mutex transform_cache_mutex;
	int transform_unique_id = -1;
	int64_t transform_session_id = 0;
	int transform_session_type = -1;
	bool cached_transform_current(const godot::Transform3D &xform, uint64_t generation);

public:
	HEGoTransformableNode();
	~HEGoTransformableNode();

	void reset_node_id() override;
	godot::Ref<HEGoTask> set_transform(godot::Transform3D xform, bool force = false);

	static void _bind_methods();
};

class HEGoTransformableNamedNode : public HEGoTransformableNode
{
	GDCLASS(HEGoTransformableNamedNode, HEGoTransformableNode)

protected:
	godot::String node_name;

public:
	HEGoTransformableNamedNode();
	~HEGoTransformableNamedNode();

	void set_node_name(godot::String name);
	godot::String get_node_name() const;

	static void _bind_methods();
};

class HEGoBaseInputNode : public HEGoTransformableNamedNode
{
	GDCLASS(HEGoBaseInputNode, HEGoTransformableNamedNode)

public:
	HEGoBaseInputNode();
	~HEGoBaseInputNode();

	void set_prim_attr(godot::String name, godot::Variant value);

	static void _bind_methods();
};

class HEGoTransformableInputReceiverNode : public HEGoTransformableNode
{
	GDCLASS(HEGoTransformableInputReceiverNode, HEGoTransformableNode)

protected:
	godot::HashMap<int, InputConnection> cached_connections;
	std::mutex connection_cache_mutex;
	bool cached_connection_current(int input_index, const InputConnection &wanted, uint64_t generation);

public:
	HEGoTransformableInputReceiverNode();
	~HEGoTransformableInputReceiverNode();

	void reset_node_id() override;
	godot::Ref<HEGoTask> connect_input(const HEGoBaseNode *other_node, int input_index, int output_index = 0, bool force = false);

	static void _bind_methods();
};

} // namespace HEGo

#endif // HEGO_BASE_NODE_H
