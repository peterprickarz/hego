#ifndef LOG_H
#define LOG_H

#include <godot_cpp/classes/object.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <string>

namespace HEGo
{
namespace Util
{
namespace Log
{

/// Severity of a log entry.
///
/// Two thresholds decide where an entry ends up: entries at or above the store
/// level are kept in the in-memory buffer the session panel reads, and entries at
/// or above the output level are also printed to the Godot output.
enum Level
{
	LEVEL_TRACE = 0, ///< Per-element detail. Off unless the store level is lowered.
	LEVEL_DEBUG = 1, ///< What HEGo is doing during a cook. Panel only by default.
	LEVEL_INFO = 2, ///< Milestones a user cares about: session started, cook finished.
	LEVEL_WARNING = 3, ///< Something was skipped or guessed, the operation continues.
	LEVEL_ERROR = 4, ///< The operation failed.
};

/// Categories used across HEGo, so the panel can filter by subsystem.
/// Free-form strings are allowed; these are the ones the code uses.
namespace Category
{
constexpr const char *SESSION = "session";
constexpr const char *NODE = "node";
constexpr const char *COOK = "cook";
constexpr const char *INPUT = "input";
constexpr const char *OUTPUT = "output";
constexpr const char *ATTRIB = "attrib";
constexpr const char *PARM = "parm";
constexpr const char *TERRAIN3D = "terrain3d";
constexpr const char *PLATFORM = "platform";
} // namespace Category

/// Whether anything would keep an entry of this level. Cheap enough to guard
/// string building with, which is what the HEGO_LOG_* macros do.
bool is_enabled(Level level);

/// Records one entry. Safe to call from any thread: worker threads only append to
/// the in-memory buffer and, when file logging is on, to the log file. Everything
/// that needs the Godot API happens later, on the main thread, in flush_to_output().
void write(Level level, const char *category, const godot::String &message);

/// Level-specific shorthands.
void trace(const char *category, const godot::String &message);
void debug(const char *category, const godot::String &message);
void info(const char *category, const godot::String &message);
void warning(const char *category, const godot::String &message);
void error(const char *category, const godot::String &message);

/// Uncategorised shorthands, kept for call sites that have no obvious subsystem.
void message(const godot::String &message);
void warning(const godot::String &message);
void error(const godot::String &message);

/// A separator, to group the output of one operation.
void line();

/// Prints everything recorded since the last call to the Godot output, and writes
/// it to the log file. Must run on the main thread; calling it from anywhere else
/// is a no-op. Called automatically when logging from the main thread, and driven
/// by the editor plugin so worker thread entries surface promptly.
void flush_to_output();

/// The in-memory log, exposed to GDScript as `HEGoLog`.
///
/// GDScript logs through the same functions the C++ side uses, so the session
/// panel, the Godot output and the log file all see one stream:
/// [codeblock]
/// HEGoLog.get_singleton().info("cook", "Cooking %s" % asset_name)
/// [/codeblock]
class HEGoLog : public godot::Object
{
	GDCLASS(HEGoLog, godot::Object)

private:
	static HEGoLog *singleton;

protected:
	static void _bind_methods();

public:
	HEGoLog();
	~HEGoLog();

	static HEGoLog *get_singleton();

	/// Reads the project settings and (re)opens the log file. Call after changing
	/// any hego/logging/* setting.
	void configure();

	// Logging, for GDScript.
	void log_message(int level, const godot::String &category, const godot::String &message);
	void log_trace(const godot::String &category, const godot::String &message);
	void log_debug(const godot::String &category, const godot::String &message);
	void log_info(const godot::String &category, const godot::String &message);
	void log_warning(const godot::String &category, const godot::String &message);
	void log_error(const godot::String &category, const godot::String &message);

	/// Index one past the newest entry. Pass a previously returned value to
	/// get_entries_since() to read only what arrived in between.
	int64_t get_cursor() const;

	/// Entries recorded since `cursor`, as dictionaries with
	/// index, time, level, level_name, category and message.
	/// Entries dropped from the buffer since then are simply missing.
	godot::Array get_entries_since(int64_t cursor, int min_level = LEVEL_TRACE) const;

	/// Categories seen since the buffer was last cleared, for the panel's filter.
	godot::PackedStringArray get_categories() const;

	void clear();

	/// Writes the whole buffer to `path` as text. Used by the panel's export button.
	bool save_to_file(const godot::String &path) const;

	/// Drains pending entries to the Godot output and the log file. Main thread only.
	void flush();

	// Configuration, mirroring the hego/logging/* project settings.
	void set_store_level(int level);
	int get_store_level() const;
	void set_output_level(int level);
	int get_output_level() const;

	/// Absolute path of the log file this session writes to, empty when file
	/// logging is off or the file could not be opened.
	godot::String get_log_file_path() const;

	/// Human readable name of a level, e.g. LEVEL_WARNING -> "WARNING".
	static godot::String level_name(int level);
};

} // namespace Log
} // namespace Util
} // namespace HEGo

VARIANT_ENUM_CAST(HEGo::Util::Log::Level);

/// Guarded logging: the message expression is only built when something would keep
/// it. Use these on paths that run per element or per attribute.
#define HEGO_LOG_TRACE(category, message_expr)                                                                                                                 \
	do                                                                                                                                                         \
	{                                                                                                                                                          \
		if (HEGo::Util::Log::is_enabled(HEGo::Util::Log::LEVEL_TRACE))                                                                                          \
			HEGo::Util::Log::trace(category, message_expr);                                                                                                     \
	} while (0)

#define HEGO_LOG_DEBUG(category, message_expr)                                                                                                                 \
	do                                                                                                                                                         \
	{                                                                                                                                                          \
		if (HEGo::Util::Log::is_enabled(HEGo::Util::Log::LEVEL_DEBUG))                                                                                          \
			HEGo::Util::Log::debug(category, message_expr);                                                                                                     \
	} while (0)

#endif // LOG_H
