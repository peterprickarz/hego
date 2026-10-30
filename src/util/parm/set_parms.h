#ifndef SET_PARMS_H
#define SET_PARMS_H

#include "hego_session_manager.h"
#include <godot_cpp/variant/variant.hpp>
#include <godot_cpp/variant/dictionary.hpp>

namespace HEGo
{
namespace Util
{
namespace Parm
{
bool set_parm(HEGoSessionManager *session_mgr, HAPI_NodeId node_id, const godot::String &parm_name, const godot::Variant &value, godot::String &error);
// All entries prevalidate before the first write. Runtime callback failures may
// leave earlier writes applied; they are surfaced rather than hidden.
bool set_parms(HEGoSessionManager *session_mgr, HAPI_NodeId node_id, const godot::Dictionary &values, godot::String &error);
void remove_multiparm_instance(HEGoSessionManager *session_mgr, HAPI_NodeId node_id, HAPI_ParmId parm_id, int instance_position);
void insert_multiparm_instance(HEGoSessionManager *session_mgr, HAPI_NodeId node_id, HAPI_ParmId parm_id, int instance_position);

} // namespace Parm
} // namespace Util
} // namespace HEGo

#endif // SET_PARMS_H
