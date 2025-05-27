#include "util/attrib/fetch_attribs.h"

#include "util/hego_util.h"
#include "util/log/log.h"

#include "fetch_attribs.h"
#include <vector>

namespace HEGo
{
namespace Util
{
namespace Attribs
{
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

godot::Variant Attribs::fetch_by_name(
		const HAPI_Session *session, const HAPI_GeoInfo &mesh_geo_info, const HAPI_PartInfo &mesh_part_info, HAPI_AttributeOwner owner, const char *attrib_name)
{
	godot::Array values;

	HAPI_AttributeInfo attrib_info;
	HOUDINI_CHECK_ERROR(HoudiniApi::GetAttributeInfo(session, mesh_geo_info.nodeId, mesh_part_info.id, attrib_name, owner, &attrib_info));
	if (!attrib_info.exists)
	{
		if (owner == HAPI_ATTROWNER_PRIM)
		{
			int nprims = mesh_part_info.faceCount;
			godot::Array result;
			result.resize(nprims);

			for (int i = 0; i < nprims; i++)
			{
				result[i] = godot::Variant();
			}
			values = result;
		}
		else if (owner == HAPI_ATTROWNER_POINT)
		{
			int npts = mesh_part_info.pointCount;
			godot::Array result;
			result.resize(npts);

			for (int i = 0; i < npts; i++)
			{
				result[i] = godot::Variant();
			}
			values = result;
		}
		else if (owner == HAPI_ATTROWNER_VERTEX)
		{
			int nvertices = mesh_part_info.vertexCount;
			godot::Array result;
			result.resize(nvertices);

			for (int i = 0; i < nvertices; i++)
			{
				result[i] = godot::Variant();
			}
			values = result;
		}
		else if (owner == HAPI_ATTROWNER_DETAIL)
		{
			godot::Array result;
			result.resize(1);
			result[0] = godot::Variant();
			values = result;
		}
	}
	else
	{
		if (attrib_info.storage == HAPI_STORAGETYPE_INT)
		{
			if (attrib_info.tupleSize == 1)
			{
				values = fetch_int(session, mesh_geo_info, mesh_part_info, owner, attrib_name);
			}
			else if (attrib_info.tupleSize == 2)
			{
				values = fetch_vector2i(session, mesh_geo_info, mesh_part_info, owner, attrib_name);
			}
			else if (attrib_info.tupleSize == 3)
			{
				values = fetch_vector3i(session, mesh_geo_info, mesh_part_info, owner, attrib_name);
			}
			else if (attrib_info.tupleSize == 4)
			{
				values = fetch_vector4i(session, mesh_geo_info, mesh_part_info, owner, attrib_name);
			}
		}
		else if (attrib_info.storage == HAPI_STORAGETYPE_FLOAT)
		{
			if (attrib_info.tupleSize == 1)
			{
				values = fetch_float(session, mesh_geo_info, mesh_part_info, owner, attrib_name);
			}
			else if (attrib_info.tupleSize == 2)
			{
				values = fetch_vector2(session, mesh_geo_info, mesh_part_info, owner, attrib_name);
			}
			else if (attrib_info.tupleSize == 3)
			{
				values = fetch_vector3(session, mesh_geo_info, mesh_part_info, owner, attrib_name);
			}
			else if (attrib_info.tupleSize == 4)
			{
				values = fetch_vector4(session, mesh_geo_info, mesh_part_info, owner, attrib_name);
			}
		}
		else if (attrib_info.storage == HAPI_STORAGETYPE_STRING)
		{
			values = fetch_string(session, mesh_geo_info, mesh_part_info, owner, attrib_name);
		}
	}
	return values;
}
} // namespace Attribs
} // namespace Util
} // namespace HEGo
