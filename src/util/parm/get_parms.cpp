#include "get_parms.h"
#include "parameter_help.h"
#include "hapi/houdini_api.h"
#include "multiparm_styles.h"
#include "util/hego_util.h"

#include <algorithm>
#include <unordered_map>
#include <vector>

namespace HEGo::Util::Parm
{
namespace
{
using godot::Array;
using godot::Dictionary;
using godot::String;

bool read_string(const HAPI_Session *session, HAPI_StringHandle handle, String &value)
{
	// HAPI reserves handle zero for a missing string and resolves it to a diagnostic.
	if (handle <= 0)
	{
		value = String();
		return true;
	}
	int length = 0;
	if (HoudiniApi::GetStringBufLength(session, handle, &length) != HAPI_RESULT_SUCCESS || length < 0)
		return false;
	if (length == 0)
	{
		value = String();
		return true;
	}
	std::vector<char> buffer(length);
	if (HoudiniApi::GetString(session, handle, buffer.data(), length) != HAPI_RESULT_SUCCESS)
		return false;
	value = String::utf8(buffer.data());
	return true;
}

struct Values
{
	std::vector<int> ints;
	std::vector<float> floats;
	std::vector<String> strings, raw_strings;
	std::vector<Dictionary> choices;

	bool read_strings(const HAPI_Session *session, HAPI_NodeId node, int count, bool evaluate, std::vector<String> &result)
	{
		if (count == 0)
			return true;
		std::vector<HAPI_StringHandle> handles(count);
		if (HoudiniApi::GetParmStringValues(session, node, evaluate, handles.data(), 0, count) != HAPI_RESULT_SUCCESS)
			return false;
		result.resize(count);
		for (int i = 0; i < count; ++i)
			if (!read_string(session, handles[i], result[i]))
				return false;
		return true;
	}

