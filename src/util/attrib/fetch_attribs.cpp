#include "util/attrib/fetch_attribs.h"

#include "util/hego_util.h"
#include "util/log/log.h"

#include "fetch_attribs.h"
#include <vector>

#include "godot_cpp/classes/json.hpp"

namespace HEGo
{
namespace Util
{
namespace Attribs
{
godot::Variant fetch_dict(
		const HAPI_Session *session, const HAPI_GeoInfo &mesh_geo_info, const HAPI_PartInfo &mesh_part_info, HAPI_AttributeOwner owner, const char *attrib_name)
{
	HAPI_AttributeInfo attrib_info;
	HOUDINI_CHECK_ERROR(HoudiniApi::GetAttributeInfo(session, mesh_geo_info.nodeId, mesh_part_info.id, attrib_name, owner, &attrib_info));

	if (!attrib_info.exists)
	{
		return godot::Variant();
	}

	// Verify that the attribute is a dictionary type
	if (attrib_info.storage != HAPI_STORAGETYPE_DICTIONARY)
	{
		HEGo::Util::Log::error(godot::String(attrib_name) + " is not a dictionary attribute!");
		return godot::Variant();
	}

	// Allocate array for string handles
	std::vector<HAPI_StringHandle> temp_data(attrib_info.count * attrib_info.tupleSize);
	HOUDINI_CHECK_ERROR(HoudiniApi::GetAttributeDictionaryData(
			session, mesh_geo_info.nodeId, mesh_part_info.id, attrib_name, &attrib_info, temp_data.data(), 0, attrib_info.count));

	godot::Array attrib_data;
	for (int i = 0; i < attrib_info.count * attrib_info.tupleSize; ++i)
	{
		// Retrieve the string immediately as handles are only valid until the next call
		std::string json_string = HEGoUtil::get_string(session, temp_data[i]);
		if (json_string.empty())
		{
			attrib_data.append(godot::Variant());
			continue;
		}
		// Parse the JSON string into a Godot dictionary
		godot::Variant parsed = godot::JSON::parse_string(json_string.c_str());
		if (parsed.get_type() == godot::Variant::DICTIONARY)
		{
			attrib_data.append(parsed);
		}
		else
		{
			HEGo::Util::Log::error(godot::String(attrib_name) + " contains invalid JSON dictionary format at index: " + std::to_string(i).c_str());
		}
	}

	HEGo::Util::Log::message(godot::String(attrib_name) + " dictionary attribute count: " + std::to_string(attrib_data.size()).c_str());
	return attrib_data;
}
godot::Variant fetch_float(
		const HAPI_Session *session, const HAPI_GeoInfo &mesh_geo_info, const HAPI_PartInfo &mesh_part_info, HAPI_AttributeOwner owner, const char *attrib_name)
{
	HAPI_AttributeInfo attrib_info;
	HOUDINI_CHECK_ERROR(HoudiniApi::GetAttributeInfo(session, mesh_geo_info.nodeId, mesh_part_info.id, attrib_name, owner, &attrib_info));

	if (!attrib_info.exists)
	{
		return godot::Variant();
	}

	if (attrib_info.tupleSize != 1)
	{
		HEGo::Util::Log::error(godot::String(attrib_name) + " has wrong tuple size!");
		return godot::Variant();
	}

	std::vector<float> temp_data(attrib_info.count);
	HOUDINI_CHECK_ERROR(HoudiniApi::GetAttributeFloatData(
			session, mesh_geo_info.nodeId, mesh_part_info.id, attrib_name, &attrib_info, -1, temp_data.data(), 0, attrib_info.count));

	godot::Array attrib_data;
	for (float value : temp_data)
	{
		attrib_data.append(value);
	}
	HEGo::Util::Log::message(godot::String(attrib_name) + " attribute count: " + std::to_string(attrib_data.size()).c_str());
	return attrib_data;
}

godot::Variant fetch_vector2(
		const HAPI_Session *session, const HAPI_GeoInfo &mesh_geo_info, const HAPI_PartInfo &mesh_part_info, HAPI_AttributeOwner owner, const char *attrib_name)
{
	HAPI_AttributeInfo attrib_info;
	HOUDINI_CHECK_ERROR(HoudiniApi::GetAttributeInfo(session, mesh_geo_info.nodeId, mesh_part_info.id, attrib_name, owner, &attrib_info));

	if (!attrib_info.exists)
	{
		return godot::Variant();
	}

	if (attrib_info.tupleSize != 2)
	{
		HEGo::Util::Log::error(godot::String(attrib_name) + " has wrong tuple size!");
		return godot::Variant();
	}

	std::vector<float> temp_data(attrib_info.count * 2);
	HOUDINI_CHECK_ERROR(HoudiniApi::GetAttributeFloatData(
			session, mesh_geo_info.nodeId, mesh_part_info.id, attrib_name, &attrib_info, -1, temp_data.data(), 0, attrib_info.count));

	godot::Array attrib_data;
	for (size_t i = 0; i < temp_data.size(); i += 2)
	{
		attrib_data.append(godot::Vector2(temp_data[i], temp_data[i + 1]));
	}
	HEGo::Util::Log::message(godot::String(attrib_name) + " attribute count: " + std::to_string(attrib_data.size()).c_str());
	return attrib_data;
}

godot::Variant fetch_vector3(
		const HAPI_Session *session, const HAPI_GeoInfo &mesh_geo_info, const HAPI_PartInfo &mesh_part_info, HAPI_AttributeOwner owner, const char *attrib_name)
{
	HAPI_AttributeInfo attrib_info;
	HOUDINI_CHECK_ERROR(HoudiniApi::GetAttributeInfo(session, mesh_geo_info.nodeId, mesh_part_info.id, attrib_name, owner, &attrib_info));

	if (!attrib_info.exists)
	{
		return godot::Variant();
	}

	if (attrib_info.tupleSize != 3)
	{
		HEGo::Util::Log::error(godot::String(attrib_name) + " has wrong tuple size!");
		return godot::Variant();
	}

	std::vector<float> temp_data(attrib_info.count * 3);
	HOUDINI_CHECK_ERROR(HoudiniApi::GetAttributeFloatData(
			session, mesh_geo_info.nodeId, mesh_part_info.id, attrib_name, &attrib_info, -1, temp_data.data(), 0, attrib_info.count));

	godot::Array attrib_data;
	for (size_t i = 0; i < temp_data.size(); i += 3)
	{
		attrib_data.append(godot::Vector3(temp_data[i], temp_data[i + 1], temp_data[i + 2]));
	}
	HEGo::Util::Log::message(godot::String(attrib_name) + " attribute count: " + std::to_string(attrib_data.size()).c_str());
	return attrib_data;
}

godot::Variant fetch_vector4(
		const HAPI_Session *session, const HAPI_GeoInfo &mesh_geo_info, const HAPI_PartInfo &mesh_part_info, HAPI_AttributeOwner owner, const char *attrib_name)
{
	HAPI_AttributeInfo attrib_info;
	HOUDINI_CHECK_ERROR(HoudiniApi::GetAttributeInfo(session, mesh_geo_info.nodeId, mesh_part_info.id, attrib_name, owner, &attrib_info));

	if (!attrib_info.exists)
	{
		return godot::Variant();
	}

	if (attrib_info.tupleSize != 4)
	{
		HEGo::Util::Log::error(godot::String(attrib_name) + " has wrong tuple size!");
		return godot::Variant();
	}

	std::vector<float> temp_data(attrib_info.count * 4);
	HOUDINI_CHECK_ERROR(HoudiniApi::GetAttributeFloatData(
			session, mesh_geo_info.nodeId, mesh_part_info.id, attrib_name, &attrib_info, -1, temp_data.data(), 0, attrib_info.count));

	godot::Array attrib_data;
	for (size_t i = 0; i < temp_data.size(); i += 4)
	{
		attrib_data.append(godot::Vector4(temp_data[i], temp_data[i + 1], temp_data[i + 2], temp_data[i + 3]));
	}
	HEGo::Util::Log::message(godot::String(attrib_name) + " attribute count: " + std::to_string(attrib_data.size()).c_str());
	return attrib_data;
}

godot::Variant fetch_int(
		const HAPI_Session *session, const HAPI_GeoInfo &mesh_geo_info, const HAPI_PartInfo &mesh_part_info, HAPI_AttributeOwner owner, const char *attrib_name)
{
	HAPI_AttributeInfo attrib_info;
	HOUDINI_CHECK_ERROR(HoudiniApi::GetAttributeInfo(session, mesh_geo_info.nodeId, mesh_part_info.id, attrib_name, owner, &attrib_info));

	if (!attrib_info.exists)
	{
		return godot::Variant();
	}

	if (attrib_info.tupleSize != 1)
	{
		HEGo::Util::Log::error(godot::String(attrib_name) + " has wrong tuple size!");
		return godot::Variant();
	}

	std::vector<int> temp_data(attrib_info.count);
	HOUDINI_CHECK_ERROR(HoudiniApi::GetAttributeIntData(
			session, mesh_geo_info.nodeId, mesh_part_info.id, attrib_name, &attrib_info, -1, temp_data.data(), 0, attrib_info.count));

	godot::Array attrib_data;
	for (int value : temp_data)
	{
		attrib_data.append(value);
	}
	HEGo::Util::Log::message(godot::String(attrib_name) + " attribute count: " + std::to_string(attrib_data.size()).c_str());
	return attrib_data;
}

godot::Variant fetch_vector2i(
		const HAPI_Session *session, const HAPI_GeoInfo &mesh_geo_info, const HAPI_PartInfo &mesh_part_info, HAPI_AttributeOwner owner, const char *attrib_name)
{
	HAPI_AttributeInfo attrib_info;
	HOUDINI_CHECK_ERROR(HoudiniApi::GetAttributeInfo(session, mesh_geo_info.nodeId, mesh_part_info.id, attrib_name, owner, &attrib_info));

	if (!attrib_info.exists)
	{
		return godot::Variant();
	}

	if (attrib_info.tupleSize != 2)
	{
		HEGo::Util::Log::error(godot::String(attrib_name) + " has wrong tuple size!");
		return godot::Variant();
	}

	std::vector<int> temp_data(attrib_info.count * 2);
	HOUDINI_CHECK_ERROR(HoudiniApi::GetAttributeIntData(
			session, mesh_geo_info.nodeId, mesh_part_info.id, attrib_name, &attrib_info, -1, temp_data.data(), 0, attrib_info.count));

	godot::Array attrib_data;
	for (size_t i = 0; i < temp_data.size(); i += 2)
	{
		attrib_data.append(godot::Vector2i(temp_data[i], temp_data[i + 1]));
	}
	HEGo::Util::Log::message(godot::String(attrib_name) + " attribute count: " + std::to_string(attrib_data.size()).c_str());
	return attrib_data;
}

godot::Variant fetch_vector3i(
		const HAPI_Session *session, const HAPI_GeoInfo &mesh_geo_info, const HAPI_PartInfo &mesh_part_info, HAPI_AttributeOwner owner, const char *attrib_name)
{
	HAPI_AttributeInfo attrib_info;
	HOUDINI_CHECK_ERROR(HoudiniApi::GetAttributeInfo(session, mesh_geo_info.nodeId, mesh_part_info.id, attrib_name, owner, &attrib_info));

	if (!attrib_info.exists)
	{
		return godot::Variant();
	}

	if (attrib_info.tupleSize != 3)
	{
		HEGo::Util::Log::error(godot::String(attrib_name) + " has wrong tuple size!");
		return godot::Variant();
	}

	std::vector<int> temp_data(attrib_info.count * 3);
	HOUDINI_CHECK_ERROR(HoudiniApi::GetAttributeIntData(
			session, mesh_geo_info.nodeId, mesh_part_info.id, attrib_name, &attrib_info, -1, temp_data.data(), 0, attrib_info.count));

	godot::Array attrib_data;
	for (size_t i = 0; i < temp_data.size(); i += 3)
	{
		attrib_data.append(godot::Vector3i(temp_data[i], temp_data[i + 1], temp_data[i + 2]));
	}
	HEGo::Util::Log::message(godot::String(attrib_name) + " attribute count: " + std::to_string(attrib_data.size()).c_str());
	return attrib_data;
}

godot::Variant fetch_vector4i(
		const HAPI_Session *session, const HAPI_GeoInfo &mesh_geo_info, const HAPI_PartInfo &mesh_part_info, HAPI_AttributeOwner owner, const char *attrib_name)
{
	HAPI_AttributeInfo attrib_info;
	HOUDINI_CHECK_ERROR(HoudiniApi::GetAttributeInfo(session, mesh_geo_info.nodeId, mesh_part_info.id, attrib_name, owner, &attrib_info));

	if (!attrib_info.exists)
	{
		return godot::Variant();
	}

	if (attrib_info.tupleSize != 4)
	{
		HEGo::Util::Log::error(godot::String(attrib_name) + " has wrong tuple size!");
		return godot::Variant();
	}

	std::vector<int> temp_data(attrib_info.count * 4);
	HOUDINI_CHECK_ERROR(HoudiniApi::GetAttributeIntData(
			session, mesh_geo_info.nodeId, mesh_part_info.id, attrib_name, &attrib_info, -1, temp_data.data(), 0, attrib_info.count));

	godot::Array attrib_data;
	for (size_t i = 0; i < temp_data.size(); i += 4)
	{
		attrib_data.append(godot::Vector4i(temp_data[i], temp_data[i + 1], temp_data[i + 2], temp_data[i + 3]));
	}
	HEGo::Util::Log::message(godot::String(attrib_name) + " attribute count: " + std::to_string(attrib_data.size()).c_str());
	return attrib_data;
}

godot::Variant fetch_string(
		const HAPI_Session *session, const HAPI_GeoInfo &mesh_geo_info, const HAPI_PartInfo &mesh_part_info, HAPI_AttributeOwner owner, const char *attrib_name)
{
	HAPI_AttributeInfo attrib_info;
	HOUDINI_CHECK_ERROR(HoudiniApi::GetAttributeInfo(session, mesh_geo_info.nodeId, mesh_part_info.id, attrib_name, owner, &attrib_info));

	if (!attrib_info.exists)
	{
		return godot::Variant();
	}

	if (attrib_info.tupleSize != 1)
	{
		HEGo::Util::Log::error(godot::String(attrib_name) + " has wrong tuple size!");
		return godot::Variant();
	}

	std::vector<int> string_handles(attrib_info.count);
	HOUDINI_CHECK_ERROR(HoudiniApi::GetAttributeStringData(
			session, mesh_geo_info.nodeId, mesh_part_info.id, attrib_name, &attrib_info, string_handles.data(), 0, attrib_info.count));

	godot::Array attrib_data;
	for (int handle : string_handles)
	{
		int buffer_length;
		HOUDINI_CHECK_ERROR(HoudiniApi::GetStringBufLength(session, handle, &buffer_length));

		std::vector<char> buffer(buffer_length);
		HOUDINI_CHECK_ERROR(HoudiniApi::GetString(session, handle, buffer.data(), buffer_length));

		attrib_data.append(godot::String(buffer.data()));
	}
	HEGo::Util::Log::message(godot::String(attrib_name) + " attribute count: " + std::to_string(attrib_data.size()).c_str());
	return attrib_data;
}

godot::Variant fetch_by_name(
		const HAPI_Session *session, const HAPI_GeoInfo &mesh_geo_info, const HAPI_PartInfo &mesh_part_info, HAPI_AttributeOwner owner, const char *attrib_name)
{
	godot::Array values;

	HAPI_AttributeInfo attrib_info;
	HOUDINI_CHECK_ERROR(HoudiniApi::GetAttributeInfo(session, mesh_geo_info.nodeId, mesh_part_info.id, attrib_name, owner, &attrib_info));
	if (!attrib_info.exists)
	{
		if (owner == HAPI_ATTROWNER_PRIM)
		{
			values.resize(mesh_part_info.faceCount);
		}
		else if (owner == HAPI_ATTROWNER_POINT)
		{
			values.resize(mesh_part_info.pointCount);
		}
		else if (owner == HAPI_ATTROWNER_VERTEX)
		{
			values.resize(mesh_part_info.vertexCount);
		}
		else if (owner == HAPI_ATTROWNER_DETAIL)
		{
			values.resize(1);
		}

		return values;
	}

	if (attrib_info.storage == HAPI_STORAGETYPE_INT)
	{
		if (attrib_info.tupleSize == 1)
		{
			std::vector<int> temp_data(attrib_info.count);
			HOUDINI_CHECK_ERROR(HoudiniApi::GetAttributeIntData(
					session, mesh_geo_info.nodeId, mesh_part_info.id, attrib_name, &attrib_info, -1, temp_data.data(), 0, attrib_info.count));
			values.resize(attrib_info.count);
			for (int i = 0; i < attrib_info.count; ++i)
			{
				values[i] = temp_data[i];
			}
		}
		else if (attrib_info.tupleSize == 2)
		{
			std::vector<int> temp_data(attrib_info.count * 2);
			HOUDINI_CHECK_ERROR(HoudiniApi::GetAttributeIntData(
					session, mesh_geo_info.nodeId, mesh_part_info.id, attrib_name, &attrib_info, -1, temp_data.data(), 0, attrib_info.count));
			values.resize(attrib_info.count);
			for (int i = 0; i < attrib_info.count; ++i)
			{
				values[i] = godot::Vector2i(temp_data[i * 2], temp_data[i * 2 + 1]);
			}
		}
		else if (attrib_info.tupleSize == 3)
		{
			std::vector<int> temp_data(attrib_info.count * 3);
			HOUDINI_CHECK_ERROR(HoudiniApi::GetAttributeIntData(
					session, mesh_geo_info.nodeId, mesh_part_info.id, attrib_name, &attrib_info, -1, temp_data.data(), 0, attrib_info.count));
			values.resize(attrib_info.count);
			for (int i = 0; i < attrib_info.count; ++i)
			{
				values[i] = godot::Vector3i(temp_data[i * 3], temp_data[i * 3 + 1], temp_data[i * 3 + 2]);
			}
		}
		else if (attrib_info.tupleSize == 4)
		{
			std::vector<int> temp_data(attrib_info.count * 4);
			HOUDINI_CHECK_ERROR(HoudiniApi::GetAttributeIntData(
					session, mesh_geo_info.nodeId, mesh_part_info.id, attrib_name, &attrib_info, -1, temp_data.data(), 0, attrib_info.count));
			values.resize(attrib_info.count);
			for (int i = 0; i < attrib_info.count; ++i)
			{
				values[i] = godot::Vector4i(temp_data[i * 4], temp_data[i * 4 + 1], temp_data[i * 4 + 2], temp_data[i * 4 + 3]);
			}
		}
	}
	else if (attrib_info.storage == HAPI_STORAGETYPE_FLOAT)
	{
		if (attrib_info.tupleSize == 1)
		{
			std::vector<float> temp_data(attrib_info.count);
			HOUDINI_CHECK_ERROR(HoudiniApi::GetAttributeFloatData(
					session, mesh_geo_info.nodeId, mesh_part_info.id, attrib_name, &attrib_info, -1, temp_data.data(), 0, attrib_info.count));
			values.resize(attrib_info.count);
			for (int i = 0; i < attrib_info.count; ++i)
			{
				values[i] = temp_data[i];
			}
		}
		else if (attrib_info.tupleSize == 2)
		{
			std::vector<float> temp_data(attrib_info.count * 2);
			HOUDINI_CHECK_ERROR(HoudiniApi::GetAttributeFloatData(
					session, mesh_geo_info.nodeId, mesh_part_info.id, attrib_name, &attrib_info, -1, temp_data.data(), 0, attrib_info.count));
			values.resize(attrib_info.count);
			for (int i = 0; i < attrib_info.count; ++i)
			{
				values[i] = godot::Vector2(temp_data[i * 2], temp_data[i * 2 + 1]);
			}
		}
		else if (attrib_info.tupleSize == 3)
		{
			std::vector<float> temp_data(attrib_info.count * 3);
			HOUDINI_CHECK_ERROR(HoudiniApi::GetAttributeFloatData(
					session, mesh_geo_info.nodeId, mesh_part_info.id, attrib_name, &attrib_info, -1, temp_data.data(), 0, attrib_info.count));
			values.resize(attrib_info.count);
			for (int i = 0; i < attrib_info.count; ++i)
			{
				values[i] = godot::Vector3(temp_data[i * 3], temp_data[i * 3 + 1], temp_data[i * 3 + 2]);
			}
		}
		else if (attrib_info.tupleSize == 4)
		{
			std::vector<float> temp_data(attrib_info.count * 4);
			HOUDINI_CHECK_ERROR(HoudiniApi::GetAttributeFloatData(
					session, mesh_geo_info.nodeId, mesh_part_info.id, attrib_name, &attrib_info, -1, temp_data.data(), 0, attrib_info.count));
			values.resize(attrib_info.count);
			for (int i = 0; i < attrib_info.count; ++i)
			{
				values[i] = godot::Vector4(temp_data[i * 4], temp_data[i * 4 + 1], temp_data[i * 4 + 2], temp_data[i * 4 + 3]);
			}
		}
	}
	else if (attrib_info.storage == HAPI_STORAGETYPE_STRING)
	{
		std::vector<int> string_handles(attrib_info.count);
		HOUDINI_CHECK_ERROR(HoudiniApi::GetAttributeStringData(
				session, mesh_geo_info.nodeId, mesh_part_info.id, attrib_name, &attrib_info, string_handles.data(), 0, attrib_info.count));

		// Use batch API: one call to get total size, one call to fetch all strings
		int string_buffer_size = 0;
		HOUDINI_CHECK_ERROR(HoudiniApi::GetStringBatchSize(session, string_handles.data(), attrib_info.count, &string_buffer_size));

		std::vector<char> string_buffer(string_buffer_size);
		HOUDINI_CHECK_ERROR(HoudiniApi::GetStringBatch(session, string_buffer.data(), string_buffer_size));

		// Parse null-separated strings from the buffer
		values.resize(attrib_info.count);
		const char *current = string_buffer.data();
		for (int i = 0; i < attrib_info.count; ++i)
		{
			values[i] = godot::String(current);
			current += strlen(current) + 1; // Move to next null-terminated string
		}
	}
	else if (attrib_info.storage == HAPI_STORAGETYPE_DICTIONARY)
	{
		std::vector<HAPI_StringHandle> temp_data(attrib_info.count * attrib_info.tupleSize);
		HOUDINI_CHECK_ERROR(HoudiniApi::GetAttributeDictionaryData(
				session, mesh_geo_info.nodeId, mesh_part_info.id, attrib_name, &attrib_info, temp_data.data(), 0, attrib_info.count));

		values.resize(attrib_info.count * attrib_info.tupleSize);
		for (int i = 0; i < attrib_info.count * attrib_info.tupleSize; ++i)
		{
			std::string json_string = HEGoUtil::get_string(session, temp_data[i]);
			if (json_string.empty())
			{
				values[i] = godot::Variant();
				continue;
			}

			godot::Variant parsed = godot::JSON::parse_string(json_string.c_str());
			if (parsed.get_type() == godot::Variant::DICTIONARY)
			{
				values[i] = parsed;
			}
			else
			{
				values[i] = godot::Variant();
			}
		}
	}

	return values;
}
} // namespace Attribs
} // namespace Util
} // namespace HEGo
