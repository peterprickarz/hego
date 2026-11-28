#include "util/cop/cop_image_output.h"

#include "hapi/houdini_api.h"
#include "hego_session_manager.h"
#include "util/hego_util.h"

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <godot_cpp/core/math.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <limits>

namespace HEGo::Util::Cop
{
namespace
{
struct PixelLayout
{
	int channels;
	godot::Image::Format format;
	bool reversed;
};

PixelLayout pixel_layout(HAPI_ImagePacking packing)
{
	switch (packing)
	{
		case HAPI_IMAGE_PACKING_SINGLE:
			return { 1, godot::Image::FORMAT_RF, false };
		case HAPI_IMAGE_PACKING_DUAL:
			return { 2, godot::Image::FORMAT_RGF, false };
		case HAPI_IMAGE_PACKING_RGB:
			return { 3, godot::Image::FORMAT_RGBF, false };
		case HAPI_IMAGE_PACKING_BGR:
			return { 3, godot::Image::FORMAT_RGBF, true };
		case HAPI_IMAGE_PACKING_RGBA:
			return { 4, godot::Image::FORMAT_RGBAF, false };
		case HAPI_IMAGE_PACKING_ABGR:
			return { 4, godot::Image::FORMAT_RGBAF, true };
		default:
			return { 0, godot::Image::FORMAT_MAX, false };
	}
}

bool valid_dimensions(const HAPI_ImageInfo &info)
{
	return info.xRes > 0 && info.yRes > 0 && info.xRes <= godot::Image::MAX_WIDTH && info.yRes <= godot::Image::MAX_HEIGHT;
}

void widen_half_pixels(godot::PackedByteArray &bytes, int64_t sample_count)
{
	// Read backwards so the expanded float never overwrites an unread half.
	uint8_t *data = bytes.ptrw();
	for (int64_t i = sample_count - 1; i >= 0; --i)
	{
		uint16_t half;
		std::memcpy(&half, data + i * sizeof(half), sizeof(half));
		const float value = godot::Math::half_to_float(half);
		std::memcpy(data + i * sizeof(value), &value, sizeof(value));
	}
}

// HAPI's buffer starts at the bottom-left. Godot's uncompressed Image starts at the top-left.
void prepare_pixels(godot::PackedByteArray &bytes, const HAPI_ImageInfo &info, const PixelLayout &layout)
{
	uint8_t *data = bytes.ptrw();
	const size_t pixel_bytes = layout.channels * sizeof(float);
	const size_t row_bytes = info.xRes * pixel_bytes;
	for (int y = 0; y < info.yRes / 2; ++y)
	{
		uint8_t *row = data + y * row_bytes;
		std::swap_ranges(row, row + row_bytes, data + (info.yRes - 1 - y) * row_bytes);
	}
	if (layout.reversed)
	{
		const uint8_t *end = data + bytes.size();
		for (uint8_t *pixel = data; pixel < end; pixel += pixel_bytes)
		{
			for (int c = 0; c < layout.channels / 2; ++c)
			{
				uint8_t *channel = pixel + c * sizeof(float);
				std::swap_ranges(channel, channel + sizeof(float), pixel + (layout.channels - 1 - c) * sizeof(float));
			}
		}
	}
}
} // namespace

godot::Ref<godot::Image> fetch_image(
		HEGoSessionManager *manager, HAPI_NodeId asset_node_id, const godot::String &cop_path, const godot::String &output_name, godot::String &error)
{
	error = godot::String();
	if (!manager || asset_node_id < 0)
	{
		error = "Fetching a COP image requires an instantiated asset and a Houdini session.";
		return {};
	}
	if (!manager->validate_cop_transfer(error))
		return {};
	const HAPI_Session *session = manager->get_session();
	const godot::String source = cop_path.is_empty() ? godot::String("the asset") : "'" + cop_path + "'";
	godot::String context = (output_name.is_empty() ? godot::String("First COP output") : "COP output '" + output_name + "'") + " on " + source;
	auto check = [&](HAPI_Result result, const char *operation) {
		if (result == HAPI_RESULT_SUCCESS)
			return true;
		const godot::String detail = godot::String::utf8(Hapi::get_last_error(session).c_str());
		error = context + " failed during " + operation + " (HAPI " + godot::String::num_int64(result) + "). " + detail;
		return false;
	};

	HAPI_NodeId node = asset_node_id;
	if (!cop_path.is_empty())
	{
		const HAPI_NodeId parent = cop_path.begins_with("/") ? -1 : asset_node_id;
		if (!check(HoudiniApi::GetNodeFromPath(session, parent, cop_path.utf8().get_data(), &node), "path resolution"))
			return {};
	}
	HAPI_NodeInfo node_info{};
	if (!check(HoudiniApi::GetNodeInfo(session, node, &node_info), "node lookup"))
		return {};
	if (node_info.type != HAPI_NODETYPE_COP)
	{
		error = context + " requires a Copernicus node.";
		return {};
	}
	if (node_info.outputCount < 1)
	{
		error = context + " has no output connectors.";
		return {};
	}
	if (!output_name.is_empty())
	{
		bool found = false;
		for (int index = 0; index < node_info.outputCount; ++index)
		{
			HAPI_StringHandle name = -1;
			if (!check(HoudiniApi::GetNodeOutputName(session, node, index, &name), "output lookup"))
				return {};
			if (Hapi::get_godot_string(session, name) == output_name)
			{
				found = true;
				break;
			}
		}
		if (!found)
		{
			error = context + " does not exist.";
			return {};
		}
	}
	if (!check(HoudiniApi::RenderCOPOutputToImage(session, node, output_name.utf8().get_data()), "rendering"))
		return {};
	HAPI_ImageInfo info{};
	if (!check(HoudiniApi::GetImageInfo(session, node, &info), "reading image information"))
		return {};
	if (!valid_dimensions(info) || int64_t(info.xRes) * info.yRes > std::numeric_limits<int>::max() / int64_t(sizeof(float)))
	{
		error = context + " has dimensions outside the supported image buffer range.";
		return {};
	}
	if (info.dataFormat == HAPI_IMAGE_DATA_INT8 || info.dataFormat == HAPI_IMAGE_DATA_INT16 || info.dataFormat == HAPI_IMAGE_DATA_INT32)
	{
		error = context + " is an integer raster. A Godot float32 Image cannot preserve all integer IDs. "
						"Convert the COP layer to Mono or RGB in Houdini if you want a floating-point texture.";
		return {};
	}
	// HAPI 9 cannot extract a native half raster directly as float32.
	const bool use_half = info.dataFormat == HAPI_IMAGE_DATA_FLOAT16;
	info.dataFormat = use_half ? HAPI_IMAGE_DATA_FLOAT16 : HAPI_IMAGE_DATA_FLOAT32;
	info.interleaved = true;
	info.gamma = 1.0;
	if (!check(HoudiniApi::SetImageInfo(session, node, &info), "setting linear floating-point extraction"))
		return {};

	int buffer_size = 0;
	if (!check(HoudiniApi::ExtractImageToMemory(session, node, HAPI_RAW_FORMAT_NAME, "C A", &buffer_size), "extracting image pixels"))
		return {};
	// Copernicus determines its actual channel packing at extraction time.
	if (!check(HoudiniApi::GetImageInfo(session, node, &info), "reading the extracted image layout"))
		return {};
	const PixelLayout layout = pixel_layout(info.packing);
	if (!valid_dimensions(info) || !layout.channels || !info.interleaved ||
			(info.dataFormat != HAPI_IMAGE_DATA_FLOAT32 && info.dataFormat != HAPI_IMAGE_DATA_FLOAT16))
	{
		error = context + " returned an unsupported RAW pixel layout.";
		return {};
	}
	const int64_t sample_count = int64_t(info.xRes) * info.yRes * layout.channels;
	const bool is_half = info.dataFormat == HAPI_IMAGE_DATA_FLOAT16;
	const int64_t expected_size = sample_count * (is_half ? sizeof(uint16_t) : sizeof(float));
	if (buffer_size <= 0 || expected_size != buffer_size)
	{
		error = context + " returned " + godot::String::num_int64(buffer_size) + " bytes for an image requiring " + godot::String::num_int64(expected_size) +
				".";
		return {};
	}
	const int64_t image_bytes = sample_count * sizeof(float);
	if (image_bytes > std::numeric_limits<int>::max())
	{
		error = context + " exceeds the supported float32 image buffer range.";
		return {};
	}
	if (!manager->validate_cop_transfer(error, buffer_size))
		return {};
	godot::PackedByteArray bytes;
	if (bytes.resize(image_bytes) != 0)
	{
		error = context + " could not allocate the pixel buffer.";
		return {};
	}
	if (!check(HoudiniApi::GetImageMemoryBuffer(session, node, reinterpret_cast<char *>(bytes.ptrw()), buffer_size), "copying image pixels"))
		return {};
	if (is_half)
		widen_half_pixels(bytes, sample_count);
	prepare_pixels(bytes, info, layout);
	godot::Ref<godot::Image> image = godot::Image::create_from_data(info.xRes, info.yRes, false, layout.format, bytes);
	if (image.is_null() || image->is_empty())
	{
		error = context + " could not be stored in a Godot Image.";
		return {};
	}
	return image;
}
} // namespace HEGo::Util::Cop
