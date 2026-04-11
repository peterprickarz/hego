#include "hego_task.h"

#include "hego_session_manager.h"
#include "util/hego_util.h"
#include "util/log/log.h"

namespace HEGo
{
HEGoTask::HEGoTask() {}

HEGoTask::~HEGoTask() {}

godot::Variant HEGoTask::execute(HEGoSessionManager *mgr)
{
	if (work_fn)
	{
		return work_fn(mgr);
	}
	return godot::Variant();
}

int HEGoTask::get_status() const { return status.load(std::memory_order_acquire); }

godot::Variant HEGoTask::get_result() const { return result; }

godot::String HEGoTask::get_error_message() const { return error_message; }

godot::String HEGoTask::get_description() const { return description; }

int HEGoTask::get_node_id() const { return static_cast<int>(node_id); }

void HEGoTask::_bind_methods()
{
	godot::ClassDB::bind_method(godot::D_METHOD("get_status"), &HEGoTask::get_status);
	godot::ClassDB::bind_method(godot::D_METHOD("get_result"), &HEGoTask::get_result);
	godot::ClassDB::bind_method(godot::D_METHOD("get_error_message"), &HEGoTask::get_error_message);
	godot::ClassDB::bind_method(godot::D_METHOD("get_description"), &HEGoTask::get_description);
	godot::ClassDB::bind_method(godot::D_METHOD("get_node_id"), &HEGoTask::get_node_id);

	BIND_ENUM_CONSTANT(PENDING);
	BIND_ENUM_CONSTANT(RUNNING);
	BIND_ENUM_CONSTANT(COMPLETED);
	BIND_ENUM_CONSTANT(FAILED);
}

} // namespace HEGo
