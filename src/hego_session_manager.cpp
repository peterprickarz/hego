#include "hego_session_manager.h"
#include "util/hego_util.h"
#include <godot_cpp/variant/utility_functions.hpp>

#include "hapi/hego_platform.h"

#include <vector>

HEGoSessionManager::HEGoSessionManager() : my_session{}, myCookOptions{} {}

bool HEGoSessionManager::start_session(SessionType session_type, const std::string &connection_data)
{
	// Parse connection data based on session type
	std::string named_pipe = connection_data;
	int tcp_port = DEFAULT_TCP_PORT;
	
	// For TCP sessions, try to parse port from connection_data
	if (session_type == NewTCPSocket || session_type == ExistingTCPSocket)
	{
		try {
			tcp_port = std::stoi(connection_data);
		} catch (...) {
			tcp_port = DEFAULT_TCP_PORT;
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

	HAPI_Result SessionResult = HAPI_RESULT_FAILURE;
	if (session_type == SessionType::NewNamedPipe)
	{
		// Start our server
		std::cout << "Starting a named-pipe server...\n";
		HAPI_ProcessId process_id;
		HOUDINI_CHECK_ERROR(HoudiniApi::StartThriftNamedPipeServer(&server_options, my_named_pipe.c_str(), &process_id, nullptr));

		// Connect to the newly started server
		std::cout << "Connecting to the named-pipe session...\n";
		HAPI_SessionInfo SessionInfo = HoudiniApi::SessionInfo_Create();
		SessionResult = HoudiniApi::CreateThriftNamedPipeSession(&my_session, my_named_pipe.c_str(), &SessionInfo);
	}
	else if (session_type == SessionType::NewTCPSocket)
	{
		// Start our server
		std::cout << "Starting a TCP socket server...\n";
		HAPI_ProcessId process_id;
		HOUDINI_CHECK_ERROR(HoudiniApi::StartThriftSocketServer(&server_options, my_tcp_port, &process_id, nullptr));

		// Connect to the newly started server
		std::cout << "Connecting to the TCP socket session...\n";
		HAPI_SessionInfo SessionInfo = HoudiniApi::SessionInfo_Create();
		SessionResult = HoudiniApi::CreateThriftSocketSession(&my_session, DEFAULT_HOST_NAME, my_tcp_port, &SessionInfo);
	}

	if (SessionResult != HAPI_RESULT_SUCCESS)
	{
		if (session_type != SessionType::InProcess)
		{
			std::string connectionError = HEGoUtil::get_connection_error();
			if (!connectionError.empty())
				HEGo::Util::Log::error("Houdini Engine Session failed to connect - " + godot::String(connectionError.c_str()));
		}

		return false;
	}

	HEGo::Util::Log::message("Started Session.");

	bool use_cooking_thread = true; // Enables asynchronous cooking of nodes.

	if (!initialize(use_cooking_thread))
	{
		HEGo::Util::Log::error("Failed to initialize HAPI.");
		return false;
	}

	HEGo::Util::Log::message("Initialized HAPI");

	return true;
}

bool HEGoSessionManager::stop_session()
{
	HEGo::Util::Log::message("Cleaning up and closing session...");

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
		HEGo::Util::Log::message("resetting node id");
		node->reset_node_id();
	}

	HEGo::Util::Log::message("Closed Session, finalized hapi and freed libHAPIL.");
	return true;
}

bool HEGoSessionManager::restart_session(SessionType session_type, bool use_cooking_thread)
{
	std::cout << "Restarting the Houdini Engine session...\n";

	// Make sure we stop the current session if it is still valid
	bool bSuccess = false;
	stop_session();

	if (!start_session())
	{
		std::cout << "Failed to restart the Houdini Engine session - Failed to start the new Session" << std::endl;
	}
	else
	{
		// Now initialize HAPI with this session
		if (!initialize(use_cooking_thread))
		{
			std::cout << "Failed to restart the Houdini Engine session - Failed to initialize HAPI" << std::endl;
		}
		else
		{
			bSuccess = true;
		}
	}

	return bSuccess;
}

bool HEGoSessionManager::initialize(bool use_cooking_thread)
{
	// We need a Valid Session
	if (HAPI_RESULT_SUCCESS != HoudiniApi::IsSessionValid(get_session()))
	{
		std::cout << "Failed to initialize HAPI: The session is invalid." << std::endl;
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
		cook_options.refineCurveToLinear = true;
		cook_options.handleBoxPartTypes = false;
		cook_options.handleSpherePartTypes = false;
		cook_options.splitPointsByVertexAttributes = false;
		cook_options.packedPrimInstancingMode = HAPI_PACKEDPRIM_INSTANCING_MODE_FLAT;

		HAPI_Result Result = HoudiniApi::Initialize(get_session(), // session
				&cook_options,
				use_cooking_thread, // use_cooking_thread
				-1, // cooking_thread_stack_size
				"", // houdini_environment_files
				nullptr, // otl_search_path
				nullptr, // dso_search_path
				nullptr, // image_dso_search_path
				nullptr // audio_dso_search_path
		);

		myCookOptions = cook_options;

		if (Result == HAPI_RESULT_SUCCESS)
		{
			std::cout << "Successfully initialized Houdini Engine." << std::endl;
		}
		else if (Result == HAPI_RESULT_ALREADY_INITIALIZED)
		{
			// Reused session? just notify the user
			std::cout << "Successfully initialized Houdini Engine - HAPI was already initialized." << std::endl;
		}
		else
		{
			std::cout << "Houdini Engine API initialization failed" << std::endl;

			return false;
		}
	}

	return true;
}

HAPI_Session *HEGoSessionManager::get_session() { return &my_session; }

bool HEGoSessionManager::is_session_active() 
{ 
	return HAPI_RESULT_SUCCESS == HoudiniApi::IsSessionValid(&my_session); 
}

HAPI_CookOptions *HEGoSessionManager::get_cook_options() { return &myCookOptions; }

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
	} while (status > HAPI_STATE_MAX_READY_STATE && result == HAPI_RESULT_SUCCESS);

	if (node_id != -1)
	{
		int buffer_length = 0;
		HoudiniApi::ComposeNodeCookResult(get_session(), node_id, HAPI_STATUSVERBOSITY_ALL, &buffer_length);
		char *buffer = new char[buffer_length];
		HoudiniApi::GetComposedNodeCookResult(get_session(), buffer, buffer_length);
		std::string result(buffer);
		delete[] buffer;
		HEGo::Util::Log::message(godot::String(result.c_str()));
	}

	if (status != HAPI_STATE_READY || result != HAPI_RESULT_SUCCESS)
	{
		HEGo::Util::Log::warning("Cook failure: " + godot::String(HEGoUtil::get_last_cook_error(get_session()).c_str()));
		return false;
	}
	HEGo::Util::Log::line();
	HEGo::Util::Log::message("Cooking completed!");
	return true;
}

bool HEGoSessionManager::wait_for_ready()
{
	HEGo::Util::Log::message("Waiting for async call");
	if (!get_session())
	{
		return false;
	}
	int status = HAPI_STATE_MAX;
	HAPI_Result result;
	do
	{
		result = HoudiniApi::GetStatus(get_session(), HAPI_STATUS_COOK_STATE, &status);
	} while (status > HAPI_STATE_MAX_READY_STATE && result == HAPI_RESULT_SUCCESS);

	return true;
}