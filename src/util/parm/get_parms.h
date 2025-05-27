#ifndef GET_PARMS_H
#define GET_PARMS_H

#include "hego_session_manager.h"
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/variant.hpp>

namespace HEGo
{
namespace Util
{
namespace Parm
{
godot::Dictionary get_parm_dict(HEGoSessionManager *session_mgr, HAPI_NodeId node_id);

} // namespace Parm
} // namespace Util
} // namespace HEGo

#endif // GET_PARMS_H