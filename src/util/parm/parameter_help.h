#ifndef HEGO_PARAMETER_HELP_H
#define HEGO_PARAMETER_HELP_H

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>
#include <vector>

namespace HEGo::Util::Parm
{
void apply_parameter_help(const godot::String &page, std::vector<godot::Dictionary> &rows);
}

#endif
