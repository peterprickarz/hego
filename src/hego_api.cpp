#include "hego_api.h"

#include "hapi/hego_platform.h"
#include "util/geo/input.h"
#include "util/geo/output.h"
#include "util/geo/transform.h"
#include "util/hego_util.h"
#include "util/log/log.h"
#include "util/node/create_nodes.h"
#include "util/parm/set_parms.h"

#include <godot_cpp/classes/dir_access.hpp>
#include <godot_cpp/classes/os.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <vector>

namespace HEGo
{
namespace
{
// Project setting holding the Houdini install HEGo talks to.
const char *HOUDINI_PATH_SETTING = "hego/houdini_installation_path";
} // namespace

HEGoAPI *HEGoAPI::singleton = nullptr;

HEGoAPI::HEGoAPI() : session_mgr()
{
	singleton = this;

	// Set up Houdini installation path project setting with default
	godot::ProjectSettings *project_settings = godot::ProjectSettings::get_singleton();
	if (!project_settings->has_setting(HOUDINI_PATH_SETTING))
	{
		project_settings->set_setting(HOUDINI_PATH_SETTING, HEGoPlatform::get_default_houdini_path());
	}

	HEGoPlatform::set_env_vars();
}

HEGoAPI::~HEGoAPI()
{
	// Stop scheduler first — worker thread must exit before session cleanup
	scheduler.stop();

	if (session_mgr.is_session_active())
	{
		HEGo::Util::Log::debug(HEGo::Util::Log::Category::SESSION, godot::String("HEGoAPI destructor: Stopping active session"));
		session_mgr.stop_session();
	}

	if (singleton == this)
	{
		singleton = nullptr;
	}
}

HEGoAPI *HEGoAPI::get_singleton() { return singleton; }

bool HEGoAPI::start_session(int connection_type, const godot::String &connection_data)
{
	HEGo::Util::Log::debug(HEGo::Util::Log::Category::SESSION, connection_data);

	// connection_type comes straight from GDScript, so check it names a session
	// type we can actually start before casting it to the enum.
	if (!HEGoSessionManager::is_supported_session_type(connection_type))
	{
		HEGo::Util::Log::error(HEGo::Util::Log::Category::SESSION, godot::String("Unsupported session type ") + godot::String::num_int64(connection_type) +
				". Use HEGoAPI.SESSION_IN_PROCESS, SESSION_NAMED_PIPE or SESSION_TCP_SOCKET.");
		return false;
	}

	HEGoSessionManager::SessionType session_type = static_cast<HEGoSessionManager::SessionType>(connection_type);

	// Convert Godot string to std::string
	std::string connection_data_str = std::string(connection_data.utf8().get_data());

	bool success = session_mgr.start_session(session_type, connection_data_str);
	if (success)
	{
		scheduler.start(&session_mgr);
	}
	return success;
}

bool HEGoAPI::stop_session()
{
	scheduler.stop();
	return session_mgr.stop_session();
}

bool HEGoAPI::is_session_active() { return session_mgr.is_session_active(); }

HEGoSessionManager *HEGoAPI::get_session_manager() { return &session_mgr; }

void HEGoAPI::set_houdini_installation_path(const godot::String &path)
{
	godot::ProjectSettings *project_settings = godot::ProjectSettings::get_singleton();
	project_settings->set_setting(HOUDINI_PATH_SETTING, path);
}

godot::String HEGoAPI::get_houdini_installation_path() const
{
	// Resolved the same way the loader resolves it, so the setting, $HFS and this
	// platform's default are consulted in that order. Reading the setting directly
	// would hand back an empty string when it is set but blank, and an empty prefix
	// makes every library look built-in in get_hda_libraries().
	return godot::String(HEGoPlatform::get_houdini_path());
}

godot::Dictionary HEGoAPI::get_hda_libraries()
{
	godot::Dictionary result;

	if (!session_mgr.is_session_active())
	{
		HEGo::Util::Log::error(HEGo::Util::Log::Category::SESSION, godot::String("Session is not active. Cannot get HDA libraries."));
		return result;
	}

	HAPI_Result res = HAPI_RESULT_SUCCESS;

	// Get loaded library count
	int library_count = 0;
	res = HoudiniApi::GetLoadedAssetLibraryCount(session_mgr.get_session(), &library_count);
	if (res != HAPI_RESULT_SUCCESS || library_count == 0)
	{
		HEGo::Util::Log::debug(HEGo::Util::Log::Category::SESSION, godot::String("No asset libraries loaded"));
		return result;
	}

	// Get library IDs
	std::vector<HAPI_AssetLibraryId> library_ids(library_count);
	res = HoudiniApi::GetAssetLibraryIds(session_mgr.get_session(), library_ids.data(), 0, library_count);
	if (res != HAPI_RESULT_SUCCESS)
	{
		HEGo::Util::Log::error(HEGo::Util::Log::Category::SESSION, godot::String("Failed to get asset library IDs"));
		return result;
	}

	// Get Houdini installation path for filtering built-in libraries
	godot::String houdini_install_path = get_houdini_installation_path().to_lower();
	// Normalize path separators to forward slashes for comparison
	houdini_install_path = houdini_install_path.replace("\\", "/");

	// Additional common Houdini built-in paths to filter
	godot::PackedStringArray builtin_paths;
	builtin_paths.append(houdini_install_path);
	builtin_paths.append(houdini_install_path + "/houdini");
	builtin_paths.append(houdini_install_path + "/otls");
	if (houdini_install_path.contains("program files"))
	{
		// Also check version without "program files" (sometimes reported differently)
		godot::String alt_path = houdini_install_path.replace("program files", "progra~1");
		builtin_paths.append(alt_path);
	}

	// For each library, get library info and assets (filter out built-in libraries)
	for (int i = 0; i < library_count; i++)
	{
		godot::Dictionary library_info;

		// Get library file path
		HAPI_StringHandle file_path_handle = 0;
		res = HoudiniApi::GetAssetLibraryFilePath(session_mgr.get_session(), library_ids[i], &file_path_handle);
		if (res != HAPI_RESULT_SUCCESS)
		{
			// Skip libraries where we can't get the file path
			continue;
		}

		godot::String full_path = HEGo::Util::Hapi::get_godot_string(session_mgr.get_session(), file_path_handle);
		if (!full_path.is_empty())
		{
			// Filter out built-in Houdini libraries by checking if path starts with any known Houdini directories
			godot::String normalized_path = full_path.to_lower().replace("\\", "/");
			bool is_builtin = false;
			for (int j = 0; j < builtin_paths.size(); j++)
			{
				if (normalized_path.begins_with(builtin_paths[j]))
				{
					is_builtin = true;
					break;
				}
			}

			// Skip built-in Houdini libraries
			if (is_builtin)
			{
				continue;
			}

			library_info["file_path"] = full_path;

			// Extract library name from file path
			library_info["name"] = full_path.get_file().get_basename();
		}

		library_info["id"] = library_ids[i];

		// Get asset count for this library
		int asset_count = 0;
		res = HoudiniApi::GetAvailableAssetCount(session_mgr.get_session(), library_ids[i], &asset_count);
		library_info["asset_count"] = asset_count;

		// Get asset names
		godot::PackedStringArray assets;
		if (res == HAPI_RESULT_SUCCESS && asset_count > 0)
		{
			std::vector<HAPI_StringHandle> asset_name_handles(asset_count);
			res = HoudiniApi::GetAvailableAssets(session_mgr.get_session(), library_ids[i], asset_name_handles.data(), asset_count);
			if (res == HAPI_RESULT_SUCCESS)
			{
				// Convert string handles to actual strings
				for (int j = 0; j < asset_count; j++)
				{
					godot::String asset_name = HEGo::Util::Hapi::get_godot_string(session_mgr.get_session(), asset_name_handles[j]);
					if (!asset_name.is_empty())
					{
						assets.append(asset_name);
					}
				}
			}
		}

		library_info["assets"] = assets;

		// Use library name as key, fallback to ID if name not available
		godot::String key = library_info.has("name") ? library_info["name"] : godot::Variant(godot::String::num_int64(library_ids[i]));
		result[key] = library_info;
	}

	return result;
}

godot::Ref<HEGoTask> HEGoAPI::submit_task(godot::Ref<HEGoTask> task) { return scheduler.submit(task); }

int HEGoAPI::get_task_pending_count() { return scheduler.get_pending_count(); }

godot::Ref<HEGoTask> HEGoAPI::get_current_task() { return scheduler.get_current_task(); }

godot::Array HEGoAPI::get_pending_tasks() { return scheduler.get_pending_tasks(); }

godot::Array HEGoAPI::get_completed_task_history() { return scheduler.get_completed_history(); }

void HEGoAPI::clear_completed_task_history() { scheduler.clear_completed_history(); }

void HEGoAPI::_bind_methods()
{
	godot::ClassDB::bind_method(godot::D_METHOD("start_session", "connection_type", "connection_data"), &HEGoAPI::start_session);
	godot::ClassDB::bind_method(godot::D_METHOD("stop_session"), &HEGoAPI::stop_session);
	godot::ClassDB::bind_method(godot::D_METHOD("is_session_active"), &HEGoAPI::is_session_active);
	godot::ClassDB::bind_method(godot::D_METHOD("set_houdini_installation_path", "path"), &HEGoAPI::set_houdini_installation_path);
	godot::ClassDB::bind_method(godot::D_METHOD("get_houdini_installation_path"), &HEGoAPI::get_houdini_installation_path);
	godot::ClassDB::bind_method(godot::D_METHOD("get_hda_libraries"), &HEGoAPI::get_hda_libraries);

	// Task scheduler
	godot::ClassDB::bind_method(godot::D_METHOD("submit_task", "task"), &HEGoAPI::submit_task);
	godot::ClassDB::bind_method(godot::D_METHOD("get_task_pending_count"), &HEGoAPI::get_task_pending_count);
	godot::ClassDB::bind_method(godot::D_METHOD("get_current_task"), &HEGoAPI::get_current_task);
	godot::ClassDB::bind_method(godot::D_METHOD("get_pending_tasks"), &HEGoAPI::get_pending_tasks);
	godot::ClassDB::bind_method(godot::D_METHOD("get_completed_task_history"), &HEGoAPI::get_completed_task_history);
	godot::ClassDB::bind_method(godot::D_METHOD("clear_completed_task_history"), &HEGoAPI::clear_completed_task_history);

	godot::ClassDB::bind_static_method("HEGoAPI", godot::D_METHOD("get_singleton"), &HEGoAPI::get_singleton);

	// So GDScript can say HEGoAPI.SESSION_NAMED_PIPE instead of a bare 2.
	BIND_ENUM_CONSTANT(SESSION_IN_PROCESS);
	BIND_ENUM_CONSTANT(SESSION_NAMED_PIPE);
	BIND_ENUM_CONSTANT(SESSION_TCP_SOCKET);
}
} // namespace HEGo