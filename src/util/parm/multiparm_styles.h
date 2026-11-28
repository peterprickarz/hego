#pragma once

#include <HAPI/HAPI_Common.h>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>

namespace HEGo::Util::Parm
{
struct ParameterLayout
{
	godot::Dictionary multiparm_styles;
	godot::Dictionary folder_defaults;
};

ParameterLayout get_parameter_layout(const HAPI_Session *session, const HAPI_AssetInfo &info);
void invalidate_multiparm_styles(const godot::String &library_path);
}
