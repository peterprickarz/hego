#include "attrib_utilities.h"
#include "util/attrib/fetch_attribs.h"

namespace HEGo
{
namespace Util
{
namespace Attribs
{
godot::Array read_attrib_pairs(
		const HAPI_Session *session, const HAPI_GeoInfo &geo_info, const HAPI_PartInfo &part_info, HAPI_AttributeOwner owner, const godot::PackedStringArray &read_attribs)
{
	godot::Array attrs;

	for (int i = 0; i < read_attribs.size(); ++i)
	{
		const godot::String attr_name = read_attribs[i];
		if (attr_name.is_empty())
		{
			continue;
		}

		godot::Dictionary pair;
		pair["name"] = attr_name;

		const godot::Variant attr_data = HEGo::Util::Attribs::fetch_by_name(session, geo_info, part_info, owner, attr_name.utf8().get_data());

		if (attr_data.get_type() == godot::Variant::ARRAY)
		{
			const godot::Array arr = attr_data;
			pair["value"] = arr.is_empty() ? godot::Variant() : arr[0];
		}
		else
		{
			pair["value"] = godot::Variant();
		}

		attrs.append(pair);
	}

	return attrs;
}
}
}
}