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

// The same, but the work function is handed its own task so it can fail it.
//
// submit() can only report a result, so work that goes wrong has to encode that in the value
// it returns, and every caller has to know the encoding. Work submitted here calls fail() and
// the task is FAILED, which is what a script's null check already looks for.
godot::Ref<HEGo::HEGoTask> submit_failable(const godot::String &desc, HAPI_NodeId nid,
								   std::function<godot::Variant(HEGoSessionManager *, HEGo::HEGoTask *)> fn);

// Mark a running task failed from inside its own work function.
void fail(HEGo::HEGoTask *task, const godot::String &msg);

// Create a task that is already completed with a null result (used for cache-hit early returns).
godot::Ref<HEGo::HEGoTask> make_noop(const godot::String &desc, HAPI_NodeId nid = -1);

} // namespace HEGo::Util::Task

#endif // HEGO_UTIL_TASK_HELPERS_H
