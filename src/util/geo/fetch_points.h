#include "hapi/houdini_api.h"
#include "hego_session_manager.h"

#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/dictionary.hpp>

namespace HEGo
{
namespace Util
{
namespace Geo
{
godot::Dictionary fetch_points(
		HEGoSessionManager *session_mgr, HAPI_NodeId node_id, godot::Ref<godot::Resource> fetch_point_config);
} // namespace Geo
} // namespace Util
} // namespace HEGo