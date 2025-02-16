#ifndef TRANSFORM_H
#define TRANSFORM_H

#include "hapi/houdini_api.h"
#include "hego_session_manager.h"
#include "util/hego_util.h"

#include <godot_cpp/core/class_db.hpp>

namespace HEGo
{
namespace Util
{
namespace Geo
{
void set_object_transform(HEGoSessionManager *session_mgr, const HAPI_NodeId node_id, const godot::Transform3D &transform);
HAPI_TransformEuler godot_to_houdini_transform(const godot::Transform3D &transform);

} // namespace Geo
} // namespace Util
} // namespace HEGo

#endif // TRANSFORM_H
