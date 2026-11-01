#include "util/parm/set_parms.h"
#include "hapi/houdini_api.h"
#include "util/hego_util.h"
#include <cmath>
#include <limits>
#include <set>
#include <vector>

namespace HEGo::Util::Parm {
namespace {
struct PreparedParm {
	godot::String name;
	HAPI_ParmInfo info{};
	std::vector<int> ints;
	std::vector<float> floats;
	godot::String text;
};
bool reject(godot::String &error, const godot::String &name, const godot::String &message) {
	error = "Parameter '" + name + "': " + message; return false;
}
bool int_type(HAPI_ParmType type) { return type >= HAPI_PARMTYPE_INT_START && type <= HAPI_PARMTYPE_INT_END; }
bool float_type(HAPI_ParmType type) { return type >= HAPI_PARMTYPE_FLOAT_START && type <= HAPI_PARMTYPE_FLOAT_END; }
bool string_type(HAPI_ParmType type) { return (type >= HAPI_PARMTYPE_STRING_START && type <= HAPI_PARMTYPE_STRING_END) || type == HAPI_PARMTYPE_PATH_FILE_DIR; }

bool metadata(const HAPI_Session *session, HAPI_NodeId node, const godot::String &name, HAPI_ParmInfo &info, godot::String &error) {
	info = HoudiniApi::ParmInfo_Create();
	if (name.is_empty() || HoudiniApi::GetParmInfoFromName(session, node, name.utf8().get_data(), &info) != HAPI_RESULT_SUCCESS || info.id < 0)
		return reject(error, name, "unknown name or unreadable HAPI metadata.");
	HAPI_NodeInfo owner = HoudiniApi::NodeInfo_Create();
	if (HoudiniApi::GetNodeInfo(session, node, &owner) != HAPI_RESULT_SUCCESS) return reject(error, name, "could not read owning node metadata.");
	const int start = int_type(info.type) ? info.intValuesIndex : float_type(info.type) ? info.floatValuesIndex : string_type(info.type) ? info.stringValuesIndex : -1;
	const int count = int_type(info.type) ? owner.parmIntValueCount : float_type(info.type) ? owner.parmFloatValueCount : owner.parmStringValueCount;
	if (info.size < 1 || info.size > 4 || start < 0 || int64_t(start) + info.size > count)
		return reject(error, name, "unsupported parameter type/tuple or invalid HAPI value-array bounds.");
	return true;
}

bool prepare(const HAPI_Session *session, HAPI_NodeId node, const godot::String &name, const godot::Variant &value, PreparedParm &out, godot::String &error) {
	out.name = name;
	if (!metadata(session, node, name, out.info, error)) return false;
	if (string_type(out.info.type)) {
		if (out.info.size != 1 || value.get_type() != godot::Variant::STRING) return reject(error, name, "requires a scalar String.");
		out.text = value; return true;
	}
	std::vector<long double> numbers;
	bool integer_input = false;
	switch (value.get_type()) {
		case godot::Variant::INT: numbers = {static_cast<long double>(int64_t(value))}; integer_input = true; break;
		case godot::Variant::FLOAT: numbers = {double(value)}; break;
		case godot::Variant::VECTOR2: { godot::Vector2 v = value; numbers = {v.x, v.y}; break; }
		case godot::Variant::VECTOR3: { godot::Vector3 v = value; numbers = {v.x, v.y, v.z}; break; }
		case godot::Variant::VECTOR4: { godot::Vector4 v = value; numbers = {v.x, v.y, v.z, v.w}; break; }
		case godot::Variant::VECTOR2I: { godot::Vector2i v = value; numbers = {static_cast<long double>(v.x), static_cast<long double>(v.y)}; integer_input = true; break; }
		case godot::Variant::VECTOR3I: { godot::Vector3i v = value; numbers = {static_cast<long double>(v.x), static_cast<long double>(v.y), static_cast<long double>(v.z)}; integer_input = true; break; }
		case godot::Variant::VECTOR4I: { godot::Vector4i v = value; numbers = {static_cast<long double>(v.x), static_cast<long double>(v.y), static_cast<long double>(v.z), static_cast<long double>(v.w)}; integer_input = true; break; }
		default: return reject(error, name, "unsupported value Variant; expected a number or matching vector.");
	}
	if (numbers.size() != size_t(out.info.size)) return reject(error, name, "value tuple length does not match the HAPI parameter.");
	for (long double number : numbers) {
		if (!std::isfinite(number)) return reject(error, name, "numeric values must be finite.");
		// HAPI reports min/max as float32; compare at that precision so 0.1 is not rejected
		// against a stored limit of 0.1f.
		const float ranged = static_cast<float>(number);
		if ((out.info.hasMin && ranged < out.info.min) || (out.info.hasMax && ranged > out.info.max)) return reject(error, name, "value exceeds the parameter's declared hard range.");
		if (int_type(out.info.type)) {
			if (std::trunc(number) != number || number < std::numeric_limits<int>::min() || number > std::numeric_limits<int>::max()) return reject(error, name, "integer parameters require integral int32 values.");
			out.ints.push_back(static_cast<int>(number));
		} else if (float_type(out.info.type)) {
			if (std::abs(number) > std::numeric_limits<float>::max()) return reject(error, name, "value exceeds HAPI float32 range.");
			const float converted = static_cast<float>(number);
			if (!std::isfinite(converted) || (number != 0 && converted == 0) || (integer_input && static_cast<long double>(converted) != number)) return reject(error, name, "value cannot be represented safely by HAPI float32 storage.");
			out.floats.push_back(converted);
		} else return reject(error, name, "parameter does not have supported numeric storage.");
	}
	return true;
}

bool apply(HEGoSessionManager *mgr, HAPI_NodeId node, const PreparedParm &parm, godot::String &error) {
	HAPI_ParmInfo current;
	if (!metadata(mgr->get_session(), node, parm.name, current, error)) return false;
	// Earlier multiparms/callbacks may move array indices. Resolve them again,
	// but never reinterpret a value if the declared type/tuple changed.
	if (current.id != parm.info.id || current.type != parm.info.type || current.size != parm.info.size)
		return reject(error, parm.name, "parameter layout changed during the batch.");
	HAPI_Result result;
	if (!parm.ints.empty()) result = HoudiniApi::SetParmIntValues(mgr->get_session(), node, parm.ints.data(), current.intValuesIndex, current.size);
	else if (!parm.floats.empty()) result = HoudiniApi::SetParmFloatValues(mgr->get_session(), node, parm.floats.data(), current.floatValuesIndex, current.size);
	else result = HoudiniApi::SetParmStringValue(mgr->get_session(), node, parm.text.utf8().get_data(), current.id, 0);
	if (result != HAPI_RESULT_SUCCESS) return reject(error, parm.name, "HAPI rejected the parameter write (code " + godot::String::num_int64(result) + ").");
	if (!mgr->wait_for_ready()) return reject(error, parm.name, "HAPI session became unavailable while waiting for the write.");
	return true;
}
} // namespace

bool set_parms(HEGoSessionManager *mgr, HAPI_NodeId node, const godot::Dictionary &values, godot::String &error) {
	const HAPI_Session *session = mgr ? mgr->get_session() : nullptr;
	if (!session || node < 0 || HoudiniApi::IsSessionValid(session) != HAPI_RESULT_SUCCESS) { error = "Cannot set parameters on an invalid node/session."; return false; }
	std::vector<PreparedParm> prepared;
	std::set<godot::String> seen;
	const godot::Array keys = values.keys();
	for (int i = 0; i < keys.size(); ++i) {
		const godot::Variant key = keys[i];
		if (key.get_type() != godot::Variant::STRING && key.get_type() != godot::Variant::STRING_NAME) { error = "Parameter names must be Strings or StringNames."; return false; }
		const godot::String name = key;
		if (!seen.insert(name).second) return reject(error, name, "duplicate normalized name.");
		PreparedParm parm;
		if (!prepare(session, node, name, values[key], parm, error)) return false;
		prepared.push_back(std::move(parm));
	}
	// Prevalidation is atomic. HAPI callbacks/runtime failures after writes begin
	// cannot generally be rolled back, and must be surfaced as task failures.
	for (const PreparedParm &parm : prepared) if (!apply(mgr, node, parm, error)) return false;
	return true;
}

bool set_parm(HEGoSessionManager *mgr, HAPI_NodeId node, const godot::String &name, const godot::Variant &value, godot::String &error) {
	godot::Dictionary values; values[name] = value;
	return set_parms(mgr, node, values, error);
}
void remove_multiparm_instance(HEGoSessionManager *session_mgr, HAPI_NodeId node_id, HAPI_ParmId parm_id, int instance_position) {
	HOUDINI_CHECK_ERROR(HoudiniApi::RemoveMultiparmInstance(session_mgr->get_session(), node_id, parm_id, instance_position));
}
void insert_multiparm_instance(HEGoSessionManager *session_mgr, HAPI_NodeId node_id, HAPI_ParmId parm_id, int instance_position) {
	HOUDINI_CHECK_ERROR(HoudiniApi::InsertMultiparmInstance(session_mgr->get_session(), node_id, parm_id, instance_position));
}
} // namespace HEGo::Util::Parm
