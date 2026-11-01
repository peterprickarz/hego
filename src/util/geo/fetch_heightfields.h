#ifndef HEGO_FETCH_HEIGHTFIELDS_H
#define HEGO_FETCH_HEIGHTFIELDS_H

#include "hapi/houdini_api.h"
#include "hego_session_manager.h"

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/string.hpp>

namespace HEGo
{
namespace Util
{
namespace Geo
{
godot::Array get_heightfield_layers(
		HEGoSessionManager *session_mgr, HAPI_NodeId node_id, const godot::PackedStringArray &read_prim_attribs, bool auto_cook = true);
godot::Ref<godot::Image> fetch_heightfield_layer_image(HEGoSessionManager *session_mgr, HAPI_NodeId node_id, int part_id, bool auto_cook = true);
// Atomic explicit-field transport. On false, result is empty and error explains
// the failed part/read. Each successful payload is ready for set_fields().
bool fetch_heightfield_fields(HEGoSessionManager *session_mgr, HAPI_NodeId node_id,
		const godot::PackedStringArray &read_prim_attribs, godot::Array &result, godot::String &error, bool auto_cook = true);
} // namespace Geo
} // namespace Util
} // namespace HEGo

#endif // HEGO_FETCH_HEIGHTFIELDS_H
