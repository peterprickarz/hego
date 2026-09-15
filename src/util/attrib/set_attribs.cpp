#include "set_attribs.h"
#include "util/log/log.h"

#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
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

static bool length_matches(int actual, int expected, const godot::String &attr_name)
{
	if (actual == expected)
	{
		return true;
	}
	HEGo::Util::Log::warning(HEGo::Util::Log::Category::ATTRIB,
			"Attribute '" + attr_name + "' values length " + godot::String::num(actual) + " does not match owner count " + godot::String::num(expected));
	return false;
}

static HAPI_AttributeInfo make_attr_info(HAPI_AttributeOwner owner, int element_count, HAPI_StorageType storage, int tuple_size)
{
	HAPI_AttributeInfo attr_info = HoudiniApi::AttributeInfo_Create();
	attr_info.count = element_count;
	attr_info.tupleSize = tuple_size;
	attr_info.owner = owner;
	attr_info.exists = true;
	attr_info.storage = storage;
	return attr_info;
}

static bool set_int_values(const HAPI_Session *session, HAPI_NodeId node_id, int part_id, const std::string &name, HAPI_AttributeOwner owner, int element_count,
		const int *data)
{
	HAPI_AttributeInfo attr_info = make_attr_info(owner, element_count, HAPI_STORAGETYPE_INT, 1);
	HOUDINI_CHECK_ERROR_RETURN(HoudiniApi::AddAttribute(session, node_id, part_id, name.c_str(), &attr_info), false);
	HOUDINI_CHECK_ERROR_RETURN(HoudiniApi::SetAttributeIntData(session, node_id, part_id, name.c_str(), &attr_info, data, 0, element_count), false);
	return true;
}

static bool set_float_values(const HAPI_Session *session, HAPI_NodeId node_id, int part_id, const std::string &name, HAPI_AttributeOwner owner, int element_count,
		const float *data, int tuple_size)
{
	HAPI_AttributeInfo attr_info = make_attr_info(owner, element_count, HAPI_STORAGETYPE_FLOAT, tuple_size);
	HOUDINI_CHECK_ERROR_RETURN(HoudiniApi::AddAttribute(session, node_id, part_id, name.c_str(), &attr_info), false);
	HOUDINI_CHECK_ERROR_RETURN(HoudiniApi::SetAttributeFloatData(session, node_id, part_id, name.c_str(), &attr_info, data, 0, element_count), false);
	return true;
}

static bool set_string_values(const HAPI_Session *session, HAPI_NodeId node_id, int part_id, const std::string &name, HAPI_AttributeOwner owner, int element_count,
		const char **data)
{
	HAPI_AttributeInfo attr_info = make_attr_info(owner, element_count, HAPI_STORAGETYPE_STRING, 1);
	HOUDINI_CHECK_ERROR_RETURN(HoudiniApi::AddAttribute(session, node_id, part_id, name.c_str(), &attr_info), false);
	HOUDINI_CHECK_ERROR_RETURN(HoudiniApi::SetAttributeStringData(session, node_id, part_id, name.c_str(), &attr_info, data, 0, element_count), false);
	return true;
}

static bool set_uniform(const HAPI_Session *session, HAPI_NodeId node_id, int part_id, const std::string &name, const godot::String &attr_name,
		HAPI_AttributeOwner owner, int element_count, const godot::Variant &value)
{
	switch (value.get_type())
	{
		case godot::Variant::INT:
		{
			HAPI_AttributeInfo attr_info = make_attr_info(owner, element_count, HAPI_STORAGETYPE_INT, 1);
			HOUDINI_CHECK_ERROR_RETURN(HoudiniApi::AddAttribute(session, node_id, part_id, name.c_str(), &attr_info), false);
			int v = static_cast<int>(static_cast<int64_t>(value));
			HOUDINI_CHECK_ERROR_RETURN(HoudiniApi::SetAttributeIntUniqueData(session, node_id, part_id, name.c_str(), &attr_info, &v, 1, 0, element_count), false);
			return true;
		}
		case godot::Variant::FLOAT:
		{
			HAPI_AttributeInfo attr_info = make_attr_info(owner, element_count, HAPI_STORAGETYPE_FLOAT, 1);
			HOUDINI_CHECK_ERROR_RETURN(HoudiniApi::AddAttribute(session, node_id, part_id, name.c_str(), &attr_info), false);
			float v = value;
			HOUDINI_CHECK_ERROR_RETURN(
					HoudiniApi::SetAttributeFloatUniqueData(session, node_id, part_id, name.c_str(), &attr_info, &v, 1, 0, element_count), false);
			return true;
		}
		case godot::Variant::VECTOR3:
		{
			HAPI_AttributeInfo attr_info = make_attr_info(owner, element_count, HAPI_STORAGETYPE_FLOAT, 3);
			HOUDINI_CHECK_ERROR_RETURN(HoudiniApi::AddAttribute(session, node_id, part_id, name.c_str(), &attr_info), false);
			godot::Vector3 vec = value;
			const float data[3] = { vec.x, vec.y, vec.z };
			HOUDINI_CHECK_ERROR_RETURN(
					HoudiniApi::SetAttributeFloatUniqueData(session, node_id, part_id, name.c_str(), &attr_info, data, 3, 0, element_count), false);
			return true;
		}
		case godot::Variant::STRING:
		{
			HAPI_AttributeInfo attr_info = make_attr_info(owner, element_count, HAPI_STORAGETYPE_STRING, 1);
			HOUDINI_CHECK_ERROR_RETURN(HoudiniApi::AddAttribute(session, node_id, part_id, name.c_str(), &attr_info), false);
			godot::String str_val = value;
			std::string cpp_str = str_val.utf8().get_data();
			HOUDINI_CHECK_ERROR_RETURN(HoudiniApi::SetAttributeStringUniqueData(session, node_id, part_id, name.c_str(), &attr_info, cpp_str.c_str(),
											   static_cast<int>(cpp_str.size()), 0, element_count),
					false);
			return true;
		}
		default:
			HEGo::Util::Log::warning(HEGo::Util::Log::Category::ATTRIB,
					"Unsupported Variant type for attribute '" + attr_name + "': " + godot::String::num(value.get_type()));
			return false;
	}
}

