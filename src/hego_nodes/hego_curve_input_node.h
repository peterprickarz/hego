#ifndef HEGO_CURVE_INPUT_NODE_H
#define HEGO_CURVE_INPUT_NODE_H

#include "hego_nodes/hego_base_node.h"
#include "hego_task.h"

#include <cstdint>

#include <godot_cpp/classes/path3d.hpp>
#include <godot_cpp/variant/transform3d.hpp>

namespace HEGo
{
class HEGoCurveInputNode : public HEGoBaseInputNode
{
	GDCLASS(HEGoCurveInputNode, HEGoBaseInputNode)

private:
	godot::String node_name;
	uint64_t last_curve_hash = 0;

public:
	HEGoCurveInputNode();
	~HEGoCurveInputNode();

	void reset_node_id() override;
	godot::Ref<HEGoTask> instantiate() override;
	godot::Ref<HEGoTask> set_curve_from_path_3d(godot::Path3D *path3d, float target_length, bool force = false);

	static void _bind_methods();
};

} // namespace HEGo

#endif // HEGO_CURVE_INPUT_NODE_H
