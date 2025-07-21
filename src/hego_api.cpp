#include "hego_api.h"

#include "hapi/hego_platform.h"
#include "util/geo/input.h"
#include "util/geo/output.h"
#include "util/geo/transform.h"
#include "util/log/log.h"
#include "util/node/create_nodes.h"
#include "util/parm/set_parms.h"

#include <godot_cpp/classes/dir_access.hpp>
#include <godot_cpp/classes/os.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

namespace HEGo
{
HEGoAPI *HEGoAPI::singleton = nullptr;

HEGoAPI::HEGoAPI() : session_mgr()
{
	singleton = this;

	// Set up Houdini installation path project setting with default
	godot::ProjectSettings *project_settings = godot::ProjectSettings::get_singleton();
	if (!project_settings->has_setting("hego/houdini_installation_path")) {
		project_settings->set_setting("hego/houdini_installation_path", "C:/Program Files/Side Effects Software/Houdini 20.5.654");
	}

	HEGoPlatform::set_env_vars();
}

HEGoAPI::~HEGoAPI()
{
	// Ensure session is stopped before destroying
	if (session_mgr.is_session_active()) {
		HEGo::Util::Log::message(godot::String("HEGoAPI destructor: Stopping active session"));
		session_mgr.stop_session();
	}

	if (singleton == this) {
		singleton = nullptr;
	}
}

HEGoAPI *HEGoAPI::get_singleton() { return singleton; }

bool HEGoAPI::start_session(int connection_type, const godot::String &connection_data)
{
	HEGoPlatform::initialize_hapi();

	// Convert Godot connection type to SessionManager enum
	HEGoSessionManager::SessionType session_type = static_cast<HEGoSessionManager::SessionType>(connection_type);

	// Convert Godot string to std::string
	std::string connection_data_str = std::string(connection_data.utf8().get_data());

	return session_mgr.start_session(session_type, connection_data_str);
}

bool HEGoAPI::stop_session() 
{ 
	return session_mgr.stop_session(); 
}

bool HEGoAPI::is_session_active() 
{ 
	return session_mgr.is_session_active(); 
}

HEGoSessionManager *HEGoAPI::get_session_manager() 
{ 
	return &session_mgr; 
}

void HEGoAPI::set_houdini_installation_path(const godot::String &path)
{
	godot::ProjectSettings *project_settings = godot::ProjectSettings::get_singleton();
	project_settings->set_setting("hego/houdini_installation_path", path);
}

godot::String HEGoAPI::get_houdini_installation_path() const
{
	godot::ProjectSettings *project_settings = godot::ProjectSettings::get_singleton();
	return project_settings->get_setting("hego/houdini_installation_path", "C:/Program Files/Side Effects Software/Houdini 20.5.654");
}

godot::Dictionary HEGoAPI::get_hda_libraries()
{
	godot::Dictionary result;

	if (!session_mgr.is_session_active()) {
		HEGo::Util::Log::error(godot::String("Session is not active. Cannot get HDA libraries."));
		return result;
	}

	HAPI_Result res = HAPI_RESULT_SUCCESS;

	// Get loaded library count
	int library_count = 0;
	res = HoudiniApi::GetLoadedAssetLibraryCount(session_mgr.get_session(), &library_count);
	if (res != HAPI_RESULT_SUCCESS || library_count == 0) {
		HEGo::Util::Log::message(godot::String("No asset libraries loaded"));
		return result;
	}

	// Get library IDs
	HAPI_AssetLibraryId *library_ids = new HAPI_AssetLibraryId[library_count];
	res = HoudiniApi::GetAssetLibraryIds(session_mgr.get_session(), library_ids, 0, library_count);
	if (res != HAPI_RESULT_SUCCESS) {
		delete[] library_ids;
		HEGo::Util::Log::error(godot::String("Failed to get asset library IDs"));
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
	if (houdini_install_path.contains("program files")) {
		// Also check version without "program files" (sometimes reported differently)
		godot::String alt_path = houdini_install_path.replace("program files", "progra~1");
		builtin_paths.append(alt_path);
	}

	// For each library, get library info and assets (filter out built-in libraries)
	for (int i = 0; i < library_count; i++) {
		godot::Dictionary library_info;

		// Get library file path
		HAPI_StringHandle file_path_handle = 0;
		res = HoudiniApi::GetAssetLibraryFilePath(session_mgr.get_session(), library_ids[i], &file_path_handle);
		if (res != HAPI_RESULT_SUCCESS) {
			// Skip libraries where we can't get the file path
			continue;
		}

		{
			int buffer_length = 0;
			res = HoudiniApi::GetStringBufLength(session_mgr.get_session(), file_path_handle, &buffer_length);
			if (res == HAPI_RESULT_SUCCESS && buffer_length > 0) {
				char *buffer = new char[buffer_length];
				res = HoudiniApi::GetString(session_mgr.get_session(), file_path_handle, buffer, buffer_length);
				if (res == HAPI_RESULT_SUCCESS) {
					godot::String full_path = godot::String(buffer);

					// Filter out built-in Houdini libraries by checking if path starts with any known Houdini directories
					godot::String normalized_path = full_path.to_lower().replace("\\", "/");
					bool is_builtin = false;
					for (int j = 0; j < builtin_paths.size(); j++) {
						if (normalized_path.begins_with(builtin_paths[j])) {
							is_builtin = true;
							break;
						}
					}

					if (is_builtin) {
						// Skip built-in Houdini libraries
						delete[] buffer;
						continue;
					}

					library_info["file_path"] = full_path;

					// Extract library name from file path
					godot::String library_name = full_path.get_file().get_basename();
					library_info["name"] = library_name;
				}
				delete[] buffer;
			}
		}

		library_info["id"] = library_ids[i];

		// Get asset count for this library
		int asset_count = 0;
		res = HoudiniApi::GetAvailableAssetCount(session_mgr.get_session(), library_ids[i], &asset_count);
		library_info["asset_count"] = asset_count;

		// Get asset names
		godot::PackedStringArray assets;
		if (res == HAPI_RESULT_SUCCESS && asset_count > 0) {
			HAPI_StringHandle *asset_name_handles = new HAPI_StringHandle[asset_count];
			res = HoudiniApi::GetAvailableAssets(session_mgr.get_session(), library_ids[i], asset_name_handles, asset_count);
			if (res == HAPI_RESULT_SUCCESS) {
				// Convert string handles to actual strings
				for (int j = 0; j < asset_count; j++) {
					int buffer_length = 0;
					res = HoudiniApi::GetStringBufLength(session_mgr.get_session(), asset_name_handles[j], &buffer_length);
					if (res == HAPI_RESULT_SUCCESS && buffer_length > 0) {
						char *buffer = new char[buffer_length];
						res = HoudiniApi::GetString(session_mgr.get_session(), asset_name_handles[j], buffer, buffer_length);
						if (res == HAPI_RESULT_SUCCESS) {
							assets.append(godot::String(buffer));
						}
						delete[] buffer;
					}
				}
			}
			delete[] asset_name_handles;
		}

		library_info["assets"] = assets;

		// Use library name as key, fallback to ID if name not available
		godot::String key = library_info.has("name") ? library_info["name"] : godot::String::num_int64(library_ids[i]);
		result[key] = library_info;
	}

	delete[] library_ids;
	return result;
}

void HEGoAPI::_bind_methods()
{
	godot::ClassDB::bind_method(godot::D_METHOD("start_session", "connection_type", "connection_data"), &HEGoAPI::start_session);
	godot::ClassDB::bind_method(godot::D_METHOD("stop_session"), &HEGoAPI::stop_session);
	godot::ClassDB::bind_method(godot::D_METHOD("is_session_active"), &HEGoAPI::is_session_active);
	godot::ClassDB::bind_method(godot::D_METHOD("set_houdini_installation_path", "path"), &HEGoAPI::set_houdini_installation_path);
	godot::ClassDB::bind_method(godot::D_METHOD("get_houdini_installation_path"), &HEGoAPI::get_houdini_installation_path);
	godot::ClassDB::bind_method(godot::D_METHOD("get_hda_libraries"), &HEGoAPI::get_hda_libraries);

	godot::ClassDB::bind_static_method("HEGoAPI", godot::D_METHOD("get_singleton"), &HEGoAPI::get_singleton);
}
} // namespace HEGo