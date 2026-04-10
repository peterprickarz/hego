#ifndef HEGO_FETCH_CURVES_H
#define HEGO_FETCH_CURVES_H

#include "hapi/houdini_api.h"
#include "hego_session_manager.h"

namespace HEGo
{
namespace Util
{
namespace Geo
{
godot::Array fetch_curves(
    HEGoSessionManager *session_mgr, HAPI_NodeId node_id, bool auto_cook);
} // namespace Geo
} // namespace Util
} // namespace HEGo

#endif // HEGO_FETCH_CURVES_H