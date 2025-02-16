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
godot::Dictionary fetch_surfaces(HEGoSessionManager *session_mgr, HAPI_NodeId node_id, godot::Ref<godot::Resource> fetch_surfaces_config);

void filter_and_update_dictionary(godot::Dictionary &point_attrs, const godot::Array &id_arr, godot::Array &vertex_point_indices);
void modify_base_entries(godot::Dictionary &nested_dict, godot::Array &vertex_point_indices, godot::Dictionary point_attrs, godot::Array filtered_prims);
} // namespace Geo
} // namespace Util
} // namespace HEGo