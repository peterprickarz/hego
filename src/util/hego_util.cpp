#include "hego_util.h"

#include <string>
#include <vector>

namespace HEGo
{
namespace Util
{
namespace Hapi
{
namespace
{
// HAPI reports buffer lengths that include the terminating null, and writes the
// string into a buffer of exactly that size. Reading into a std::string of that
// length keeps the allocation and the free in one place, and the extra element
// guarantees a terminator even if HAPI writes nothing at all.
//
// reader() is whatever HAPI call fills the buffer; it gets the buffer and its length.
template <typename Reader> std::string read_hapi_string(int buffer_length, Reader reader)
{
	if (buffer_length <= 0)
		return std::string();

	std::vector<char> buffer(static_cast<size_t>(buffer_length) + 1, '\0');
	if (reader(buffer.data(), buffer_length) != HAPI_RESULT_SUCCESS)
		return std::string();

	// Trust the terminator rather than buffer_length: HAPI counts the null byte.
	return std::string(buffer.data());
}
} // namespace

std::string get_last_error(HAPI_Session *session)
{
	int buffer_length = 0;
	if (HoudiniApi::GetStatusStringBufLength(session, HAPI_STATUS_CALL_RESULT, HAPI_STATUSVERBOSITY_ERRORS, &buffer_length) != HAPI_RESULT_SUCCESS)
		return std::string();

	return read_hapi_string(buffer_length, [&](char *buffer, int length) { return HoudiniApi::GetStatusString(session, HAPI_STATUS_CALL_RESULT, buffer, length); });
}

std::string get_last_cook_error(HAPI_Session *session)
{
	int buffer_length = 0;
	if (HoudiniApi::GetStatusStringBufLength(session, HAPI_STATUS_COOK_RESULT, HAPI_STATUSVERBOSITY_ALL, &buffer_length) != HAPI_RESULT_SUCCESS)
		return std::string("buffer error");

	return read_hapi_string(buffer_length, [&](char *buffer, int length) { return HoudiniApi::GetStatusString(session, HAPI_STATUS_COOK_RESULT, buffer, length); });
}

std::string get_last_cook_status(HAPI_Session *session)
{
	int buffer_length = 0;
	if (HoudiniApi::GetStatusStringBufLength(session, HAPI_STATUS_COOK_STATE, HAPI_STATUSVERBOSITY_ERRORS, &buffer_length) != HAPI_RESULT_SUCCESS)
		return std::string("buffer error");

	return read_hapi_string(buffer_length, [&](char *buffer, int length) { return HoudiniApi::GetStatusString(session, HAPI_STATUS_COOK_STATE, buffer, length); });
}

std::string get_connection_error()
{
	int buffer_length = 0;
	if (HoudiniApi::GetConnectionErrorLength(&buffer_length) != HAPI_RESULT_SUCCESS)
		return std::string();

	return read_hapi_string(buffer_length, [](char *buffer, int length) { return HoudiniApi::GetConnectionError(buffer, length, true); });
}

std::string get_string(const HAPI_Session *session, HAPI_StringHandle string_handle)
{
	int buffer_length = 0;
	if (HoudiniApi::GetStringBufLength(session, string_handle, &buffer_length) != HAPI_RESULT_SUCCESS)
		return std::string();

	return read_hapi_string(buffer_length, [&](char *buffer, int length) { return HoudiniApi::GetString(session, string_handle, buffer, length); });
}

godot::String get_godot_string(const HAPI_Session *session, HAPI_StringHandle string_handle)
{
	return godot::String::utf8(get_string(session, string_handle).c_str());
}

std::string get_composed_cook_result(const HAPI_Session *session, HAPI_NodeId node_id)
{
	if (node_id < 0)
		return std::string();

	int buffer_length = 0;
	if (HoudiniApi::ComposeNodeCookResult(session, node_id, HAPI_STATUSVERBOSITY_ALL, &buffer_length) != HAPI_RESULT_SUCCESS)
		return std::string();

	return read_hapi_string(buffer_length, [&](char *buffer, int length) { return HoudiniApi::GetComposedNodeCookResult(session, buffer, length); });
}

bool save_to_hip(const HAPI_Session *session, const std::string &filename)
{
	HAPI_Result result = HoudiniApi::SaveHIPFile(session, filename.c_str(), /*lock_nodes=*/false);
	return result == HAPI_RESULT_SUCCESS;
}

HAPI_NodeId get_parent_node_id(const HAPI_Session *session, const HAPI_NodeId &node_id)
{
	HAPI_NodeId parent_id = -1;
	if (node_id >= 0)
	{
		HAPI_NodeInfo node_info;
		if (HAPI_RESULT_SUCCESS == HoudiniApi::GetNodeInfo(session, node_id, &node_info))
			parent_id = node_info.parentId;
	}

	return parent_id;
}

} // namespace Hapi
} // namespace Util
} // namespace HEGo
