#include "log.h"

// Define the prefix as a static const character array
static const char *PREFIX = "[Houdini Engine]: ";

namespace HEGo
{
namespace Util
{
namespace Log
{

HEGoLogManager* HEGoLogManager::singleton = nullptr;

HEGoLogManager::HEGoLogManager()
{
	singleton = this;
}

HEGoLogManager::~HEGoLogManager()
{
	if (singleton == this)
	{
		singleton = nullptr;
	}
}

HEGoLogManager* HEGoLogManager::get_singleton()
{
	return singleton;
}

void HEGoLogManager::_bind_methods()
{
	godot::ClassDB::bind_method(godot::D_METHOD("emit_log_message", "message", "level"), &HEGoLogManager::emit_log_message);
	godot::ClassDB::bind_static_method("HEGoLogManager", godot::D_METHOD("get_singleton"), &HEGoLogManager::get_singleton);
	
	ADD_SIGNAL(godot::MethodInfo("log_message", godot::PropertyInfo(godot::Variant::STRING, "message"), godot::PropertyInfo(godot::Variant::STRING, "level")));
}

void HEGoLogManager::emit_log_message(const godot::String &message, const godot::String &level)
{
	emit_signal("log_message", message, level);
}

void message(const godot::String &msg) 
{ 
	godot::UtilityFunctions::print(godot::String(PREFIX) + msg);
	
	if (HEGoLogManager::get_singleton())
	{
		HEGoLogManager::get_singleton()->emit_log_message(msg, "MESSAGE");
	}
}

void warning(const godot::String &msg)
{
	godot::UtilityFunctions::push_warning(godot::String(PREFIX) + msg);
	godot::UtilityFunctions::print(godot::String(PREFIX) + "WARNING: " + msg);
	
	if (HEGoLogManager::get_singleton())
	{
		HEGoLogManager::get_singleton()->emit_log_message(msg, "WARNING");
	}
}

void error(const godot::String &msg)
{
	godot::UtilityFunctions::push_error(godot::String(PREFIX) + msg);
	godot::UtilityFunctions::print(godot::String(PREFIX) + "ERROR: " + msg);
	
	if (HEGoLogManager::get_singleton())
	{
		HEGoLogManager::get_singleton()->emit_log_message(msg, "ERROR");
	}
}

void line() 
{ 
	godot::String line_msg = "---------------------";
	godot::UtilityFunctions::print(godot::String(PREFIX) + line_msg);
	
	if (HEGoLogManager::get_singleton())
	{
		HEGoLogManager::get_singleton()->emit_log_message(line_msg, "LINE");
	}
}

} // namespace Log
} // namespace Util
} // namespace HEGo