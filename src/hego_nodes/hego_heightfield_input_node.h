#ifndef HEGO_HEIGHTFIELD_INPUT_NODE_H
#define HEGO_HEIGHTFIELD_INPUT_NODE_H

#include "hego_nodes/hego_base_node.h"
#include "hego_task.h"

#include <cstdint>

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
	uint64_t last_layers_hash = 0;

	// Internal instantiate for use within task lambdas (runs on worker thread)
	void instantiate_internal(HEGoSessionManager *session_mgr);

	static uint64_t compute_layers_hash(const godot::Dictionary &layers, float voxel_size, float height_scale);

public:
	HEGoHeightfieldInputNode();
	~HEGoHeightfieldInputNode();

	void reset_node_id() override;
	godot::Ref<HEGoTask> instantiate() override;
	godot::Ref<HEGoTask> set_layers(godot::Dictionary layers, float voxel_size = 1.0f, float height_scale = 1.0f, bool force = false);

	static void _bind_methods();
};

} // namespace HEGo

#endif // HEGO_HEIGHTFIELD_INPUT_NODE_H
