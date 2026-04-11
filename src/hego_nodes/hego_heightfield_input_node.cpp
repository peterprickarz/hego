#include "hego_nodes/hego_heightfield_input_node.h"

#include "hego_api.h"
#include "util/hash/fnv.h"
#include "util/hego_util.h"
#include "util/log/log.h"
#include "util/task/task_helpers.h"

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <algorithm>
#include <map>
#include <string>
#include <vector>

using HEGo::Util::Task::make_failed;
using HEGo::Util::Task::make_noop;
using HEGo::Util::Task::submit;

namespace HEGo
{

namespace
{
static const bool kHeightfieldDebugLogs = false;

static void debug_log(const godot::String &message)
{
	if (kHeightfieldDebugLogs)
	{
		HEGo::Util::Log::message("[HFDBG] " + message);
	}
}

static std::vector<float> image_to_height_data(const godot::Ref<godot::Image> &image_ref, int target_w, int target_h)
{
	std::vector<float> data(target_w * target_h, 0.0f);
	if (image_ref.is_null() || target_w <= 0 || target_h <= 0)
	{
		return data;
	}

	godot::Ref<godot::Image> image = image_ref->duplicate();
	if (image.is_null())
	{
		return data;
	}

	if (image->is_compressed())
	{
		debug_log("image_to_height_data: decompressing source image");
		const godot::Error err = image->decompress();
		if (err != godot::OK)
		{
			HEGo::Util::Log::error("image_to_height_data: failed to decompress image");
			return data;
		}
	}

	if (image->get_format() != godot::Image::FORMAT_RF)
	{
		debug_log("image_to_height_data: converting source image format to RF");
		image->convert(godot::Image::FORMAT_RF);
	}

	if (image->get_width() != target_w || image->get_height() != target_h)
	{
		image->resize(target_w, target_h, godot::Image::INTERPOLATE_BILINEAR);
	}

	for (int y = 0; y < target_h; ++y)
	{
		for (int x = 0; x < target_w; ++x)
		{
			const godot::Color pixel = image->get_pixel(x, y);
			data[y * target_w + x] = pixel.r;
		}
	}

	return data;
}

static void apply_prim_attributes(const HAPI_Session *session, HAPI_NodeId volume_node_id, const godot::Dictionary &attrs)
{
	const godot::Array keys = attrs.keys();
	for (int i = 0; i < keys.size(); ++i)
	{
		const godot::String attr_name = keys[i];
		if (attr_name.is_empty())
		{
			continue;
		}

		const godot::Variant value = attrs[attr_name];
		HAPI_AttributeInfo attr_info = HoudiniApi::AttributeInfo_Create();
		attr_info.count = 1;
		attr_info.owner = HAPI_ATTROWNER_PRIM;
		attr_info.exists = true;

		const godot::CharString attr_name_cs = attr_name.utf8();
		const std::string attr_name_utf8 = std::string(attr_name_cs.get_data());

		switch (value.get_type())
		{
			case godot::Variant::BOOL:
			case godot::Variant::INT:
			{
				attr_info.storage = HAPI_STORAGETYPE_INT;
				attr_info.tupleSize = 1;
				const int int_value = static_cast<int>(value);
				if (HoudiniApi::AddAttribute(session, volume_node_id, 0, attr_name_utf8.c_str(), &attr_info) != HAPI_RESULT_SUCCESS)
				{
					HEGo::Util::Log::warning("Failed to add prim attr '" + attr_name + "'");
					break;
				}
				HoudiniApi::SetAttributeIntData(session, volume_node_id, 0, attr_name_utf8.c_str(), &attr_info, &int_value, 0, 1);
				break;
			}

			case godot::Variant::FLOAT:
			{
				attr_info.storage = HAPI_STORAGETYPE_FLOAT;
				attr_info.tupleSize = 1;
				const float float_value = static_cast<float>(value);
				if (HoudiniApi::AddAttribute(session, volume_node_id, 0, attr_name_utf8.c_str(), &attr_info) != HAPI_RESULT_SUCCESS)
				{
					HEGo::Util::Log::warning("Failed to add prim attr '" + attr_name + "'");
					break;
				}
				HoudiniApi::SetAttributeFloatData(session, volume_node_id, 0, attr_name_utf8.c_str(), &attr_info, &float_value, 0, 1);
				break;
			}

			case godot::Variant::STRING:
			{
				attr_info.storage = HAPI_STORAGETYPE_STRING;
				attr_info.tupleSize = 1;
				const std::string string_value = std::string(godot::String(value).utf8().get_data(), godot::String(value).utf8().size());
				const char *string_ptr = string_value.c_str();
				if (HoudiniApi::AddAttribute(session, volume_node_id, 0, attr_name_utf8.c_str(), &attr_info) != HAPI_RESULT_SUCCESS)
				{
					HEGo::Util::Log::warning("Failed to add prim attr '" + attr_name + "'");
					break;
				}
				HoudiniApi::SetAttributeStringData(session, volume_node_id, 0, attr_name_utf8.c_str(), &attr_info, &string_ptr, 0, 1);
				break;
			}

			case godot::Variant::VECTOR3:
			{
				attr_info.storage = HAPI_STORAGETYPE_FLOAT;
				attr_info.tupleSize = 3;
				const godot::Vector3 vec = value;
				const float vec_data[3] = {vec.x, vec.y, vec.z};
				if (HoudiniApi::AddAttribute(session, volume_node_id, 0, attr_name_utf8.c_str(), &attr_info) != HAPI_RESULT_SUCCESS)
				{
					HEGo::Util::Log::warning("Failed to add prim attr '" + attr_name + "'");
					break;
				}
				HoudiniApi::SetAttributeFloatData(session, volume_node_id, 0, attr_name_utf8.c_str(), &attr_info, vec_data, 0, 1);
				break;
			}

			default:
				HEGo::Util::Log::warning("Unsupported prim attr type for '" + attr_name + "'");
				break;
		}
	}
}

static bool commit_layer_to_node(const HAPI_Session *session, const HAPI_Transform &volume_transform, const std::string &layer_name,
		const std::vector<float> &input_values, const godot::Dictionary &attrs, HAPI_NodeId target_node)
{
	debug_log("commit_layer_to_node: begin layer='" + godot::String(layer_name.c_str()) + "' target_node=" + godot::String::num_int64(target_node));

	if (HoudiniApi::CookNode(session, target_node, nullptr) != HAPI_RESULT_SUCCESS)
	{
		HEGo::Util::Log::error("Failed cooking layer node: " + godot::String(layer_name.c_str()));
		return false;
	}

	HAPI_GeoInfo geo_info = HoudiniApi::GeoInfo_Create();
	HoudiniApi::GeoInfo_Init(&geo_info);
	if (HoudiniApi::GetGeoInfo(session, target_node, &geo_info) != HAPI_RESULT_SUCCESS)
	{
		HEGo::Util::Log::error("Failed fetching geo info for layer: " + godot::String(layer_name.c_str()));
		return false;
	}

	HAPI_PartInfo part_info = HoudiniApi::PartInfo_Create();
	HoudiniApi::PartInfo_Init(&part_info);
	if (HoudiniApi::GetPartInfo(session, geo_info.nodeId, 0, &part_info) != HAPI_RESULT_SUCCESS)
	{
		HEGo::Util::Log::error("Failed fetching part info for layer: " + godot::String(layer_name.c_str()));
		return false;
	}

	HAPI_VolumeInfo volume_info = HoudiniApi::VolumeInfo_Create();
	HoudiniApi::VolumeInfo_Init(&volume_info);
	if (HoudiniApi::GetVolumeInfo(session, geo_info.nodeId, 0, &volume_info) != HAPI_RESULT_SUCCESS)
	{
		HEGo::Util::Log::error("Failed fetching volume info for layer: " + godot::String(layer_name.c_str()));
		return false;
	}

	volume_info.tileSize = 1;
	volume_info.type = HAPI_VOLUMETYPE_HOUDINI;
	volume_info.transform = volume_transform;

	if (HoudiniApi::SetVolumeInfo(session, target_node, 0, &volume_info) != HAPI_RESULT_SUCCESS)
	{
		HEGo::Util::Log::error("Failed setting volume info for layer: " + godot::String(layer_name.c_str()));
		return false;
	}

	const int total_size = volume_info.xLength * volume_info.yLength;
	std::vector<float> values = input_values;
	if (total_size <= 0)
	{
		HEGo::Util::Log::error("Invalid volume size for layer: " + godot::String(layer_name.c_str()));
		return false;
	}

	if (static_cast<int>(values.size()) != total_size)
	{
		values.resize(total_size, 0.0f);
	}

	if (values.empty())
	{
		HEGo::Util::Log::error("No voxel data to write for layer: " + godot::String(layer_name.c_str()));
		return false;
	}

	std::string volume_name = HEGo::Util::Hapi::get_string(session, volume_info.nameSH);
	if (volume_name.empty())
	{
		volume_name = layer_name;
	}

	if (HoudiniApi::SetHeightFieldData(session, target_node, 0, volume_name.c_str(), values.data(), 0, total_size) != HAPI_RESULT_SUCCESS)
	{
		HEGo::Util::Log::error("Failed setting heightfield data for layer: " + godot::String(layer_name.c_str()));
		return false;
	}

	if (!attrs.is_empty())
	{
		apply_prim_attributes(session, target_node, attrs);
	}

	if (HoudiniApi::CommitGeo(session, target_node) != HAPI_RESULT_SUCCESS)
	{
		HEGo::Util::Log::error("Failed committing geo for layer: " + godot::String(layer_name.c_str()));
		return false;
	}

	return true;
}
} // namespace

HEGoHeightfieldInputNode::HEGoHeightfieldInputNode() : height_node_id(-1), mask_node_id(-1), merge_node_id(-1), x_size(256), y_size(256), voxel_size(1.0f) {}

HEGoHeightfieldInputNode::~HEGoHeightfieldInputNode() {}

void HEGoHeightfieldInputNode::reset_node_id()
{
	HEGoBaseInputNode::reset_node_id();
	height_node_id = -1;
	mask_node_id = -1;
	merge_node_id = -1;
	last_layers_hash = 0;
}

void HEGoHeightfieldInputNode::instantiate_internal(HEGoSessionManager *session_mgr)
{
	if (node_id >= 0)
	{
		return;
	}

	if (session_mgr == nullptr || session_mgr->get_session() == nullptr)
	{
		HEGo::Util::Log::error("No active Houdini session for heightfield node instantiation");
		return;
	}

	const godot::String hf_name = node_name.is_empty() ? godot::String("HEGoHeightfieldInput") : node_name;
	const HAPI_Result result = HoudiniApi::CreateHeightFieldInput(session_mgr->get_session(), -1, hf_name.utf8().get_data(), x_size, y_size, voxel_size,
			HAPI_HEIGHTFIELD_SAMPLING_CENTER, &node_id, &height_node_id, &mask_node_id, &merge_node_id);

	if (result != HAPI_RESULT_SUCCESS)
	{
		HEGo::Util::Log::error("Failed to create heightfield input node");
		node_id = -1;
		height_node_id = -1;
		mask_node_id = -1;
		merge_node_id = -1;
		return;
	}

	session_mgr->register_node(this);
	debug_log("instantiate: created HF node_id=" + godot::String::num_int64(node_id) + " height_node_id=" + godot::String::num_int64(height_node_id) +
			" mask_node_id=" + godot::String::num_int64(mask_node_id) + " merge_node_id=" + godot::String::num_int64(merge_node_id));
}

godot::Ref<HEGoTask> HEGoHeightfieldInputNode::instantiate()
{
	HEGoHeightfieldInputNode *self = this;

	return submit("Instantiate heightfield", node_id, [self](HEGoSessionManager *mgr) -> godot::Variant {
		self->instantiate_internal(mgr);
		return self->node_id;
	});
}

uint64_t HEGoHeightfieldInputNode::compute_layers_hash(const godot::Dictionary &layers, float p_voxel_size, float p_height_scale)
{
	using namespace HEGo::Util::Hash;
	uint64_t hash = FNV_OFFSET;

	hash = hash_float(p_voxel_size, hash);
	hash = hash_float(p_height_scale, hash);

	godot::Array keys = layers.keys();
	int key_count = keys.size();
	hash = hash_combine(hash, static_cast<uint64_t>(key_count));

	for (int i = 0; i < key_count; ++i)
	{
		godot::String layer_name = keys[i];
		hash = hash_string(layer_name, hash);

		godot::Variant layer_variant = layers[layer_name];
		if (layer_variant.get_type() != godot::Variant::DICTIONARY)
		{
			continue;
		}

		godot::Dictionary layer_dict = layer_variant;

		// Hash image pixel data
		if (layer_dict.has("image") && godot::Variant(layer_dict["image"]).get_type() == godot::Variant::OBJECT)
		{
			godot::Ref<godot::Image> image = layer_dict["image"];
			if (image.is_valid())
			{
				godot::PackedByteArray data = image->get_data();
				hash = hash_packed_byte(data, hash);
			}
		}

		// Hash layer attributes
		if (layer_dict.has("attrs") && godot::Variant(layer_dict["attrs"]).get_type() == godot::Variant::DICTIONARY)
		{
			godot::Dictionary attrs = layer_dict["attrs"];
			hash = hash_dictionary(attrs, hash);
		}
	}

	return hash;
}

godot::Ref<HEGoTask> HEGoHeightfieldInputNode::set_layers(godot::Dictionary layers, float voxel_size_value, float height_scale_value, bool force)
{
	if (voxel_size_value <= 0.0f)
	{
		return make_failed("voxel_size must be > 0", "Set heightfield layers");
	}
	if (height_scale_value <= 0.0f)
	{
		return make_failed("height_scale must be > 0", "Set heightfield layers");
	}

	uint64_t layers_hash = compute_layers_hash(layers, voxel_size_value, height_scale_value);
	if (!force && layers_hash == last_layers_hash)
	{
		return make_noop("Set heightfield layers (cached)", node_id);
	}

	last_layers_hash = layers_hash;

	HEGoHeightfieldInputNode *self = this;

	return submit("Set heightfield layers", node_id,
			[self, layers, voxel_size_value, height_scale_value](HEGoSessionManager *mgr) -> godot::Variant {
				self->voxel_size = voxel_size_value;

				// Find reference image for dimensions
				godot::Ref<godot::Image> reference_image;
				const godot::Array layer_keys = layers.keys();
				for (int i = 0; i < layer_keys.size(); ++i)
				{
					const godot::Variant layer_variant = layers[layer_keys[i]];
					if (layer_variant.get_type() != godot::Variant::DICTIONARY)
						continue;
					const godot::Dictionary layer_dict = layer_variant;
					if (!layer_dict.has("image"))
						continue;
					const godot::Variant image_variant = layer_dict["image"];
					if (image_variant.get_type() != godot::Variant::OBJECT)
						continue;
					godot::Ref<godot::Image> image_ref = image_variant;
					if (image_ref.is_valid())
					{
						reference_image = image_ref;
						break;
					}
				}

				if (reference_image.is_valid())
				{
					self->x_size = reference_image->get_width();
					self->y_size = reference_image->get_height();
				}
				else
				{
					HEGo::Util::Log::error("No valid images found in layer dictionary");
					return -1;
				}

				if (self->x_size <= 0 || self->y_size <= 0)
				{
					self->x_size = 256;
					self->y_size = 256;
				}

				// Delete old node if exists
				if (self->node_id >= 0 && mgr->get_session() != nullptr)
				{
					HoudiniApi::DeleteNode(mgr->get_session(), self->node_id);
				}

				self->node_id = -1;
				self->height_node_id = -1;
				self->mask_node_id = -1;
				self->merge_node_id = -1;
				self->instantiate_internal(mgr);

				if (self->node_id < 0 || self->height_node_id < 0 || self->mask_node_id < 0 || self->merge_node_id < 0)
				{
					HEGo::Util::Log::error("Failed to initialize heightfield internals");
					return -1;
				}

				// Parse layer data
				std::map<std::string, std::vector<float>> layer_values;
				std::map<std::string, godot::Dictionary> layer_attrs;
				for (int i = 0; i < layer_keys.size(); ++i)
				{
					const godot::String layer_name_raw = layer_keys[i];
					const godot::String layer_name = layer_name_raw.to_lower().strip_edges();
					if (layer_name.is_empty())
						continue;

					const godot::Variant layer_variant = layers[layer_name_raw];
					if (layer_variant.get_type() != godot::Variant::DICTIONARY)
						continue;

					const godot::Dictionary layer_dict = layer_variant;
					std::vector<float> values(self->x_size * self->y_size, 0.0f);
					godot::Dictionary attrs;

					if (layer_dict.has("attrs") && godot::Variant(layer_dict["attrs"]).get_type() == godot::Variant::DICTIONARY)
					{
						attrs = layer_dict["attrs"];
					}

					if (layer_dict.has("image") && godot::Variant(layer_dict["image"]).get_type() == godot::Variant::OBJECT)
					{
						godot::Ref<godot::Image> layer_image = layer_dict["image"];
						if (layer_image.is_valid())
						{
							values = image_to_height_data(layer_image, self->x_size, self->y_size);
						}
					}

					const godot::CharString layer_name_cs = layer_name.utf8();
					const std::string layer_name_utf8 = std::string(layer_name_cs.get_data());
					layer_values[layer_name_utf8] = values;
					layer_attrs[layer_name_utf8] = attrs;
				}

				// Ensure height and mask exist
				if (layer_values.find("height") == layer_values.end())
				{
					layer_values["height"] = std::vector<float>(self->x_size * self->y_size, 0.0f);
					layer_attrs["height"] = godot::Dictionary();
				}
				if (layer_values.find("mask") == layer_values.end())
				{
					layer_values["mask"] = std::vector<float>(self->x_size * self->y_size, 0.0f);
					layer_attrs["mask"] = godot::Dictionary();
				}

				const HAPI_Session *session = mgr->get_session();

				HAPI_Transform volume_transform = HoudiniApi::Transform_Create();
				HoudiniApi::Transform_Init(&volume_transform);
				volume_transform.scale[0] = (static_cast<float>(self->x_size) * voxel_size_value) * 0.5f;
				volume_transform.scale[1] = (static_cast<float>(self->y_size) * voxel_size_value) * 0.5f;
				volume_transform.scale[2] = voxel_size_value * 0.5f;

				// Commit height layer (with scale)
				std::vector<float> scaled_height_values = layer_values["height"];
				if (height_scale_value != 1.0f)
				{
					for (size_t i = 0; i < scaled_height_values.size(); ++i)
					{
						scaled_height_values[i] *= height_scale_value;
					}
				}

				if (!commit_layer_to_node(session, volume_transform, "height", scaled_height_values, layer_attrs["height"], self->height_node_id))
				{
					return -1;
				}

				if (!commit_layer_to_node(session, volume_transform, "mask", layer_values["mask"], layer_attrs["mask"], self->mask_node_id))
				{
					return -1;
				}

				// Additional layers
				int next_merge_input = 2;
				for (std::map<std::string, std::vector<float>>::const_iterator it = layer_values.begin(); it != layer_values.end(); ++it)
				{
					if (it->first == "height" || it->first == "mask")
						continue;

					HAPI_NodeId extra_volume_id = -1;
					if (HoudiniApi::CreateHeightfieldInputVolumeNode(
								session, self->node_id, &extra_volume_id, it->first.c_str(), self->x_size, self->y_size, self->voxel_size) !=
							HAPI_RESULT_SUCCESS)
					{
						HEGo::Util::Log::error("Failed creating additional heightfield layer: " + godot::String(it->first.c_str()));
						continue;
					}

					if (!commit_layer_to_node(session, volume_transform, it->first, it->second, layer_attrs[it->first], extra_volume_id))
					{
						continue;
					}

					if (HoudiniApi::ConnectNodeInput(session, self->merge_node_id, next_merge_input, extra_volume_id, 0) == HAPI_RESULT_SUCCESS)
					{
						++next_merge_input;
					}
				}

				// Final cook
				HOUDINI_CHECK_ERROR(HoudiniApi::CookNode(session, self->node_id, nullptr));
				mgr->wait_for_ready();

				return 0;
			});
}

void HEGoHeightfieldInputNode::_bind_methods()
{
	godot::ClassDB::bind_method(
			godot::D_METHOD("set_layers", "layers", "voxel_size", "height_scale", "force"), &HEGoHeightfieldInputNode::set_layers, DEFVAL(1.0f), DEFVAL(1.0f), DEFVAL(false));
}

} // namespace HEGo
