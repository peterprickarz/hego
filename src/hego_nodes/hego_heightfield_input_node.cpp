#include "hego_nodes/hego_heightfield_input_node.h"

#include "hego_api.h"
#include "util/hash/fnv.h"
#include "util/hego_util.h"
#include "util/log/log.h"
#include "util/task/task_helpers.h"
#include "util/geo/heightfield_grid.h"
#include "util/geo/geo_cache.h"

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>
#include <memory>
#include <set>
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

struct FieldAttribute {
	std::string name;
	godot::Variant value;
};

struct FieldSnapshot {
	std::string name;
	HEGo::Util::Geo::HeightfieldGrid grid;
	HAPI_Transform transform;
	std::vector<float> samples;
	std::vector<FieldAttribute> attrs;
};

bool valid_c_string(const godot::String &value) {
	const godot::CharString bytes = value.utf8();
	return !value.strip_edges().is_empty() && std::strlen(bytes.get_data()) == static_cast<size_t>(bytes.length());
}

bool snapshot_fields(const godot::Array &source, std::vector<FieldSnapshot> &fields, uint64_t &hash, godot::String &error) {
	using namespace HEGo::Util::Hash;
	if (source.size() > 64) {
		error = "At most 64 explicit heightfield fields are supported per upload.";
		return false;
	}
	std::set<std::string> names;
	int64_t total_samples = 0;
	hash = hash_combine(FNV_OFFSET, static_cast<uint64_t>(source.size()));
	for (int i = 0; i < source.size(); ++i) {
		if (godot::Variant(source[i]).get_type() != godot::Variant::DICTIONARY) {
			error = "Each heightfield field must be a Dictionary.";
			return false;
		}
		const godot::Dictionary item = source[i];
		for (const char *required : {"name", "image", "sample_origin", "sample_step_x", "sample_step_y"}) {
			if (!item.has(required)) {
				error = godot::String("Heightfield field is missing '") + required + "'.";
				return false;
			}
		}
		const godot::Variant name_variant = item["name"];
		if ((name_variant.get_type() != godot::Variant::STRING && name_variant.get_type() != godot::Variant::STRING_NAME) || !valid_c_string(name_variant)) {
			error = "Heightfield field names must be nonempty strings without embedded NUL characters.";
			return false;
		}
		FieldSnapshot field;
		const godot::String name = name_variant;
		field.name = name.utf8().get_data();
		if (!names.insert(field.name).second) {
			error = "Duplicate exact heightfield field name: " + name;
			return false;
		}
		const godot::Variant image_variant = item["image"];
		godot::Ref<godot::Image> image = image_variant.get_type() == godot::Variant::OBJECT ? godot::Ref<godot::Image>(image_variant) : godot::Ref<godot::Image>();
		if (image.is_null() || image->is_compressed() || image->get_format() != godot::Image::FORMAT_RF || image->get_width() <= 0 || image->get_height() <= 0) {
			error = "Explicit heightfield images must be nonempty uncompressed FORMAT_RF Images; no format conversion or resizing is performed.";
			return false;
		}
		for (const char *key : {"sample_origin", "sample_step_x", "sample_step_y"}) {
			if (godot::Variant(item[key]).get_type() != godot::Variant::VECTOR3) {
				error = godot::String(key) + " must be a Vector3 in SOP-local Houdini coordinates.";
				return false;
			}
		}
		field.grid = {image->get_width(), image->get_height(), item["sample_origin"], item["sample_step_x"], item["sample_step_y"]};
		if (!HEGo::Util::Geo::volume_transform_from_heightfield_grid(field.grid, field.transform, error)) {
			return false;
		}
		const int64_t count = int64_t(field.grid.width) * field.grid.height;
		total_samples += count;
		if (total_samples > 536870912) {
			error = "Explicit heightfield upload exceeds the 512 Mi total-sample limit.";
			return false;
		}
		const godot::PackedByteArray bytes = image->get_data();
		if (bytes.size() < count * int64_t(sizeof(float))) {
			error = "Heightfield RF image has incomplete pixel storage.";
			return false;
		}
		field.samples.resize(count);
		std::memcpy(field.samples.data(), bytes.ptr(), count * sizeof(float));
		for (float value : field.samples) {
			if (!std::isfinite(value)) {
				error = "Heightfield scalar samples must all be finite float32 values.";
				return false;
			}
		}
		godot::Dictionary attrs;
		if (item.has("attrs")) {
			if (godot::Variant(item["attrs"]).get_type() != godot::Variant::DICTIONARY) {
				error = "Heightfield attrs must be a Dictionary.";
				return false;
			}
			attrs = item["attrs"];
		}
		const godot::Array keys = attrs.keys();
		for (int a = 0; a < keys.size(); ++a) {
			const godot::Variant key = keys[a];
			if (key.get_type() != godot::Variant::STRING || !valid_c_string(key) || godot::String(key) == "name") {
				error = "Primitive attribute keys must be nonempty strings; 'name' is reserved for the exact field name.";
				return false;
			}
			const godot::Variant value = attrs[key];
			const auto type = value.get_type();
			if (type != godot::Variant::BOOL && type != godot::Variant::INT && type != godot::Variant::FLOAT && type != godot::Variant::STRING && type != godot::Variant::VECTOR3) {
				error = "Supported primitive attribute values are bool, int, float, String and Vector3.";
				return false;
			}
			if ((type == godot::Variant::FLOAT && !std::isfinite(static_cast<double>(value))) || (type == godot::Variant::VECTOR3 && !HEGo::Util::Geo::finite_vector(value))) {
				error = "Primitive numeric attributes must be finite.";
				return false;
			}
			if (type == godot::Variant::STRING) {
				const godot::CharString string_bytes = godot::String(value).utf8();
				if (std::strlen(string_bytes.get_data()) != static_cast<size_t>(string_bytes.length())) {
					error = "Primitive string attributes cannot contain embedded NUL characters.";
					return false;
				}
			}
			field.attrs.push_back({godot::String(key).utf8().get_data(), value});
		}
		std::sort(field.attrs.begin(), field.attrs.end(), [](const FieldAttribute &a, const FieldAttribute &b) { return a.name < b.name; });
		hash = hash_string(name, hash);
		hash = hash_combine(hash, field.grid.width);
		hash = hash_combine(hash, field.grid.height);
		for (godot::Vector3 vector : {field.grid.origin, field.grid.step_x, field.grid.step_y}) {
			for (int axis = 0; axis < 3; ++axis) hash = hash_float(vector[axis], hash);
		}
		for (float value : field.samples) hash = hash_float(value, hash);
		for (const FieldAttribute &attr : field.attrs) {
			hash = hash_string(godot::String(attr.name.c_str()), hash);
			hash = hash_combine(hash, attr.value.get_type());
			hash = hash_combine(hash, attr.value.hash());
		}
		fields.push_back(std::move(field));
	}
	return true;
}

