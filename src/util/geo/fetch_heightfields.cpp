#include "fetch_heightfields.h"

#include "util/attrib/fetch_attribs.h"
#include "util/geo/geo_cache.h"
#include "util/geo/part_selection.h"
#include "util/hego_util.h"
#include "util/log/log.h"
#include "util/geo/heightfield_grid.h"

#include <algorithm>
#include <cstring>
#include <cmath>
#include <set>
#include <vector>

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/variant/vector3.hpp>
#include <godot_cpp/variant/vector3i.hpp>
#include <godot_cpp/variant/vector2i.hpp>

namespace HEGo
{
namespace Util
{
namespace Geo
{

namespace {
// Probe the volume's actual index-to-position mapping. HAPI 22 GetVolumeInfo
// loses real shear and can return uninitialized shear components, so its
// decomposed transform cannot safely establish an orthogonal sample lattice.
// Only these temporary nodes are created/deleted; source display flags and
// source geometry are never changed. Object Merge "None" preserves SOP space.
struct GridProbe {
	const HAPI_Session *session;
	HAPI_NodeId object = -1;
	HAPI_GeoInfo geometry{};
	explicit GridProbe(const HAPI_Session *p_session) : session(p_session) {}
	~GridProbe() { if (object >= 0) HoudiniApi::DeleteNode(session, object); }
	bool create(HEGoSessionManager *manager, const HAPI_GeoInfo &source, godot::String &error) {
		HAPI_NodeId merge = -1;
		HAPI_NodeId probe = -1;
		HAPI_ParmId snippet_id = -1;
		if (HoudiniApi::CreateNode(session, -1, "Object/geo", "HEGoFieldRead", false, &object) != HAPI_RESULT_SUCCESS ||
			HoudiniApi::CreateNode(session, object, "object_merge", "source", false, &merge) != HAPI_RESULT_SUCCESS ||
			HoudiniApi::SetParmNodeValue(session, merge, "objpath1", source.nodeId) != HAPI_RESULT_SUCCESS ||
			HoudiniApi::SetParmIntValue(session, merge, "xformtype", 0, 0) != HAPI_RESULT_SUCCESS ||
			HoudiniApi::CreateNode(session, object, "attribwrangle", "sample_grid", false, &probe) != HAPI_RESULT_SUCCESS ||
			HoudiniApi::ConnectNodeInput(session, probe, 0, merge, 0) != HAPI_RESULT_SUCCESS ||
			HoudiniApi::SetParmIntValue(session, probe, "class", 0, 1) != HAPI_RESULT_SUCCESS ||
			HoudiniApi::GetParmIdFromName(session, probe, "snippet", &snippet_id) != HAPI_RESULT_SUCCESS) {
			error = "Could not create the private heightfield sample-grid query.";
			return false;
		}
		const char *snippet = "v@__hego_q_origin = volumeindextopos(0, @primnum, set(0,0,0));\n"
			"vector resolution = volumeres(0, @primnum);\n"
			"matrix3 frame = primintrinsic(0, 'transform', @primnum);\n"
			"v@__hego_q_x = set(2.0/resolution.x,0,0) * frame;\n"
			"v@__hego_q_y = set(0,2.0/resolution.y,0) * frame;\n"
			"i@__hego_q_primitive = @primnum;\n";
		int state = HAPI_STATE_MAX;
		if (HoudiniApi::SetParmStringValue(session, probe, snippet, snippet_id, 0) != HAPI_RESULT_SUCCESS ||
			HoudiniApi::CookNode(session, probe, manager->get_cook_options()) != HAPI_RESULT_SUCCESS || !manager->wait_for_ready() ||
			HoudiniApi::GetStatus(session, HAPI_STATUS_COOK_STATE, &state) != HAPI_RESULT_SUCCESS || state != HAPI_STATE_READY ||
			HoudiniApi::GetGeoInfo(session, probe, &geometry) != HAPI_RESULT_SUCCESS || geometry.partCount != source.partCount) {
			error = "The private sample-grid query failed or changed the source part layout.";
			return false;
		}
		return true;
	}
	bool read(const HAPI_PartInfo &source_part, const HAPI_VolumeInfo &source_volume, HeightfieldGrid &grid, int &primitive_index, godot::String &error) const {
		HAPI_PartInfo part{};
		HAPI_VolumeInfo volume{};
		if (!validate_heightfield_volume_shape(source_volume, error)) return false;
		if (HoudiniApi::GetPartInfo(session, geometry.nodeId, source_part.id, &part) != HAPI_RESULT_SUCCESS || part.type != HAPI_PARTTYPE_VOLUME || part.id != source_part.id ||
			HoudiniApi::GetVolumeInfo(session, geometry.nodeId, part.id, &volume) != HAPI_RESULT_SUCCESS ||
			volume.xLength != source_volume.xLength || volume.yLength != source_volume.yLength || volume.zLength != source_volume.zLength ||
			HEGo::Util::Hapi::get_string(session, volume.nameSH) != HEGo::Util::Hapi::get_string(session, source_volume.nameSH)) {
			error = "Private heightfield query did not preserve per-part identity.";
			return false;
		}
		godot::Vector3 vectors[3];
		const char *names[3] = {"__hego_q_origin", "__hego_q_x", "__hego_q_y"};
		for (int i = 0; i < 3; ++i) {
			HAPI_AttributeInfo info{};
			float values[3] = {};
			if (HoudiniApi::GetAttributeInfo(session, geometry.nodeId, part.id, names[i], HAPI_ATTROWNER_PRIM, &info) != HAPI_RESULT_SUCCESS || !info.exists || info.count != 1 || info.tupleSize != 3 ||
				HoudiniApi::GetAttributeFloatData(session, geometry.nodeId, part.id, names[i], &info, -1, values, 0, 1) != HAPI_RESULT_SUCCESS) {
				error = "Could not read the exact per-part heightfield sample-grid query.";
				return false;
			}
			vectors[i] = godot::Vector3(values[0], values[1], values[2]);
		}
		HAPI_AttributeInfo identity{};
		if (HoudiniApi::GetAttributeInfo(session, geometry.nodeId, part.id, "__hego_q_primitive", HAPI_ATTROWNER_PRIM, &identity) != HAPI_RESULT_SUCCESS ||
			HoudiniApi::GetAttributeIntData(session, geometry.nodeId, part.id, "__hego_q_primitive", &identity, -1, &primitive_index, 0, 1) != HAPI_RESULT_SUCCESS) {
			error = "Could not read the heightfield's original primitive identity.";
			return false;
		}
		grid = {volume.xLength, volume.yLength, vectors[0], vectors[1], vectors[2]};
		return validate_heightfield_grid(grid, error);
	}
};

void add_grid_metadata(const HAPI_Session *session, const HAPI_VolumeInfo &volume, godot::Dictionary &metadata, const HeightfieldGrid *probed = nullptr) {
	HeightfieldGrid grid;
	godot::String error;
	bool valid = false;
	if (probed) {
		grid = *probed;
		valid = validate_heightfield_volume_shape(volume, error) && validate_heightfield_grid(grid, error);
	} else valid = heightfield_grid_from_volume(session, volume, grid, error);
	metadata["coordinate_space"] = "sop_local";
	metadata["grid_valid"] = valid;
	metadata["grid_error"] = error;
	metadata["resolution"] = godot::Vector2i(volume.xLength, volume.yLength);
	metadata["volume_resolution"] = godot::Vector3i(volume.xLength, volume.yLength, volume.zLength);
	metadata["volume_min_index"] = godot::Vector3i(volume.minX, volume.minY, volume.minZ);
	metadata["volume_type"] = int(volume.type);
	metadata["tuple_size"] = volume.tupleSize;
	metadata["storage"] = int(volume.storage);
	metadata["tile_size"] = volume.tileSize;
	metadata["has_taper"] = bool(volume.hasTaper);
	if (valid) {
		metadata["sample_origin"] = grid.origin;
		metadata["sample_step_x"] = grid.step_x;
		metadata["sample_step_y"] = grid.step_y;
		metadata["voxel_size_x"] = grid_vector_length(grid.step_x);
		metadata["voxel_size_y"] = grid_vector_length(grid.step_y);
	}
}

bool read_field_attributes(const HAPI_Session *session, HAPI_NodeId node, const HAPI_PartInfo &part, const godot::PackedStringArray &requested, godot::Dictionary &attrs, godot::String &error) {
	godot::PackedStringArray names = requested;
	if (names.is_empty()) {
		const int count = part.attributeCounts[HAPI_ATTROWNER_PRIM];
		std::vector<HAPI_StringHandle> handles(count);
		if (count > 0 && HoudiniApi::GetAttributeNames(session, node, part.id, HAPI_ATTROWNER_PRIM, handles.data(), count) != HAPI_RESULT_SUCCESS) {
			error = "Could not enumerate heightfield primitive attributes.";
			return false;
		}
		for (HAPI_StringHandle handle : handles) names.push_back(HEGo::Util::Hapi::get_string(session, handle).c_str());
	}
	for (int i = 0; i < names.size(); ++i) {
		const godot::String name = names[i];
		if (name == "name") continue;
		const godot::CharString bytes = name.utf8();
		HAPI_AttributeInfo info = HoudiniApi::AttributeInfo_Create();
		if (HoudiniApi::GetAttributeInfo(session, node, part.id, bytes.get_data(), HAPI_ATTROWNER_PRIM, &info) != HAPI_RESULT_SUCCESS) {
			error = "Could not read heightfield attribute metadata: " + name;
			return false;
		}
		if (!info.exists) continue;
		if (info.count != 1 || (info.tupleSize != 1 && info.tupleSize != 3)) {
			error = "Unsupported heightfield attribute tuple/count: " + name;
			return false;
		}
		HAPI_Result result = HAPI_RESULT_FAILURE;
		godot::Variant value;
		if ((info.storage == HAPI_STORAGETYPE_INT || info.storage == HAPI_STORAGETYPE_INT64) && info.tupleSize == 1) {
			HAPI_Int64 integer = 0;
			if (info.storage == HAPI_STORAGETYPE_INT) {
				int number = 0;
				result = HoudiniApi::GetAttributeIntData(session, node, part.id, bytes.get_data(), &info, -1, &number, 0, 1);
				integer = number;
			} else result = HoudiniApi::GetAttributeInt64Data(session, node, part.id, bytes.get_data(), &info, -1, &integer, 0, 1);
			value = static_cast<int64_t>(integer);
		} else if (info.storage == HAPI_STORAGETYPE_FLOAT || info.storage == HAPI_STORAGETYPE_FLOAT64) {
			double numbers[3] = {};
			if (info.storage == HAPI_STORAGETYPE_FLOAT) {
				float floats[3] = {};
				result = HoudiniApi::GetAttributeFloatData(session, node, part.id, bytes.get_data(), &info, -1, floats, 0, 1);
				for (int component = 0; component < info.tupleSize; ++component) numbers[component] = floats[component];
			} else result = HoudiniApi::GetAttributeFloat64Data(session, node, part.id, bytes.get_data(), &info, -1, numbers, 0, 1);
			for (int component = 0; component < info.tupleSize; ++component) {
				if (!std::isfinite(numbers[component])) {
					error = "Nonfinite heightfield attribute: " + name;
					return false;
				}
			}
			if (info.tupleSize == 1) value = numbers[0];
			else {
				const godot::Vector3 vector(numbers[0], numbers[1], numbers[2]);
				if (!finite_vector(vector)) {
					error = "Heightfield Vector3 attribute exceeds float32 range: " + name;
					return false;
				}
				value = vector;
			}
		} else if (info.storage == HAPI_STORAGETYPE_STRING && info.tupleSize == 1) {
			HAPI_StringHandle handle = 0;
			result = HoudiniApi::GetAttributeStringData(session, node, part.id, bytes.get_data(), &info, &handle, 0, 1);
			value = godot::String(HEGo::Util::Hapi::get_string(session, handle).c_str());
		} else {
			error = "Unsupported heightfield primitive attribute storage: " + name;
			return false;
		}
		if (result != HAPI_RESULT_SUCCESS) {
			error = "Could not read heightfield primitive attribute: " + name;
			return false;
		}
		attrs[name] = value;
	}
	return true;
}
} // namespace

godot::Array get_heightfield_layers(HEGoSessionManager *session_mgr, HAPI_NodeId node_id, const godot::PackedStringArray &read_prim_attribs, bool auto_cook)
{
	godot::Array layers;

	const HAPI_Result session_valid = HoudiniApi::IsSessionValid(session_mgr->get_session());
	if (session_valid != HAPI_RESULT_SUCCESS)
	{
		HEGo::Util::Log::error(HEGo::Util::Log::Category::OUTPUT, "Cannot get heightfield layers: invalid session.");
		return layers;
	}

	std::shared_ptr<GeoCache> cache = GeoCache::acquire(session_mgr, node_id, auto_cook);
	if (!cache)
	{
		return layers;
	}
	const HAPI_GeoInfo &geo_info = cache->geo_info();

	std::vector<HAPI_PartInfo> volume_parts = get_parts_by_type(session_mgr->get_session(), geo_info, HAPI_PARTTYPE_VOLUME);
	std::sort(volume_parts.begin(), volume_parts.end(), [](const HAPI_PartInfo &a, const HAPI_PartInfo &b) { return a.id < b.id; });

	for (const HAPI_PartInfo &part_info : volume_parts)
	{
		HAPI_VolumeInfo volume_info{};
		if (HoudiniApi::GetVolumeInfo(session_mgr->get_session(), geo_info.nodeId, part_info.id, &volume_info) != HAPI_RESULT_SUCCESS)
		{
			HEGo::Util::Log::error(HEGo::Util::Log::Category::OUTPUT, "Failed to read volume info for heightfield part id " + godot::String::num_int64(part_info.id));
			continue;
		}

		const godot::String layer_name = HEGo::Util::Hapi::get_string(session_mgr->get_session(), volume_info.nameSH).c_str();
		const float voxel_scale_x = volume_info.transform.scale[0] * 2.0f;
		const float voxel_scale_y = volume_info.transform.scale[1] * 2.0f;

		godot::Vector3 rotation_euler(
				volume_info.transform.rotationQuaternion[0], volume_info.transform.rotationQuaternion[1], volume_info.transform.rotationQuaternion[2]);
		float rotation_matrix[16] = {};
		if (HoudiniApi::ConvertTransformQuatToMatrix(session_mgr->get_session(), &volume_info.transform, rotation_matrix) == HAPI_RESULT_SUCCESS)
		{
			HAPI_TransformEuler euler_transform = HoudiniApi::TransformEuler_Create();
			HoudiniApi::TransformEuler_Init(&euler_transform);
			if (HoudiniApi::ConvertMatrixToEuler(session_mgr->get_session(), rotation_matrix, volume_info.transform.rstOrder, HAPI_ZXY, &euler_transform) ==
					HAPI_RESULT_SUCCESS)
			{
				rotation_euler = godot::Vector3(euler_transform.rotationEuler[0], euler_transform.rotationEuler[1], euler_transform.rotationEuler[2]);
			}
		}

		godot::Dictionary layer;

		layer["part_id"] = part_info.id;
		layer["layer_name"] = layer_name;
		layer["name"] = layer_name;
		layer["attrs"] = cache->attribute_pairs(part_info, HAPI_ATTROWNER_PRIM, read_prim_attribs);
		layer["voxel_count_x"] = volume_info.xLength;
		layer["voxel_count_y"] = volume_info.yLength;
		layer["voxel_scale_x"] = voxel_scale_x;
		layer["voxel_scale_y"] = voxel_scale_y;
		layer["transform_position"] = godot::Vector3(volume_info.transform.position[0], volume_info.transform.position[1], volume_info.transform.position[2]);
		layer["transform_rotation"] = rotation_euler;
		// Exact indexed sample metadata is available through the new strict
		// get_heightfield_fields API. Keep legacy discovery free of extra cooks.

		layers.append(layer);
	}

	return layers;
}

godot::Ref<godot::Image> fetch_heightfield_layer_image(HEGoSessionManager *session_mgr, HAPI_NodeId node_id, int part_id, bool auto_cook)
{
	godot::Ref<godot::Image> image;

	const HAPI_Result session_valid = HoudiniApi::IsSessionValid(session_mgr->get_session());
	if (session_valid != HAPI_RESULT_SUCCESS)
	{
		HEGo::Util::Log::error(HEGo::Util::Log::Category::OUTPUT, "Cannot fetch heightfield layer: invalid session.");
		return image;
	}

	std::shared_ptr<GeoCache> cache = GeoCache::acquire(session_mgr, node_id, auto_cook);
	if (!cache)
	{
		return image;
	}
	const HAPI_GeoInfo &geo_info = cache->geo_info();

	HAPI_PartInfo part_info;
	if (HoudiniApi::GetPartInfo(session_mgr->get_session(), geo_info.nodeId, part_id, &part_info) != HAPI_RESULT_SUCCESS)
	{
		HEGo::Util::Log::error(HEGo::Util::Log::Category::OUTPUT, "Invalid part_id for heightfield layer fetch: " + godot::String::num_int64(part_id));
		return image;
	}

	if (part_info.type != HAPI_PARTTYPE_VOLUME)
	{
		HEGo::Util::Log::error(HEGo::Util::Log::Category::OUTPUT, "Requested part is not a volume part.");
		return image;
	}

	HAPI_VolumeInfo volume_info{};
	if (HoudiniApi::GetVolumeInfo(session_mgr->get_session(), geo_info.nodeId, part_info.id, &volume_info) != HAPI_RESULT_SUCCESS)
	{
		HEGo::Util::Log::error(HEGo::Util::Log::Category::OUTPUT, "Failed to get volume info for part id " + godot::String::num_int64(part_id));
		return image;
	}

	const int voxel_count = volume_info.xLength * volume_info.yLength * volume_info.zLength;
	if (voxel_count <= 0)
	{
		HEGo::Util::Log::error(HEGo::Util::Log::Category::OUTPUT, "Volume has invalid dimensions for part id " + godot::String::num_int64(part_id));
		return image;
	}

	std::vector<float> values(voxel_count, 0.0f);
	if (HoudiniApi::GetHeightFieldData(session_mgr->get_session(), geo_info.nodeId, part_info.id, values.data(), 0, voxel_count) != HAPI_RESULT_SUCCESS)
	{
		HEGo::Util::Log::error(HEGo::Util::Log::Category::OUTPUT, "Failed to read heightfield voxel data for part id " + godot::String::num_int64(part_id));
		return image;
	}

	godot::PackedByteArray image_bytes;
	image_bytes.resize(voxel_count * static_cast<int>(sizeof(float)));
	if (voxel_count > 0)
	{
		std::memcpy(image_bytes.ptrw(), values.data(), image_bytes.size());
	}

	image = godot::Image::create_from_data(volume_info.xLength, volume_info.yLength, false, godot::Image::FORMAT_RF, image_bytes);
	if (image.is_null())
	{
		HEGo::Util::Log::error(HEGo::Util::Log::Category::OUTPUT, "Failed to create FORMAT_RF image for heightfield layer.");
		return image;
	}

	return image;
}

bool fetch_heightfield_fields(HEGoSessionManager *session_mgr, HAPI_NodeId node_id,
		const godot::PackedStringArray &read_prim_attribs, godot::Array &result, godot::String &error, bool auto_cook) {
	result.clear();
	if (!session_mgr || !session_mgr->get_session() || HoudiniApi::IsSessionValid(session_mgr->get_session()) != HAPI_RESULT_SUCCESS) {
		error = "Cannot fetch heightfield fields: invalid Houdini session.";
		return false;
	}
	const HAPI_Session *session = session_mgr->get_session();
	HAPI_GeoInfo geo = HoudiniApi::GeoInfo_Create();
	if (!get_display_geo_info(session_mgr, node_id, geo, auto_cook)) {
		error = "Could not read heightfield display geometry.";
		return false;
	}
	int cook_state = HAPI_STATE_MAX;
	if (HoudiniApi::GetStatus(session, HAPI_STATUS_COOK_STATE, &cook_state) != HAPI_RESULT_SUCCESS || cook_state != HAPI_STATE_READY) {
		error = "Heightfield cook did not complete cleanly; no stale or partial fields are published.";
		return false;
	}
	godot::Array complete;
	GridProbe probe(session);
	if (!probe.create(session_mgr, geo, error)) return false;
	int64_t total_samples = 0;
	for (int index = 0; index < geo.partCount; ++index) {
		HAPI_PartInfo part = HoudiniApi::PartInfo_Create();
		if (HoudiniApi::GetPartInfo(session, geo.nodeId, index, &part) != HAPI_RESULT_SUCCESS) {
			error = "Could not inspect every output geometry part; no partial field result is published.";
			return false;
		}
		if (part.type == HAPI_PARTTYPE_INSTANCER || part.isInstanced) {
			error = "Instanced heightfield geometry is unsupported; explicit sample grids are required.";
			return false;
		}
		if (part.type != HAPI_PARTTYPE_VOLUME) continue;
		HAPI_VolumeInfo volume{};
		HeightfieldGrid grid;
		if (HoudiniApi::GetVolumeInfo(session, geo.nodeId, part.id, &volume) != HAPI_RESULT_SUCCESS) {
			error = "Could not read output heightfield volume information.";
			return false;
		}
		int primitive_index = -1;
		if (!probe.read(part, volume, grid, primitive_index, error)) return false;
		const std::string name = HEGo::Util::Hapi::get_string(session, volume.nameSH);
		if (name.empty()) {
			error = "Output heightfield names must be nonempty, preserving exact case.";
			return false;
		}
		const int64_t count = int64_t(grid.width) * grid.height;
		total_samples += count;
		if (complete.size() >= 64 || total_samples > 67108864) {
			error = "Heightfield output exceeds the 64-field or 64-million-sample transport limit.";
			return false;
		}
		std::vector<float> values(count);
		if (HoudiniApi::GetHeightFieldData(session, geo.nodeId, part.id, values.data(), 0, count) != HAPI_RESULT_SUCCESS) {
			error = "Could not read all scalar samples for field " + godot::String(name.c_str());
			return false;
		}
		for (float value : values) {
			if (!std::isfinite(value)) {
				error = "Output heightfield contains nonfinite scalar samples: " + godot::String(name.c_str());
				return false;
			}
		}
		godot::Dictionary attrs;
		if (!read_field_attributes(session, geo.nodeId, part, read_prim_attribs, attrs, error)) return false;
		godot::PackedByteArray bytes;
		bytes.resize(count * sizeof(float));
		std::memcpy(bytes.ptrw(), values.data(), count * sizeof(float));
		const godot::Ref<godot::Image> image = godot::Image::create_from_data(grid.width, grid.height, false, godot::Image::FORMAT_RF, bytes);
		if (image.is_null()) {
			error = "Could not construct a complete RF field image.";
			return false;
		}
		godot::Dictionary field;
		add_grid_metadata(session, volume, field, &grid);
		field["name"] = godot::String(name.c_str());
		field["layer_name"] = godot::String(name.c_str());
		field["part_id"] = part.id;
		field["primitive_index"] = primitive_index;
		field["image"] = image;
		field["attrs"] = attrs;
		complete.push_back(field);
	}
	result = complete;
	return true;
}

} // namespace Geo
} // namespace Util
} // namespace HEGo