static bool set_array_values(const HAPI_Session *session, HAPI_NodeId node_id, int part_id, const std::string &name, const godot::String &attr_name,
		HAPI_AttributeOwner owner, int element_count, const godot::Array &array)
{
	if (!length_matches(array.size(), element_count, attr_name))
	{
		return false;
	}
	if (array.is_empty())
	{
		return false;
	}

	const godot::Variant::Type elem_type = array[0].get_type();
	for (int i = 1; i < array.size(); ++i)
	{
		if (array[i].get_type() != elem_type)
		{
			HEGo::Util::Log::warning(HEGo::Util::Log::Category::ATTRIB, "Attribute '" + attr_name + "' values array has mixed types");
			return false;
		}
	}

	switch (elem_type)
	{
		case godot::Variant::INT:
		{
			std::vector<int> data(static_cast<size_t>(element_count));
			for (int i = 0; i < element_count; ++i)
			{
				data[static_cast<size_t>(i)] = static_cast<int>(static_cast<int64_t>(array[i]));
			}
			return set_int_values(session, node_id, part_id, name, owner, element_count, data.data());
		}
		case godot::Variant::FLOAT:
		{
			std::vector<float> data(static_cast<size_t>(element_count));
			for (int i = 0; i < element_count; ++i)
			{
				data[static_cast<size_t>(i)] = array[i];
			}
			return set_float_values(session, node_id, part_id, name, owner, element_count, data.data(), 1);
		}
		case godot::Variant::VECTOR3:
		{
			std::vector<float> data(static_cast<size_t>(element_count) * 3);
			for (int i = 0; i < element_count; ++i)
			{
				godot::Vector3 vec = array[i];
				data[static_cast<size_t>(i) * 3 + 0] = vec.x;
				data[static_cast<size_t>(i) * 3 + 1] = vec.y;
				data[static_cast<size_t>(i) * 3 + 2] = vec.z;
			}
			return set_float_values(session, node_id, part_id, name, owner, element_count, data.data(), 3);
		}
		case godot::Variant::STRING:
		{
			std::vector<std::string> storage(static_cast<size_t>(element_count));
			for (int i = 0; i < element_count; ++i)
			{
				godot::String s = array[i];
				storage[static_cast<size_t>(i)] = s.utf8().get_data();
			}
			std::vector<const char *> ptrs(static_cast<size_t>(element_count));
			for (int i = 0; i < element_count; ++i)
			{
				ptrs[static_cast<size_t>(i)] = storage[static_cast<size_t>(i)].c_str();
			}
			return set_string_values(session, node_id, part_id, name, owner, element_count, ptrs.data());
		}
		default:
			HEGo::Util::Log::warning(HEGo::Util::Log::Category::ATTRIB,
					"Unsupported element type in values array for attribute '" + attr_name + "': " + godot::String::num(elem_type));
			return false;
	}
}