	bool read(const HAPI_Session *session, const HAPI_NodeInfo &info)
	{
		ints.resize(info.parmIntValueCount);
		floats.resize(info.parmFloatValueCount);
		if ((!ints.empty() && HoudiniApi::GetParmIntValues(session, info.id, ints.data(), 0, info.parmIntValueCount) != HAPI_RESULT_SUCCESS) ||
				(!floats.empty() && HoudiniApi::GetParmFloatValues(session, info.id, floats.data(), 0, info.parmFloatValueCount) != HAPI_RESULT_SUCCESS) ||
				!read_strings(session, info.id, info.parmStringValueCount, true, strings) ||
				!read_strings(session, info.id, info.parmStringValueCount, false, raw_strings))
			return false;
		if (info.parmChoiceCount == 0)
			return true;
		std::vector<HAPI_ParmChoiceInfo> items(info.parmChoiceCount);
		if (HoudiniApi::GetParmChoiceLists(session, info.id, items.data(), 0, info.parmChoiceCount) != HAPI_RESULT_SUCCESS)
			return false;
		for (const auto &item : items)
		{
			String label, value;
			if (!read_string(session, item.labelSH, label) || !read_string(session, item.valueSH, value))
				return false;
			Dictionary choice;
			choice["label"] = label;
			choice["value"] = value;
			choices.push_back(choice);
		}
		return true;
	}
};

template <typename T> bool copy_values(Dictionary &entry, const char *key, const std::vector<T> &source, int start, int count)
{
	if (count < 0 || (count > 0 && (start < 0 || int64_t(start) + count > int64_t(source.size()))))
		return false;
	Array items;
	for (int i = 0; i < count; ++i)
		items.append(source[start + i]);
	entry[key] = items;
	return true;
}

bool describe(const HAPI_Session *session, HAPI_NodeId node, const HAPI_ParmInfo &p, const Values &values, Dictionary &d)
{
	d["id"] = p.id;
	d["parent_id"] = p.parentId;
	d["child_index"] = p.childIndex;
	d["type"] = int(p.type);
	d["script_type"] = int(p.scriptType);
	d["size"] = p.size;
	d["visible"] = !p.invisible;
	d["disabled"] = bool(p.disabled);
	d["join_next"] = bool(p.joinNext);
	d["label_none"] = bool(p.labelNone);
	d["has_min"] = bool(p.hasMin);
	d["has_max"] = bool(p.hasMax);
	d["has_ui_min"] = bool(p.hasUIMin);
	d["has_ui_max"] = bool(p.hasUIMax);
	d["min"] = p.min;
	d["max"] = p.max;
	d["ui_min"] = p.UIMin;
	d["ui_max"] = p.UIMax;
	d["choice_list_type"] = int(p.choiceListType);
	d["use_menu_item_token_as_value"] = bool(p.useMenuItemTokenAsValue);
	d["ramp_type"] = int(p.rampType);
	d["permissions"] = int(p.permissions);
	d["is_child_of_multiparm"] = bool(p.isChildOfMultiParm);
	d["instance_num"] = p.instanceNum;

	String name, label, help, type_info, templ;
	if (!read_string(session, p.nameSH, name) || !read_string(session, p.labelSH, label) || !read_string(session, p.helpSH, help) ||
			!read_string(session, p.typeInfoSH, type_info) || !read_string(session, p.templateNameSH, templ))
		return false;
	d["name"] = name;
	d["label"] = label;
	d["help"] = help;
	d["template_name"] = templ;
	d["type_info"] = type_info;

	if (p.tagCount)
	{
		Dictionary tags;
		for (int i = 0; i < p.tagCount; ++i)
		{
			HAPI_StringHandle handle;
			String tag, value;
			if (HoudiniApi::GetParmTagName(session, node, p.id, i, &handle) != HAPI_RESULT_SUCCESS || !read_string(session, handle, tag) ||
					HoudiniApi::GetParmTagValue(session, node, p.id, tag.utf8().get_data(), &handle) != HAPI_RESULT_SUCCESS ||
					!read_string(session, handle, value))
				return false;
			tags[tag] = value;
		}
		d["tags"] = tags;
	}
	if (p.choiceCount && !copy_values(d, "choices", values.choices, p.choiceIndex, p.choiceCount))
		return false;
	if (p.type >= HAPI_PARMTYPE_INT_START && p.type <= HAPI_PARMTYPE_INT_END)
	{
		if (!copy_values(d, "values", values.ints, p.intValuesIndex, p.size))
			return false;
	}
	else if (p.type >= HAPI_PARMTYPE_FLOAT_START && p.type <= HAPI_PARMTYPE_FLOAT_END)
	{
		if (!copy_values(d, "values", values.floats, p.floatValuesIndex, p.size))
			return false;
	}
	else if (p.type == HAPI_PARMTYPE_FOLDERLIST_RADIO)
	{
		if (!copy_values(d, "values", values.ints, p.intValuesIndex, 1))
			return false;
	}
	else if ((p.type >= HAPI_PARMTYPE_STRING_START && p.type <= HAPI_PARMTYPE_STRING_END) || p.type == HAPI_PARMTYPE_PATH_FILE_DIR ||
			p.type == HAPI_PARMTYPE_LABEL)
	{
		// A label without column text can have no string storage.
		if (p.type != HAPI_PARMTYPE_LABEL || p.stringValuesIndex >= 0)
		{
			if (!copy_values(d, "values", values.strings, p.stringValuesIndex, p.size) ||
					!copy_values(d, "raw_values", values.raw_strings, p.stringValuesIndex, p.size))
				return false;
		}
	}
	if (p.type == HAPI_PARMTYPE_NODE)
	{
		d["input_node_type"] = int(p.inputNodeType);
		d["input_node_flag"] = int(p.inputNodeFlag);
		HAPI_NodeId source = -1;
		if (HoudiniApi::GetParmNodeValue(session, node, name.utf8().get_data(), &source) != HAPI_RESULT_SUCCESS)
			return false;
		d["node_id"] = source;
	}
	return true;
}
} // namespace

bool get_help_page(const HAPI_Session *session, HAPI_NodeId node, Dictionary &result, String &error)
{
	auto asset = HoudiniApi::AssetInfo_Create();
	String text, url, op_name;
	if (HoudiniApi::GetAssetInfo(session, node, &asset) != HAPI_RESULT_SUCCESS ||
			!read_string(session, asset.helpTextSH, text) || !read_string(session, asset.helpURLSH, url) ||
			!read_string(session, asset.fullOpNameSH, op_name))
	{
		error = "Could not read the Houdini operator help page.";
		return false;
	}
	result["text"] = text;
	result["url"] = url;
	result["op_name"] = op_name;
	return true;
}

bool get_parm_dict(HEGoSessionManager *manager, HAPI_NodeId node, Dictionary &result, String &error)
{
	const HAPI_Session *session = manager->get_session();
	HAPI_NodeInfo info = HoudiniApi::NodeInfo_Create();
	if (HoudiniApi::GetNodeInfo(session, node, &info) != HAPI_RESULT_SUCCESS)
	{
		error = "Could not read HAPI node metadata.";
		return false;
	}
	if (info.parmCount == 0)
		return true;
	std::vector<HAPI_ParmInfo> parms(info.parmCount);
	Values values;
	if (HoudiniApi::GetParameters(session, node, parms.data(), 0, info.parmCount) != HAPI_RESULT_SUCCESS || !values.read(session, info))
	{
		error = "Could not read the complete HAPI parameter list, values or menu choices.";
		return false;
	}
	const bool needs_layout = std::any_of(parms.begin(), parms.end(), [](const auto &parm) {
		return (parm.type == HAPI_PARMTYPE_MULTIPARMLIST && parm.rampType == HAPI_RAMPTYPE_INVALID) ||
				(parm.type == HAPI_PARMTYPE_FOLDER && (parm.scriptType == HAPI_PRM_SCRIPT_TYPE_GROUPCOLLAPSIBLE || parm.scriptType == HAPI_PRM_SCRIPT_TYPE_GROUP));
	});
	// Some built-in operators have no asset metadata. Their live parameters
	// and explicit tooltips remain available independently of the help page.
	auto asset = HoudiniApi::AssetInfo_Create();
	const bool has_asset = HoudiniApi::GetAssetInfo(session, node, &asset) == HAPI_RESULT_SUCCESS;
	const auto layout = has_asset && needs_layout ? get_parameter_layout(session, asset) : ParameterLayout{};
	std::vector<String> folder_defaults(info.parmCount);
	std::vector<Dictionary> rows(info.parmCount);
	std::unordered_map<int, int> index;
	for (int i = 0; i < info.parmCount; ++i)
	{
		const auto &p = parms[i];
		Dictionary &row = rows[i];
		if (!describe(session, node, p, values, row))
		{
			error = "Could not read complete metadata or values for parameter '" + Util::Hapi::get_godot_string(session, p.nameSH) + "'.";
			return false;
		}
		index.emplace(p.id, i);
		if (p.type == HAPI_PARMTYPE_MULTIPARMLIST)
		{
			if (p.rampType == HAPI_RAMPTYPE_INVALID)
			{
				const Dictionary tags = row.get("tags", Dictionary());
				String style = layout.multiparm_styles.get(row["template_name"], layout.multiparm_styles.get(row["name"], tags.get("hego_multiparm_style", "list")));
				row["multiparm_style"] = style == "tabs" || style == "scroll" ? style : String("list");
			}
			row["instance_count"] = p.instanceCount;
			row["instance_length"] = p.instanceLength;
			row["instance_start_offset"] = p.instanceStartOffset;
			Array instances;
			for (int j = 0; j < p.instanceCount; ++j)
				instances.append(Array());
			row["instances"] = instances;
		}
		else if (p.type == HAPI_PARMTYPE_FOLDER || p.type == HAPI_PARMTYPE_FOLDERLIST || p.type == HAPI_PARMTYPE_FOLDERLIST_RADIO)
		{
			row["children"] = Array();
			if (p.type != HAPI_PARMTYPE_FOLDER)
			{
				// Switchers describe the following sibling folders; each folder owns its fields.
				Array folders;
				for (int j = i + 1; j < info.parmCount && j - i <= p.size; ++j)
				{
					if (parms[j].type != HAPI_PARMTYPE_FOLDER || parms[j].parentId != p.parentId)
						break;
					folders.append(parms[j].id);
				}
				row["folder_ids"] = folders;
				if (folders.size() > 0)
				{
					// The switcher carries the first authored folder name. Its first
					// folder descriptor has a synthetic name such as "options_0".
					const String initial = layout.folder_defaults.get(row["template_name"], layout.folder_defaults.get(row["name"], ""));
					folder_defaults[i] = initial;
					folder_defaults[i + 1] = initial;
				}
			}
			if (!folder_defaults[i].is_empty())
			{
				Dictionary tags = row.get("tags", Dictionary());
				if (!tags.has("group_default")) tags["group_default"] = folder_defaults[i];
				row["tags"] = tags;
			}
		}
	}
	String page;
	if (has_asset && read_string(session, asset.helpTextSH, page) && !page.is_empty())
		apply_parameter_help(page, rows);
	for (int i = 0; i < info.parmCount; ++i)
	{
		const auto &p = parms[i];
		if (p.parentId == -1)
		{
			if (!p.invisible)
				result[rows[i]["name"]] = rows[i];
			continue;
		}
		auto parent = index.find(p.parentId);
		if (parent == index.end())
			continue;
		Dictionary &owner = rows[parent->second];
		if (owner.has("instances"))
		{
			Array instances = owner["instances"];
			const int offset = p.instanceNum - parms[parent->second].instanceStartOffset;
			if (offset < 0 || offset >= instances.size())
				continue;
			Array children = instances[offset];
			children.append(rows[i]);
		}
		else if (owner.has("children"))
		{
			Array children = owner["children"];
			children.append(rows[i]);
		}
	}
	return true;
}
} // namespace HEGo::Util::Parm
