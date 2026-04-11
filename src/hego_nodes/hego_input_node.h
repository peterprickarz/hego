#ifndef HEGO_INPUT_NODE_H
#define HEGO_INPUT_NODE_H

#include "hego_nodes/hego_base_node.h"
#include "hego_task.h"

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

public:
	HEGoInputNode();
	~HEGoInputNode();

	godot::Ref<HEGoTask> instantiate() override;
	godot::Ref<HEGoTask> set_geo_from_mesh_instance_3d(godot::MeshInstance3D *mesh_instance, const godot::Array &attributes = godot::Array());
	godot::Ref<HEGoTask> set_geo_from_mesh(godot::Ref<godot::Mesh> mesh, const godot::Array &attributes = godot::Array());

	static void _bind_methods();
};

} // namespace HEGo

#endif // HEGO_INPUT_NODE_H
