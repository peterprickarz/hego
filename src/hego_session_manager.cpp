#include "hego_session_manager.h"
#include "util/hego_util.h"

#include "hapi/hego_platform.h"

#include <vector>

HEGoSessionManager::HEGoSessionManager() : my_session{}, myCookOptions{} {}

bool HEGoSessionManager::start_session()
{
	// GET SETTINGS TO BE IMPLEMENTED LATER HERE
	SessionType session_type = NewNamedPipe;
	std::string named_pipe = DEFAULT_NAMED_PIPE;
	int tcp_port = DEFAULT_TCP_PORT;

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
		HOUDINI_CHECK_ERROR(
				HoudiniApi::StartThriftNamedPipeServer(&server_options, my_named_pipe.c_str(), &process_id, nullptr));

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
		SessionResult =
				HoudiniApi::CreateThriftSocketSession(&my_session, DEFAULT_HOST_NAME, my_tcp_port, &SessionInfo);
	}

	if (SessionResult != HAPI_RESULT_SUCCESS)
	{
		if (session_type != SessionType::InProcess)
		{
			std::string connectionError = HEGoUtil::get_connection_error();
			if (!connectionError.empty())
				HEGo::Util::Log::error(
						"Houdini Engine Session failed to connect - " + godot::String(connectionError.c_str()));
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

HAPI_CookOptions *HEGoSessionManager::get_cook_options() { return &myCookOptions; }

bool HEGoSessionManager::get_parms(HAPI_NodeId node_id)
{
	HAPI_NodeInfo node_info;
	HOUDINI_CHECK_ERROR_RETURN(HoudiniApi::GetNodeInfo(get_session(), node_id, &node_info), false);

	HAPI_ParmInfo *parm_infos = new HAPI_ParmInfo[node_info.parmCount];
	HOUDINI_CHECK_ERROR_RETURN(
			HoudiniApi::GetParameters(get_session(), node_id, parm_infos, 0, node_info.parmCount), false);

	std::cout << "\nParameters: " << std::endl;
	std::cout << "==========" << std::endl;
	for (int i = 0; i < node_info.parmCount; ++i)
	{
		std::cout << "  Name: ";
		std::cout << HEGoUtil::get_string(get_session(), parm_infos[i].nameSH) << std::endl;
		std::cout << "  Values: (";

		if (HoudiniApi::ParmInfo_IsInt(&parm_infos[i]))
		{
			int parm_int_count = HoudiniApi::ParmInfo_GetIntValueCount(&parm_infos[i]);
			int *parm_int_values = new int[parm_int_count];

			HOUDINI_CHECK_ERROR_RETURN(HoudiniApi::GetParmIntValues(get_session(), node_id, parm_int_values,
											   parm_infos[i].intValuesIndex, parm_int_count),
					false);

			for (int v = 0; v < parm_int_count; ++v)
			{
				if (v != 0)
					std::cout << ", ";
				std::cout << parm_int_values[v];
			}

			delete[] parm_int_values;
		}
		else if (HoudiniApi::ParmInfo_IsFloat(&parm_infos[i]))
		{
			int parm_float_count = HoudiniApi::ParmInfo_GetFloatValueCount(&parm_infos[i]);
			float *parm_float_values = new float[parm_float_count];

			HOUDINI_CHECK_ERROR_RETURN(HoudiniApi::GetParmFloatValues(get_session(), node_id, parm_float_values,
											   parm_infos[i].floatValuesIndex, parm_float_count),
					false);

			for (int v = 0; v < parm_float_count; ++v)
			{
				if (v != 0)
					std::cout << ", ";
				std::cout << parm_float_values[v];
			}

			delete[] parm_float_values;
		}
		else if (HoudiniApi::ParmInfo_IsString(&parm_infos[i]))
		{
			int parm_string_count = HoudiniApi::ParmInfo_GetStringValueCount(&parm_infos[i]);
			HAPI_StringHandle *parmSH_values = new HAPI_StringHandle[parm_string_count];

			HOUDINI_CHECK_ERROR_RETURN(HoudiniApi::GetParmStringValues(get_session(), node_id, true, parmSH_values,
											   parm_infos[i].stringValuesIndex, parm_string_count),
					false);

			for (int v = 0; v < parm_string_count; ++v)
			{
				if (v != 0)
					std::cout << ", ";

				std::cout << HEGoUtil::get_string(get_session(), parmSH_values[v]);
			}
			delete[] parmSH_values;
		}
		std::cout << ")" << std::endl;
	}
	delete[] parm_infos;

	return true;
}

bool HEGoSessionManager::get_attribs(HAPI_NodeId node_id, HAPI_PartId part_id)
{
	HAPI_PartInfo part_info;
	HoudiniApi::PartInfo_Init(&part_info);
	HOUDINI_CHECK_ERROR_RETURN(HoudiniApi::GetPartInfo(get_session(), node_id, part_id, &part_info), false);

	int vertex_attr_count = part_info.attributeCounts[HAPI_ATTROWNER_VERTEX];
	int point_attr_count = part_info.attributeCounts[HAPI_ATTROWNER_POINT];
	int prim_attr_count = part_info.attributeCounts[HAPI_ATTROWNER_PRIM];
	int detail_attr_count = part_info.attributeCounts[HAPI_ATTROWNER_DETAIL];

	std::cout << "\nAttributes: " << std::endl;
	std::cout << "==========" << std::endl;

	// Point attributes
	std::vector<HAPI_StringHandle> point_attr_nameSH;
	point_attr_nameSH.resize(point_attr_count);
	HOUDINI_CHECK_ERROR_RETURN(HoudiniApi::GetAttributeNames(get_session(), node_id, part_id, HAPI_ATTROWNER_POINT,
									   point_attr_nameSH.data(), point_attr_count),
			false);

	std::cout << "\n  Point Attributes: " << point_attr_count << std::endl;
	std::cout << "  ----------" << std::endl;
	for (int i = 0; i < point_attr_count; ++i)
	{
		std::string attr_name = HEGoUtil::get_string(get_session(), point_attr_nameSH[i]);
		std::cout << "  Name: " << attr_name << std::endl;

		HAPI_AttributeInfo attr_info;
		HoudiniApi::AttributeInfo_Init(&attr_info);
		HOUDINI_CHECK_ERROR_RETURN(HoudiniApi::GetAttributeInfo(get_session(), node_id, part_id, attr_name.c_str(),
										   HAPI_ATTROWNER_POINT, &attr_info),
				false);

		std::cout << "  Count: " << attr_info.count << " Storage type: " << attr_info.storage << std::endl;
	}

	// Vertex attributes
	std::vector<HAPI_StringHandle> vertex_attr_nameSH;
	vertex_attr_nameSH.resize(vertex_attr_count);
	HOUDINI_CHECK_ERROR_RETURN(HoudiniApi::GetAttributeNames(get_session(), node_id, part_id, HAPI_ATTROWNER_VERTEX,
									   vertex_attr_nameSH.data(), vertex_attr_count),
			false);

	std::cout << "\n  Vertex Attributes: " << vertex_attr_count << std::endl;
	std::cout << "  ----------" << std::endl;
	for (int i = 0; i < vertex_attr_count; ++i)
	{
		std::string attr_name = HEGoUtil::get_string(get_session(), vertex_attr_nameSH[i]);
		std::cout << "  Name: " << attr_name << std::endl;

		HAPI_AttributeInfo attr_info;
		HoudiniApi::AttributeInfo_Init(&attr_info);
		HOUDINI_CHECK_ERROR_RETURN(HoudiniApi::GetAttributeInfo(get_session(), node_id, part_id, attr_name.c_str(),
										   HAPI_ATTROWNER_VERTEX, &attr_info),
				false);

		std::cout << "  Count: " << attr_info.count << " Storage type: " << attr_info.storage << std::endl;
	}

	// Primitive attributes
	std::vector<HAPI_StringHandle> prim_attr_nameSH;
	prim_attr_nameSH.resize(prim_attr_count);
	HOUDINI_CHECK_ERROR_RETURN(HoudiniApi::GetAttributeNames(get_session(), node_id, part_id, HAPI_ATTROWNER_PRIM,
									   prim_attr_nameSH.data(), prim_attr_count),
			false);

	std::cout << "\n  Primitive Attributes: " << prim_attr_count << std::endl;
	std::cout << "  ----------" << std::endl;
	for (int i = 0; i < prim_attr_count; ++i)
	{
		std::string attr_name = HEGoUtil::get_string(get_session(), prim_attr_nameSH[i]);
		std::cout << "  Name: " << attr_name << std::endl;

		HAPI_AttributeInfo attr_info;
		HoudiniApi::AttributeInfo_Init(&attr_info);
		HOUDINI_CHECK_ERROR_RETURN(HoudiniApi::GetAttributeInfo(get_session(), node_id, part_id, attr_name.c_str(),
										   HAPI_ATTROWNER_PRIM, &attr_info),
				false);

		std::cout << "  Count: " << attr_info.count << " Storage type: " << attr_info.storage << std::endl;
	}

	// Detail attributes
	std::vector<HAPI_StringHandle> detail_attr_nameSH;
	detail_attr_nameSH.resize(detail_attr_count);
	HOUDINI_CHECK_ERROR_RETURN(HoudiniApi::GetAttributeNames(get_session(), node_id, part_id, HAPI_ATTROWNER_DETAIL,
									   detail_attr_nameSH.data(), detail_attr_count),
			false);

	std::cout << "\n  Detail Attributes: " << detail_attr_count << std::endl;
	std::cout << "  ----------" << std::endl;
	for (int i = 0; i < detail_attr_count; ++i)
	{
		std::string attr_name = HEGoUtil::get_string(get_session(), detail_attr_nameSH[i]);
		std::cout << "  " << attr_name << std::endl;
	};

	return true;
}

bool HEGoSessionManager::wait_for_cook()
{
	if (!get_session())
		return false;

	int status;
	HAPI_Result result;
	do
	{
		result = HoudiniApi::GetStatus(get_session(), HAPI_STATUS_COOK_STATE, &status);
	} while (status > HAPI_STATE_MAX_READY_STATE && result == HAPI_RESULT_SUCCESS);

	if (status != HAPI_STATE_READY || result != HAPI_RESULT_SUCCESS)
	{
		HEGo::Util::Log::error("Cook failure: " + godot::String(HEGoUtil::get_last_cook_error().c_str()));
		godot::String result_string;
		switch (result)
		{
			case HAPI_RESULT_SUCCESS:
				result_string = "HAPI_RESULT_SUCCESS";
			case HAPI_RESULT_FAILURE:
				result_string = "HAPI_RESULT_FAILURE";
			case HAPI_RESULT_ALREADY_INITIALIZED:
				result_string = "HAPI_RESULT_ALREADY_INITIALIZED";
			case HAPI_RESULT_NOT_INITIALIZED:
				result_string = "HAPI_RESULT_NOT_INITIALIZED";
			case HAPI_RESULT_CANT_LOADFILE:
				result_string = "HAPI_RESULT_CANT_LOADFILE";
			case HAPI_RESULT_PARM_SET_FAILED:
				result_string = "HAPI_RESULT_PARM_SET_FAILED";
			case HAPI_RESULT_INVALID_ARGUMENT:
				result_string = "HAPI_RESULT_INVALID_ARGUMENT";
			case HAPI_RESULT_CANT_LOAD_GEO:
				result_string = "HAPI_RESULT_CANT_LOAD_GEO";
			case HAPI_RESULT_CANT_GENERATE_PRESET:
				result_string = "HAPI_RESULT_CANT_GENERATE_PRESET";
			case HAPI_RESULT_CANT_LOAD_PRESET:
				result_string = "HAPI_RESULT_CANT_LOAD_PRESET";
			case HAPI_RESULT_ASSET_DEF_ALREADY_LOADED:
				result_string = "HAPI_RESULT_ASSET_DEF_ALREADY_LOADED";
			case HAPI_RESULT_NO_LICENSE_FOUND:
				result_string = "HAPI_RESULT_NO_LICENSE_FOUND";
			case HAPI_RESULT_DISALLOWED_NC_LICENSE_FOUND:
				result_string = "HAPI_RESULT_DISALLOWED_NC_LICENSE_FOUND";
			case HAPI_RESULT_DISALLOWED_NC_ASSET_WITH_C_LICENSE:
				result_string = "HAPI_RESULT_DISALLOWED_NC_ASSET_WITH_C_LICENSE";
			case HAPI_RESULT_DISALLOWED_NC_ASSET_WITH_LC_LICENSE:
				result_string = "HAPI_RESULT_DISALLOWED_NC_ASSET_WITH_LC_LICENSE";
			case HAPI_RESULT_DISALLOWED_LC_ASSET_WITH_C_LICENSE:
				result_string = "HAPI_RESULT_DISALLOWED_LC_ASSET_WITH_C_LICENSE";
			case HAPI_RESULT_DISALLOWED_HENGINEINDIE_W_3PARTY_PLUGIN:
				result_string = "HAPI_RESULT_DISALLOWED_HENGINEINDIE_W_3PARTY_PLUGIN";
			case HAPI_RESULT_ASSET_INVALID:
				result_string = "HAPI_RESULT_ASSET_INVALID";
			case HAPI_RESULT_NODE_INVALID:
				result_string = "HAPI_RESULT_NODE_INVALID";
			case HAPI_RESULT_USER_INTERRUPTED:
				result_string = "HAPI_RESULT_USER_INTERRUPTED";
			case HAPI_RESULT_INVALID_SESSION:
				result_string = "HAPI_RESULT_INVALID_SESSION";
			default:
				result_string = "DEFAULT - MOST LIKELY YOU'RE FINE AND JUST HAVEN'T HOOKED UP INPUTS YET";
		}
		HEGo::Util::Log::error(result_string);
		godot::String status_string;
		switch (status)
		{
			case HAPI_STATE_READY:
				status_string = "HAPI_STATE_READY";
			case HAPI_STATE_READY_WITH_FATAL_ERRORS:
				status_string = "HAPI_STATE_READY_WITH_FATAL_ERRORS";
			case HAPI_STATE_READY_WITH_COOK_ERRORS:
				status_string = "HAPI_STATE_READY_WITH_COOK_ERRORS";
			case HAPI_STATE_STARTING_COOK:
				status_string = "HAPI_STATE_STARTING_COOK";
			case HAPI_STATE_COOKING:
				status_string = "HAPI_STATE_COOKING";
			case HAPI_STATE_STARTING_LOAD:
				status_string = "HAPI_STATE_STARTING_LOAD";
			case HAPI_STATE_LOADING:
				status_string = "HAPI_STATE_LOADING";
			case HAPI_STATE_MAX:
				status_string = "HAPI_STATE_MAX";
			default:
				result_string = "DEFAULT - MOST LIKELY YOU'RE FINE AND JUST HAVEN'T HOOKED UP INPUTS YET";
		}
		HEGo::Util::Log::error(status_string);
		return false;
	}
	return true;
}