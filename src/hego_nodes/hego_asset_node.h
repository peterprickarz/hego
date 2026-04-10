#ifndef HEGO_ASSET_NODE_H
#define HEGO_ASSET_NODE_H

#include "hego_nodes/hego_base_node.h"

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
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
	void set_preset(godot::PackedByteArray preset);
	void insert_multiparm_instance(int parm_id, int index);
	void remove_multiparm_instance(int parm_id, int index);
	godot::PackedByteArray get_preset();
	godot::Dictionary get_parms_dict();
	godot::PackedStringArray get_input_names();
	godot::Array fetch_output();
	void cook();
	godot::Dictionary fetch_points(godot::Ref<godot::Resource> fetch_point_config, bool auto_cook = true);
	godot::Dictionary fetch_surfaces(godot::Ref<godot::Resource> fetch_surface_config, bool auto_cook = true);
	godot::Array get_heightfield_layers(godot::PackedStringArray read_prim_attribs = godot::PackedStringArray(), bool auto_cook = true);
	godot::Ref<godot::Image> fetch_heightfield_layer_image(int part_id, bool auto_cook = true);
	godot::Array fetch_curves(bool auto_cook = true);

	void set_op_name(godot::String name);
	godot::String get_op_name() const;

	static void _bind_methods();
};

} // namespace HEGo

#endif // HEGO_ASSET_NODE_H