bool write_field_attrs(const HAPI_Session *session, HAPI_NodeId node, const std::vector<FieldAttribute> &attrs) {
	for (const FieldAttribute &attr : attrs) {
		HAPI_AttributeInfo info{};
		info.exists = true;
		info.owner = HAPI_ATTROWNER_PRIM;
		info.originalOwner = HAPI_ATTROWNER_PRIM;
		info.typeInfo = HAPI_ATTRIBUTE_TYPE_NONE;
		info.count = 1;
		info.tupleSize = attr.value.get_type() == godot::Variant::VECTOR3 ? 3 : 1;
		switch (attr.value.get_type()) {
			case godot::Variant::BOOL:
			case godot::Variant::INT: info.storage = HAPI_STORAGETYPE_INT64; break;
			case godot::Variant::FLOAT: info.storage = HAPI_STORAGETYPE_FLOAT64; break;
			case godot::Variant::VECTOR3: info.storage = HAPI_STORAGETYPE_FLOAT; break;
			case godot::Variant::STRING: info.storage = HAPI_STORAGETYPE_STRING; break;
			default: return false;
		}
		if (HoudiniApi::AddAttribute(session, node, 0, attr.name.c_str(), &info) != HAPI_RESULT_SUCCESS) return false;
		HAPI_Result result = HAPI_RESULT_FAILURE;
		if (info.storage == HAPI_STORAGETYPE_INT64) {
			const HAPI_Int64 value = static_cast<int64_t>(attr.value);
			result = HoudiniApi::SetAttributeInt64Data(session, node, 0, attr.name.c_str(), &info, &value, 0, 1);
		} else if (info.storage == HAPI_STORAGETYPE_FLOAT64) {
			const double value = attr.value;
			result = HoudiniApi::SetAttributeFloat64Data(session, node, 0, attr.name.c_str(), &info, &value, 0, 1);
		} else if (info.storage == HAPI_STORAGETYPE_FLOAT) {
			const godot::Vector3 value = attr.value;
			const float values[3] = {value.x, value.y, value.z};
			result = HoudiniApi::SetAttributeFloatData(session, node, 0, attr.name.c_str(), &info, values, 0, 1);
		} else {
			const godot::CharString value = godot::String(attr.value).utf8();
			const char *pointer = value.get_data();
			result = HoudiniApi::SetAttributeStringData(session, node, 0, attr.name.c_str(), &info, &pointer, 0, 1);
		}
		if (result != HAPI_RESULT_SUCCESS) return false;
	}
	return true;
}

