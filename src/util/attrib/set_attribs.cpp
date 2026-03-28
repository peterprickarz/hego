#include "set_attribs.h"
#include "util/log/log.h"

#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/variant.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <string>
#include <vector>

#include "util/hego_util.h"

namespace HEGo
{
namespace Util
{
namespace Attribs
{

bool add_and_set_attribute(const HAPI_Session *session, HAPI_NodeId node_id, int part_id, const godot::Dictionary &attr_dict, int point_count, int prim_count)
{
	if (!attr_dict.has("name") || !attr_dict.has("value") || !attr_dict.has("type"))
	{
		HEGo::Util::Log::warning("Attribute dict missing required keys: name, value, type");
		return false;
	}

	godot::String attr_name = attr_dict["name"];
	godot::Variant value = attr_dict["value"];
	godot::String owner_str = attr_dict["type"];

	if (attr_name.is_empty())
	{
		HEGo::Util::Log::warning("Empty attribute name");
		return false;
	}

	HAPI_AttributeOwner owner = HAPI_ATTROWNER_INVALID;
	int element_count = 0;

	if (owner_str == "point")
	{
		owner = HAPI_ATTROWNER_POINT;
		element_count = point_count;
	}
	else if (owner_str == "prim")
	{
		owner = HAPI_ATTROWNER_PRIM;
		element_count = prim_count;
	}
	else
	{
		HEGo::Util::Log::warning("Unsupported owner type: '" + owner_str + "' (expected 'point' or 'prim')");
		return false;
	}

	if (element_count <= 0)
	{
		HEGo::Util::Log::warning("Cannot create attribute '" + attr_name + "' — zero elements for owner");
		return false;
	}

	HAPI_AttributeInfo attr_info = HoudiniApi::AttributeInfo_Create();
	attr_info.count = element_count;
	attr_info.tupleSize = 1; // default
	attr_info.owner = owner;
	attr_info.exists = true;

	std::string attr_name_utf8 = attr_name.utf8().get_data();

	bool success = false;

	switch (value.get_type())
	{
		case godot::Variant::INT:
		{
			attr_info.storage = HAPI_STORAGETYPE_INT;
			attr_info.tupleSize = 1;

			HOUDINI_CHECK_ERROR_RETURN(HoudiniApi::AddAttribute(session, node_id, part_id, attr_name_utf8.c_str(), &attr_info), false);

			int32_t v = value;
			HOUDINI_CHECK_ERROR_RETURN(
					HoudiniApi::SetAttributeIntData(session, node_id, part_id, attr_name_utf8.c_str(), &attr_info, &v, 0, element_count), false);
			success = true;
			break;
		}

		case godot::Variant::FLOAT:
		{
			attr_info.storage = HAPI_STORAGETYPE_FLOAT;
			attr_info.tupleSize = 1;

			HOUDINI_CHECK_ERROR_RETURN(HoudiniApi::AddAttribute(session, node_id, part_id, attr_name_utf8.c_str(), &attr_info), false);

			float v = value;
			HOUDINI_CHECK_ERROR_RETURN(
					HoudiniApi::SetAttributeFloatData(session, node_id, part_id, attr_name_utf8.c_str(), &attr_info, &v, 0, element_count), false);
			success = true;
			break;
		}

		case godot::Variant::VECTOR3:
		{
			attr_info.storage = HAPI_STORAGETYPE_FLOAT;
			attr_info.tupleSize = 3;

			HOUDINI_CHECK_ERROR_RETURN(HoudiniApi::AddAttribute(session, node_id, part_id, attr_name_utf8.c_str(), &attr_info), false);

			godot::Vector3 vec = value;
			std::vector<float> data(element_count * 3);

			// Uniform value across all elements
			for (int i = 0; i < element_count; ++i)
			{
				data[i * 3 + 0] = vec.x;
				data[i * 3 + 1] = vec.y;
				data[i * 3 + 2] = vec.z;
			}

			HOUDINI_CHECK_ERROR_RETURN(
					HoudiniApi::SetAttributeFloatData(session, node_id, part_id, attr_name_utf8.c_str(), &attr_info, data.data(), 0, element_count), false);
			success = true;
			break;
		}

		case godot::Variant::STRING:
		{
			attr_info.storage = HAPI_STORAGETYPE_STRING;
			attr_info.tupleSize = 1;

			std::string attr_name_utf8 = attr_name.utf8().get_data();

			// 1. Add the attribute (defines name, owner, storage, count, tupleSize)
			HOUDINI_CHECK_ERROR_RETURN(HoudiniApi::AddAttribute(session, node_id, part_id, attr_name_utf8.c_str(), &attr_info), false);

			// 2. Prepare raw string pointers — for uniform value, same string repeated
			godot::String str_val = value;
			std::string cpp_str = str_val.utf8().get_data(); // UTF-8 safe

			// We need 'element_count' pointers, all pointing to the **same** string data
			// Important: the buffer must live until after CommitGeo!
			std::vector<const char *> string_pointers(element_count, cpp_str.c_str());

			// 3. Set the data — pass array of const char*
			HOUDINI_CHECK_ERROR_RETURN(HoudiniApi::SetAttributeStringData(session, node_id, part_id, attr_name_utf8.c_str(), &attr_info,
											   string_pointers.data(), // const char**
											   0, // start
											   element_count), // length = num elements
					false);

			success = true;
			break;
		}

		default:
		{
			HEGo::Util::Log::warning("Unsupported Variant type for attribute '" + attr_name + "': " + godot::String::num(value.get_type()));
			break;
		}
	}

	return success;
}

void apply_attributes(const HAPI_Session *session, HAPI_NodeId node_id, int part_id, const godot::Array &attributes, int point_count, int prim_count)
{
	if (attributes.is_empty())
	{
		return;
	}

	HEGo::Util::Log::message("Applying " + godot::String::num(attributes.size()) + " custom attributes");

	for (int i = 0; i < attributes.size(); ++i)
	{
		godot::Variant v = attributes[i];
		if (v.get_type() != godot::Variant::DICTIONARY)
		{
			HEGo::Util::Log::warning("Attribute entry at index " + godot::String::num(i) + " is not a Dictionary");
			continue;
		}

		godot::Dictionary d = v;

		bool ok = add_and_set_attribute(session, node_id, part_id, d, point_count, prim_count);

		if (!ok)
		{
			HEGo::Util::Log::warning("Failed to set attribute at index " + godot::String::num(i));
		}
	}
}

} // namespace Attribs
} // namespace Util
} // namespace HEGo