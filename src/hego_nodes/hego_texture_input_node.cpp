#include "hego_nodes/hego_texture_input_node.h"

#include "util/attrib/set_attribs.h"
#include "util/hash/fnv.h"
#include "util/hego_util.h"
#include "util/log/log.h"
#include "util/task/task_helpers.h"

#include <algorithm>
#include <cmath>
#include <limits>
#include <utility>

namespace HEGo
{
namespace
{
using godot::Image;
using godot::String;

bool same_session(const HAPI_Session &a, const HAPI_Session &b)
{
	return a.type == b.type && a.id == b.id;
}

int channels_for(Image::Format format)
{
	switch (format)
	{
		case Image::FORMAT_L8: case Image::FORMAT_R8: case Image::FORMAT_RF: case Image::FORMAT_RH: case Image::FORMAT_R16:
			return 1;
		case Image::FORMAT_LA8: case Image::FORMAT_RG8: case Image::FORMAT_RGF: case Image::FORMAT_RGH: case Image::FORMAT_RG16:
			return 2;
		case Image::FORMAT_RGB8: case Image::FORMAT_RGB565: case Image::FORMAT_RGBF: case Image::FORMAT_RGBH:
		case Image::FORMAT_RGBE9995: case Image::FORMAT_RGB16:
			return 3;
		case Image::FORMAT_RGBA8: case Image::FORMAT_RGBA4444: case Image::FORMAT_RGBAF: case Image::FORMAT_RGBAH: case Image::FORMAT_RGBA16:
			return 4;
		default:
			return 0;
	}
}

// A failed upload can leave children even when HAPI did not return an image
// node. Stage everything under a private subnet so that one deletion rolls it back.
struct TemporaryNode
{
	const HAPI_Session *session;
	HAPI_NodeId id = -1;
	~TemporaryNode()
	{
		if (id >= 0 && HoudiniApi::DeleteNode(session, id) != HAPI_RESULT_SUCCESS)
			Util::Log::warning(Util::Log::Category::INPUT, "Could not remove a temporary texture input node.");
	}
};

String hapi_error(const HAPI_Session *session, const char *message)
{
	return String(message) + " " + String::utf8(Util::Hapi::get_last_error(session).c_str());
}

bool create_texture_point(const HAPI_Session *session, HAPI_NodeId owner, HAPI_NodeId cop, HAPI_NodeId &point)
{
	HAPI_StringHandle path_handle = -1;
	if (HoudiniApi::GetNodePath(session, cop, -1, &path_handle) != HAPI_RESULT_SUCCESS) return false;
	const String path = Util::Hapi::get_godot_string(session, path_handle);
	if (path.is_empty() || HoudiniApi::CreateInputNode(session, owner, &point, "texture_point") != HAPI_RESULT_SUCCESS) return false;

	HAPI_PartInfo part = HoudiniApi::PartInfo_Create();
	part.type = HAPI_PARTTYPE_MESH;
	part.pointCount = 1;
	if (HoudiniApi::SetPartInfo(session, point, 0, &part) != HAPI_RESULT_SUCCESS) return false;

	godot::Dictionary attribute;
	attribute["type"] = "point";
	attribute["name"] = "P";
	attribute["value"] = godot::Vector3();
	if (!Util::Attribs::add_and_set_attribute(session, point, 0, attribute, 1, 0)) return false;
	attribute["name"] = "hego_cop_path";
	attribute["value"] = path;
	return Util::Attribs::add_and_set_attribute(session, point, 0, attribute, 1, 0) &&
			HoudiniApi::CommitGeo(session, point) == HAPI_RESULT_SUCCESS &&
			HoudiniApi::SetNodeDisplay(session, point, true) == HAPI_RESULT_SUCCESS;
}
} // namespace

struct HEGoTextureInputNode::Snapshot
{
	int width = 0;
	int height = 0;
	Image::Format format = Image::FORMAT_MAX;
	ImageEncoding encoding = ENCODING_LINEAR;
	godot::PackedByteArray bytes;

