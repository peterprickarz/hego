#include "hego_nodes/hego_input_node.h"

#include "hego_api.h"
#include "hego_input_node.h"
#include "util/geo/input.h"

#include <godot_cpp/classes/material.hpp>
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

HEGoInputNode::HEGoInputNode() {}

HEGoInputNode::~HEGoInputNode() {}

void HEGoInputNode::reset_node_id()
{
	HEGoBaseInputNode::reset_node_id();
	last_geo_hash = 0;
	has_cached_mesh_instance_transform = false;
}

uint64_t HEGoInputNode::compute_mesh_hash(const godot::Ref<godot::Mesh> &mesh, const godot::Array &attributes)
{
	using namespace HEGo::Util::Hash;
	uint64_t hash = FNV_OFFSET;

	if (mesh.is_null() || !mesh.is_valid())
	{
		return hash;
	}

	int surface_count = mesh->get_surface_count();
	hash = hash_combine(hash, static_cast<uint64_t>(surface_count));

	for (int i = 0; i < surface_count; ++i)
	{
		godot::Array surface_array = mesh->surface_get_arrays(i);
		godot::PackedVector3Array positions = surface_array[0];
		hash = hash_packed_vector3(positions, hash);

		godot::PackedColorArray colors = surface_array[3];
		hash = hash_packed_color(colors, hash);

		godot::PackedInt32Array indices = surface_array[12];
		hash = hash_packed_int32(indices, hash);

		godot::Ref<godot::Material> mat = mesh->surface_get_material(i);
		godot::String path = mat.is_valid() ? mat->get_path() : "empty";
		hash = hash_string(path, hash);
	}

	hash = hash_array(attributes, hash);

	return hash;
}

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

godot::Ref<HEGoTask> HEGoInputNode::set_geo_from_mesh_instance_3d(godot::MeshInstance3D *mesh_instance, const godot::Array &attributes, bool force)
{
	if (mesh_instance == nullptr)
	{
		return make_failed("MeshInstance3D is null", "Set geo from MeshInstance3D");
	}

	// Extract data from Godot node on main thread before submitting
	godot::Ref<godot::Mesh> mesh = mesh_instance->get_mesh();
	godot::Transform3D xform = mesh_instance->get_global_transform();
	HAPI_NodeId nid = node_id;

	uint64_t geo_hash = compute_mesh_hash(mesh, attributes);
	bool geo_changed = force || (geo_hash != last_geo_hash);
	bool xform_changed = force || !has_cached_mesh_instance_transform || !(last_mesh_instance_transform == xform);

	if (!geo_changed && !xform_changed)
	{
		return make_noop("Set geo from MeshInstance3D (cached)", nid);
	}

	last_geo_hash = geo_hash;
	last_mesh_instance_transform = xform;
	has_cached_mesh_instance_transform = true;

	if (!geo_changed && xform_changed)
	{
		// Only transform changed — skip geo upload
		return submit("Set transform from MeshInstance3D", nid, [nid, xform](HEGoSessionManager *mgr) -> godot::Variant {
			HEGo::Util::Geo::set_object_transform(mgr, nid, xform);
			return 0;
		});
	}

	return submit("Set geo from MeshInstance3D", nid, [nid, mesh, xform, attributes](HEGoSessionManager *mgr) -> godot::Variant {
		HEGo::Util::Geo::create_input_from_mesh(mgr, mesh, nid, attributes);
		HEGo::Util::Geo::set_object_transform(mgr, nid, xform);
		return 0;
	});
}

godot::Ref<HEGoTask> HEGoInputNode::set_geo_from_mesh(godot::Ref<godot::Mesh> mesh, const godot::Array &attributes, bool force)
{
	HAPI_NodeId nid = node_id;

	uint64_t geo_hash = compute_mesh_hash(mesh, attributes);
	if (!force && geo_hash == last_geo_hash)
	{
		return make_noop("Set geo from Mesh (cached)", nid);
	}

	last_geo_hash = geo_hash;

	return submit("Set geo from Mesh", nid, [nid, mesh, attributes](HEGoSessionManager *mgr) -> godot::Variant {
		HEGo::Util::Geo::create_input_from_mesh(mgr, mesh, nid, attributes);
		return 0;
	});
}

void HEGoInputNode::_bind_methods()
{
	godot::ClassDB::bind_method(godot::D_METHOD("set_geo_from_mesh_instance_3d", "mesh_instance_3d", "attributes", "force"),
			&HEGoInputNode::set_geo_from_mesh_instance_3d, DEFVAL(godot::Array()), DEFVAL(false));
	godot::ClassDB::bind_method(
			godot::D_METHOD("set_geo_from_mesh", "mesh", "attributes", "force"), &HEGoInputNode::set_geo_from_mesh, DEFVAL(godot::Array()), DEFVAL(false));
}

} // namespace HEGo
