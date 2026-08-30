#ifndef HEGO_TASK_H
#define HEGO_TASK_H

#include <atomic>
#include <functional>

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/variant.hpp>

#include "hapi/houdini_api.h"

class HEGoSessionManager;

namespace HEGo
{
class HEGoTask : public godot::RefCounted
{
	GDCLASS(HEGoTask, godot::RefCounted)

public:
	enum Status
	{
		PENDING = 0,
		RUNNING = 1,
		COMPLETED = 2,
		FAILED = 3
	};

	HEGoTask();
	~HEGoTask();

	// Task execution — called by the scheduler on the worker thread
	godot::Variant execute(HEGoSessionManager *mgr);

	// GDScript-bound getters
	int get_status() const;
	godot::Variant get_result() const;
	godot::String get_error_message() const;
	godot::String get_description() const;
	int get_node_id() const;

	// Status — atomic for cross-thread polling
	std::atomic<int> status{PENDING};

	// Result and error — written by worker before status is set to COMPLETED/FAILED
	godot::Variant result;
	godot::String error_message;

	// Metadata for UI display
	godot::String description;
	HAPI_NodeId node_id = -1;

	// The work function — a lambda capturing the data it needs
	std::function<godot::Variant(HEGoSessionManager *)> work_fn;

	static void _bind_methods();
};

} // namespace HEGo

VARIANT_ENUM_CAST(HEGo::HEGoTask::Status);

#endif // HEGO_TASK_H
