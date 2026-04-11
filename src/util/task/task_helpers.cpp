#include "util/task/task_helpers.h"

#include "hego_api.h"

namespace HEGo::Util::Task
{

godot::Ref<HEGo::HEGoTask> make_failed(const godot::String &msg, const godot::String &desc, HAPI_NodeId nid)
{
	godot::Ref<HEGoTask> task;
	task.instantiate();
	task->description = desc;
	task->node_id = nid;
	task->error_message = msg;
	task->status.store(HEGoTask::FAILED, std::memory_order_release);
	return task;
}

godot::Ref<HEGo::HEGoTask> submit(const godot::String &desc, HAPI_NodeId nid,
								   std::function<godot::Variant(HEGoSessionManager *)> fn)
{
	godot::Ref<HEGoTask> task;
	task.instantiate();
	task->description = desc;
	task->node_id = nid;
	task->work_fn = std::move(fn);
	return HEGoAPI::get_singleton()->submit_task(task);
}

godot::Ref<HEGo::HEGoTask> make_noop(const godot::String &desc, HAPI_NodeId nid)
{
	godot::Ref<HEGoTask> task;
	task.instantiate();
	task->description = desc;
	task->node_id = nid;
	task->status.store(HEGoTask::COMPLETED, std::memory_order_release);
	return task;
}

} // namespace HEGo::Util::Task
