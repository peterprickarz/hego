#ifndef HEGO_HEIGHTFIELD_INPUT_NODE_H
#define HEGO_HEIGHTFIELD_INPUT_NODE_H

#include "hego_nodes/hego_base_node.h"
#include "hego_task.h"

#include <godot_cpp/variant/dictionary.hpp>

namespace HEGo
{
class HEGoHeightfieldInputNode : public HEGoBaseInputNode
{
	GDCLASS(HEGoHeightfieldInputNode, HEGoBaseInputNode)

private:
	HAPI_NodeId height_node_id;
	HAPI_NodeId mask_node_id;
	HAPI_NodeId merge_node_id;
	int x_size;
	int y_size;
	float voxel_size;

	// Internal instantiate for use within task lambdas (runs on worker thread)
	void instantiate_internal(HEGoSessionManager *session_mgr);

public:
	HEGoHeightfieldInputNode();
	~HEGoHeightfieldInputNode();

	godot::Ref<HEGoTask> instantiate() override;
	godot::Ref<HEGoTask> set_layers(godot::Dictionary layers, float voxel_size = 1.0f, float height_scale = 1.0f);

	static void _bind_methods();
};

} // namespace HEGo

#endif // HEGO_HEIGHTFIELD_INPUT_NODE_H
