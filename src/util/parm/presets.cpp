#include "presets.h"
#include "util/log/log.h"
#include "util/hego_util.h"

#include <algorithm>
#include <vector>
#include <godot_cpp/variant/packed_byte_array.hpp>

namespace HEGo
{
namespace Util
{
namespace Parm
{
bool read_preset(HEGoSessionManager *session_mgr, HAPI_NodeId node_id, godot::PackedByteArray &result, godot::String &error)
{
	result.clear();
	HAPI_Session *session = session_mgr ? session_mgr->get_session() : nullptr;
	if (!session || node_id < 0 || HoudiniApi::IsSessionValid(session) != HAPI_RESULT_SUCCESS) {
		error = "Cannot read preset from an invalid node or session.";
		return false;
	}
	int length = 0;
	if (HoudiniApi::GetPresetBufLength(session, node_id, HAPI_PRESETTYPE_BINARY, nullptr, &length) != HAPI_RESULT_SUCCESS || length <= 0 || length > 67108864) {
		error = "HAPI failed to return a valid nonempty preset buffer length.";
		return false;
	}
	godot::PackedByteArray complete;
	complete.resize(length);
	if (HoudiniApi::GetPreset(session, node_id, reinterpret_cast<char *>(complete.ptrw()), length) != HAPI_RESULT_SUCCESS) {
		error = "HAPI failed to read the complete preset.";
		return false;
	}
	result = complete;
	return true;
}

namespace
{
using MultiparmLayout = std::vector<std::pair<godot::String, int>>;

bool read_multiparm_layout(const HAPI_Session *session, HAPI_NodeId node, MultiparmLayout &layout)
{
	HAPI_NodeInfo info = HoudiniApi::NodeInfo_Create();
	if (HoudiniApi::GetNodeInfo(session, node, &info) != HAPI_RESULT_SUCCESS || info.parmCount < 0) return false;
	if (info.parmCount == 0) return true;
	std::vector<HAPI_ParmInfo> parms(info.parmCount);
	if (HoudiniApi::GetParameters(session, node, parms.data(), 0, info.parmCount) != HAPI_RESULT_SUCCESS) return false;
	for (const auto &parm : parms)
	{
		if (parm.type != HAPI_PARMTYPE_MULTIPARMLIST) continue;
		const godot::String name = Hapi::get_godot_string(session, parm.nameSH);
		if (name.is_empty() || parm.instanceCount < 0) return false;
		layout.emplace_back(name, parm.instanceCount);
	}
	return true;
}
}

bool write_preset(HEGoSessionManager *session_mgr, HAPI_NodeId node_id, const godot::PackedByteArray &preset, godot::String &error)
{
	HAPI_Session *session = session_mgr ? session_mgr->get_session() : nullptr;
	if (!session || node_id < 0 || preset.is_empty() || preset.size() > 67108864 || HoudiniApi::IsSessionValid(session) != HAPI_RESULT_SUCCESS) {
		error = "Cannot apply an empty/oversized preset or use an invalid node/session.";
		return false;
	}
	// HAPI 22.0.429 and .511 can shrink a nested multiparm, then fail to find a
	// removed row while finishing this same preset. Reapply only after the specific
	// SDK error and an observed layout change. A successful or unrelated write runs once.
	MultiparmLayout first;
	std::vector<MultiparmLayout> visited;
	if (read_multiparm_layout(session, node_id, first) && !first.empty()) visited.push_back(std::move(first));
	for (;;)
	{
		const auto result = HoudiniApi::SetPreset(session, node_id, HAPI_PRESETTYPE_BINARY, nullptr, reinterpret_cast<const char *>(preset.ptr()), preset.size());
		if (result == HAPI_RESULT_SUCCESS) return true;
		const std::string detail = Hapi::get_last_error(session);
		error = "HAPI rejected the preset (code " + godot::String::num_int64(result) + "): " + godot::String::utf8(detail.c_str());
		if (result != HAPI_RESULT_FAILURE || detail.find("Unable to find key in unordered_map") == std::string::npos || visited.empty() || visited.size() >= 4)
			return false;
		MultiparmLayout current;
		if (!read_multiparm_layout(session, node_id, current) || std::find(visited.begin(), visited.end(), current) != visited.end())
			return false;
		visited.push_back(std::move(current));
		error = godot::String();
	}
}

godot::PackedByteArray get_preset(HEGoSessionManager *session_mgr, HAPI_NodeId node_id)
{
	godot::PackedByteArray result;

	// Validate inputs
	if (!session_mgr || node_id < 0)
	{
		return result;
	}

	// Get HAPI session
	HAPI_Session *session = session_mgr->get_session(); // Adjust based on actual method
	if (!session)
	{
		return result;
	}

	// Get preset buffer length
	int buffer_length = 0;
	HAPI_Result hapi_result = HoudiniApi::GetPresetBufLength(session, node_id, HAPI_PRESETTYPE_BINARY, nullptr, &buffer_length);
	if (hapi_result != HAPI_RESULT_SUCCESS || buffer_length <= 0)
	{
		return result;
	}

	// Allocate buffer for preset data
	char *buffer = new char[buffer_length];
	if (!buffer)
	{
		return result;
	}

	// Retrieve preset
	hapi_result = HoudiniApi::GetPreset(session, node_id, buffer, buffer_length);
	if (hapi_result != HAPI_RESULT_SUCCESS)
	{
		delete[] buffer;
		return result;
	}

	// Copy buffer to PackedByteArray
	result.resize(buffer_length);
	memcpy(result.ptrw(), buffer, buffer_length);

	// Clean up
	delete[] buffer;

	return result;
}

void set_preset(HEGoSessionManager *session_mgr, HAPI_NodeId node_id, godot::PackedByteArray preset)
{
	// Validate inputs
	if (!session_mgr || node_id < 0 || preset.is_empty())
	{
		return;
	}

	// Get HAPI session
	HAPI_Session *session = session_mgr->get_session(); // Adjust based on actual method
	if (!session)
	{
		return;
	}

	// Get buffer from PackedByteArray
	const char *buffer = (const char *)preset.ptr();
	int buffer_length = preset.size();

	if (buffer_length <= 0)
	{
		return;
	}

	HEGo::Util::Log::debug(HEGo::Util::Log::Category::PARM, "Setting preset");
	HAPI_Result result = HoudiniApi::SetPreset(session, node_id, HAPI_PRESETTYPE_BINARY, nullptr, buffer, buffer_length);
	if (result != HAPI_RESULT_SUCCESS)
	{
		HEGo::Util::Log::error(HEGo::Util::Log::Category::PARM, "Error setting preset!");
		return;
	}
}

} // namespace Parm
} // namespace Util
} // namespace HEGo
