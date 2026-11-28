#ifndef HEGO_COP_IMAGE_OUTPUT_H
#define HEGO_COP_IMAGE_OUTPUT_H

#include <HAPI/HAPI_Common.h>
#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/variant/string.hpp>

class HEGoSessionManager;

namespace HEGo::Util::Cop
{
// Call on the session worker. An empty path selects the asset itself and an
// empty output name selects its first connector. Failures return a null image.
godot::Ref<godot::Image> fetch_image(
		HEGoSessionManager *manager, HAPI_NodeId asset_node_id, const godot::String &cop_path, const godot::String &output_name, godot::String &error);
} // namespace HEGo::Util::Cop

#endif
