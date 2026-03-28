#ifndef HEGO_UTIL_ATTRIB_SET_ATTRIBS_H
#define HEGO_UTIL_ATTRIB_SET_ATTRIBS_H

#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>

#include <hapi/houdini_api.h> // HAPI_Session, HAPI_NodeId, HAPI_AttributeInfo, etc.

#include "util/log/log.h" // Assuming this is where HEGo::Util::Log lives

namespace HEGo
{
namespace Util
{
namespace Attribs
{

/**
 * Adds and sets an attribute on a Houdini input node part using data from a Godot Dictionary.
 *
 * Expected dictionary format:
 *   {
 *     "name":  String         // attribute name (required)
 *     "type":  String         // "point" or "prim" (required)
 *     "value": Variant        // scalar value applied uniformly (int, float, Vector3, String, ...)
 *   }
 *
 * Currently supports uniform (constant) values across all elements.
 * Per-element varying values can be added in a future version (e.g. via "values": Array).
 *
 * @param session       Active Houdini session
 * @param node_id       The input node ID
 * @param part_id       Usually 0 for simple input geometry
 * @param attr_dict     Godot Dictionary containing the attribute description
 * @param point_count   Total number of points in the geometry
 * @param prim_count    Total number of primitives (faces) in the geometry
 * @return true if the attribute was successfully added and set, false otherwise
 */
bool add_and_set_attribute(const HAPI_Session *session, HAPI_NodeId node_id, int part_id, const godot::Dictionary &attr_dict, int point_count, int prim_count);

/**
 * Applies all custom attributes from a Godot Array to the Houdini geometry.
 *
 * Iterates over the array, expects each element to be a Dictionary compatible
 * with add_and_set_custom_attribute().
 *
 * Logs warnings for invalid entries but continues processing others.
 *
 * @param session       Active Houdini session
 * @param node_id       The input node ID
 * @param part_id       Usually 0
 * @param attributes    Godot Array of Dictionaries
 * @param point_count   Number of points
 * @param prim_count    Number of primitives
 */
void apply_attributes(const HAPI_Session *session, HAPI_NodeId node_id, int part_id, const godot::Array &attributes, int point_count, int prim_count);

} // namespace Attribs
} // namespace Util
} // namespace HEGo

#endif // HEGO_UTIL_ATTRIB_SET_ATTRIBS_H