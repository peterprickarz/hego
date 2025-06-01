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
	enum SessionType
	{
		InProcess = 1,
		NewNamedPipe = 2,
		NewTCPSocket = 3,
		ExistingNamedPipe = 4,
		ExistingTCPSocket = 5,
		ExistingSharedMemory = 6
	};

	HEGoSessionManager();

	// Creates a new session
	bool start_session();

	// Stop the existing session if valid, and creates a new session
	bool restart_session(SessionType session_type, bool use_cooking_thread);

	// Cleanup and shutdown an existing session
	bool stop_session();

	// Initializes the HAPI session, should be called after successfully creating a session
	bool initialize(bool use_cooking_thread);

	bool wait_for_cook(HAPI_NodeId node_id = -1);

	bool wait_for_ready();

	// Get the HAPI session
	HAPI_Session *get_session();

	// Get the cook options used to initialize the HAPI session
	HAPI_CookOptions *get_cook_options();

	// Query and list the paramters of the given node
	bool get_parms(HAPI_NodeId node_id);

	// Query and list the point, vertex, prim and detail attributes of the given node
	bool get_attribs(HAPI_NodeId node_id, HAPI_PartId part_id);

	void register_node(HEGo::HEGoTrackableNode *node);
	void unregister_node(HEGo::HEGoTrackableNode *node);

private:
	void *libHAPIL;

	HAPI_Session my_session;
	HAPI_CookOptions myCookOptions;
	SessionType my_session_type = InProcess;
	std::string my_named_pipe = DEFAULT_NAMED_PIPE;
	int my_tcp_port = DEFAULT_TCP_PORT;
	std::string my_shared_memory_name;
	std::vector<HEGo::HEGoTrackableNode *> nodes;
};

#endif // HEGO_NODE_MANAGER_H