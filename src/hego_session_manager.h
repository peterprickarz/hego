#ifndef HEGO_SESSION_MANAGER_H
#define HEGO_SESSION_MANAGER_H

#include "hapi/houdini_api.h"
#include "hego_nodes/hego_trackable_node.h"
#include <string>

#define DEFAULT_NAMED_PIPE "hapi"
#define DEFAULT_HOST_NAME "127.0.0.1"
#define DEFAULT_TCP_PORT 9090

#define RETURN_IF_VALID_NODE_ID(node_id, session)                                                                                                              \
	if (node_id != -1 && session != nullptr)                                                                                                                   \
	{                                                                                                                                                          \
		HAPI_NodeInfo node_info;                                                                                                                               \
		HAPI_Result result = HoudiniApi::GetNodeInfo(session, node_id, &node_info);                                                                            \
		if (result == HAPI_RESULT_SUCCESS && node_info.id == node_id)                                                                                          \
		{                                                                                                                                                      \
			return node_id;                                                                                                                                    \
		}                                                                                                                                                      \
	}

class HEGoSessionManager
{
public:
	// How HEGo connects to Houdini Engine. The New* types start the server
	// themselves; the Existing* types are reserved for connecting to a server
	// somebody else started and are not implemented yet.
	//
	// InProcess starts a shared memory server, which behaves like an in-process
	// session (Houdini starts with HEGo and closes with it) without being HAPI's
	// in-process session type.
	enum SessionType
	{
		InProcess = 1,
		NewNamedPipe = 2,
		NewTCPSocket = 3,
		ExistingNamedPipe = 4,
		ExistingTCPSocket = 5,
		ExistingSharedMemory = 6
	};

	// Whether a value coming from GDScript names a session type HEGo can start.
	static bool is_supported_session_type(int session_type)
	{
		return session_type == InProcess || session_type == NewNamedPipe || session_type == NewTCPSocket;
	}

	HEGoSessionManager();

	// Creates a new session. connection_data is the pipe or shared memory name, or
	// the port number for TCP sessions.
	bool start_session(SessionType session_type = NewNamedPipe, const std::string &connection_data = DEFAULT_NAMED_PIPE);

	// Stop the existing session if valid, and creates a new session of the given
	// type, reusing the pipe name or port of the session that was stopped.
	bool restart_session(SessionType session_type, bool use_cooking_thread);

	// Cleanup and shutdown an existing session
	bool stop_session();

	// Initializes the HAPI session, should be called after successfully creating a session
	bool initialize(bool use_cooking_thread);

	// Blocks until the session finishes cooking, polling HAPI for the cook state.
	// Pass a node id to have that node's cook errors and warnings logged.
	bool wait_for_cook(HAPI_NodeId node_id = -1);

	// Blocks until the session is idle, without logging any cook result.
	bool wait_for_ready();

	// Get the HAPI session
	HAPI_Session *get_session();

	// Check if session is currently active
	bool is_session_active();

	// Get the cook options used to initialize the HAPI session
	HAPI_CookOptions *get_cook_options();

	void register_node(HEGo::HEGoTrackableNode *node);
	void unregister_node(HEGo::HEGoTrackableNode *node);

private:
	void *libHAPIL;

	HAPI_Session my_session;
	HAPI_CookOptions my_cook_options;
	SessionType my_session_type = InProcess;
	std::string my_named_pipe = DEFAULT_NAMED_PIPE;
	int my_tcp_port = DEFAULT_TCP_PORT;
	std::string my_shared_memory_name;
	std::vector<HEGo::HEGoTrackableNode *> nodes;
};

#endif // HEGO_SESSION_MANAGER_H