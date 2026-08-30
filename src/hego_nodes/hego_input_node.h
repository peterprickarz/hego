#ifndef HEGO_INPUT_NODE_H
#define HEGO_INPUT_NODE_H

#include "hego_nodes/hego_base_node.h"
#include "hego_task.h"

#include <cstdint>

#include <godot_cpp/classes/mesh.hpp>
#include <godot_cpp/classes/mesh_instance3d.hpp>
#include <godot_cpp/variant/transform3d.hpp>

namespace HEGo
{
class HEGoInputNode : public HEGoBaseInputNode
{
	GDCLASS(HEGoInputNode, HEGoBaseInputNode)

private:
	godot::String node_name;
	uint64_t last_geo_hash = 0;
	godot::Transform3D last_mesh_instance_transform;
	bool has_cached_mesh_instance_transform = false;

	static uint64_t compute_mesh_hash(const godot::Ref<godot::Mesh> &mesh, const godot::Array &attributes);

public:
	HEGoInputNode();
	~HEGoInputNode();

	void reset_node_id() override;
	godot::Ref<HEGoTask> instantiate() override;
	godot::Ref<HEGoTask> set_geo_from_mesh_instance_3d(godot::MeshInstance3D *mesh_instance, const godot::Array &attributes = godot::Array(), bool force = false);
	godot::Ref<HEGoTask> set_geo_from_mesh(godot::Ref<godot::Mesh> mesh, const godot::Array &attributes = godot::Array(), bool force = false);

	static void _bind_methods();
};

} // namespace HEGo

#endif // HEGO_INPUT_NODE_H
