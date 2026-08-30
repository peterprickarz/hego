#include "hego_task_scheduler.h"

#include "hego_session_manager.h"
#include "util/log/log.h"

namespace HEGo
{
HEGoTaskScheduler::HEGoTaskScheduler() {}

HEGoTaskScheduler::~HEGoTaskScheduler()
{
	if (running.load())
	{
		stop();
	}
}

void HEGoTaskScheduler::start(HEGoSessionManager *mgr)
{
	if (running.load())
	{
		return;
	}

	session_mgr = mgr;
	running.store(true);
	worker_thread = std::thread(&HEGoTaskScheduler::worker_loop, this);

	HEGo::Util::Log::message("Task scheduler started.");
}

void HEGoTaskScheduler::stop()
{
	if (!running.load())
	{
		return;
	}

	running.store(false);
	queue_cv.notify_one();

	if (worker_thread.joinable())
	{
		worker_thread.join();
	}

	// Fail any remaining queued tasks
	{
		std::lock_guard<std::mutex> lock(queue_mutex);
		for (godot::Ref<HEGoTask> &task : task_queue)
		{
			task->error_message = "Scheduler stopped before task could execute.";
			task->status.store(HEGoTask::FAILED, std::memory_order_release);
		}
		task_queue.clear();
	}

	{
		std::lock_guard<std::mutex> lock(current_task_mutex);
		current_task = godot::Ref<HEGoTask>();
	}

	session_mgr = nullptr;

	HEGo::Util::Log::message("Task scheduler stopped.");
}

godot::Ref<HEGoTask> HEGoTaskScheduler::submit(godot::Ref<HEGoTask> task)
{
	if (!running.load())
	{
		task->error_message = "Scheduler is not running. Is the session active?";
		task->status.store(HEGoTask::FAILED, std::memory_order_release);
		return task;
	}

	{
		std::lock_guard<std::mutex> lock(queue_mutex);
		task_queue.push_back(task);
	}
	queue_cv.notify_one();

	return task;
}

void HEGoTaskScheduler::worker_loop()
{
	while (running.load())
	{
		godot::Ref<HEGoTask> task;

		// Wait for a task
		{
			std::unique_lock<std::mutex> lock(queue_mutex);
			queue_cv.wait(lock, [this] { return !task_queue.empty() || !running.load(); });

			if (!running.load() && task_queue.empty())
			{
				break;
			}

			if (task_queue.empty())
			{
				continue;
			}

			task = task_queue.front();
			task_queue.pop_front();
		}

		// Set as current task
		{
			std::lock_guard<std::mutex> lock(current_task_mutex);
			current_task = task;
		}

		// Execute the task
		task->status.store(HEGoTask::RUNNING, std::memory_order_release);

		godot::Variant result;
		bool failed = false;

		result = task->execute(session_mgr);

		// Check if the work function set FAILED status directly (e.g. via error_message)
		if (task->status.load(std::memory_order_acquire) == HEGoTask::FAILED)
		{
			failed = true;
		}

		if (!failed)
		{
			task->result = result;
			task->status.store(HEGoTask::COMPLETED, std::memory_order_release);
		}

		// Clear current task
		{
			std::lock_guard<std::mutex> lock(current_task_mutex);
			current_task = godot::Ref<HEGoTask>();
		}

		// Add to completed history
		{
			std::lock_guard<std::mutex> lock(history_mutex);
			completed_history.push_back(task);
			while (static_cast<int>(completed_history.size()) > MAX_HISTORY)
			{
				completed_history.pop_front();
			}
		}
	}
}

int HEGoTaskScheduler::get_pending_count()
{
	std::lock_guard<std::mutex> lock(queue_mutex);
	return static_cast<int>(task_queue.size());
}

godot::Ref<HEGoTask> HEGoTaskScheduler::get_current_task()
{
	std::lock_guard<std::mutex> lock(current_task_mutex);
	return current_task;
}

godot::Array HEGoTaskScheduler::get_pending_tasks()
{
	godot::Array arr;
	std::lock_guard<std::mutex> lock(queue_mutex);
	for (const godot::Ref<HEGoTask> &task : task_queue)
	{
		arr.push_back(task);
	}
	return arr;
}

godot::Array HEGoTaskScheduler::get_completed_history()
{
	godot::Array arr;
	std::lock_guard<std::mutex> lock(history_mutex);
	for (const godot::Ref<HEGoTask> &task : completed_history)
	{
		arr.push_back(task);
	}
	return arr;
}

void HEGoTaskScheduler::clear_completed_history()
{
	std::lock_guard<std::mutex> lock(history_mutex);
	completed_history.clear();
}

} // namespace HEGo
