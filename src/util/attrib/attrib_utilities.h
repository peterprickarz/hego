#ifndef ATTRIB_UTILITIES_H
#define ATTRIB_UTILITIES_H

#include "hapi/houdini_api.h"
#include "hego_session_manager.h"

#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>

namespace HEGo 
{
namespace Util
{
namespace Attribs
{
godot::Array read_attrib_pairs(
    const HAPI_Session *session,
    const HAPI_GeoInfo &geo_info,
    const HAPI_PartInfo &part_info,
    HAPI_AttributeOwner owner,
    const godot::PackedStringArray &read_attribs
);
} // namespace Attrib
} // namespace Util
} // namespace HEGo

#endif // ATTRIB_UTILITIES_H