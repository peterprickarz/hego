#ifndef HEGO_UTIL_TASK_HELPERS_H
#define HEGO_UTIL_TASK_HELPERS_H

#include "hego_task.h"

#include <functional>

#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/variant.hpp>

class HEGoSessionManager;

namespace HEGo::Util::Task
{

// Create a task that is already failed with the given message.
godot::Ref<HEGo::HEGoTask> make_failed(const godot::String &msg, const godot::String &desc = "", HAPI_NodeId nid = -1);

// Create a task, set metadata, assign work_fn, and submit it to the scheduler.
godot::Ref<HEGo::HEGoTask> submit(const godot::String &desc, HAPI_NodeId nid,
								   std::function<godot::Variant(HEGoSessionManager *)> fn);

// Create a task that is already completed with a null result (used for cache-hit early returns).
godot::Ref<HEGo::HEGoTask> make_noop(const godot::String &desc, HAPI_NodeId nid = -1);

} // namespace HEGo::Util::Task

#endif // HEGO_UTIL_TASK_HELPERS_H
