#include "log.h"

#include <godot_cpp/classes/dir_access.hpp>
#include <godot_cpp/classes/project_settings.hpp>
#include <godot_cpp/variant/dictionary.hpp>

#include <algorithm>
#include <chrono>
#include <ctime>
#include <deque>
#include <fstream>
#include <mutex>
#include <set>
#include <thread>
#include <vector>

namespace HEGo
{
namespace Util
{
namespace Log
{
namespace
{
// Prefix on everything HEGo prints, so its output is recognisable in Godot's.
const char *PREFIX = "[Houdini Engine] ";

// Category used by the uncategorised message()/warning()/error() shorthands.
const char *DEFAULT_CATEGORY = "hego";

// Entries kept in memory. At roughly 100 bytes an entry this is a few hundred KB,
// and it is about two orders of magnitude more than the panel shows at once.
constexpr size_t MAX_ENTRIES = 4096;

// Upper bound on how many entries one flush prints, so a burst from a long cook
// cannot stall a frame. The rest goes out on the next flush.
constexpr size_t MAX_ENTRIES_PER_FLUSH = 256;

// Project settings, named after Godot's own debug/file_logging/* settings.
const char *SETTING_STORE_LEVEL = "hego/logging/store_level";
const char *SETTING_OUTPUT_LEVEL = "hego/logging/output_level";
const char *SETTING_ENABLE_FILE_LOGGING = "hego/logging/enable_file_logging";
const char *SETTING_LOG_PATH = "hego/logging/log_path";
const char *SETTING_MAX_LOG_FILES = "hego/logging/max_log_files";

struct Entry
{
	int64_t index = 0;
	int64_t epoch_ms = 0;
	int level = LEVEL_INFO;
	std::string category;
	std::string message;
};

// Everything below is shared between the scheduler's worker thread and the main
// thread, so it all lives behind one mutex. Only std types: no Godot object is
// created, destroyed or refcounted while a worker thread holds the lock.
struct Store
{
	std::mutex mutex;
	std::deque<Entry> entries;
	std::set<std::string> categories;

	int64_t next_index = 0; // Index the next entry will get.
	int64_t output_cursor = 0; // First index flush_to_output() has not printed yet.

	int store_level = LEVEL_DEBUG;
	int output_level = LEVEL_INFO;

	std::ofstream file;
	std::string file_path; // Absolute path, empty when file logging is off.

