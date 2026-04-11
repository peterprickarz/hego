#include "hego_nodes/hego_input_node.h"

#include "hego_api.h"
#include "hego_input_node.h"
#include "util/geo/input.h"
#include "util/geo/transform.h"
#include "util/log/log.h"
#include "util/node/create_nodes.h"
#include "util/task/task_helpers.h"

using HEGo::Util::Task::make_failed;
using HEGo::Util::Task::submit;

namespace HEGo
{

HEGoInputNode::HEGoInputNode() {}

HEGoInputNode::~HEGoInputNode() {}

godot::Ref<HEGoTask> HEGoInputNode::instantiate()
{
	HAPI_NodeId nid = node_id;
	godot::String name = node_name;
	HEGoInputNode *self = this;

	return submit("Instantiate input node", nid, [self, name, nid](HEGoSessionManager *mgr) -> godot::Variant {
		self->node_id = HEGo::Util::Node::create_and_cook_input_node(mgr, name, nid);
		mgr->register_node(self);
		return self->node_id;
	});
}

godot::Ref<HEGoTask> HEGoInputNode::set_geo_from_mesh_instance_3d(godot::MeshInstance3D *mesh_instance, const godot::Array &attributes)
{
	if (mesh_instance == nullptr)
	{
		return make_failed("MeshInstance3D is null", "Set geo from MeshInstance3D");
	}

	// Extract data from Godot node on main thread before submitting
	godot::Ref<godot::Mesh> mesh = mesh_instance->get_mesh();
	godot::Transform3D xform = mesh_instance->get_global_transform();
	HAPI_NodeId nid = node_id;

	return submit("Set geo from MeshInstance3D", nid, [nid, mesh, xform, attributes](HEGoSessionManager *mgr) -> godot::Variant {
		HEGo::Util::Geo::create_input_from_mesh(mgr, mesh, nid, attributes);
		HEGo::Util::Geo::set_object_transform(mgr, nid, xform);
		return 0;
	});
}

godot::Ref<HEGoTask> HEGoInputNode::set_geo_from_mesh(godot::Ref<godot::Mesh> mesh, const godot::Array &attributes)
{
	HAPI_NodeId nid = node_id;

	return submit("Set geo from Mesh", nid, [nid, mesh, attributes](HEGoSessionManager *mgr) -> godot::Variant {
		HEGo::Util::Geo::create_input_from_mesh(mgr, mesh, nid, attributes);
		return 0;
	});
}

void HEGoInputNode::_bind_methods()
{
	godot::ClassDB::bind_method(godot::D_METHOD("set_geo_from_mesh_instance_3d", "mesh_instance_3d", "attributes"),
			&HEGoInputNode::set_geo_from_mesh_instance_3d, DEFVAL(godot::Array()));
	godot::ClassDB::bind_method(
			godot::D_METHOD("set_geo_from_mesh", "mesh", "attributes"), &HEGoInputNode::set_geo_from_mesh, DEFVAL(godot::Array()));
}

} // namespace HEGo
