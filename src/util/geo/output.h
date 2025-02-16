#ifndef OUTPUT_H
#define OUTPUT_H

#include "hapi/houdini_api.h"
#include "util/log/log.h"
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/array.hpp>

namespace HEGo
{
namespace Util
{
namespace Geo
{
godot::Dictionary build_nested_dictionary(const godot::Array &split_attribs, const godot::Dictionary &split_attribs_dict, const godot::Array &filtered_indices,
		const godot::Dictionary &read_attribs_dict, int level);
godot::Array get_unique_values(const godot::Array &input_array);
} // namespace Geo
} // namespace Util
} // namespace HEGo

#endif // OUTPUT_H
