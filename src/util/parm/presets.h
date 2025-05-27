#ifndef PRESETS_H
#define PRESETS_H

#include "hego_session_manager.h"
#include <godot_cpp/variant/variant.hpp>

namespace HEGo
{
namespace Util
{
namespace Parm
{
godot::PackedByteArray get_preset(HEGoSessionManager *session_mgr, HAPI_NodeId node_id);
void set_preset(HEGoSessionManager *session_mgr, HAPI_NodeId node_id, godot::PackedByteArray preset);
} // namespace Parm
} // namespace Util
} // namespace HEGo

#endif // GET_PARMS_H