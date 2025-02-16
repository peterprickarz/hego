#ifndef HEGO_INPUT_NODE_H
#define HEGO_INPUT_NODE_H

#include "hego_nodes/hego_base_node.h"

#include <godot_cpp/classes/mesh_instance3d.hpp>
#include <godot_cpp/variant/transform3d.hpp>

namespace HEGo
{
class HEGoInputNode : public HEGoTransformableNamedNode
{
	GDCLASS(HEGoInputNode, HEGoTransformableNamedNode)

private:
	godot::String node_name;

public:
	HEGoInputNode();
	~HEGoInputNode();

	void instantiate() override;
	void set_geo_from_mesh_instance_3d(godot::MeshInstance3D *mesh_instance);
	void set_geo_from_mesh(godot::Mesh *mesh);

	static void _bind_methods();
};

} // namespace HEGo

#endif // HEGO_INPUT_NODE_H