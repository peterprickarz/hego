#ifndef HEGO_BASE_NODE_H
#define HEGO_BASE_NODE_H

#include "hapi/houdini_api.h"

#include "hego_nodes/hego_trackable_node.h"
#include "hego_session_manager.h"

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/godot.hpp>
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

	virtual void instantiate();

	static void _bind_methods();
};

class HEGoInputReceiverNode : public HEGoBaseNode
{
	GDCLASS(HEGoInputReceiverNode, HEGoBaseNode)

public:
	HEGoInputReceiverNode();
	~HEGoInputReceiverNode();

	void connect_input(const HEGoBaseNode *other_node, int input_index);

	static void _bind_methods();
};

class HEGoTransformableNode : public HEGoBaseNode
{
	GDCLASS(HEGoTransformableNode, HEGoBaseNode)

public:
	HEGoTransformableNode();
	~HEGoTransformableNode();

	void set_transform(godot::Transform3D xform);

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

class HEGoTransformableInputReceiverNode : public HEGoTransformableNode
{
	GDCLASS(HEGoTransformableInputReceiverNode, HEGoTransformableNode)

public:
	HEGoTransformableInputReceiverNode();
	~HEGoTransformableInputReceiverNode();

	void connect_input(const HEGoBaseNode *other_node, int input_index);

	static void _bind_methods();
};

} // namespace HEGo

#endif // HEGO_BASE_NODE_H
