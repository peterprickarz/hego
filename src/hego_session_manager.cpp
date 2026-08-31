#include "hego_session_manager.h"
#include "util/hego_util.h"
#include <godot_cpp/variant/utility_functions.hpp>

#include "hapi/hego_platform.h"

#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <thread>
#include <vector>

namespace
{
// HAPI offers no blocking wait, so cook progress has to be polled. Sleeping between
// polls keeps a cook from pinning a core; a few milliseconds is far below the
// resolution anyone notices in cook times.
constexpr int COOK_POLL_INTERVAL_MS = 2;

// Whether the cook is still running and worth polling again. Sleeps for one poll
// interval when it is, so callers can use it directly as a do/while condition.
bool poll_again(int status, HAPI_Result result)
{
	if (status <= HAPI_STATE_MAX_READY_STATE || result != HAPI_RESULT_SUCCESS)
	{
		return false;
	}

	std::this_thread::sleep_for(std::chrono::milliseconds(COOK_POLL_INTERVAL_MS));
	return true;
}
} // namespace

HEGoSessionManager::HEGoSessionManager() : libHAPIL(nullptr), my_session{}, my_cook_options{} {}

bool HEGoSessionManager::start_session(SessionType session_type, const std::string &connection_data)
{
	// Load the HAPI library
	libHAPIL = HEGoPlatform::initialize_hapi();

	// Parse connection data based on session type
	std::string named_pipe = connection_data;
	int tcp_port = DEFAULT_TCP_PORT;

	// For TCP sessions the connection data is the port number. It comes from
	// GDScript, so it is not necessarily a number at all, and the extension is built
	// without exceptions - std::stoi would terminate the process rather than throw.
	if (session_type == NewTCPSocket || session_type == ExistingTCPSocket)
	{
		char *parse_end = nullptr;
		const long parsed_port = std::strtol(connection_data.c_str(), &parse_end, 10);
		const bool is_port = parse_end != connection_data.c_str() && *parse_end == '\0' && parsed_port > 0 && parsed_port <= 65535;
		if (is_port)
		{
			tcp_port = static_cast<int>(parsed_port);
		}
		else
		{
			HEGo::Util::Log::warning(HEGo::Util::Log::Category::SESSION, godot::String("Connection data '") + connection_data.c_str() + "' is not a valid port number, using " +
					godot::String::num_int64(DEFAULT_TCP_PORT) + ".");
		}
	}

	// Only start a new Session if we dont already have a valid one
	if (HAPI_RESULT_SUCCESS == HoudiniApi::IsSessionValid(&my_session))
		return true;

	// Clear the connection error before starting a new session
	HoudiniApi::ClearConnectionError();

	// Init the thrift server options
	HAPI_ThriftServerOptions server_options = HoudiniApi::ThriftServerOptions_Create();
	server_options.autoClose = true;
	server_options.timeoutMs = 3000.0f;

	my_session_type = session_type;
	my_named_pipe = named_pipe;
	my_tcp_port = tcp_port;
	HAPI_Result session_result = HAPI_RESULT_FAILURE;
	if (session_type == SessionType::NewNamedPipe)
	{
		// Start our server
		HEGo::Util::Log::debug(HEGo::Util::Log::Category::SESSION, "Starting a named-pipe server...");
		HAPI_ProcessId process_id;
		HOUDINI_CHECK_ERROR(HoudiniApi::StartThriftNamedPipeServer(&server_options, my_named_pipe.c_str(), &process_id, nullptr));

		// Connect to the newly started server
		HEGo::Util::Log::debug(HEGo::Util::Log::Category::SESSION, "Connecting to the named-pipe session...");
		HAPI_SessionInfo session_info = HoudiniApi::SessionInfo_Create();
		session_result = HoudiniApi::CreateThriftNamedPipeSession(&my_session, my_named_pipe.c_str(), &session_info);
	}
	else if (session_type == SessionType::NewTCPSocket)
	{
		// Start our server
		HEGo::Util::Log::debug(HEGo::Util::Log::Category::SESSION, "Starting a TCP socket server...");
		HAPI_ProcessId process_id;
		HOUDINI_CHECK_ERROR(HoudiniApi::StartThriftSocketServer(&server_options, my_tcp_port, &process_id, nullptr));

		// Connect to the newly started server
		HEGo::Util::Log::debug(HEGo::Util::Log::Category::SESSION, "Connecting to the TCP socket session...");
		HAPI_SessionInfo session_info = HoudiniApi::SessionInfo_Create();
		session_result = HoudiniApi::CreateThriftSocketSession(&my_session, DEFAULT_HOST_NAME, my_tcp_port, &session_info);
	}
	else if (session_type == SessionType::InProcess)
	{
		// InProcess is served by a shared memory server: it is in-process from the
		// user's point of view (Houdini is started by HEGo and closes with it), but
		// it is not HAPI's in-process session type.
		HEGo::Util::Log::debug(HEGo::Util::Log::Category::SESSION, "Starting a Shared Memory server...");
		HAPI_ProcessId process_id;
		HOUDINI_CHECK_ERROR(HoudiniApi::StartThriftSharedMemoryServer(&server_options, my_named_pipe.c_str(), &process_id, nullptr));
		HEGo::Util::Log::debug(HEGo::Util::Log::Category::SESSION, "Connecting to shared memory session...");
		HAPI_SessionInfo session_info = HoudiniApi::SessionInfo_Create();
		session_result = HoudiniApi::CreateThriftSharedMemorySession(&my_session, my_named_pipe.c_str(), &session_info);
	}
	else
	{
		// The Existing* types are declared but not implemented yet.
		HEGo::Util::Log::error(HEGo::Util::Log::Category::SESSION, godot::String("Unsupported session type ") + godot::String::num_int64(session_type) + ".");
	}

	if (session_result != HAPI_RESULT_SUCCESS)
	{
		if (session_type != SessionType::InProcess)
		{
			std::string connectionError = HEGo::Util::Hapi::get_connection_error();
			if (!connectionError.empty())
				HEGo::Util::Log::error(HEGo::Util::Log::Category::SESSION, "Houdini Engine Session failed to connect - " + godot::String(connectionError.c_str()));
		}

		return false;
	}

	HEGo::Util::Log::info(HEGo::Util::Log::Category::SESSION, "Started Session.");

	bool use_cooking_thread = true; // Enables asynchronous cooking of nodes.

	if (!initialize(use_cooking_thread))
	{
		HEGo::Util::Log::error(HEGo::Util::Log::Category::SESSION, "Failed to initialize HAPI.");
		return false;
	}

	HEGo::Util::Log::info(HEGo::Util::Log::Category::SESSION, "Initialized HAPI");

	return true;
}

