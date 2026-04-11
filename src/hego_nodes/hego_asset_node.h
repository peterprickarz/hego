#ifndef HEGO_ASSET_NODE_H
#define HEGO_ASSET_NODE_H

#include "hego_nodes/hego_base_node.h"
#include "hego_task.h"

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/ref.hpp>
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

	// Returns a task — all HAPI work happens on the scheduler thread
	godot::Ref<HEGoTask> instantiate() override;
	godot::Ref<HEGoTask> cook();
	godot::Ref<HEGoTask> set_parm(godot::String parm_name, godot::Variant value);
	godot::Ref<HEGoTask> set_parms_batch(godot::Dictionary parms);
	godot::Ref<HEGoTask> set_preset(godot::PackedByteArray preset);
	godot::Ref<HEGoTask> get_preset();
	godot::Ref<HEGoTask> insert_multiparm_instance(int parm_id, int index);
	godot::Ref<HEGoTask> remove_multiparm_instance(int parm_id, int index);
	godot::Ref<HEGoTask> get_parms_dict();
	godot::Ref<HEGoTask> get_input_names();
	godot::Ref<HEGoTask> fetch_surfaces(godot::Ref<godot::Resource> fetch_surface_config);
	godot::Ref<HEGoTask> fetch_points(godot::Ref<godot::Resource> fetch_point_config);
	godot::Ref<HEGoTask> get_heightfield_layers(godot::PackedStringArray read_prim_attribs = godot::PackedStringArray());
	godot::Ref<HEGoTask> fetch_heightfield_layer_image(int part_id);

	// Sync accessors (no HAPI call)
	void set_op_name(godot::String name);
	godot::String get_op_name() const;

	static void _bind_methods();
};

} // namespace HEGo

#endif // HEGO_ASSET_NODE_H
