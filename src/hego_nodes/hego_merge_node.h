#ifndef HEGO_MERGE_NODE_H
#define HEGO_MERGE_NODE_H

#include "hego_nodes/hego_base_node.h"
#include "hego_task.h"

#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/transform3d.hpp>

namespace HEGo
{
class HEGoMergeNode : public HEGoInputReceiverNode
{
	GDCLASS(HEGoMergeNode, HEGoInputReceiverNode)

public:
	HEGoMergeNode();
	~HEGoMergeNode();

	godot::Ref<HEGoTask> instantiate() override;
	godot::Ref<HEGoTask> connect_inputs(godot::Array inputs);

	static void _bind_methods();
};

} // namespace HEGo

#endif // HEGO_MERGE_NODE_H