	uint64_t hash() const
	{
		using namespace Util::Hash;
		uint64_t value = hash_int(width);
		value = hash_int(height, value);
		value = hash_int(format, value);
		value = hash_int(encoding, value);
		return fnv1a(bytes.ptr(), static_cast<size_t>(bytes.size()), value);
	}

	bool pack(HEGoSessionManager *manager, godot::PackedFloat32Array &pixels, HAPI_ImagePacking &packing, String &error) const
	{
		godot::Ref<Image> image = Image::create_from_data(width, height, false, format, bytes);
		if (image.is_null() || image->is_empty() || (image->is_compressed() && image->decompress() != godot::OK))
		{
			error = "Godot could not decode the texture's base image.";
			return false;
		}
		const Image::Format decoded = image->get_format();
		const int channels = channels_for(decoded);
		const int64_t texels = static_cast<int64_t>(width) * height;
		if (!channels)
		{
			error = "Unsupported Godot Image format for a Copernicus float upload: " + String::num_int64(decoded) + ".";
			return false;
		}
		if (texels > std::numeric_limits<int>::max() / channels)
		{
			error = "Texture dimensions and channel count exceed HAPI's sample count limit.";
			return false;
		}
		const int64_t count = texels * channels;
		if (!manager->validate_cop_transfer(error, count * sizeof(float))) return false;

		static constexpr HAPI_ImagePacking packings[] = { HAPI_IMAGE_PACKING_SINGLE, HAPI_IMAGE_PACKING_DUAL, HAPI_IMAGE_PACKING_RGB, HAPI_IMAGE_PACKING_RGBA };
		static constexpr Image::Format float_formats[] = { Image::FORMAT_RF, Image::FORMAT_RGF, Image::FORMAT_RGBF, Image::FORMAT_RGBAF };
		packing = packings[channels - 1];
		if (decoded == Image::FORMAT_LA8)
		{
			// Image.convert(RGF) interprets luminance as RGB and would lose alpha.
			const godot::PackedByteArray data = image->get_data();
			if (data.size() != count || pixels.resize(count) != godot::OK)
			{
				error = "Could not allocate luminance and alpha samples.";
				return false;
			}
			float *dst = pixels.ptrw();
			const uint8_t *src = data.ptr();
			for (int64_t i = 0; i < count; ++i) dst[i] = src[i] / 255.0f;
		}
		else
		{
			if (decoded != float_formats[channels - 1]) image->convert(float_formats[channels - 1]);
			if (image->get_format() != float_formats[channels - 1])
			{
				error = "Godot could not convert the texture to floating-point samples.";
				return false;
			}
			pixels = image->get_data().to_float32_array();
		}
		if (pixels.size() != count)
		{
			error = "The texture byte count does not match its dimensions and channels.";
			return false;
		}
		const int color_channels = decoded == Image::FORMAT_LA8 ? 1 : std::min(channels, 3);
		float *sample = pixels.ptrw();
		for (int64_t i = 0; i < texels; ++i)
		{
			for (int c = 0; c < channels; ++c, ++sample)
			{
				float v = *sample;
				if (encoding == ENCODING_SRGB && c < color_channels)
					v = v <= 0.04045f ? v / 12.92f : std::pow((v + 0.055f) / 1.055f, 2.4f);
				if (!std::isfinite(v))
				{
					error = "Texture samples must be finite.";
					return false;
				}
				*sample = v;
			}
		}
		return true;
	}
};

bool HEGoTextureInputNode::Handle::read(const HAPI_Session *session, HAPI_NodeId node_id)
{
	HAPI_NodeInfo info{};
	if (HoudiniApi::GetNodeInfo(session, node_id, &info) != HAPI_RESULT_SUCCESS) return false;
	id = node_id;
	unique_id = info.uniqueHoudiniNodeId;
	return true;
}

bool HEGoTextureInputNode::Handle::valid(const HAPI_Session *session) const
{
	HAPI_Bool live = false;
	return id >= 0 && HoudiniApi::IsNodeValid(session, id, unique_id, &live) == HAPI_RESULT_SUCCESS && live;
}

HAPI_NodeId HEGoTextureInputNode::get_owned_node_id(const HAPI_Session *session, HAPI_NodeId id) const
{
	return id == network.output.id && same_session(network.session, *session) && network.owner.valid(session) ? network.owner.id : -1;
}

HAPI_NodeId HEGoTextureInputNode::get_connection_node_id(HAPI_NodeType receiver_type) const
{
	return receiver_type == HAPI_NODETYPE_SOP ? network.point.id : get_id();
}

void HEGoTextureInputNode::reset_node_id()
{
	network = {};
	HEGoBaseNode::reset_node_id();
}

godot::Ref<HEGoTask> HEGoTextureInputNode::instantiate()
{
	return submit_upload({}, false);
}

godot::Ref<HEGoTask> HEGoTextureInputNode::set_image(godot::Ref<Image> image, ImageEncoding encoding, bool force)
{
	if (image.is_null() || image->is_empty()) return Util::Task::make_failed("Provide a nonempty Image.", "Set texture image");
	if (encoding != ENCODING_LINEAR && encoding != ENCODING_SRGB) return Util::Task::make_failed("Unknown texture color encoding.", "Set texture image");
	Snapshot snapshot;
	snapshot.width = image->get_width();
	snapshot.height = image->get_height();
	snapshot.format = image->get_format();
	snapshot.encoding = encoding;
	snapshot.bytes = image->get_data();
	if (image->has_mipmaps()) snapshot.bytes = snapshot.bytes.slice(0, image->get_mipmap_offset(1));
	return submit_upload(std::move(snapshot), force);
}

godot::Ref<HEGoTask> HEGoTextureInputNode::set_texture(godot::Ref<godot::Texture2D> texture, ImageEncoding encoding, bool force)
{
	return set_image(texture.is_valid() ? texture->get_image() : godot::Ref<Image>(), encoding, force);
}

godot::Ref<HEGoTask> HEGoTextureInputNode::submit_upload(Snapshot snapshot, bool force)
{
	const String action = snapshot.width ? "Set texture image" : "Instantiate texture input";
	HEGoSessionManager *manager = get_session_manager();
	if (!manager || !manager->get_session()) return Util::Task::make_failed("No Houdini session is available.", action);
	const HAPI_Session expected = *manager->get_session();
	const uint64_t generation = get_generation();
	godot::Ref<HEGoTextureInputNode> self = this;
	return Util::Task::submit_failable(action, node_id, [self, expected, generation, snapshot = std::move(snapshot), force](HEGoSessionManager *mgr, HEGoTask *task) -> godot::Variant {
		const HAPI_Session *session = mgr ? mgr->get_session() : nullptr;
		if (!session || !same_session(*session, expected) || self->get_generation() != generation || HoudiniApi::IsSessionValid(session) != HAPI_RESULT_SUCCESS)
		{
			Util::Task::fail(task, "The texture input or its session changed before the upload.");
			return {};
		}
		String error;
		const HAPI_NodeId result = self->apply(mgr, snapshot, force, error);
		if (result < 0) Util::Task::fail(task, error);
		return result;
	});
}

HAPI_NodeId HEGoTextureInputNode::apply(HEGoSessionManager *manager, const Snapshot &snapshot, bool force, String &error)
{
	if (!manager->validate_cop_transfer(error)) return -1;
	const HAPI_Session *session = manager->get_session();
	const bool owner_live = same_session(network.session, *session) && network.owner.valid(session);
	const bool output_live = owner_live && network.output.valid(session) && network.point.valid(session);
	const bool uploading = snapshot.width > 0;
	const uint64_t hash = uploading ? snapshot.hash() : 0;
	if (output_live && (!uploading || (!force && hash == network.hash && network.upload.valid(session) && network.source.valid(session)))) return node_id;
	godot::PackedFloat32Array pixels;
	HAPI_ImagePacking packing = HAPI_IMAGE_PACKING_UNKNOWN;
	if (uploading && !snapshot.pack(manager, pixels, packing, error)) return -1;

	TemporaryNode new_owner{session};
	TemporaryNode new_upload{session};
	Network next = output_live ? network : Network{};
	next.session = *session;
	if (!output_live)
	{
		HAPI_NodeId copnet = -1;
		HAPI_NodeId output = -1;
		HAPI_NodeId point = -1;
		if (HoudiniApi::CreateNode(session, -1, "Object/geo", "HEGoTexture", false, &new_owner.id) != HAPI_RESULT_SUCCESS ||
				HoudiniApi::CreateNode(session, new_owner.id, "copnet", "texture_out", false, &copnet) != HAPI_RESULT_SUCCESS ||
				HoudiniApi::CreateNode(session, copnet, "null", "OUT_TEXTURE", false, &output) != HAPI_RESULT_SUCCESS ||
				!next.owner.read(session, new_owner.id) || !next.output.read(session, output))
		{
			error = hapi_error(session, "Could not create the private Copernicus input network.");
			return -1;
		}
		if (!create_texture_point(session, next.owner.id, output, point) || !next.point.read(session, point))
		{
			error = hapi_error(session, "Could not create the SOP input point with the texture's hego_cop_path.");
			return -1;
		}
	}
	if (uploading)
	{
		HAPI_NodeId image = -1;
		if (HoudiniApi::CreateNode(session, next.owner.id, "subnet", "texture_upload", false, &new_upload.id) != HAPI_RESULT_SUCCESS ||
				HoudiniApi::CreateCOPImage(session, new_upload.id, snapshot.width, snapshot.height, packing, false, true, pixels.ptr(), 0,
						static_cast<int>(pixels.size()), &image) != HAPI_RESULT_SUCCESS ||
				!next.upload.read(session, new_upload.id) || !next.source.read(session, image))
		{
			error = hapi_error(session, "Could not create the Copernicus image.");
			return -1;
		}
		// A cross-object SOP connection can select the owner's display SOP.
		// Keep it on the reference point when a replacement image is staged.
		if (HoudiniApi::SetNodeDisplay(session, next.point.id, true) != HAPI_RESULT_SUCCESS)
		{
			error = hapi_error(session, "Could not select the texture input point as the display SOP.");
			return -1;
		}
		// Houdini creates one local COP reference and reuses it when reconnecting.
		// Keeping this public output stable also preserves node-reference parameters.
		if (HoudiniApi::ConnectNodeInput(session, next.output.id, 0, image, 0) != HAPI_RESULT_SUCCESS)
		{
			error = hapi_error(session, "Could not connect the replacement image to the texture output.");
			if (output_live && network.source.valid(session) && HoudiniApi::ConnectNodeInput(session, node_id, 0, network.source.id, 0) != HAPI_RESULT_SUCCESS)
				error += " Houdini could not restore the prior texture connection.";
			return -1;
		}
		next.hash = hash;
	}
	const Handle retired = output_live ? network.upload : network.owner;
	if (node_id >= 0 && !output_live) node_generation.fetch_add(1, std::memory_order_acq_rel);
	node_id = next.output.id;
	network = next;
	new_upload.id = new_owner.id = -1;
	manager->register_node(this);
	if (owner_live && retired.valid(session) && HoudiniApi::DeleteNode(session, retired.id) != HAPI_RESULT_SUCCESS)
		Util::Log::warning(Util::Log::Category::INPUT, "The new texture is active, but Houdini could not delete the retired upload.");
	return node_id;
}

void HEGoTextureInputNode::_bind_methods()
{
	godot::ClassDB::bind_method(godot::D_METHOD("set_image", "image", "encoding", "force"), &HEGoTextureInputNode::set_image, DEFVAL(ENCODING_LINEAR), DEFVAL(false));
	godot::ClassDB::bind_method(godot::D_METHOD("set_texture", "texture", "encoding", "force"), &HEGoTextureInputNode::set_texture, DEFVAL(ENCODING_LINEAR), DEFVAL(false));
	BIND_ENUM_CONSTANT(ENCODING_LINEAR);
	BIND_ENUM_CONSTANT(ENCODING_SRGB);
}
} // namespace HEGo