static void debug_log(const godot::String &message)
{
	if (kHeightfieldDebugLogs)
	{
		HEGo::Util::Log::debug(HEGo::Util::Log::Category::INPUT, "[HFDBG] " + message);
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
			HEGo::Util::Log::error(HEGo::Util::Log::Category::INPUT, "image_to_height_data: failed to decompress image");
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
					HEGo::Util::Log::warning(HEGo::Util::Log::Category::INPUT, "Failed to add prim attr '" + attr_name + "'");
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
					HEGo::Util::Log::warning(HEGo::Util::Log::Category::INPUT, "Failed to add prim attr '" + attr_name + "'");
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
					HEGo::Util::Log::warning(HEGo::Util::Log::Category::INPUT, "Failed to add prim attr '" + attr_name + "'");
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
					HEGo::Util::Log::warning(HEGo::Util::Log::Category::INPUT, "Failed to add prim attr '" + attr_name + "'");
					break;
				}
				HoudiniApi::SetAttributeFloatData(session, volume_node_id, 0, attr_name_utf8.c_str(), &attr_info, vec_data, 0, 1);
				break;
			}

			default:
				HEGo::Util::Log::warning(HEGo::Util::Log::Category::INPUT, "Unsupported prim attr type for '" + attr_name + "'");
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
		HEGo::Util::Log::error(HEGo::Util::Log::Category::INPUT, "Failed cooking layer node: " + godot::String(layer_name.c_str()));
		return false;
	}

	HAPI_GeoInfo geo_info = HoudiniApi::GeoInfo_Create();
	HoudiniApi::GeoInfo_Init(&geo_info);
	if (HoudiniApi::GetGeoInfo(session, target_node, &geo_info) != HAPI_RESULT_SUCCESS)
	{
		HEGo::Util::Log::error(HEGo::Util::Log::Category::INPUT, "Failed fetching geo info for layer: " + godot::String(layer_name.c_str()));
		return false;
	}

	HAPI_PartInfo part_info = HoudiniApi::PartInfo_Create();
	HoudiniApi::PartInfo_Init(&part_info);
	if (HoudiniApi::GetPartInfo(session, geo_info.nodeId, 0, &part_info) != HAPI_RESULT_SUCCESS)
	{
		HEGo::Util::Log::error(HEGo::Util::Log::Category::INPUT, "Failed fetching part info for layer: " + godot::String(layer_name.c_str()));
		return false;
	}

	HAPI_VolumeInfo volume_info = HoudiniApi::VolumeInfo_Create();
	HoudiniApi::VolumeInfo_Init(&volume_info);
	if (HoudiniApi::GetVolumeInfo(session, geo_info.nodeId, 0, &volume_info) != HAPI_RESULT_SUCCESS)
	{
		HEGo::Util::Log::error(HEGo::Util::Log::Category::INPUT, "Failed fetching volume info for layer: " + godot::String(layer_name.c_str()));
		return false;
	}

	volume_info.tileSize = 1;
	volume_info.type = HAPI_VOLUMETYPE_HOUDINI;
	volume_info.transform = volume_transform;

	if (HoudiniApi::SetVolumeInfo(session, target_node, 0, &volume_info) != HAPI_RESULT_SUCCESS)
	{
		HEGo::Util::Log::error(HEGo::Util::Log::Category::INPUT, "Failed setting volume info for layer: " + godot::String(layer_name.c_str()));
		return false;
	}

	const int total_size = volume_info.xLength * volume_info.yLength;
	std::vector<float> values = input_values;
	if (total_size <= 0)
	{
		HEGo::Util::Log::error(HEGo::Util::Log::Category::INPUT, "Invalid volume size for layer: " + godot::String(layer_name.c_str()));
		return false;
	}

	if (static_cast<int>(values.size()) != total_size)
	{
		values.resize(total_size, 0.0f);
	}

	if (values.empty())
	{
		HEGo::Util::Log::error(HEGo::Util::Log::Category::INPUT, "No voxel data to write for layer: " + godot::String(layer_name.c_str()));
		return false;
	}

	std::string volume_name = HEGo::Util::Hapi::get_string(session, volume_info.nameSH);
	if (volume_name.empty())
	{
		volume_name = layer_name;
	}

	if (HoudiniApi::SetHeightFieldData(session, target_node, 0, volume_name.c_str(), values.data(), 0, total_size) != HAPI_RESULT_SUCCESS)
	{
		HEGo::Util::Log::error(HEGo::Util::Log::Category::INPUT, "Failed setting heightfield data for layer: " + godot::String(layer_name.c_str()));
		return false;
	}

	if (!attrs.is_empty())
	{
		apply_prim_attributes(session, target_node, attrs);
	}

	if (HoudiniApi::CommitGeo(session, target_node) != HAPI_RESULT_SUCCESS)
	{
		HEGo::Util::Log::error(HEGo::Util::Log::Category::INPUT, "Failed committing geo for layer: " + godot::String(layer_name.c_str()));
		return false;
	}

	return true;
}
} // namespace