bool HEGoSessionManager::stop_session()
{
	HEGo::Util::Log::info(HEGo::Util::Log::Category::SESSION, "Cleaning up and closing session...");

	if (HAPI_RESULT_SUCCESS == HoudiniApi::IsSessionValid(&my_session))
	{
		// SessionPtr is valid, clean up and close the session
		HoudiniApi::Cleanup(&my_session);

		// When using an in-process session, this method must be called
		// in order for the host process to shutdown cleanly.
		if (my_session_type == InProcess)
			HoudiniApi::Shutdown(&my_session);

		HoudiniApi::CloseSession(&my_session);
	}

	HoudiniApi::finalize_hapi();
	HEGoPlatform::free_lib_hapil(libHAPIL);

	// Reset node_id for all tracked nodes
	for (HEGo::HEGoTrackableNode *node : nodes)
	{
		HEGo::Util::Log::debug(HEGo::Util::Log::Category::SESSION, "resetting node id");
		node->reset_node_id();
	}

	HEGo::Util::Log::info(HEGo::Util::Log::Category::SESSION, "Closed Session, finalized hapi and freed libHAPIL.");
	return true;
}

bool HEGoSessionManager::restart_session(SessionType session_type, bool use_cooking_thread)
{
	HEGo::Util::Log::info(HEGo::Util::Log::Category::SESSION, "Restarting the Houdini Engine session...");

	// Make sure we stop the current session if it is still valid
	stop_session();

	// Reuse the connection data of the session we just stopped, so a restart lands
	// on the same pipe or port.
	const std::string connection_data =
			(session_type == NewTCPSocket || session_type == ExistingTCPSocket) ? std::to_string(my_tcp_port) : my_named_pipe;

	if (!start_session(session_type, connection_data))
	{
		HEGo::Util::Log::error(HEGo::Util::Log::Category::SESSION, "Failed to restart the Houdini Engine session - Failed to start the new Session");
		return false;
	}

	// Now initialize HAPI with this session
	if (!initialize(use_cooking_thread))
	{
		HEGo::Util::Log::error(HEGo::Util::Log::Category::SESSION, "Failed to restart the Houdini Engine session - Failed to initialize HAPI");
		return false;
	}

	return true;
}

