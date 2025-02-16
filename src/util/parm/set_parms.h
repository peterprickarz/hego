#ifndef SET_PARMS_H
#define SET_PARMS_H

#include "hego_session_manager.h"
#include <godot_cpp/variant/variant.hpp>

namespace HEGo
{
namespace Util
{
namespace Parm
{
void set_parm(HEGoSessionManager *session_mgr, HAPI_NodeId node_id, godot::String parm_name, godot::Variant *value);

} // namespace Parm
} // namespace Util
} // namespace HEGo

#endif // SET_PARMS_H
