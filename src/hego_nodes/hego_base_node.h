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

namespace HEGo
{
class HEGoBaseNode : public HEGoTrackableNode
{
	GDCLASS(HEGoBaseNode, HEGoTrackableNode)
protected:
	HAPI_NodeId node_id;

	HEGoSessionManager *get_session_manager();

public:
	HEGoBaseNode();
	~HEGoBaseNode();

	HAPI_NodeId get_id() const;

	void reset_node_id() override;

	virtual godot::Ref<HEGoTask> instantiate();

	static void _bind_methods();
};

class HEGoInputReceiverNode : public HEGoBaseNode
{
	GDCLASS(HEGoInputReceiverNode, HEGoBaseNode)

protected:
	godot::HashMap<int, HAPI_NodeId> cached_connections;

public:
	HEGoInputReceiverNode();
	~HEGoInputReceiverNode();

	void reset_node_id() override;
	godot::Ref<HEGoTask> connect_input(const HEGoBaseNode *other_node, int input_index, bool force = false);

	static void _bind_methods();
};

class HEGoTransformableNode : public HEGoBaseNode
{
	GDCLASS(HEGoTransformableNode, HEGoBaseNode)

protected:
	godot::Transform3D last_transform;
	bool has_cached_transform = false;

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
	godot::HashMap<int, HAPI_NodeId> cached_connections;

public:
	HEGoTransformableInputReceiverNode();
	~HEGoTransformableInputReceiverNode();

	void reset_node_id() override;
	godot::Ref<HEGoTask> connect_input(const HEGoBaseNode *other_node, int input_index, bool force = false);

	static void _bind_methods();
};

} // namespace HEGo

#endif // HEGO_BASE_NODE_H
