#ifndef LOG_H
#define LOG_H

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/classes/object.hpp>

namespace HEGo
{
namespace Util
{
namespace Log
{

/// Log a standard message to console and UI
void message(const godot::String &message);

/// Log a warning message to console and UI
void warning(const godot::String &message);

/// Log an error message to console and UI
void error(const godot::String &message);

/// Log a separator line to console and UI
void line();

/// HEGoLogManager handles signal-based logging for UI capture
/// 
/// This singleton class receives log messages from HEGo logging functions
/// and emits Godot signals that UI components can connect to for real-time
/// log display and session status monitoring.
class HEGoLogManager : public godot::Object
{
	GDCLASS(HEGoLogManager, godot::Object)

private:
	static HEGoLogManager* singleton;

public:
	HEGoLogManager();
	~HEGoLogManager();
	
	/// Get the HEGoLogManager singleton instance
	static HEGoLogManager* get_singleton();
	
	/// Bind methods for Godot integration
	static void _bind_methods();
	
	/// Emit log_message signal with message and level
	void emit_log_message(const godot::String &message, const godot::String &level);
};

} // namespace Log
} // namespace Util
} // namespace HEGo

#endif // LOG_H