#ifndef HEGO_GET_PARMS_H
#define HEGO_GET_PARMS_H

#include "hego_session_manager.h"
#include <godot_cpp/variant/dictionary.hpp>

namespace HEGo::Util::Parm
{
bool get_help_page(const HAPI_Session *session, HAPI_NodeId node, godot::Dictionary &result, godot::String &error);
bool get_parm_dict(HEGoSessionManager *manager, HAPI_NodeId node, godot::Dictionary &result, godot::String &error);
}

#endif
