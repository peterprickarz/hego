#ifndef HEGO_CURVE_INPUT_NODE_H
#define HEGO_CURVE_INPUT_NODE_H

#include "hego_nodes/hego_base_node.h"

#include <godot_cpp/classes/path3d.hpp>
#include <godot_cpp/variant/transform3d.hpp>

namespace HEGo
{
class HEGoCurveInputNode : public HEGoTransformableNode
{
	GDCLASS(HEGoCurveInputNode, HEGoTransformableNode)

private:
	godot::String node_name;

public:
	HEGoCurveInputNode();
	~HEGoCurveInputNode();

	void instantiate() override;
	void set_curve_from_path_3d(godot::Path3D *path3d, float target_length);

	static void _bind_methods();
};

} // namespace HEGo

#endif // HEGO_INPUT_NODE_H