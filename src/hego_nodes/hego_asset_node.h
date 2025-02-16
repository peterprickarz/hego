#ifndef HEGO_ASSET_NODE_H
#define HEGO_ASSET_NODE_H

#include "hego_nodes/hego_base_node.h"

#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/variant.hpp>

namespace HEGo
{
class HEGoAssetNode : public HEGoTransformableInputReceiverNode
{
	GDCLASS(HEGoAssetNode, HEGoTransformableInputReceiverNode)

protected:
	godot::String op_name;

public:
	HEGoAssetNode();
	~HEGoAssetNode();

	void instantiate() override;
	void set_parm(godot::String parm_name, godot::Variant value);
	godot::Array fetch_output();
	godot::Dictionary fetch_points(godot::Ref<godot::Resource> fetch_point_config);
	godot::Dictionary fetch_surfaces(godot::Ref<godot::Resource> fetch_surface_config);

	void set_op_name(godot::String name);
	godot::String get_op_name() const;

	static void _bind_methods();
};

} // namespace HEGo

#endif // HEGO_ASSET_NODE_H
