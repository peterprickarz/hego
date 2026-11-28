#include "set_parms.h"
#include "hapi/houdini_api.h"
#include "util/hego_util.h"

#include <algorithm>
#include <cmath>
#include <limits>
#include <set>
#include <type_traits>
#include <vector>

namespace HEGo::Util::Parm
{
namespace
{
using godot::String;
using godot::Variant;

struct PreparedParm
{
	String name;
	HAPI_ParmInfo info{};
	std::vector<int> ints;
	std::vector<float> floats;
	godot::PackedStringArray strings;
};

bool reject(String &error, const String &name, const String &message)
{
	error = "Parameter '" + name + "': " + message;
	return false;
}

bool int_type(HAPI_ParmType type) { return type >= HAPI_PARMTYPE_INT_START && type <= HAPI_PARMTYPE_INT_END; }
bool float_type(HAPI_ParmType type) { return type >= HAPI_PARMTYPE_FLOAT_START && type <= HAPI_PARMTYPE_FLOAT_END; }
bool string_type(HAPI_ParmType type) { return (type >= HAPI_PARMTYPE_STRING_START && type <= HAPI_PARMTYPE_STRING_END) || type == HAPI_PARMTYPE_PATH_FILE_DIR; }

bool metadata(const HAPI_Session *session, HAPI_NodeId node, const String &name, HAPI_ParmInfo &info, String &error)
{
	info = HoudiniApi::ParmInfo_Create();
	if (name.is_empty() || HoudiniApi::GetParmInfoFromName(session, node, name.utf8().get_data(), &info) != HAPI_RESULT_SUCCESS || info.id < 0)
		return reject(error, name, "unknown name or unreadable HAPI metadata.");
	HAPI_NodeInfo owner = HoudiniApi::NodeInfo_Create();
	if (HoudiniApi::GetNodeInfo(session, node, &owner) != HAPI_RESULT_SUCCESS)
		return reject(error, name, "could not read owning node metadata.");
	const bool radio = info.type == HAPI_PARMTYPE_FOLDERLIST_RADIO;
	const bool integer = int_type(info.type) || radio;
	const int start = integer ? info.intValuesIndex : float_type(info.type) ? info.floatValuesIndex : string_type(info.type) ? info.stringValuesIndex : -1;
	const int count = integer ? owner.parmIntValueCount : float_type(info.type) ? owner.parmFloatValueCount : owner.parmStringValueCount;
	const int arity = radio ? 1 : info.size;
	if (info.size < 1 || start < 0 || int64_t(start) + arity > count)
		return reject(error, name, "unsupported parameter type/tuple or invalid HAPI value-array bounds.");
	return true;
}

template <typename T> bool append_number(PreparedParm &out, T number, String &error)
{
	const auto &p = out.info;
	const double n = static_cast<double>(number);
	if (!std::isfinite(n))
		return reject(error, out.name, "numeric values must be finite.");
	const float ranged = static_cast<float>(number);
	if ((p.hasMin && ranged < p.min) || (p.hasMax && ranged > p.max))
		return reject(error, out.name, "value exceeds the parameter's declared hard range.");
	if (int_type(p.type) || p.type == HAPI_PARMTYPE_FOLDERLIST_RADIO)
	{
		if (std::trunc(n) != n || n < std::numeric_limits<int>::min() || n > std::numeric_limits<int>::max())
			return reject(error, out.name, "integer parameters require integral int32 values.");
		if (p.type == HAPI_PARMTYPE_FOLDERLIST_RADIO && (n < 0 || n >= p.size))
			return reject(error, out.name, "radio tab index is out of range.");
		out.ints.push_back(static_cast<int>(number));
	}
	else
	{
		if (!std::isfinite(ranged) || (number != 0 && ranged == 0))
			return reject(error, out.name, "value exceeds HAPI float32 storage.");
		if constexpr (std::is_integral_v<T>)
		{
			// Compare the original integer before MSVC's double-width long double can lose precision.
			if (ranged >= 0x1p63 || ranged < -0x1p63 || static_cast<int64_t>(ranged) != int64_t(number))
				return reject(error, out.name, "integer cannot be represented exactly in HAPI float32 storage.");
		}
		out.floats.push_back(ranged);
	}
	return true;
}

template <typename Array> bool append_components(PreparedParm &out, const Array &values, int count, String &error)
{
	for (int i = 0; i < count; ++i)
		if (!append_number(out, values[i], error))
			return false;
	return true;
}

bool prepare(const HAPI_Session *session, HAPI_NodeId node, const String &name, const Variant &value, PreparedParm &out, String &error)
{
	out.name = name;
	if (!metadata(session, node, name, out.info, error))
		return false;
	const auto &p = out.info;
	const int arity = p.type == HAPI_PARMTYPE_FOLDERLIST_RADIO ? 1 : p.size;
	const auto mismatch = [&]() { return reject(error, name, "value tuple length does not match the HAPI parameter."); };
	if (string_type(p.type))
	{
		if (value.get_type() == Variant::STRING)
			out.strings.append(value);
		else if (value.get_type() == Variant::PACKED_STRING_ARRAY)
			out.strings = value;
		else
			return reject(error, name, "requires a String or a matching PackedStringArray.");
		return out.strings.size() == arity || mismatch();
	}
	switch (value.get_type())
	{
		case Variant::BOOL:
			if (p.type != HAPI_PARMTYPE_TOGGLE)
				return reject(error, name, "bool is accepted only for toggles.");
			if (!append_number(out, int(bool(value)), error))
				return false;
			break;
		case Variant::INT:
			if (!append_number(out, int64_t(value), error))
				return false;
			break;
		case Variant::FLOAT:
			if (!append_number(out, double(value), error))
				return false;
			break;
		case Variant::COLOR:
			if (p.type != HAPI_PARMTYPE_COLOR || (arity != 3 && arity != 4))
				return reject(error, name, "Color requires an RGB or RGBA parameter.");
			if (!append_components(out, godot::Color(value), arity, error))
				return false;
			break;
		case Variant::VECTOR2:
			if (!append_components(out, godot::Vector2(value), 2, error))
				return false;
			break;
		case Variant::VECTOR3:
			if (!append_components(out, godot::Vector3(value), 3, error))
				return false;
			break;
		case Variant::VECTOR4:
			if (!append_components(out, godot::Vector4(value), 4, error))
				return false;
			break;
		case Variant::VECTOR2I:
			if (!append_components(out, godot::Vector2i(value), 2, error))
				return false;
			break;
		case Variant::VECTOR3I:
			if (!append_components(out, godot::Vector3i(value), 3, error))
				return false;
			break;
		case Variant::VECTOR4I:
			if (!append_components(out, godot::Vector4i(value), 4, error))
				return false;
			break;
		case Variant::PACKED_INT32_ARRAY:
		{
			godot::PackedInt32Array a = value;
			if (a.size() != arity)
				return mismatch();
			return append_components(out, a, arity, error);
		}
		case Variant::PACKED_INT64_ARRAY:
		{
			godot::PackedInt64Array a = value;
			if (a.size() != arity)
				return mismatch();
			return append_components(out, a, arity, error);
		}
		case Variant::PACKED_FLOAT32_ARRAY:
		{
			godot::PackedFloat32Array a = value;
			if (a.size() != arity)
				return mismatch();
			return append_components(out, a, arity, error);
		}
		case Variant::PACKED_FLOAT64_ARRAY:
		{
			godot::PackedFloat64Array a = value;
			if (a.size() != arity)
				return mismatch();
			return append_components(out, a, arity, error);
		}
		default:
			return reject(error, name, "expected a matching numeric scalar, vector or typed packed array.");
	}
	return out.ints.size() + out.floats.size() == size_t(arity) || mismatch();
}

bool current_info(const HAPI_Session *session, HAPI_NodeId node, const PreparedParm &parm, HAPI_ParmInfo &current, String &error)
{
	if (!metadata(session, node, parm.name, current, error))
		return false;
	if (current.id != parm.info.id || current.type != parm.info.type || current.size != parm.info.size || current.scriptType != parm.info.scriptType)
		return reject(error, parm.name, "parameter layout changed during the batch.");
	return true;
}

bool write_result(HEGoSessionManager *mgr, HAPI_Result result, const String &name, String &error)
{
	if (result != HAPI_RESULT_SUCCESS)
		return reject(error, name, "HAPI rejected the write (code " + String::num_int64(result) + ").");
	if (!mgr->wait_for_ready())
		return reject(error, name, "session became unavailable while waiting for the write.");
	int status = HAPI_RESULT_FAILURE;
	if (HoudiniApi::GetStatus(mgr->get_session(), HAPI_STATUS_COOK_RESULT, &status) != HAPI_RESULT_SUCCESS || status != HAPI_RESULT_SUCCESS)
		return reject(error, name, "HAPI reported a failed write: " + String::utf8(Util::Hapi::get_last_cook_error(mgr->get_session()).c_str()));
	return true;
}

bool apply(HEGoSessionManager *manager, HAPI_NodeId node, const PreparedParm &parm, String &error)
{
	const HAPI_Session *session = manager->get_session();
	HAPI_ParmInfo current;
	if (!current_info(session, node, parm, current, error))
		return false;
	if (!parm.ints.empty())
		return write_result(
				manager, HoudiniApi::SetParmIntValues(session, node, parm.ints.data(), current.intValuesIndex, int(parm.ints.size())), parm.name, error);
	if (!parm.floats.empty())
		return write_result(manager, HoudiniApi::SetParmFloatValues(session, node, parm.floats.data(), current.floatValuesIndex, int(parm.floats.size())),
				parm.name, error);
	for (int i = 0; i < parm.strings.size(); ++i)
	{
		if (i && !current_info(session, node, parm, current, error))
			return false;
		if (!write_result(manager, HoudiniApi::SetParmStringValue(session, node, parm.strings[i].utf8().get_data(), current.id, i), parm.name, error))
			return false;
	}
	return true;
}
} // namespace

bool set_parms(HEGoSessionManager *manager, HAPI_NodeId node, const godot::Dictionary &values, String &error)
{
	const HAPI_Session *session = manager ? manager->get_session() : nullptr;
	if (!session || node < 0 || HoudiniApi::IsSessionValid(session) != HAPI_RESULT_SUCCESS)
	{
		error = "Cannot set parameters on an invalid node/session.";
		return false;
	}
	std::vector<PreparedParm> prepared;
	std::set<String> seen;
	const godot::Array keys = values.keys();
	for (int i = 0; i < keys.size(); ++i)
	{
		const Variant key = keys[i];
		if (key.get_type() != Variant::STRING && key.get_type() != Variant::STRING_NAME)
		{
			error = "Parameter names must be Strings or StringNames.";
			return false;
		}
		const String name = key;
		if (!seen.insert(name).second)
			return reject(error, name, "duplicate normalized name.");
		PreparedParm parm;
		if (!prepare(session, node, name, values[key], parm, error))
			return false;
		prepared.push_back(std::move(parm));
	}
	// All values must validate before any callback or write can happen.
	for (const PreparedParm &parm : prepared)
		if (!apply(manager, node, parm, error))
			return false;
	return true;
}

bool set_parm(HEGoSessionManager *mgr, HAPI_NodeId node, const String &name, const Variant &value, String &error)
{
	godot::Dictionary values;
	values[name] = value;
	return set_parms(mgr, node, values, error);
}

bool change_multiparm(HEGoSessionManager *manager, HAPI_NodeId node, int id, int position, bool insert, String &error)
{
	const HAPI_Session *session = manager->get_session();
	HAPI_ParmInfo info = HoudiniApi::ParmInfo_Create();
	if (HoudiniApi::GetParmInfo(session, node, id, &info) != HAPI_RESULT_SUCCESS || info.type != HAPI_PARMTYPE_MULTIPARMLIST || info.id != id)
	{
		error = "The selected multiparm no longer exists.";
		return false;
	}
	const int64_t end = int64_t(info.instanceStartOffset) + info.instanceCount;
	if (position < info.instanceStartOffset || position > end || (!insert && position == end))
	{
		error = "Multiparm instance position is outside the current list.";
		return false;
	}
	const HAPI_Result result =
			insert ? HoudiniApi::InsertMultiparmInstance(session, node, id, position) : HoudiniApi::RemoveMultiparmInstance(session, node, id, position);
	if (result != HAPI_RESULT_SUCCESS)
	{
		error = "HAPI rejected the multiparm edit (code " + String::num_int64(result) + ").";
		return false;
	}
	return true;
}

bool get_node_parm_info(const HAPI_Session *session, HAPI_NodeId node, const String &name, HAPI_ParmInfo &info, String &error)
{
	if (!metadata(session, node, name, info, error))
		return false;
	return (info.type == HAPI_PARMTYPE_NODE && info.size == 1) || reject(error, name, "requires a single Houdini node-reference parameter.");
}

bool accepts_node(const HAPI_Session *session, const HAPI_ParmInfo &parm, HAPI_NodeId source)
{
	HAPI_NodeInfo node = HoudiniApi::NodeInfo_Create();
	if (source < 0 || HoudiniApi::GetNodeInfo(session, source, &node) != HAPI_RESULT_SUCCESS || !(node.type & parm.inputNodeType) ||
			(parm.inputNodeType == HAPI_NODETYPE_NONE && parm.inputNodeFlag == HAPI_NODEFLAGS_NONE))
		return false;
	if (parm.inputNodeFlag == HAPI_NODEFLAGS_ANY || parm.inputNodeFlag == HAPI_NODEFLAGS_NONE)
		return true;
	// HAPI_NodeInfo does not expose a complete node flag mask. Ask Houdini to apply
	// the same node-type/flag filter to this source's siblings, including the source.
	int count = 0;
	if (HoudiniApi::ComposeChildNodeList(session, node.parentId, parm.inputNodeType, parm.inputNodeFlag, false, &count) != HAPI_RESULT_SUCCESS || count <= 0)
		return false;
	std::vector<HAPI_NodeId> nodes(count);
	return HoudiniApi::GetComposedChildNodeList(session, node.parentId, nodes.data(), count) == HAPI_RESULT_SUCCESS &&
			std::find(nodes.begin(), nodes.end(), source) != nodes.end();
}
} // namespace HEGo::Util::Parm
