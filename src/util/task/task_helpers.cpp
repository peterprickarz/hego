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

godot::Ref<HEGo::HEGoTask> submit_failable(const godot::String &desc, HAPI_NodeId nid,
								   std::function<godot::Variant(HEGoSessionManager *, HEGo::HEGoTask *)> fn)
{
	godot::Ref<HEGoTask> task;
	task.instantiate();
	task->description = desc;
	task->node_id = nid;

	// A raw pointer rather than a Ref, because the lambda this captures into lives on the
	// task itself: a Ref would make the task hold itself alive forever. The scheduler owns a
	// Ref for as long as the work runs, which is the only time the pointer is used.
	HEGoTask *raw_task = task.ptr();
	task->work_fn = [raw_task, work = std::move(fn)](HEGoSessionManager *mgr) -> godot::Variant {
		return work(mgr, raw_task);
	};

	return HEGoAPI::get_singleton()->submit_task(task);
}

void fail(HEGo::HEGoTask *task, const godot::String &msg)
{
	if (task == nullptr)
	{
		return;
	}
	task->error_message = msg;
	task->status.store(HEGoTask::FAILED, std::memory_order_release);
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
