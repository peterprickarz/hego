#ifndef HEGO_SET_PARMS_H
#define HEGO_SET_PARMS_H

#include "hego_session_manager.h"
#include <godot_cpp/variant/dictionary.hpp>

namespace HEGo::Util::Parm
{
bool set_parm(HEGoSessionManager *manager, HAPI_NodeId node, const godot::String &name, const godot::Variant &value, godot::String &error);
bool set_parms(HEGoSessionManager *manager, HAPI_NodeId node, const godot::Dictionary &values, godot::String &error);
bool change_multiparm(HEGoSessionManager *manager, HAPI_NodeId node, int id, int position, bool insert, godot::String &error);
bool get_node_parm_info(const HAPI_Session *session, HAPI_NodeId node, const godot::String &name, HAPI_ParmInfo &info, godot::String &error);
bool accepts_node(const HAPI_Session *session, const HAPI_ParmInfo &parm, HAPI_NodeId source);
} // namespace HEGo::Util::Parm

#endif
