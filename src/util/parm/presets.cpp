#include "presets.h"
#include "util/log/log.h"
#include <godot_cpp/variant/packed_byte_array.hpp>

namespace HEGo
{
namespace Util
{
namespace Parm
{
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

	HEGo::Util::Log::message("Setting preset");
	HAPI_Result result = HoudiniApi::SetPreset(session, node_id, HAPI_PRESETTYPE_BINARY, nullptr, buffer, buffer_length);
	if (result != HAPI_RESULT_SUCCESS)
	{
		HEGo::Util::Log::error("Error setting preset!");
		return;
	}
}

} // namespace Parm
} // namespace Util
} // namespace HEGo