HEGoHeightfieldInputNode::HEGoHeightfieldInputNode() : height_node_id(-1), mask_node_id(-1), merge_node_id(-1), x_size(256), y_size(256), voxel_size(1.0f) {}

HEGoHeightfieldInputNode::~HEGoHeightfieldInputNode() {}

void HEGoHeightfieldInputNode::reset_node_id()
{
	std::lock_guard<std::mutex> guard(fields_state_mutex);
	HEGoBaseInputNode::reset_node_id();
	height_node_id = -1;
	mask_node_id = -1;
	merge_node_id = -1;
	last_layers_hash = 0;
	last_fields_hash = 0;
	has_fields_hash = false;
	fields_object_id = -1;
	fields_unique_node_id = -1;
	fields_epoch.fetch_add(1, std::memory_order_release);
}

void HEGoHeightfieldInputNode::instantiate_internal(HEGoSessionManager *session_mgr)
{
	if (node_id >= 0)
	{
		return;
	}

	if (session_mgr == nullptr || session_mgr->get_session() == nullptr)
	{
		HEGo::Util::Log::error(HEGo::Util::Log::Category::INPUT, "No active Houdini session for heightfield node instantiation");
		return;
	}

	const godot::String hf_name = node_name.is_empty() ? godot::String("HEGoHeightfieldInput") : node_name;
	const HAPI_Result result = HoudiniApi::CreateHeightFieldInput(session_mgr->get_session(), -1, hf_name.utf8().get_data(), x_size, y_size, voxel_size,
			HAPI_HEIGHTFIELD_SAMPLING_CENTER, &node_id, &height_node_id, &mask_node_id, &merge_node_id);

	if (result != HAPI_RESULT_SUCCESS)
	{
		HEGo::Util::Log::error(HEGo::Util::Log::Category::INPUT, "Failed to create heightfield input node");
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
	// A reference, not a raw pointer: the task runs on the worker thread and must not
	// find this node destroyed underneath it if the owning script is freed meanwhile.
	godot::Ref<HEGoHeightfieldInputNode> self = this;

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

	// Held by reference for the same reason as in instantiate(), and for longer: this
	// task carries the full layer images and outlives most others.
	godot::Ref<HEGoHeightfieldInputNode> self = this;

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
					HEGo::Util::Log::error(HEGo::Util::Log::Category::INPUT, "No valid images found in layer dictionary");
					return -1;
				}

				if (self->x_size <= 0 || self->y_size <= 0)
				{
					self->x_size = 256;
					self->y_size = 256;
				}

				// Switching back to the legacy API invalidates the explicit-field
				// cache and retires its private OBJ container, not only its merge.
				self->has_fields_hash = false;
				if (self->fields_object_id >= 0 && mgr->get_session() != nullptr)
				{
					HoudiniApi::DeleteNode(mgr->get_session(), self->fields_object_id);
					self->fields_object_id = -1;
					self->node_id = -1;
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
					HEGo::Util::Log::error(HEGo::Util::Log::Category::INPUT, "Failed to initialize heightfield internals");
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
						HEGo::Util::Log::error(HEGo::Util::Log::Category::INPUT, "Failed creating additional heightfield layer: " + godot::String(it->first.c_str()));
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

godot::Ref<HEGoTask> HEGoHeightfieldInputNode::set_fields(godot::Array source_fields, bool force)
{
	std::vector<FieldSnapshot> snapshots;
	uint64_t hash = 0;
	godot::String error;
	// All Image reads and validation happen before enqueueing. The task captures
	// independent float buffers and scalar/string attributes, never caller images
	// or dictionaries that could change while the worker is using them.
	if (!snapshot_fields(source_fields, snapshots, hash, error)) {
		return make_failed(error, "Set heightfield fields", node_id);
	}
	HEGoSessionManager *manager = get_session_manager();
	if (!manager || !manager->get_session()) {
		return make_failed("No Houdini session manager is available.", "Set heightfield fields", node_id);
	}
	const HAPI_Session expected_session = *manager->get_session();
	const uint64_t expected_epoch = fields_epoch.load(std::memory_order_acquire);
	const auto fields = std::make_shared<const std::vector<FieldSnapshot>>(std::move(snapshots));
	const godot::String requested_name = node_name.is_empty() ? godot::String("HEGoFields") : node_name;
	godot::Ref<HEGoHeightfieldInputNode> self = this;
	return HEGo::Util::Task::submit_failable("Set heightfield fields", node_id,
			[self, fields, hash, force, expected_session, expected_epoch, requested_name](HEGoSessionManager *mgr, HEGoTask *task) -> godot::Variant {
				HAPI_Session *session = mgr ? mgr->get_session() : nullptr;
				if (!session || session->id != expected_session.id || session->type != expected_session.type || self->fields_epoch.load(std::memory_order_acquire) != expected_epoch || HoudiniApi::IsSessionValid(session) != HAPI_RESULT_SUCCESS) {
					HEGo::Util::Task::fail(task, "The Houdini session changed or became invalid before this field upload ran.");
					return godot::Variant();
				}
				{
					std::lock_guard<std::mutex> guard(self->fields_state_mutex);
					HAPI_Bool valid_cached_node = false;
					if (self->fields_epoch.load(std::memory_order_acquire) == expected_epoch && !force && self->has_fields_hash && self->last_fields_hash == hash && self->fields_session.id == session->id && self->fields_session.type == session->type && self->node_id >= 0 && HoudiniApi::IsNodeValid(session, self->node_id, self->fields_unique_node_id, &valid_cached_node) == HAPI_RESULT_SUCCESS && valid_cached_node) {
						return 0;
					}
				}
				HAPI_NodeId new_object = -1;
				HAPI_NodeId new_merge = -1;
				const auto fail_upload = [&](const godot::String &message) -> godot::Variant {
					const godot::String detail = HEGo::Util::Hapi::get_last_error(session).c_str();
					if (new_object >= 0 && session->id == expected_session.id && session->type == expected_session.type) HoudiniApi::DeleteNode(session, new_object);
					HEGo::Util::Task::fail(task, message + godot::String(": ") + detail);
					return godot::Variant();
				};
				const auto cook = [&](HAPI_NodeId id) {
					int state = HAPI_STATE_MAX;
					return HoudiniApi::CookNode(session, id, mgr->get_cook_options()) == HAPI_RESULT_SUCCESS && mgr->wait_for_ready() && HoudiniApi::GetStatus(session, HAPI_STATUS_COOK_STATE, &state) == HAPI_RESULT_SUCCESS && state == HAPI_STATE_READY;
				};
				if (HoudiniApi::CreateNode(session, -1, "Object/geo", requested_name.utf8().get_data(), false, &new_object) != HAPI_RESULT_SUCCESS || HoudiniApi::CreateNode(session, new_object, "merge", "fields", false, &new_merge) != HAPI_RESULT_SUCCESS) {
					return fail_upload("Could not create the replacement heightfield container");
				}
				for (size_t index = 0; index < fields->size(); ++index) {
					const FieldSnapshot &field = fields->at(index);
					HAPI_NodeId volume = -1;
					// Creation dimensions are world-size-like when voxel size differs
					// from one. Use 1 here, then write explicit resolution and transform.
					if (HoudiniApi::CreateHeightfieldInputVolumeNode(session, new_object, &volume, field.name.c_str(), field.grid.width, field.grid.height, 1.0f) != HAPI_RESULT_SUCCESS || !cook(volume)) {
						return fail_upload("Could not create heightfield volume " + godot::String(field.name.c_str()));
					}
					HAPI_VolumeInfo info{};
					if (HoudiniApi::GetVolumeInfo(session, volume, 0, &info) != HAPI_RESULT_SUCCESS) return fail_upload("Could not query replacement volume information");
					info.xLength = field.grid.width;
					info.yLength = field.grid.height;
					info.zLength = 1;
					info.minX = info.minY = info.minZ = 0;
					info.tupleSize = 1;
					info.storage = HAPI_STORAGETYPE_FLOAT;
					info.type = HAPI_VOLUMETYPE_HOUDINI;
					info.tileSize = 1;
					info.hasTaper = false;
					info.transform = field.transform;
					// HAPI 22's dense heightfield setter discards quaternion rotation.
					// Upload an axis-aligned centered grid and apply its physical frame
					// with a private built-in Transform SOP, without resampling voxels.
					for (int axis = 0; axis < 3; ++axis) info.transform.position[axis] = 0.0f;
					info.transform.rotationQuaternion[0] = info.transform.rotationQuaternion[1] = info.transform.rotationQuaternion[2] = 0.0f;
					info.transform.rotationQuaternion[3] = 1.0f;
					if (HoudiniApi::SetVolumeInfo(session, volume, 0, &info) != HAPI_RESULT_SUCCESS || HoudiniApi::SetHeightFieldData(session, volume, 0, field.name.c_str(), field.samples.data(), 0, static_cast<int>(field.samples.size())) != HAPI_RESULT_SUCCESS || !write_field_attrs(session, volume, field.attrs) || HoudiniApi::CommitGeo(session, volume) != HAPI_RESULT_SUCCESS) {
						return fail_upload("Could not upload complete heightfield volume " + godot::String(field.name.c_str()));
					}
					float matrix[16] = {};
					HAPI_TransformEuler frame{};
					HAPI_NodeId oriented = -1;
					if (HoudiniApi::ConvertTransformQuatToMatrix(session, &field.transform, matrix) != HAPI_RESULT_SUCCESS || HoudiniApi::ConvertMatrixToEuler(session, matrix, HAPI_SRT, HAPI_XYZ, &frame) != HAPI_RESULT_SUCCESS || HoudiniApi::CreateNode(session, new_object, "xform", "field_basis", false, &oriented) != HAPI_RESULT_SUCCESS || HoudiniApi::ConnectNodeInput(session, oriented, 0, volume, 0) != HAPI_RESULT_SUCCESS) {
						return fail_upload("Could not create heightfield sample-frame transform");
					}
					for (int axis = 0; axis < 3; ++axis) {
						if (HoudiniApi::SetParmFloatValue(session, oriented, "t", axis, field.transform.position[axis]) != HAPI_RESULT_SUCCESS || HoudiniApi::SetParmFloatValue(session, oriented, "r", axis, frame.rotationEuler[axis]) != HAPI_RESULT_SUCCESS) {
							return fail_upload("Could not set the exact heightfield sample frame");
						}
					}
					if (HoudiniApi::ConnectNodeInput(session, new_merge, index, oriented, 0) != HAPI_RESULT_SUCCESS) return fail_upload("Could not connect an oriented heightfield volume");
				}
				if (HoudiniApi::SetNodeDisplay(session, new_merge, 1) != HAPI_RESULT_SUCCESS || !cook(new_merge)) {
					return fail_upload("Replacement heightfield merge did not cook successfully");
				}
				HAPI_GeoInfo geo = HoudiniApi::GeoInfo_Create();
				HAPI_NodeInfo node_info = HoudiniApi::NodeInfo_Create();
				if (HoudiniApi::GetGeoInfo(session, new_merge, &geo) != HAPI_RESULT_SUCCESS || geo.partCount != static_cast<int>(fields->size()) || HoudiniApi::GetNodeInfo(session, new_merge, &node_info) != HAPI_RESULT_SUCCESS) {
					return fail_upload("Replacement heightfield merge has incomplete geometry");
				}
				// Publish only after every field and the final merge succeeded.
				HAPI_NodeId old_node = -1;
				HAPI_NodeId old_object = -1;
				{
				std::lock_guard<std::mutex> guard(self->fields_state_mutex);
				if (self->fields_epoch.load(std::memory_order_acquire) != expected_epoch || session->id != expected_session.id || session->type != expected_session.type) {
					return fail_upload("The heightfield node or session was reset during the upload; replacement was not published");
				}
				old_node = self->node_id;
				old_object = self->fields_object_id;
				self->node_id = new_merge;
				self->fields_object_id = new_object;
				self->merge_node_id = new_merge;
				self->height_node_id = self->mask_node_id = -1;
				self->fields_unique_node_id = node_info.uniqueHoudiniNodeId;
				self->fields_session = *session;
				self->last_fields_hash = hash;
				self->has_fields_hash = true;
				self->last_layers_hash = 0;
				{
					std::lock_guard<std::mutex> transform_guard(self->transform_cache_mutex);
					self->has_cached_transform = false;
				}
				self->node_generation.fetch_add(1, std::memory_order_acq_rel);
				}
					mgr->register_node(self.ptr());
					HEGo::Util::Geo::GeoCache::invalidate(new_merge);
				const HAPI_NodeId retired = old_object >= 0 ? old_object : old_node;
				if (retired >= 0 && HoudiniApi::DeleteNode(session, retired) != HAPI_RESULT_SUCCESS) {
					HEGo::Util::Log::warning(HEGo::Util::Log::Category::INPUT, "Published replacement fields, but could not delete the retired input node.");
				}
					if (old_node >= 0) HEGo::Util::Geo::GeoCache::invalidate(old_node);
				return 0;
			});
}

void HEGoHeightfieldInputNode::_bind_methods()
{
	godot::ClassDB::bind_method(
			godot::D_METHOD("set_layers", "layers", "voxel_size", "height_scale", "force"), &HEGoHeightfieldInputNode::set_layers, DEFVAL(1.0f), DEFVAL(1.0f), DEFVAL(false));
	godot::ClassDB::bind_method(godot::D_METHOD("set_fields", "fields", "force"), &HEGoHeightfieldInputNode::set_fields, DEFVAL(false));
}

} // namespace HEGo
