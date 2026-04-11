#include "hego_api.h"
#include "hego_nodes/hego_curve_input_node.h"
#include "util/geo/input.h"
#include "util/geo/transform.h"
#include "util/log/log.h"
#include "util/node/create_nodes.h"
#include "util/task/task_helpers.h"

using HEGo::Util::Task::make_failed;
using HEGo::Util::Task::submit;

namespace HEGo
{

HEGoCurveInputNode::HEGoCurveInputNode() {}

HEGoCurveInputNode::~HEGoCurveInputNode() {}

godot::Ref<HEGoTask> HEGoCurveInputNode::instantiate()
{
	HAPI_NodeId nid = node_id;
	godot::String name = node_name;
	HEGoCurveInputNode *self = this;

	return submit("Instantiate curve input", nid, [self, name, nid](HEGoSessionManager *mgr) -> godot::Variant {
		self->node_id = HEGo::Util::Node::create_and_cook_input_curve_node(mgr, name, nid);
		mgr->register_node(self);
		return self->node_id;
	});
}

godot::Ref<HEGoTask> HEGoCurveInputNode::set_curve_from_path_3d(godot::Path3D *path3d, float target_length)
{
	if (path3d == nullptr)
	{
		return make_failed("Path3D is null", "Set curve from Path3D");
	}

	// Extract curve data and transform on main thread
	godot::Ref<godot::Curve3D> curve = path3d->get_curve();
	godot::Transform3D xform = path3d->get_global_transform();
	HAPI_NodeId nid = node_id;

	if (curve.is_null() || !curve.is_valid())
	{
		return make_failed("Curve3D is null or invalid", "Set curve from Path3D");
	}

	return submit("Set curve from Path3D", nid, [nid, curve, xform, target_length](HEGoSessionManager *mgr) -> godot::Variant {
		HEGo::Util::Geo::create_input_from_curve3d(mgr, curve, nid, target_length);
		mgr->wait_for_ready();
		HEGo::Util::Geo::set_object_transform(mgr, nid, xform);
		return 0;
	});
}

void HEGoCurveInputNode::_bind_methods()
{
	godot::ClassDB::bind_method(
			godot::D_METHOD("set_curve_from_path_3d", "path_3d", "target_length"), &HEGoCurveInputNode::set_curve_from_path_3d);
}

} // namespace HEGo
