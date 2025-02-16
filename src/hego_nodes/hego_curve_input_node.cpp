#include "hego_api.h"
#include "hego_nodes/hego_curve_input_node.h"
#include "util/geo/input.h"
#include "util/log/log.h"
#include "util/node/create_nodes.h"
namespace HEGo
{
HEGo::HEGoCurveInputNode::HEGoCurveInputNode() {}

HEGo::HEGoCurveInputNode::~HEGoCurveInputNode() {}

void HEGo::HEGoCurveInputNode::instantiate() { node_id = HEGo::Util::Node::create_and_cook_input_curve_node(get_session_manager(), node_name, node_id); }

void HEGo::HEGoCurveInputNode::set_curve_from_path_3d(godot::Path3D *path3d, float target_length)
{
	HEGo::Util::Geo::create_input_from_path_3d(get_session_manager(), path3d, node_id, target_length);
}

void HEGo::HEGoCurveInputNode::_bind_methods()
{
	godot::ClassDB::bind_method(godot::D_METHOD("set_curve_from_path_3d", "path_3d", "target_length"), &HEGoCurveInputNode::set_curve_from_path_3d);
}
} // namespace HEGo