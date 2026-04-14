#include "fetch_heightfields.h"

#include "util/attrib/fetch_attribs.h"
#include "util/geo/part_selection.h"
#include "util/hego_util.h"
#include "util/log/log.h"

#include <algorithm>
#include <cstring>
#include <vector>

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/variant/vector3.hpp>

namespace HEGo
{
namespace Util
{
namespace Geo
{

godot::Array get_heightfield_layers(HEGoSessionManager *session_mgr, HAPI_NodeId node_id, const godot::PackedStringArray &read_prim_attribs, bool auto_cook)
{
	godot::Array layers;

	const HAPI_Result session_valid = HoudiniApi::IsSessionValid(session_mgr->get_session());
	if (session_valid != HAPI_RESULT_SUCCESS)
	{
		HEGo::Util::Log::error("Cannot get heightfield layers: invalid session.");
		return layers;
	}

	HAPI_GeoInfo geo_info;
	if (!get_display_geo_info(session_mgr, node_id, geo_info, auto_cook))
	{
		return layers;
	}

	std::vector<HAPI_PartInfo> volume_parts = get_parts_by_type(session_mgr->get_session(), geo_info, HAPI_PARTTYPE_VOLUME);
	std::sort(volume_parts.begin(), volume_parts.end(), [](const HAPI_PartInfo &a, const HAPI_PartInfo &b) { return a.id < b.id; });

	for (const HAPI_PartInfo &part_info : volume_parts)
	{
		HAPI_VolumeInfo volume_info;
		if (HoudiniApi::GetVolumeInfo(session_mgr->get_session(), geo_info.nodeId, part_info.id, &volume_info) != HAPI_RESULT_SUCCESS)
		{
			HEGo::Util::Log::error("Failed to read volume info for heightfield part id " + godot::String::num_int64(part_info.id));
			continue;
		}

		const godot::String layer_name = HEGoUtil::get_string(session_mgr->get_session(), volume_info.nameSH).c_str();
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
		layer["attrs"] = HEGo::Util::Attribs::read_attrib_pairs(session_mgr->get_session(), geo_info, part_info, HAPI_ATTROWNER_PRIM, read_prim_attribs);
		layer["voxel_count_x"] = volume_info.xLength;
		layer["voxel_count_y"] = volume_info.yLength;
		layer["voxel_scale_x"] = voxel_scale_x;
		layer["voxel_scale_y"] = voxel_scale_y;
		layer["transform_position"] = godot::Vector3(volume_info.transform.position[0], volume_info.transform.position[1], volume_info.transform.position[2]);
		layer["transform_rotation"] = rotation_euler;

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
		HEGo::Util::Log::error("Cannot fetch heightfield layer: invalid session.");
		return image;
	}

	HAPI_GeoInfo geo_info;
	if (!get_display_geo_info(session_mgr, node_id, geo_info, auto_cook))
	{
		return image;
	}

	HAPI_PartInfo part_info;
	if (HoudiniApi::GetPartInfo(session_mgr->get_session(), geo_info.nodeId, part_id, &part_info) != HAPI_RESULT_SUCCESS)
	{
		HEGo::Util::Log::error("Invalid part_id for heightfield layer fetch: " + godot::String::num_int64(part_id));
		return image;
	}

	if (part_info.type != HAPI_PARTTYPE_VOLUME)
	{
		HEGo::Util::Log::error("Requested part is not a volume part.");
		return image;
	}

	HAPI_VolumeInfo volume_info;
	if (HoudiniApi::GetVolumeInfo(session_mgr->get_session(), geo_info.nodeId, part_info.id, &volume_info) != HAPI_RESULT_SUCCESS)
	{
		HEGo::Util::Log::error("Failed to get volume info for part id " + godot::String::num_int64(part_id));
		return image;
	}

	const int voxel_count = volume_info.xLength * volume_info.yLength * volume_info.zLength;
	if (voxel_count <= 0)
	{
		HEGo::Util::Log::error("Volume has invalid dimensions for part id " + godot::String::num_int64(part_id));
		return image;
	}

	std::vector<float> values(voxel_count, 0.0f);
	if (HoudiniApi::GetHeightFieldData(session_mgr->get_session(), geo_info.nodeId, part_info.id, values.data(), 0, voxel_count) != HAPI_RESULT_SUCCESS)
	{
		HEGo::Util::Log::error("Failed to read heightfield voxel data for part id " + godot::String::num_int64(part_id));
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
		HEGo::Util::Log::error("Failed to create FORMAT_RF image for heightfield layer.");
		return image;
	}

	return image;
}

} // namespace Geo
} // namespace Util
} // namespace HEGo