#include "log.h"

// Define the prefix as a static const character array
static const char *PREFIX = "[Houdini Engine]: ";

namespace HEGo
{
namespace Util
{
namespace Log
{
void message(const godot::String &msg) { godot::UtilityFunctions::print(godot::String(PREFIX) + msg); }

void warning(const godot::String &msg)
{
	godot::UtilityFunctions::push_warning(godot::String(PREFIX) + msg);
	message(godot::String(PREFIX) + "WARNING: " + msg);
}

void error(const godot::String &msg)
{
	godot::UtilityFunctions::push_error(godot::String(PREFIX) + msg);
	message(godot::String(PREFIX) + "ERROR: " + msg);
}

void line() { godot::UtilityFunctions::print(godot::String(PREFIX) + "---------------------"); }
} // namespace Log
} // namespace Util
} // namespace HEGo