	// Captured while the extension initialises, which happens on the main thread.
	std::thread::id main_thread_id = std::this_thread::get_id();
};

Store &store()
{
	// Function-local so the logger works during static initialisation, before the
	// HEGoLog singleton exists.
	static Store instance;
	return instance;
}

bool is_main_thread() { return std::this_thread::get_id() == store().main_thread_id; }

int64_t now_epoch_ms()
{
	using namespace std::chrono;
	return duration_cast<milliseconds>(system_clock::now().time_since_epoch()).count();
}

// Local wall clock as HH:MM:SS.mmm. std::localtime shares a static buffer between
// threads, so use the reentrant variants.
std::string format_time(int64_t epoch_ms)
{
	const std::time_t seconds = static_cast<std::time_t>(epoch_ms / 1000);
	std::tm local_time{};
#if defined(_WIN32)
	localtime_s(&local_time, &seconds);
#else
	localtime_r(&seconds, &local_time);
#endif

	char buffer[32];
	std::snprintf(buffer, sizeof(buffer), "%02d:%02d:%02d.%03d", local_time.tm_hour, local_time.tm_min, local_time.tm_sec, static_cast<int>(epoch_ms % 1000));
	return std::string(buffer);
}

const char *level_to_cstr(int level)
{
	switch (level)
	{
		case LEVEL_TRACE:
			return "TRACE";
		case LEVEL_DEBUG:
			return "DEBUG";
		case LEVEL_INFO:
			return "INFO";
		case LEVEL_WARNING:
			return "WARNING";
		case LEVEL_ERROR:
			return "ERROR";
		default:
			return "INFO";
	}
}

// One line as it appears in the log file and in the panel export.
std::string format_line(const Entry &entry)
{
	return format_time(entry.epoch_ms) + " [" + level_to_cstr(entry.level) + "] [" + entry.category + "] " + entry.message;
}

// Timestamp suffix for a session's log file, sortable and filename safe.
std::string file_timestamp()
{
	const std::time_t seconds = static_cast<std::time_t>(now_epoch_ms() / 1000);
	std::tm local_time{};
#if defined(_WIN32)
	localtime_s(&local_time, &seconds);
#else
	localtime_r(&seconds, &local_time);
#endif

	char buffer[32];
	std::snprintf(buffer, sizeof(buffer), "%04d-%02d-%02d_%02d.%02d.%02d", local_time.tm_year + 1900, local_time.tm_mon + 1, local_time.tm_mday, local_time.tm_hour,
			local_time.tm_min, local_time.tm_sec);
	return std::string(buffer);
}

// Reads a project setting, registering it with its default the first time so it
// shows up in the Project Settings dialog.
godot::Variant setting(const char *name, const godot::Variant &default_value)
{
	godot::ProjectSettings *settings = godot::ProjectSettings::get_singleton();
	if (settings == nullptr)
	{
		return default_value;
	}
	if (!settings->has_setting(name))
	{
		settings->set_setting(name, default_value);
		settings->set_initial_value(name, default_value);
	}
	return settings->get_setting(name, default_value);
}

// Deletes the oldest session logs, keeping at most max_files of them. Runs on the
// main thread, from configure(), because it uses Godot's DirAccess.
void prune_old_logs(const godot::String &directory, const godot::String &prefix, const godot::String &extension, int max_files)
{
	if (max_files <= 0)
	{
		return; // Keep everything.
	}

	godot::Ref<godot::DirAccess> dir = godot::DirAccess::open(directory);
	if (dir.is_null())
	{
		return;
	}

	// Names carry a sortable timestamp, so sorting by name sorts by age.
	godot::PackedStringArray logs;
	for (const godot::String &file_name : dir->get_files())
	{
		if (file_name.begins_with(prefix) && file_name.ends_with(extension))
		{
			logs.append(file_name);
		}
	}
	logs.sort();

	for (int i = 0; i < logs.size() - max_files; i++)
	{
		dir->remove(logs[i]);
	}
}
} // namespace

bool is_enabled(Level level)
{
	Store &s = store();
	std::lock_guard<std::mutex> lock(s.mutex);
	return level >= s.store_level;
}

void write(Level level, const char *category, const godot::String &message)
{
	const std::string message_utf8 = message.utf8().get_data();
	const char *entry_category = (category != nullptr && category[0] != '\0') ? category : DEFAULT_CATEGORY;

	{
		Store &s = store();
		std::lock_guard<std::mutex> lock(s.mutex);
		if (level < s.store_level)
		{
			return;
		}

		Entry entry;
		entry.index = s.next_index++;
		entry.epoch_ms = now_epoch_ms();
		entry.level = level;
		entry.category = entry_category;
		entry.message = message_utf8;

		// Written straight away rather than from the flush, so the tail of the log
		// survives a crash in the middle of a cook.
		if (s.file.is_open())
		{
			s.file << format_line(entry) << '\n';
			s.file.flush();
		}

		s.categories.insert(entry.category);
		s.entries.push_back(std::move(entry));
		while (s.entries.size() > MAX_ENTRIES)
		{
			s.entries.pop_front();
		}
	}

	// Printing has to happen on the main thread. When we are already there, do it
	// now so ordering matches the caller's; otherwise the next flush picks it up.
	if (is_main_thread())
	{
		flush_to_output();
	}
}

void trace(const char *category, const godot::String &message) { write(LEVEL_TRACE, category, message); }
void debug(const char *category, const godot::String &message) { write(LEVEL_DEBUG, category, message); }
void info(const char *category, const godot::String &message) { write(LEVEL_INFO, category, message); }
void warning(const char *category, const godot::String &message) { write(LEVEL_WARNING, category, message); }
void error(const char *category, const godot::String &message) { write(LEVEL_ERROR, category, message); }

void message(const godot::String &msg) { write(LEVEL_INFO, DEFAULT_CATEGORY, msg); }
void warning(const godot::String &msg) { write(LEVEL_WARNING, DEFAULT_CATEGORY, msg); }
void error(const godot::String &msg) { write(LEVEL_ERROR, DEFAULT_CATEGORY, msg); }
void line() { write(LEVEL_DEBUG, DEFAULT_CATEGORY, "---------------------"); }

void flush_to_output()
{
	if (!is_main_thread())
	{
		return;
	}

	// Copy out what has to be printed, then print outside the lock: push_error()
	// can re-enter user code, and a worker thread must not be blocked on that.
	std::vector<Entry> pending;
	{
		Store &s = store();
		std::lock_guard<std::mutex> lock(s.mutex);
		if (s.entries.empty())
		{
			return;
		}

		// Entries evicted before being printed are gone; start from the oldest
		// entry still held.
		const int64_t oldest_index = s.entries.front().index;
		int64_t cursor = std::max(s.output_cursor, oldest_index);

		for (const Entry &entry : s.entries)
		{
			if (entry.index < cursor)
			{
				continue;
			}
			if (pending.size() >= MAX_ENTRIES_PER_FLUSH)
			{
				break;
			}
			cursor = entry.index + 1;
			if (entry.level >= s.output_level)
			{
				pending.push_back(entry);
			}
		}
		s.output_cursor = cursor;
	}

	for (const Entry &entry : pending)
	{
		const godot::String text = godot::String(PREFIX) + godot::String::utf8(("[" + entry.category + "] " + entry.message).c_str());
		switch (entry.level)
		{
			case LEVEL_WARNING:
				// Keeps HEGo's warnings and errors in Godot's debugger, where users
				// already look for them, on top of the session panel.
				godot::UtilityFunctions::push_warning(text);
				break;
			case LEVEL_ERROR:
				godot::UtilityFunctions::push_error(text);
				break;
			default:
				godot::UtilityFunctions::print(text);
				break;
		}
	}
}

HEGoLog *HEGoLog::singleton = nullptr;

HEGoLog::HEGoLog() { singleton = this; }

HEGoLog::~HEGoLog()
{
	{
		Store &s = store();
		std::lock_guard<std::mutex> lock(s.mutex);
		if (s.file.is_open())
		{
			s.file.close();
		}
	}

	if (singleton == this)
	{
		singleton = nullptr;
	}
}

HEGoLog *HEGoLog::get_singleton() { return singleton; }

void HEGoLog::configure()
{
	const int store_level = static_cast<int>(setting(SETTING_STORE_LEVEL, LEVEL_DEBUG));
	const int output_level = static_cast<int>(setting(SETTING_OUTPUT_LEVEL, LEVEL_INFO));
	const bool file_logging = setting(SETTING_ENABLE_FILE_LOGGING, false);
	const godot::String log_path = setting(SETTING_LOG_PATH, "user://hego_logs/hego.log");
	const int max_log_files = static_cast<int>(setting(SETTING_MAX_LOG_FILES, 5));

	{
		Store &s = store();
		std::lock_guard<std::mutex> lock(s.mutex);
		s.store_level = std::clamp(store_level, static_cast<int>(LEVEL_TRACE), static_cast<int>(LEVEL_ERROR));
		s.output_level = std::clamp(output_level, static_cast<int>(LEVEL_TRACE), static_cast<int>(LEVEL_ERROR));
		if (s.file.is_open())
		{
			s.file.close();
		}
		s.file_path.clear();
	}

	if (!file_logging || log_path.is_empty())
	{
		return;
	}

	// One file per session, named after the configured path with a timestamp, so
	// max_log_files sessions of history are kept side by side.
	const godot::String directory = log_path.get_base_dir();
	const godot::String prefix = log_path.get_file().get_basename() + "_";
	const godot::String extension = "." + log_path.get_extension();

	if (!godot::DirAccess::dir_exists_absolute(directory) && godot::DirAccess::make_dir_recursive_absolute(directory) != godot::OK)
	{
		godot::UtilityFunctions::push_warning(godot::String(PREFIX) + "Could not create log directory " + directory + ", file logging is off.");
		return;
	}

	prune_old_logs(directory, prefix, extension, max_log_files - 1);

	// Resolved here, on the main thread, so worker threads can write to the file
	// without going through Godot's path handling.
	const godot::String session_path = directory.path_join(prefix + godot::String(file_timestamp().c_str()) + extension);
	const std::string absolute_path = godot::ProjectSettings::get_singleton()->globalize_path(session_path).utf8().get_data();

	Store &s = store();
	std::lock_guard<std::mutex> lock(s.mutex);
	s.file.open(absolute_path, std::ios::out | std::ios::trunc);
	if (!s.file.is_open())
	{
		godot::UtilityFunctions::push_warning(godot::String(PREFIX) + "Could not open log file " + session_path + ", file logging is off.");
		return;
	}
	s.file_path = absolute_path;
}

void HEGoLog::log_message(int level, const godot::String &category, const godot::String &message)
{
	const std::string category_utf8 = category.utf8().get_data();
	write(static_cast<Level>(std::clamp(level, static_cast<int>(LEVEL_TRACE), static_cast<int>(LEVEL_ERROR))), category_utf8.c_str(), message);
}

void HEGoLog::log_trace(const godot::String &category, const godot::String &message) { log_message(LEVEL_TRACE, category, message); }
void HEGoLog::log_debug(const godot::String &category, const godot::String &message) { log_message(LEVEL_DEBUG, category, message); }
void HEGoLog::log_info(const godot::String &category, const godot::String &message) { log_message(LEVEL_INFO, category, message); }
void HEGoLog::log_warning(const godot::String &category, const godot::String &message) { log_message(LEVEL_WARNING, category, message); }
void HEGoLog::log_error(const godot::String &category, const godot::String &message) { log_message(LEVEL_ERROR, category, message); }

int64_t HEGoLog::get_cursor() const
{
	Store &s = store();
	std::lock_guard<std::mutex> lock(s.mutex);
	return s.next_index;
}

godot::Array HEGoLog::get_entries_since(int64_t cursor, int min_level) const
{
	godot::Array result;

	Store &s = store();
	std::lock_guard<std::mutex> lock(s.mutex);
	for (const Entry &entry : s.entries)
	{
		if (entry.index < cursor || entry.level < min_level)
		{
			continue;
		}

		godot::Dictionary dict;
		dict["index"] = entry.index;
		dict["time"] = godot::String(format_time(entry.epoch_ms).c_str());
		dict["level"] = entry.level;
		dict["level_name"] = godot::String(level_to_cstr(entry.level));
		dict["category"] = godot::String::utf8(entry.category.c_str());
		dict["message"] = godot::String::utf8(entry.message.c_str());
		result.push_back(dict);
	}

	return result;
}

godot::PackedStringArray HEGoLog::get_categories() const
{
	godot::PackedStringArray result;

	Store &s = store();
	std::lock_guard<std::mutex> lock(s.mutex);
	for (const std::string &category : s.categories)
	{
		result.append(godot::String::utf8(category.c_str()));
	}

	return result;
}

void HEGoLog::clear()
{
	Store &s = store();
	std::lock_guard<std::mutex> lock(s.mutex);
	s.entries.clear();
	s.categories.clear();
	s.output_cursor = s.next_index;
}

bool HEGoLog::save_to_file(const godot::String &path) const
{
	std::vector<std::string> lines;
	{
		Store &s = store();
		std::lock_guard<std::mutex> lock(s.mutex);
		lines.reserve(s.entries.size());
		for (const Entry &entry : s.entries)
		{
			lines.push_back(format_line(entry));
		}
	}

	const std::string absolute_path = godot::ProjectSettings::get_singleton()->globalize_path(path).utf8().get_data();
	std::ofstream out(absolute_path, std::ios::out | std::ios::trunc);
	if (!out.is_open())
	{
		return false;
	}

	for (const std::string &line_text : lines)
	{
		out << line_text << '\n';
	}
	return true;
}

void HEGoLog::flush() { flush_to_output(); }

void HEGoLog::set_store_level(int level)
{
	Store &s = store();
	std::lock_guard<std::mutex> lock(s.mutex);
	s.store_level = std::clamp(level, static_cast<int>(LEVEL_TRACE), static_cast<int>(LEVEL_ERROR));
}

int HEGoLog::get_store_level() const
{
	Store &s = store();
	std::lock_guard<std::mutex> lock(s.mutex);
	return s.store_level;
}

void HEGoLog::set_output_level(int level)
{
	Store &s = store();
	std::lock_guard<std::mutex> lock(s.mutex);
	s.output_level = std::clamp(level, static_cast<int>(LEVEL_TRACE), static_cast<int>(LEVEL_ERROR));
}

int HEGoLog::get_output_level() const
{
	Store &s = store();
	std::lock_guard<std::mutex> lock(s.mutex);
	return s.output_level;
}

godot::String HEGoLog::get_log_file_path() const
{
	Store &s = store();
	std::lock_guard<std::mutex> lock(s.mutex);
	return godot::String::utf8(s.file_path.c_str());
}

godot::String HEGoLog::level_name(int level) { return godot::String(level_to_cstr(level)); }

void HEGoLog::_bind_methods()
{
	godot::ClassDB::bind_static_method("HEGoLog", godot::D_METHOD("get_singleton"), &HEGoLog::get_singleton);
	godot::ClassDB::bind_static_method("HEGoLog", godot::D_METHOD("level_name", "level"), &HEGoLog::level_name);

	godot::ClassDB::bind_method(godot::D_METHOD("configure"), &HEGoLog::configure);
	godot::ClassDB::bind_method(godot::D_METHOD("log_message", "level", "category", "message"), &HEGoLog::log_message);
	godot::ClassDB::bind_method(godot::D_METHOD("trace", "category", "message"), &HEGoLog::log_trace);
	godot::ClassDB::bind_method(godot::D_METHOD("debug", "category", "message"), &HEGoLog::log_debug);
	godot::ClassDB::bind_method(godot::D_METHOD("info", "category", "message"), &HEGoLog::log_info);
	godot::ClassDB::bind_method(godot::D_METHOD("warning", "category", "message"), &HEGoLog::log_warning);
	godot::ClassDB::bind_method(godot::D_METHOD("error", "category", "message"), &HEGoLog::log_error);

	godot::ClassDB::bind_method(godot::D_METHOD("get_cursor"), &HEGoLog::get_cursor);
	godot::ClassDB::bind_method(godot::D_METHOD("get_entries_since", "cursor", "min_level"), &HEGoLog::get_entries_since, DEFVAL(LEVEL_TRACE));
	godot::ClassDB::bind_method(godot::D_METHOD("get_categories"), &HEGoLog::get_categories);
	godot::ClassDB::bind_method(godot::D_METHOD("clear"), &HEGoLog::clear);
	godot::ClassDB::bind_method(godot::D_METHOD("save_to_file", "path"), &HEGoLog::save_to_file);
	godot::ClassDB::bind_method(godot::D_METHOD("flush"), &HEGoLog::flush);
	godot::ClassDB::bind_method(godot::D_METHOD("get_log_file_path"), &HEGoLog::get_log_file_path);

	godot::ClassDB::bind_method(godot::D_METHOD("set_store_level", "level"), &HEGoLog::set_store_level);
	godot::ClassDB::bind_method(godot::D_METHOD("get_store_level"), &HEGoLog::get_store_level);
	godot::ClassDB::bind_method(godot::D_METHOD("set_output_level", "level"), &HEGoLog::set_output_level);
	godot::ClassDB::bind_method(godot::D_METHOD("get_output_level"), &HEGoLog::get_output_level);

	BIND_ENUM_CONSTANT(LEVEL_TRACE);
	BIND_ENUM_CONSTANT(LEVEL_DEBUG);
	BIND_ENUM_CONSTANT(LEVEL_INFO);
	BIND_ENUM_CONSTANT(LEVEL_WARNING);
	BIND_ENUM_CONSTANT(LEVEL_ERROR);
}

} // namespace Log
} // namespace Util
} // namespace HEGo
