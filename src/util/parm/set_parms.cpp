#include "util/parm/set_parms.h"

#include "hapi/houdini_api.h"
#include "set_parms.h"
#include "util/hego_util.h"
#include "util/log/log.h"

namespace HEGo
{
namespace Util
{
namespace Parm
{
void set_parm(HEGoSessionManager *session_mgr, HAPI_NodeId node_id, godot::String parm_name, godot::Variant *value)
{
	if (value->get_type() == godot::Variant::Type::INT)
	{
		int int_value = value->operator int();
		HOUDINI_CHECK_ERROR(HoudiniApi::SetParmIntValue(session_mgr->get_session(), node_id, parm_name.utf8().get_data(), 0, int_value));
		session_mgr->wait_for_ready();
	}
	else if (value->get_type() == godot::Variant::Type::FLOAT)
	{
		float float_value = value->operator float();
		HOUDINI_CHECK_ERROR(HoudiniApi::SetParmFloatValue(session_mgr->get_session(), node_id, parm_name.utf8().get_data(), 0, float_value));
		session_mgr->wait_for_ready();
	}
	else if (value->get_type() == godot::Variant::Type::STRING)
	{
		godot::String string_value = value->operator godot::String();
		HAPI_ParmId parm_id = -1;
		HOUDINI_CHECK_ERROR(HoudiniApi::GetParmIdFromName(session_mgr->get_session(), node_id, parm_name.utf8().get_data(), &parm_id));
		HOUDINI_CHECK_ERROR(HoudiniApi::SetParmStringValue(session_mgr->get_session(), node_id, string_value.utf8().get_data(), parm_id, 0));
		session_mgr->wait_for_ready();
	}
	else if (value->get_type() == godot::Variant::Type::VECTOR2)
	{
		godot::Vector2 vector2_value = value->operator godot::Vector2();
		HOUDINI_CHECK_ERROR(HoudiniApi::SetParmFloatValue(session_mgr->get_session(), node_id, parm_name.utf8().get_data(), 0, vector2_value.x));
		session_mgr->wait_for_ready();
		HOUDINI_CHECK_ERROR(HoudiniApi::SetParmFloatValue(session_mgr->get_session(), node_id, parm_name.utf8().get_data(), 1, vector2_value.y));
		session_mgr->wait_for_ready();
	}
	else if (value->get_type() == godot::Variant::Type::VECTOR3)
	{
		godot::Vector3 vector3_value = value->operator godot::Vector3();
		HOUDINI_CHECK_ERROR(HoudiniApi::SetParmFloatValue(session_mgr->get_session(), node_id, parm_name.utf8().get_data(), 0, vector3_value.x));
		session_mgr->wait_for_ready();
		HOUDINI_CHECK_ERROR(HoudiniApi::SetParmFloatValue(session_mgr->get_session(), node_id, parm_name.utf8().get_data(), 1, vector3_value.y));
		session_mgr->wait_for_ready();
		HOUDINI_CHECK_ERROR(HoudiniApi::SetParmFloatValue(session_mgr->get_session(), node_id, parm_name.utf8().get_data(), 2, vector3_value.z));
		session_mgr->wait_for_ready();
	}
	else if (value->get_type() == godot::Variant::Type::VECTOR4)
	{
		godot::Vector4 vector4_value = value->operator godot::Vector4();
		HOUDINI_CHECK_ERROR(HoudiniApi::SetParmFloatValue(session_mgr->get_session(), node_id, parm_name.utf8().get_data(), 0, vector4_value.x));
		session_mgr->wait_for_ready();
		HOUDINI_CHECK_ERROR(HoudiniApi::SetParmFloatValue(session_mgr->get_session(), node_id, parm_name.utf8().get_data(), 1, vector4_value.y));
		session_mgr->wait_for_ready();
		HOUDINI_CHECK_ERROR(HoudiniApi::SetParmFloatValue(session_mgr->get_session(), node_id, parm_name.utf8().get_data(), 2, vector4_value.z));
		session_mgr->wait_for_ready();
		HOUDINI_CHECK_ERROR(HoudiniApi::SetParmFloatValue(session_mgr->get_session(), node_id, parm_name.utf8().get_data(), 3, vector4_value.w));
		session_mgr->wait_for_ready();
	}
	else if (value->get_type() == godot::Variant::Type::VECTOR2I)
	{
		godot::Vector2i vector2i_value = value->operator godot::Vector2i();
		HOUDINI_CHECK_ERROR(HoudiniApi::SetParmIntValue(session_mgr->get_session(), node_id, parm_name.utf8().get_data(), 0, vector2i_value.x));
		session_mgr->wait_for_ready();
		HOUDINI_CHECK_ERROR(HoudiniApi::SetParmIntValue(session_mgr->get_session(), node_id, parm_name.utf8().get_data(), 1, vector2i_value.y));
		session_mgr->wait_for_ready();
	}
	else if (value->get_type() == godot::Variant::Type::VECTOR3I)
	{
		godot::Vector3i vector3i_value = value->operator godot::Vector3i();
		HOUDINI_CHECK_ERROR(HoudiniApi::SetParmIntValue(session_mgr->get_session(), node_id, parm_name.utf8().get_data(), 0, vector3i_value.x));
		session_mgr->wait_for_ready();
		HOUDINI_CHECK_ERROR(HoudiniApi::SetParmIntValue(session_mgr->get_session(), node_id, parm_name.utf8().get_data(), 1, vector3i_value.y));
		session_mgr->wait_for_ready();
		HOUDINI_CHECK_ERROR(HoudiniApi::SetParmIntValue(session_mgr->get_session(), node_id, parm_name.utf8().get_data(), 2, vector3i_value.z));
		session_mgr->wait_for_ready();
	}
	else if (value->get_type() == godot::Variant::Type::VECTOR4I)
	{
		godot::Vector4i vector4i_value = value->operator godot::Vector4i();
		HOUDINI_CHECK_ERROR(HoudiniApi::SetParmIntValue(session_mgr->get_session(), node_id, parm_name.utf8().get_data(), 0, vector4i_value.x));
		session_mgr->wait_for_ready();
		HOUDINI_CHECK_ERROR(HoudiniApi::SetParmIntValue(session_mgr->get_session(), node_id, parm_name.utf8().get_data(), 1, vector4i_value.y));
		session_mgr->wait_for_ready();
		HOUDINI_CHECK_ERROR(HoudiniApi::SetParmIntValue(session_mgr->get_session(), node_id, parm_name.utf8().get_data(), 2, vector4i_value.z));
		session_mgr->wait_for_ready();
		HOUDINI_CHECK_ERROR(HoudiniApi::SetParmIntValue(session_mgr->get_session(), node_id, parm_name.utf8().get_data(), 3, vector4i_value.w));
		session_mgr->wait_for_ready();
	}
	else
	{
		HEGo::Util::Log::error("Unsupported Variant type");
	}
}

void remove_multiparm_instance(HEGoSessionManager *session_mgr, HAPI_NodeId node_id, HAPI_ParmId parm_id, int instance_position)
{
	HOUDINI_CHECK_ERROR(HoudiniApi::RemoveMultiparmInstance(session_mgr->get_session(), node_id, parm_id, instance_position));
}
void insert_multiparm_instance(HEGoSessionManager *session_mgr, HAPI_NodeId node_id, HAPI_ParmId parm_id, int instance_position)
{
	HOUDINI_CHECK_ERROR(HoudiniApi::InsertMultiparmInstance(session_mgr->get_session(), node_id, parm_id, instance_position));
}
} // namespace Parm
} // namespace Util
} // namespace HEGo
