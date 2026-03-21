#ifndef HEGO_HEIGHTFIELD_INPUT_NODE_H
#define HEGO_HEIGHTFIELD_INPUT_NODE_H

#include "hego_nodes/hego_base_node.h"

#include <godot_cpp/variant/dictionary.hpp>

namespace HEGo
{
/**
 * Input node for creating Houdini HeightFields from Godot image layers.
 *
 * Typical workflow:
 * 1) Prepare a Dictionary of layer definitions.
 * 2) Call set_layers(layers, voxel_size).
 * 3) Use the resulting node like other HEGo input nodes.
 */
class HEGoHeightfieldInputNode : public HEGoBaseInputNode
{
	GDCLASS(HEGoHeightfieldInputNode, HEGoBaseInputNode)

private:
	HAPI_NodeId height_node_id;
	HAPI_NodeId mask_node_id;
	HAPI_NodeId merge_node_id;
	int x_size;
	int y_size;
	float voxel_size;

public:
	HEGoHeightfieldInputNode();
	~HEGoHeightfieldInputNode();

	/**
	 * Creates the core Houdini HeightField input nodes if they do not exist.
	 *
	 * This allocates:
	 * - the parent heightfield node
	 * - the default "height" volume node
	 * - the default "mask" volume node
	 * - the internal merge node used for additional layers
	 */
	void instantiate() override;

	/**
	 * Builds/rebuilds heightfield layers from a Godot Dictionary.
	 *
	 * Dictionary format:
	 * {
	 *   "height": { "image": Image, "attrs": Dictionary },
	 *   "mask":   { "image": Image, "attrs": Dictionary },
	 *   "water":  { "image": Image, "attrs": Dictionary },
	 *   ...
	 * }
	 *
	 * Keys:
	 * - image: Ref<Image> (required for valid data sampling)
	 * - attrs: Dictionary of primitive attributes (optional)
	 *
	 * Behavior:
	 * - The first valid layer image defines x/y resolution.
	 * - If no valid image exists in any layer, the function logs an error and returns.
	 * - Missing "height" or "mask" layers are auto-created with zero-filled data.
	 * - Additional layers are created as heightfield volume layers and connected to merge.
	 *
	 * @param layers Dictionary of layer-name -> layer-definition.
	 * @param voxel_size World-units per pixel/voxel in X/Y. Must be > 0.
	 *                   Final XY size is resolution * voxel_size.
	 */
	void set_layers(godot::Dictionary layers, float voxel_size = 1.0f);

	/** Bind methods to Godot ClassDB. */
	static void _bind_methods();
};

} // namespace HEGo

#endif // HEGO_HEIGHTFIELD_INPUT_NODE_H
