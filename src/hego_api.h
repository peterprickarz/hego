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

public:
	bool start_session(int connection_type = 2, const godot::String &connection_data = "hapi");
	bool stop_session();
	bool is_session_active();
	HEGoSessionManager *get_session_manager();
	void set_houdini_installation_path(const godot::String &path);
	godot::String get_houdini_installation_path() const;
	
	// Get list of available HDAs from all loaded libraries
	godot::PackedStringArray get_available_hdas();

	static HEGoAPI *get_singleton();

	static void _bind_methods(); // Function to bind methods to Godot

	HEGoAPI();
	~HEGoAPI();
};
} // Namespace HEGo
#endif // HEGO_H