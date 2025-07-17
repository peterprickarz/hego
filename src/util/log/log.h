#ifndef LOG_H
#define LOG_H

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

namespace HEGo
{
namespace Util
{
namespace Log
{
void message(const godot::String &message);
void warning(const godot::String &message);
void error(const godot::String &message);
void line();
} // namespace Log
} // namespace Util
} // namespace HEGo

#endif // HEGO_LOGGER_H