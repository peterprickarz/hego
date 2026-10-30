#ifndef HEGO_MERGE_NODE_H
#define HEGO_MERGE_NODE_H

#include "hego_nodes/hego_base_node.h"
#include "hego_task.h"

#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <vector>

namespace HEGo
{
class HEGoMergeNode : public HEGoInputReceiverNode
{
	GDCLASS(HEGoMergeNode, HEGoInputReceiverNode)

private:
	godot::PackedInt32Array cached_source_ids;
	std::vector<uint64_t> cached_source_generations;
	std::mutex inputs_cache_mutex;
	bool has_cached_sources = false;
	std::vector<int> cached_source_unique_ids;
	int cached_target_unique_id = -1;
	int64_t cached_session_id = 0;
	int cached_session_type = -1;

public:
	HEGoMergeNode();
	~HEGoMergeNode();

	void reset_node_id() override;
	godot::Ref<HEGoTask> instantiate() override;
	godot::Ref<HEGoTask> connect_inputs(godot::Array inputs, bool force = false);

	static void _bind_methods();
};

} // namespace HEGo

#endif // HEGO_MERGE_NODE_H
