#ifndef HEGO_UTIL_H
#define HEGO_UTIL_H

#include "hapi/houdini_api.h"
#include "util/log/log.h"

#include <string>

namespace HEGo
{
namespace Util
{
namespace Hapi
{

std::string get_last_error(HAPI_Session *session = nullptr);
std::string get_last_cook_error(HAPI_Session *session = nullptr);
std::string get_last_cook_status(HAPI_Session *session);
std::string get_connection_error();
std::string get_string(const HAPI_Session *session, HAPI_StringHandle string_handle);
bool save_to_hip(const HAPI_Session *session, const std::string &filename);
HAPI_NodeId get_parent_node_id(const HAPI_Session *session, const HAPI_NodeId &node_id);

} // namespace Hapi
} // namespace Util
} // namespace HEGo

// Error checking - this macro will check the status and return specified parameter in case of failure.
#define HOUDINI_CHECK_ERROR_RETURN(HAPI_PARAM_CALL, HAPI_PARAM_RETURN)                                                                                         \
	do                                                                                                                                                         \
	{                                                                                                                                                          \
		HAPI_Result ResultVariable = HAPI_PARAM_CALL;                                                                                                          \
		if (ResultVariable != HAPI_RESULT_SUCCESS)                                                                                                             \
		{                                                                                                                                                      \
			HEGo::Util::Log::error(                                                                                                                            \
					godot::String("HAPI failed: ") + HEGo::Util::Hapi::get_last_error().c_str() + "  (" + __FILE__ + ":" + std::to_string(__LINE__).c_str() + ")"); \
			return HAPI_PARAM_RETURN;                                                                                                                          \
		}                                                                                                                                                      \
	} while (0)

// Simple Error checking - this macro will check the status and log the error if any.
#define HOUDINI_CHECK_ERROR(HAPI_PARAM_CALL)                                                                                                                   \
	do                                                                                                                                                         \
	{                                                                                                                                                          \
		HAPI_Result ResultVariable = HAPI_PARAM_CALL;                                                                                                          \
		if (ResultVariable != HAPI_RESULT_SUCCESS)                                                                                                             \
		{                                                                                                                                                      \
			HEGo::Util::Log::error(                                                                                                                            \
					godot::String("HAPI failed: ") + HEGo::Util::Hapi::get_last_error().c_str() + "  (" + __FILE__ + ":" + std::to_string(__LINE__).c_str() + ")"); \
		}                                                                                                                                                      \
	} while (0)

// Error checking - this macro will check the status and returns it in the param.
#define HOUDINI_CHECK_ERROR_GET(HAPI_PARAM_RESULT, HAPI_PARAM_CALL)                                                                                            \
	do                                                                                                                                                         \
	{                                                                                                                                                          \
		*HAPI_PARAM_RESULT = HAPI_PARAM_CALL;                                                                                                                  \
		if (*HAPI_PARAM_RESULT != HAPI_RESULT_SUCCESS)                                                                                                         \
		{                                                                                                                                                      \
			std::cout << "HAPI failed: " << HEGo::Util::Hapi::get_last_error() << "  (" << __FILE__ << ":" << __LINE__ << ")" << std::endl;                    \
		}                                                                                                                                                      \
	} while (0)

#endif // HEGO_UTIL_H
