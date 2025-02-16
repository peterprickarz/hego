#include "util/attrib/fetch_attribs.h"
#include "util/geo/output.h"
#include "util/hego_util.h"
#include <godot_cpp/classes/mesh.hpp>
#include <vector>

namespace HEGo
{
namespace Util
{
namespace Geo
{
godot::Array get_unique_values(const godot::Array &input_array)
{
	godot::Array unique_array;

	for (int i = 0; i < input_array.size(); ++i)
	{
		godot::Variant value = input_array[i];
		if (!unique_array.has(value))
		{
			unique_array.append(value);
		}
	}

	return unique_array;
}

godot::Dictionary build_nested_dictionary(const godot::Array &split_attribs, const godot::Dictionary &split_attribs_dict, const godot::Array &filtered_indices,
		const godot::Dictionary &read_attribs_dict, int level)
{
	godot::Dictionary nested_dict;
	if (level >= split_attribs.size())
	{
		// Base case: at the deepest level, store the filtered indices under "ptnum"
		nested_dict["ids"] = filtered_indices;

		// Iterate over each entry in the read_attribs_dict and store the corresponding values
		for (int i = 0; i < read_attribs_dict.size(); i++)
		{
			godot::String key = read_attribs_dict.keys()[i];
			godot::Array values = read_attribs_dict[key];

			godot::Array mapped_values;
			for (int j = 0; j < filtered_indices.size(); j++)
			{
				godot::Variant idx = filtered_indices[j];
				mapped_values.append(values[idx]);
			}

			nested_dict[key] = mapped_values;
		}

		return nested_dict;
	}

	godot::Array values = split_attribs_dict[split_attribs[level]];
	godot::Array unique_values = get_unique_values(values);

	for (int i = 0; i < unique_values.size(); i++)
	{
		godot::Variant value = unique_values[i];

		// Filter the indices for the current value
		godot::Array next_filtered_indices;
		for (int j = 0; j < filtered_indices.size(); j++)
		{
			godot::Variant idx = filtered_indices[j];

			if (values[idx] == value)
			{
				next_filtered_indices.append(idx);
			}
		}

		// Recurse into the next level
		nested_dict[value] = build_nested_dictionary(split_attribs, split_attribs_dict, next_filtered_indices, read_attribs_dict, level + 1);
	}

	return nested_dict;
}

} // namespace Geo
} // namespace Util
} // namespace HEGo
