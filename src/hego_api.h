#ifndef HEGO_API_H
#define HEGO_API_H

#include <godot_cpp/classes/mesh.hpp>
#include <godot_cpp/classes/mesh_instance3d.hpp>
#include <godot_cpp/classes/object.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/classes/project_settings.hpp>

#include "hego_session_manager.h"

#include "hapi/houdini_api.h"

namespace HEGo
{
class HEGoAPI : public godot::Object
{
	GDCLASS(HEGoAPI, Object);

private:
	static HEGoAPI *singleton;
	HEGoSessionManager session_mgr;
	void *libHAPIL;
	
	// Track explicitly loaded libraries
	godot::Array explicitly_loaded_libraries;

public:
	bool start_session(int connection_type = 2, const godot::String &connection_data = "hapi");
	bool stop_session();
	bool is_session_active();
	HEGoSessionManager *get_session_manager();
	void set_houdini_installation_path(const godot::String &path);
	godot::String get_houdini_installation_path() const;
	
	// Get list of available HDAs from all loaded libraries
	godot::PackedStringArray get_available_hdas();
	
	// Get dictionary of all loaded HDA libraries with their assets
	godot::Dictionary get_hda_libraries();
	
	// Load an HDA library from file path
	bool load_hda_library(const godot::String &file_path);
	
	// Get information about a specific loaded library
	godot::Dictionary get_library_info(int library_id);
	
	// Get only explicitly loaded libraries (not built-in)
	godot::Dictionary get_user_hda_libraries();
	
	// Get common user HDA directory paths for scanning
	godot::PackedStringArray scan_user_hda_directories();

	static HEGoAPI *get_singleton();

	static void _bind_methods(); // Function to bind methods to Godot

	HEGoAPI();
	~HEGoAPI();
};
} // Namespace HEGo
#endif // HEGO_H