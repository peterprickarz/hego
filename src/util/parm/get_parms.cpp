#include "get_parms.h"
#include "hapi/houdini_api.h"
#include "util/hego_util.h"

#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/string.hpp>

namespace HEGo
{
namespace Util
{
namespace Parm
{
// Helper function to get a string from a string handle
godot::String get_parm_string(HAPI_Session *session, HAPI_NodeId node_id, HAPI_StringHandle string_handle)
{
	int buffer_length;
	HoudiniApi::GetStringBufLength(session, string_handle, &buffer_length);
	char *buffer = new char[buffer_length];
	HoudiniApi::GetString(session, string_handle, buffer, buffer_length);
	godot::String result = godot::String::utf8(buffer);
	delete[] buffer;
	return result;
}

// Helper function to build a dictionary for a single parameter
godot::Dictionary build_parm_dict(HAPI_Session *session, HAPI_NodeId node_id, HAPI_ParmInfo *parm_infos, int parm_count, int parm_index)
{
	godot::Dictionary parm_dict;
	HAPI_ParmInfo &parm = parm_infos[parm_index];

	// Basic parameter info
	parm_dict["id"] = parm.id;
	parm_dict["type"] = static_cast<int>(parm.type);
	parm_dict["size"] = parm.size;
	parm_dict["visible"] = !parm.invisible;
	parm_dict["name"] = get_parm_string(session, node_id, parm.nameSH);
	parm_dict["label"] = get_parm_string(session, node_id, parm.labelSH);
	parm_dict["help"] = get_parm_string(session, node_id, parm.helpSH);
	parm_dict["join_next"] = parm.joinNext;
	parm_dict["label_none"] = parm.labelNone;
	parm_dict["has_min"] = parm.hasMin;
	parm_dict["has_max"] = parm.hasMax;
	parm_dict["min"] = parm.min;
	parm_dict["max"] = parm.max;
	parm_dict["is_child_of_multiparm"] = parm.isChildOfMultiParm;
	parm_dict["instance_num"] = parm.instanceNum;

	// Handle parameter tags
	if (parm.tagCount > 0)
	{
		godot::Dictionary tags;
		for (int j = 0; j < parm.tagCount; ++j)
		{
			HAPI_StringHandle tag_name_handle;
			if (HoudiniApi::GetParmTagName(session, node_id, parm.id, j, &tag_name_handle) == HAPI_RESULT_SUCCESS)
			{
				godot::String tag_name = get_parm_string(session, node_id, tag_name_handle);
				HAPI_StringHandle tag_value_handle;
				if (HoudiniApi::GetParmTagValue(session, node_id, parm.id, tag_name.utf8().get_data(), &tag_value_handle) == HAPI_RESULT_SUCCESS)
				{
					godot::String tag_value = get_parm_string(session, node_id, tag_value_handle);
					tags[tag_name] = tag_value;
				}
				else
				{
					tags[tag_name] = godot::String(); // Empty value if tag value retrieval fails
				}
			}
		}
		parm_dict["tags"] = tags;
	}

	// Handle parameter values based on type
	if (parm.type >= HAPI_PARMTYPE_INT_START && parm.type <= HAPI_PARMTYPE_INT_END)
	{
		godot::Array values;
		int *int_values = new int[parm.size];
		HoudiniApi::GetParmIntValues(session, node_id, int_values, parm.intValuesIndex, parm.size);
		for (int j = 0; j < parm.size; ++j)
		{
			values.append(int_values[j]);
		}
		delete[] int_values;
		parm_dict["values"] = values;

		// For multi-parm lists, include instance count and related fields
		if (parm.type == HAPI_PARMTYPE_MULTIPARMLIST)
		{
			parm_dict["instance_count"] = parm.instanceCount;
			parm_dict["instance_length"] = parm.instanceLength;
			parm_dict["instance_start_offset"] = parm.instanceStartOffset;
		}
	}
	else if (parm.type >= HAPI_PARMTYPE_FLOAT_START && parm.type <= HAPI_PARMTYPE_FLOAT_END)
	{
		godot::Array values;
		float *float_values = new float[parm.size];
		HoudiniApi::GetParmFloatValues(session, node_id, float_values, parm.floatValuesIndex, parm.size);
		for (int j = 0; j < parm.size; ++j)
		{
			values.append(float_values[j]);
		}
		delete[] float_values;
		parm_dict["values"] = values;
	}
	else if (parm.type >= HAPI_PARMTYPE_STRING_START && parm.type <= HAPI_PARMTYPE_STRING_END)
	{
		godot::Array values;
		HAPI_StringHandle *string_handles = new HAPI_StringHandle[parm.size];
		// Use evaluate = true to get evaluated strings (e.g., "1" instead of "$F").
		// Set to false if you want raw strings (e.g., "$F").
		if (HoudiniApi::GetParmStringValues(session, node_id, true, string_handles, parm.stringValuesIndex, parm.size) == HAPI_RESULT_SUCCESS)
		{
			for (int j = 0; j < parm.size; ++j)
			{
				values.append(get_parm_string(session, node_id, string_handles[j]));
			}
		}
		delete[] string_handles;
		parm_dict["values"] = values;
	}

	// Handle hierarchical parameters (e.g., folders, folder lists, multi-parm lists)
	if (parm.type == HAPI_PARMTYPE_FOLDER || parm.type == HAPI_PARMTYPE_FOLDERLIST || parm.type == HAPI_PARMTYPE_FOLDERLIST_RADIO ||
			parm.type == HAPI_PARMTYPE_MULTIPARMLIST)
	{
		if (parm.type == HAPI_PARMTYPE_MULTIPARMLIST)
		{
			// For multi-parm lists, group children by instance
			godot::Array instances;
			int start_offset = parm.instanceStartOffset;
			for (int instance = 0; instance < parm.instanceCount; ++instance)
			{
				int instance_num = start_offset + instance;
				godot::Array instance_children;
				for (int j = 0; j < parm_count; ++j)
				{
					HAPI_ParmInfo &child_parm = parm_infos[j];
					if (child_parm.parentId == parm.id && child_parm.instanceNum == instance_num)
					{
						godot::Dictionary child_dict = build_parm_dict(session, node_id, parm_infos, parm_count, j);
						instance_children.append(child_dict);
					}
				}
				instances.append(instance_children);
			}
			parm_dict["instances"] = instances;
		}
		else
		{
			// For folders, collect all children in a single array
			godot::Array children;
			for (int j = 0; j < parm_count; ++j)
			{
				if (parm_infos[j].parentId == parm.id)
				{
					godot::Dictionary child_dict = build_parm_dict(session, node_id, parm_infos, parm_count, j);
					children.append(child_dict);
				}
			}
			parm_dict["children"] = children;
		}
	}

	// Add additional info for specific parameter types
	if (parm.choiceCount > 0)
	{
		godot::Array choices;
		HAPI_ParmChoiceInfo *choice_infos = new HAPI_ParmChoiceInfo[parm.choiceCount];
		HoudiniApi::GetParmChoiceLists(session, node_id, choice_infos, parm.choiceIndex, parm.choiceCount);
		for (int j = 0; j < parm.choiceCount; ++j)
		{
			godot::Dictionary choice_dict;
			choice_dict["value"] = get_parm_string(session, node_id, choice_infos[j].valueSH);
			choice_dict["label"] = get_parm_string(session, node_id, choice_infos[j].labelSH);
			choices.append(choice_dict);
		}
		delete[] choice_infos;
		parm_dict["choices"] = choices;
	}

	return parm_dict;
}

godot::Dictionary HEGo::Util::Parm::get_parm_dict(HEGoSessionManager *session_mgr, HAPI_NodeId node_id)
{
	godot::Dictionary result;

	// Get the session
	HAPI_Session *session = session_mgr->get_session();
	if (!session)
	{
		// Handle invalid session
		return result;
	}

	// Get node info
	HAPI_NodeInfo node_info;
	if (HoudiniApi::GetNodeInfo(session, node_id, &node_info) != HAPI_RESULT_SUCCESS)
	{
		return result;
	}

	// Allocate array for parameter info
	HAPI_ParmInfo *parm_infos = new HAPI_ParmInfo[node_info.parmCount];
	if (HoudiniApi::GetParameters(session, node_id, parm_infos, 0, node_info.parmCount) != HAPI_RESULT_SUCCESS)
	{
		delete[] parm_infos;
		return result;
	}

	// Iterate through parameters to build the dictionary
	for (int i = 0; i < node_info.parmCount; ++i)
	{
		HAPI_ParmInfo &parm = parm_infos[i];

		// Skip if invisible or not a top-level parameter
		if (parm.invisible || parm.parentId != -1)
		{
			continue;
		}

		// Create a dictionary for this parameter
		godot::Dictionary parm_dict = build_parm_dict(session, node_id, parm_infos, node_info.parmCount, i);

		// Get parameter name using string handle
		godot::String parm_name = get_parm_string(session, node_id, parm.nameSH);
		result[parm_name] = parm_dict;
	}

	delete[] parm_infos;
	return result;
}

} // namespace Parm
} // namespace Util
} // namespace HEGo