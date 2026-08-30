#ifndef HEGO_TASK_SCHEDULER_H
#define HEGO_TASK_SCHEDULER_H

#include <atomic>
#include <condition_variable>
#include <deque>
#include <mutex>
#include <thread>

#include <godot_cpp/classes/ref.hpp>
#include <godot_cpp/variant/array.hpp>

#include "hego_task.h"

class HEGoSessionManager;

namespace HEGo
{
class HEGoTaskScheduler
{
public:
	HEGoTaskScheduler();
	~HEGoTaskScheduler();

	// Lifecycle — tied to the HAPI session
	void start(HEGoSessionManager *mgr);
	void stop();

	// Submit a task to the queue, returns the same task for polling
	godot::Ref<HEGoTask> submit(godot::Ref<HEGoTask> task);

	// Query methods for UI (callable from main thread)
	int get_pending_count();
	godot::Ref<HEGoTask> get_current_task();
	godot::Array get_pending_tasks();
	godot::Array get_completed_history();
	void clear_completed_history();

private:
	void worker_loop();

	std::thread worker_thread;
	std::mutex queue_mutex;
	std::condition_variable queue_cv;
	std::deque<godot::Ref<HEGoTask>> task_queue;

	std::atomic<bool> running{false};
	HEGoSessionManager *session_mgr = nullptr;

	// Tracking for UI queries
	std::mutex current_task_mutex;
	godot::Ref<HEGoTask> current_task;

	std::mutex history_mutex;
	std::deque<godot::Ref<HEGoTask>> completed_history;
	static const int MAX_HISTORY = 64;
};

} // namespace HEGo

#endif // HEGO_TASK_SCHEDULER_H