bool HEGoSessionManager::initialize(bool use_cooking_thread)
{
	// We need a Valid Session
	if (HAPI_RESULT_SUCCESS != HoudiniApi::IsSessionValid(get_session()))
	{
		HEGo::Util::Log::error(HEGo::Util::Log::Category::SESSION, "Failed to initialize HAPI: The session is invalid.");
		return false;
	}

	if (HoudiniApi::IsInitialized(get_session()) == HAPI_RESULT_NOT_INITIALIZED)
	{
		// Initialize HAPI
		HAPI_CookOptions cook_options = HoudiniApi::CookOptions_Create();

		cook_options.curveRefineLOD = 8.0f;
		cook_options.clearErrorsAndWarnings = false;
		cook_options.maxVerticesPerPrimitive = 3;
		cook_options.splitGeosByGroup = false;
		cook_options.refineCurveToLinear = false;
		cook_options.handleBoxPartTypes = false;
		cook_options.handleSpherePartTypes = false;
		cook_options.splitPointsByVertexAttributes = false;
		cook_options.packedPrimInstancingMode = HAPI_PACKEDPRIM_INSTANCING_MODE_FLAT;

		HAPI_Result result = HoudiniApi::Initialize(get_session(), // session
				&cook_options,
				use_cooking_thread, // use_cooking_thread
				-1, // cooking_thread_stack_size
				"", // houdini_environment_files
				nullptr, // otl_search_path
				nullptr, // dso_search_path
				nullptr, // image_dso_search_path
				nullptr // audio_dso_search_path
		);

		my_cook_options = cook_options;

		if (result == HAPI_RESULT_SUCCESS)
		{
			HEGo::Util::Log::info(HEGo::Util::Log::Category::SESSION, "Successfully initialized Houdini Engine.");
		}
		else if (result == HAPI_RESULT_ALREADY_INITIALIZED)
		{
			// Reused session? just notify the user
			HEGo::Util::Log::info(HEGo::Util::Log::Category::SESSION, "Successfully initialized Houdini Engine - HAPI was already initialized.");
		}
		else
		{
			HEGo::Util::Log::error(HEGo::Util::Log::Category::SESSION, "Houdini Engine API initialization failed");
			return false;
		}
	}

	return true;
}

HAPI_Session *HEGoSessionManager::get_session() { return &my_session; }

bool HEGoSessionManager::is_session_active() { return HAPI_RESULT_SUCCESS == HoudiniApi::IsSessionValid(&my_session); }

HAPI_CookOptions *HEGoSessionManager::get_cook_options() { return &my_cook_options; }

void HEGoSessionManager::register_node(HEGo::HEGoTrackableNode *node)
{
	if (node == nullptr)
	{
		return;
	}

	// Check if the node is already in the registered_nodes vector
	bool is_already_registered = false;
	for (unsigned int i = 0; i < nodes.size(); i++)
	{
		if (nodes[i] == node)
		{
			is_already_registered = true;
			break;
		}
	}

	// Add the node only if it is not already registered
	if (!is_already_registered)
	{
		nodes.push_back(node);
	}
}

void HEGoSessionManager::unregister_node(HEGo::HEGoTrackableNode *node) { nodes.erase(std::remove(nodes.begin(), nodes.end(), node), nodes.end()); }

bool HEGoSessionManager::wait_for_cook(HAPI_NodeId node_id)
{
	if (!get_session())
		return false;

	int status = HAPI_STATE_MAX;
	HAPI_Result result;
	do
	{
		result = HoudiniApi::GetStatus(get_session(), HAPI_STATUS_COOK_STATE, &status);
	} while (poll_again(status, result));

	if (node_id != -1)
	{
		const std::string cook_result = HEGo::Util::Hapi::get_composed_cook_result(get_session(), node_id);
		if (!cook_result.empty())
		{
			HEGo::Util::Log::debug(HEGo::Util::Log::Category::SESSION, godot::String(cook_result.c_str()));
		}
	}

	if (status != HAPI_STATE_READY || result != HAPI_RESULT_SUCCESS)
	{
		HEGo::Util::Log::warning(HEGo::Util::Log::Category::SESSION, "Cook failure: " + godot::String(HEGo::Util::Hapi::get_last_cook_error(get_session()).c_str()));
		return false;
	}
	HEGo::Util::Log::line();
	HEGo::Util::Log::info(HEGo::Util::Log::Category::SESSION, "Cooking completed!");
	return true;
}

bool HEGoSessionManager::wait_for_ready()
{
	HEGo::Util::Log::debug(HEGo::Util::Log::Category::SESSION, "Waiting for async call");
	if (!get_session())
	{
		return false;
	}
	int status = HAPI_STATE_MAX;
	HAPI_Result result;
	do
	{
		result = HoudiniApi::GetStatus(get_session(), HAPI_STATUS_COOK_STATE, &status);
	} while (poll_again(status, result));

	return true;
}