#ifndef HEGO_TEXTURE_INPUT_NODE_H
#define HEGO_TEXTURE_INPUT_NODE_H

#include "hego_nodes/hego_base_node.h"

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/texture2d.hpp>

namespace HEGo
{
class HEGoTextureInputNode : public HEGoBaseNode
{
	GDCLASS(HEGoTextureInputNode, HEGoBaseNode)

public:
	enum ImageEncoding
	{
		ENCODING_LINEAR,
		ENCODING_SRGB,
	};

	godot::Ref<HEGoTask> instantiate() override;
	godot::Ref<HEGoTask> set_image(godot::Ref<godot::Image> image, ImageEncoding encoding = ENCODING_LINEAR, bool force = false);
	godot::Ref<HEGoTask> set_texture(godot::Ref<godot::Texture2D> texture, ImageEncoding encoding = ENCODING_LINEAR, bool force = false);
	HAPI_NodeId get_connection_node_id(HAPI_NodeType receiver_type) const override;
	void reset_node_id() override;
	static void _bind_methods();

protected:
	HAPI_NodeId get_owned_node_id(const HAPI_Session *session, HAPI_NodeId id) const override;

private:
	struct Handle
	{
		HAPI_NodeId id = -1;
		int unique_id = -1;
		bool read(const HAPI_Session *session, HAPI_NodeId node_id);
		bool valid(const HAPI_Session *session) const;
	};
	struct Network
	{
		HAPI_Session session{};
		Handle owner;
		Handle output;
		Handle point;
		Handle upload;
		Handle source;
		uint64_t hash = 0;
	};
	struct Snapshot;

	Network network;
	// The scheduler serializes all network edits. Session shutdown joins its
	// worker before resetting the registered node handles.
	godot::Ref<HEGoTask> submit_upload(Snapshot snapshot, bool force);
	HAPI_NodeId apply(HEGoSessionManager *manager, const Snapshot &snapshot, bool force, godot::String &error);
};
} // namespace HEGo

VARIANT_ENUM_CAST(HEGo::HEGoTextureInputNode::ImageEncoding)

#endif
