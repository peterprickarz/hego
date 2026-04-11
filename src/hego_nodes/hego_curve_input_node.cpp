#include "hego_api.h"
#include "hego_nodes/hego_curve_input_node.h"
#include "util/geo/input.h"
#include "util/geo/transform.h"
#include "util/hash/fnv.h"
#include "util/log/log.h"
#include "util/node/create_nodes.h"
#include "util/task/task_helpers.h"

using HEGo::Util::Task::make_failed;
using HEGo::Util::Task::make_noop;
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

godot::Ref<HEGoTask> HEGoCurveInputNode::set_curve_from_path_3d(godot::Path3D *path3d, float target_length, bool force)
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

	// Tessellate on main thread so we can hash and avoid double-tessellation
	godot::PackedVector3Array tessellated = curve->tessellate_even_length(10, target_length);

	using namespace HEGo::Util::Hash;
	uint64_t hash = FNV_OFFSET;
	hash = hash_packed_vector3(tessellated, hash);
	hash = hash_float(target_length, hash);
	hash = hash_transform(xform, hash);

	if (!force && hash == last_curve_hash)
	{
		return make_noop("Set curve from Path3D (cached)", nid);
	}

	last_curve_hash = hash;

	return submit("Set curve from Path3D", nid, [nid, tessellated, xform](HEGoSessionManager *mgr) -> godot::Variant {
		HEGo::Util::Geo::create_input_from_curve3d(mgr, tessellated, nid);
		mgr->wait_for_ready();
		HEGo::Util::Geo::set_object_transform(mgr, nid, xform);
		return 0;
	});
}

void HEGoCurveInputNode::_bind_methods()
{
	godot::ClassDB::bind_method(
			godot::D_METHOD("set_curve_from_path_3d", "path_3d", "target_length", "force"), &HEGoCurveInputNode::set_curve_from_path_3d, DEFVAL(false));
}

} // namespace HEGo
