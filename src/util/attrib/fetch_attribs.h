#ifndef FETCH_ATTRIBS_H
#define FETCH_ATTRIBS_H

#include "hapi/houdini_api.h"
#include <godot_cpp/core/class_db.hpp>

namespace HEGo
{
namespace Util
{
namespace Attribs
{
godot::Variant fetch_dict(const HAPI_Session *session, const HAPI_GeoInfo &mesh_geo_info, const HAPI_PartInfo &mesh_part_info, HAPI_AttributeOwner owner,
		const char *attrib_name);
godot::Variant fetch_float(const HAPI_Session *session, const HAPI_GeoInfo &mesh_geo_info, const HAPI_PartInfo &mesh_part_info, HAPI_AttributeOwner owner,
		const char *attrib_name);

godot::Variant fetch_vector2(const HAPI_Session *session, const HAPI_GeoInfo &mesh_geo_info, const HAPI_PartInfo &mesh_part_info, HAPI_AttributeOwner owner,
		const char *attrib_name);

godot::Variant fetch_vector3(const HAPI_Session *session, const HAPI_GeoInfo &mesh_geo_info, const HAPI_PartInfo &mesh_part_info, HAPI_AttributeOwner owner,
		const char *attrib_name);

godot::Variant fetch_vector4(const HAPI_Session *session, const HAPI_GeoInfo &mesh_geo_info, const HAPI_PartInfo &mesh_part_info, HAPI_AttributeOwner owner,
		const char *attrib_name);

godot::Variant fetch_int(const HAPI_Session *session, const HAPI_GeoInfo &mesh_geo_info, const HAPI_PartInfo &mesh_part_info, HAPI_AttributeOwner owner,
		const char *attrib_name);

godot::Variant fetch_vector2i(const HAPI_Session *session, const HAPI_GeoInfo &mesh_geo_info, const HAPI_PartInfo &mesh_part_info, HAPI_AttributeOwner owner,
		const char *attrib_name);

godot::Variant fetch_vector3i(const HAPI_Session *session, const HAPI_GeoInfo &mesh_geo_info, const HAPI_PartInfo &mesh_part_info, HAPI_AttributeOwner owner,
		const char *attrib_name);

godot::Variant fetch_vector4i(const HAPI_Session *session, const HAPI_GeoInfo &mesh_geo_info, const HAPI_PartInfo &mesh_part_info, HAPI_AttributeOwner owner,
		const char *attrib_name);

godot::Variant fetch_string(const HAPI_Session *session, const HAPI_GeoInfo &mesh_geo_info, const HAPI_PartInfo &mesh_part_info, HAPI_AttributeOwner owner,
		const char *attrib_name);

godot::Variant fetch_by_name(const HAPI_Session *session, const HAPI_GeoInfo &mesh_geo_info, const HAPI_PartInfo &mesh_part_info, HAPI_AttributeOwner owner,
		const char *attrib_name);
} // namespace Attribs
} // namespace Util
} // namespace HEGo

#endif // HEGO_ATTRIB_FETCHER_H
