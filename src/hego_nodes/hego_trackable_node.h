#ifndef HEGO_TRACKABLE_NODE_H
#define HEGO_TRACKABLE_NODE_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/godot.hpp>

namespace HEGo
{
class HEGoTrackableNode : public godot::RefCounted
{
	GDCLASS(HEGoTrackableNode, godot::RefCounted)

public:
	/// Removes this node from the session manager's registry. See the definition.
	virtual ~HEGoTrackableNode();
	virtual void reset_node_id() = 0;

	static void _bind_methods();
};
} // namespace HEGo

#endif // HEGO_TRACKABLE_NODE_H