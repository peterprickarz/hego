#include "hego_nodes/hego_input_node.h"

#include "hego_api.h"
#include "hego_input_node.h"
#include "util/geo/input.h"
#include "util/log/log.h"
#include "util/node/create_nodes.h"

namespace HEGo
{
HEGoInputNode::HEGoInputNode()
{
	// Constructor code, if any
}

HEGoInputNode::~HEGoInputNode()
{
	// Destructor code, if any
}

void HEGoInputNode::instantiate()
{
	node_id = HEGo::Util::Node::create_and_cook_input_node(get_session_manager(), node_name, node_id);
	get_session_manager()->register_node(this);
}

void HEGoInputNode::set_geo_from_mesh_instance_3d(godot::MeshInstance3D *mesh_instance)
{
	HEGo::Util::Geo::create_input_from_mesh_instance_3d(get_session_manager(), mesh_instance, node_id);
}

void HEGoInputNode::set_geo_from_mesh(godot::Mesh *mesh) { HEGo::Util::Geo::create_input_from_mesh(get_session_manager(), mesh, node_id); }
void HEGoInputNode::_bind_methods()
{
	godot::ClassDB::bind_method(godot::D_METHOD("set_geo_from_mesh_instance_3d", "mesh_instance_3d"), &HEGoInputNode::set_geo_from_mesh_instance_3d);
	godot::ClassDB::bind_method(godot::D_METHOD("set_geo_from_mesh", "mesh"), &HEGoInputNode::set_geo_from_mesh);
}

} // namespace HEGo