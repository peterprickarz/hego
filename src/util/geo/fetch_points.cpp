#include "fetch_points.h"

#include "util/attrib/fetch_attribs.h"
#include "util/geo/geo_cache.h"
#include "util/geo/output.h"
#include "util/geo/part_selection.h"
#include "util/hego_util.h"
#include "util/log/log.h"

#include <godot_cpp/variant/utility_functions.hpp>

namespace HEGo
{
namespace Util
{
namespace Geo
{
godot::Dictionary fetch_points(HEGoSessionManager *session_mgr, HAPI_NodeId node_id, godot::Ref<godot::Resource> fetch_point_config, bool auto_cook)
{
	godot::PackedStringArray read_attribs = fetch_point_config->get("read_attribs");
	godot::PackedStringArray filter_attribs = fetch_point_config->get("filter_attribs");
	godot::Array filter_attrib_values = fetch_point_config->get("filter_attrib_values");
	godot::PackedStringArray split_attribs = fetch_point_config->get("split_attribs");

	// Shared with every other output of this cook, so attributes several of them
	// want - P, N, up, pscale, scale - only cross the connection once.
	std::shared_ptr<GeoCache> cache = GeoCache::acquire(session_mgr, node_id, auto_cook);
	if (!cache)
	{
		return godot::Dictionary();
	}

	const HAPI_PartInfo *points_part = cache->points_part();
	if (points_part == nullptr)
	{
		HEGO_LOG_DEBUG(HEGo::Util::Log::Category::OUTPUT, "fetch_points: no loose-point mesh part found.");
		return godot::Dictionary();
	}

	HEGO_LOG_DEBUG(HEGo::Util::Log::Category::OUTPUT,
			godot::String("fetch_points: part id=") + godot::String::num_int64(static_cast<int64_t>(points_part->id)) +
					" points=" + godot::String::num_int64(static_cast<int64_t>(points_part->pointCount)));

	// Read the filter attributes first: they decide whether there is anything to
	// return at all, and the rest can be skipped when there is not.
	godot::Dictionary filter_attribs_dict;
	for (int i = 0; i < filter_attribs.size(); i++)
	{
		filter_attribs_dict[filter_attribs[i]] = cache->attribute(*points_part, HAPI_ATTROWNER_POINT, filter_attribs[i]);
	}

	godot::Array filtered_indices;
	for (int i = 0; i < points_part->pointCount; i++)
	{
		bool all_filters_pass = true;
		for (int j = 0; j < filter_attribs.size(); j++)
		{
			godot::Array values = filter_attribs_dict[filter_attribs[j]];
			if (i >= values.size() || values[i] != filter_attrib_values[j])
			{
				all_filters_pass = false;
				break;
			}
		}
		if (all_filters_pass)
		{
			filtered_indices.append(i);
		}
	}
	if (filtered_indices.is_empty())
	{
		return godot::Dictionary();
	}

	godot::Dictionary read_attribs_dict;
	read_attribs_dict["P"] = cache->attribute(*points_part, HAPI_ATTROWNER_POINT, "P");
	for (int i = 0; i < read_attribs.size(); i++)
	{
		read_attribs_dict[read_attribs[i]] = cache->attribute(*points_part, HAPI_ATTROWNER_POINT, read_attribs[i]);
	}

	godot::Dictionary split_attribs_dict;
	for (int i = 0; i < split_attribs.size(); i++)
	{
		split_attribs_dict[split_attribs[i]] = cache->attribute(*points_part, HAPI_ATTROWNER_POINT, split_attribs[i]);
	}

	return HEGo::Util::Geo::build_nested_dictionary(split_attribs, split_attribs_dict, filtered_indices, read_attribs_dict, 0);
}

} // namespace Geo
} // namespace Util
} // namespace HEGo