static bool set_varying(const HAPI_Session *session, HAPI_NodeId node_id, int part_id, const std::string &name, const godot::String &attr_name,
		HAPI_AttributeOwner owner, int element_count, const godot::Variant &values)
{
	switch (values.get_type())
	{
		case godot::Variant::PACKED_INT32_ARRAY:
		{
			godot::PackedInt32Array arr = values;
			if (!length_matches(arr.size(), element_count, attr_name))
			{
				return false;
			}
			std::vector<int> data(static_cast<size_t>(element_count));
			const int32_t *src = arr.ptr();
			for (int i = 0; i < element_count; ++i)
			{
				data[static_cast<size_t>(i)] = src[i];
			}
			return set_int_values(session, node_id, part_id, name, owner, element_count, data.data());
		}
		case godot::Variant::PACKED_FLOAT32_ARRAY:
		{
			godot::PackedFloat32Array arr = values;
			if (!length_matches(arr.size(), element_count, attr_name))
			{
				return false;
			}
			return set_float_values(session, node_id, part_id, name, owner, element_count, arr.ptr(), 1);
		}
		case godot::Variant::PACKED_VECTOR3_ARRAY:
		{
			godot::PackedVector3Array arr = values;
			if (!length_matches(arr.size(), element_count, attr_name))
			{
				return false;
			}
			std::vector<float> data(static_cast<size_t>(element_count) * 3);
			for (int i = 0; i < element_count; ++i)
			{
				godot::Vector3 vec = arr[i];
				data[static_cast<size_t>(i) * 3 + 0] = vec.x;
				data[static_cast<size_t>(i) * 3 + 1] = vec.y;
				data[static_cast<size_t>(i) * 3 + 2] = vec.z;
			}
			return set_float_values(session, node_id, part_id, name, owner, element_count, data.data(), 3);
		}
		case godot::Variant::PACKED_STRING_ARRAY:
		{
			godot::PackedStringArray arr = values;
			if (!length_matches(arr.size(), element_count, attr_name))
			{
				return false;
			}
			std::vector<std::string> storage(static_cast<size_t>(element_count));
			for (int i = 0; i < element_count; ++i)
			{
				storage[static_cast<size_t>(i)] = arr[i].utf8().get_data();
			}
			std::vector<const char *> ptrs(static_cast<size_t>(element_count));
			for (int i = 0; i < element_count; ++i)
			{
				ptrs[static_cast<size_t>(i)] = storage[static_cast<size_t>(i)].c_str();
			}
			return set_string_values(session, node_id, part_id, name, owner, element_count, ptrs.data());
		}
		case godot::Variant::ARRAY:
			return set_array_values(session, node_id, part_id, name, attr_name, owner, element_count, values);
		default:
			HEGo::Util::Log::warning(HEGo::Util::Log::Category::ATTRIB,
					"Unsupported values type for attribute '" + attr_name + "': " + godot::String::num(values.get_type()));
			return false;
	}
}

bool add_and_set_attribute(const HAPI_Session *session, HAPI_NodeId node_id, int part_id, const godot::Dictionary &attr_dict, int point_count, int prim_count)
{
	if (!attr_dict.has("name") || !attr_dict.has("type"))
	{
		HEGo::Util::Log::warning(HEGo::Util::Log::Category::ATTRIB, "Attribute dict missing required keys: name, type");
		return false;
	}

	const bool has_values = attr_dict.has("values");
	const bool has_value = attr_dict.has("value");
	if (!has_values && !has_value)
	{
		HEGo::Util::Log::warning(HEGo::Util::Log::Category::ATTRIB, "Attribute dict missing 'value' or 'values'");
		return false;
	}

	godot::String attr_name = attr_dict["name"];
	godot::String owner_str = attr_dict["type"];

	if (attr_name.is_empty())
	{
		HEGo::Util::Log::warning(HEGo::Util::Log::Category::ATTRIB, "Empty attribute name");
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
		HEGo::Util::Log::warning(HEGo::Util::Log::Category::ATTRIB, "Unsupported owner type: '" + owner_str + "' (expected 'point' or 'prim')");
		return false;
	}

	if (element_count <= 0)
	{
		HEGo::Util::Log::warning(HEGo::Util::Log::Category::ATTRIB, "Cannot create attribute '" + attr_name + "' — zero elements for owner");
		return false;
	}

	std::string attr_name_utf8 = attr_name.utf8().get_data();

	if (has_values)
	{
		return set_varying(session, node_id, part_id, attr_name_utf8, attr_name, owner, element_count, attr_dict["values"]);
	}
	return set_uniform(session, node_id, part_id, attr_name_utf8, attr_name, owner, element_count, attr_dict["value"]);
}

void apply_attributes(const HAPI_Session *session, HAPI_NodeId node_id, int part_id, const godot::Array &attributes, int point_count, int prim_count)
{
	if (attributes.is_empty())
	{
		return;
	}

	HEGo::Util::Log::debug(HEGo::Util::Log::Category::ATTRIB, "Applying " + godot::String::num(attributes.size()) + " custom attributes");

	for (int i = 0; i < attributes.size(); ++i)
	{
		godot::Variant v = attributes[i];
		if (v.get_type() != godot::Variant::DICTIONARY)
		{
			HEGo::Util::Log::warning(HEGo::Util::Log::Category::ATTRIB, "Attribute entry at index " + godot::String::num(i) + " is not a Dictionary");
			continue;
		}

		godot::Dictionary d = v;

		bool ok = add_and_set_attribute(session, node_id, part_id, d, point_count, prim_count);

		if (!ok)
		{
			HEGo::Util::Log::warning(HEGo::Util::Log::Category::ATTRIB, "Failed to set attribute at index " + godot::String::num(i));
		}
	}
}

} // namespace Attribs
} // namespace Util
} // namespace HEGo