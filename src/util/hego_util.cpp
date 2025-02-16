#include "hego_util.h"

#include <iostream>
#include <string>

std::string
HEGoUtil::get_last_error(HAPI_Session *session)
{
    int buffer_length = 0;
    HoudiniApi::GetStatusStringBufLength(
        session,
        HAPI_STATUS_CALL_RESULT,
        HAPI_STATUSVERBOSITY_ERRORS,
        &buffer_length);
    if (buffer_length <= 0)
        return std::string("");

    char *buffer = new char[buffer_length];
    HoudiniApi::GetStatusString(session, HAPI_STATUS_CALL_RESULT, buffer, buffer_length);
    std::string result(buffer);
    delete[] buffer;

    return result;
}

std::string
HEGoUtil::get_last_cook_error(HAPI_Session *session)
{
    int buffer_length = 0;
    HoudiniApi::GetStatusStringBufLength(
        session,
        HAPI_STATUS_COOK_RESULT,
        HAPI_STATUSVERBOSITY_ERRORS,
        &buffer_length);

    if (buffer_length <= 0)
        return std::string("");

    char *buffer = new char[buffer_length];
    HoudiniApi::GetStatusString(session, HAPI_STATUS_COOK_RESULT, buffer, buffer_length);
    std::string result(buffer);
    delete[] buffer;

    return result;
}

std::string
HEGoUtil::get_connection_error()
{
    int buffer_length = 0;
    HoudiniApi::GetConnectionErrorLength(&buffer_length);

    if (buffer_length <= 0)
        return std::string("");

    char *buffer = new char[buffer_length];
    HoudiniApi::GetConnectionError(buffer, buffer_length, true);

    std::string result(buffer);
    delete[] buffer;

    return result;
}

std::string
HEGoUtil::get_string(const HAPI_Session *session, HAPI_StringHandle string_handle)
{
    int length = 0;
    HoudiniApi::GetStringBufLength(session, string_handle, &length);

    char *buffer = new char[length + 1];
    HoudiniApi::GetString(session, string_handle, buffer, length);

    std::string result(buffer);
    delete[] buffer;
    return result;
}

bool HEGoUtil::save_to_hip(const HAPI_Session *session, const std::string &filename)
{
    HAPI_Result result = HoudiniApi::SaveHIPFile(session, filename.c_str(), /*lock_nodes=*/false);
    return result == HAPI_RESULT_SUCCESS;
}

HAPI_NodeId HEGoUtil::get_parent_node_id(const HAPI_Session *session, const HAPI_NodeId &node_id)
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


