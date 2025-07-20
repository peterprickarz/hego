#include "hego_api.h"

#include "hapi/hego_platform.h"
#include "util/geo/input.h"
#include "util/geo/output.h"
#include "util/geo/transform.h"
#include "util/log/log.h"
#include "util/node/create_nodes.h"
#include "util/parm/set_parms.h"

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
	if (singleton == this)
	{
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

HEGoSessionManager *HEGoAPI::get_session_manager() { return &session_mgr; }

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

godot::PackedStringArray HEGoAPI::get_available_hdas()
{
	godot::PackedStringArray result;
	
	if (HAPI_RESULT_SUCCESS != HoudiniApi::IsSessionValid(session_mgr.get_session())) {
		HEGo::Util::Log::error("Session not valid, cannot get available HDAs");
		return result;
	}
	
	// Get count of loaded asset libraries
	int library_count = 0;
	HAPI_Result res = HoudiniApi::GetLoadedAssetLibraryCount(session_mgr.get_session(), &library_count);
	if (res != HAPI_RESULT_SUCCESS) {
		HEGo::Util::Log::error("Failed to get loaded asset library count");
		return result;
	}
	
	if (library_count == 0) {
		return result;
	}
	
	// Get library IDs
	HAPI_AssetLibraryId *library_ids = new HAPI_AssetLibraryId[library_count];
	res = HoudiniApi::GetAssetLibraryIds(session_mgr.get_session(), library_ids, 0, library_count);
	if (res != HAPI_RESULT_SUCCESS) {
		delete[] library_ids;
		HEGo::Util::Log::error("Failed to get asset library IDs");
		return result;
	}
	
	// For each library, get available assets
	for (int i = 0; i < library_count; i++) {
		int asset_count = 0;
		res = HoudiniApi::GetAvailableAssetCount(session_mgr.get_session(), library_ids[i], &asset_count);
		if (res != HAPI_RESULT_SUCCESS || asset_count == 0) {
			continue;
		}
		
		// Get asset names
		HAPI_StringHandle *asset_name_handles = new HAPI_StringHandle[asset_count];
		res = HoudiniApi::GetAvailableAssets(session_mgr.get_session(), library_ids[i], asset_name_handles, asset_count);
		if (res != HAPI_RESULT_SUCCESS) {
			delete[] asset_name_handles;
			continue;
		}
		
		// Convert string handles to actual strings
		for (int j = 0; j < asset_count; j++) {
			int buffer_length = 0;
			res = HoudiniApi::GetStringBufLength(session_mgr.get_session(), asset_name_handles[j], &buffer_length);
			if (res != HAPI_RESULT_SUCCESS || buffer_length == 0) {
				continue;
			}
			
			char *buffer = new char[buffer_length];
			res = HoudiniApi::GetString(session_mgr.get_session(), asset_name_handles[j], buffer, buffer_length);
			if (res == HAPI_RESULT_SUCCESS) {
				result.append(godot::String(buffer));
			}
			delete[] buffer;
		}
		
		delete[] asset_name_handles;
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
	godot::ClassDB::bind_method(godot::D_METHOD("get_available_hdas"), &HEGoAPI::get_available_hdas);

	godot::ClassDB::bind_static_method("HEGoAPI", godot::D_METHOD("get_singleton"), &HEGoAPI::get_singleton);
}
} // namespace HEGo