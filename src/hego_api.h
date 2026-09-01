#ifndef HEGO_API_H
#define HEGO_API_H

#include <godot_cpp/classes/mesh.hpp>
#include <godot_cpp/classes/mesh_instance3d.hpp>
#include <godot_cpp/classes/object.hpp>
#include <godot_cpp/classes/project_settings.hpp>
#include <godot_cpp/core/class_db.hpp>

#include "hego_session_manager.h"
#include "hego_task.h"
#include "hego_task_scheduler.h"

#include "hapi/houdini_api.h"

namespace HEGo
{
class HEGoAPI : public godot::Object
{
	GDCLASS(HEGoAPI, Object);

private:
	static HEGoAPI *singleton;
	HEGoSessionManager session_mgr;
	HEGoTaskScheduler scheduler;

public:
	// Session types exposed to GDScript, mirroring HEGoSessionManager::SessionType.
	// Only these three can be started; the manager's Existing* types are reserved.
	enum SessionType
	{
		SESSION_IN_PROCESS = HEGoSessionManager::InProcess,
		SESSION_NAMED_PIPE = HEGoSessionManager::NewNamedPipe,
		SESSION_TCP_SOCKET = HEGoSessionManager::NewTCPSocket,
	};

	// connection_data is the pipe or shared memory name, or the port for TCP sessions.
	bool start_session(int connection_type = SESSION_NAMED_PIPE, const godot::String &connection_data = DEFAULT_NAMED_PIPE);
	bool stop_session();
	bool is_session_active();
	HEGoSessionManager *get_session_manager();
	void set_houdini_installation_path(const godot::String &path);
	godot::String get_houdini_installation_path() const;

	// Get dictionary of all loaded HDA libraries with their assets
	godot::Dictionary get_hda_libraries();

	// Task scheduler
	godot::Ref<HEGoTask> submit_task(godot::Ref<HEGoTask> task);
	int get_task_pending_count();
	godot::Ref<HEGoTask> get_current_task();
	godot::Array get_pending_tasks();
	godot::Array get_completed_task_history();
	void clear_completed_task_history();

	static HEGoAPI *get_singleton();

	static void _bind_methods(); // Function to bind methods to Godot

	HEGoAPI();
	~HEGoAPI();
};
} // Namespace HEGo

VARIANT_ENUM_CAST(HEGo::HEGoAPI::SessionType);

#endif // HEGO_API_H