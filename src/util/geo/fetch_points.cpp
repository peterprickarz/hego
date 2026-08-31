#include "fetch_points.h"

#include "util/attrib/fetch_attribs.h"
#include "util/geo/geo_cache.h"
#include "util/geo/geo_output.h"
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
namespace
{
/// Splits a selection by each attribute in turn, so a config with two split
/// attributes produces a dictionary of dictionaries, and assembles the wanted
/// attributes at the leaves.
godot::Variant split_recursive(
		const godot::Ref<HEGoGeoSelection> &selection, const godot::PackedStringArray &split_attribs, int depth, const godot::PackedStringArray &read_attribs)
{
	if (depth >= split_attribs.size())
	{
		return selection->get_points(read_attribs);
	}

	godot::Dictionary result;
	const godot::Dictionary groups = selection->split_by(split_attribs[depth]);
	const godot::Array keys = groups.keys();
	for (int i = 0; i < keys.size(); ++i)
	{
		const godot::Ref<HEGoGeoSelection> group = groups[keys[i]];
		result[keys[i]] = split_recursive(group, split_attribs, depth + 1, read_attribs);
	}
	return result;
}
} // namespace

godot::Dictionary fetch_points(HEGoSessionManager *session_mgr, HAPI_NodeId node_id, godot::Ref<godot::Resource> fetch_point_config, bool auto_cook)
{
	const godot::PackedStringArray read_attribs = fetch_point_config->get("read_attribs");
	const godot::PackedStringArray filter_attribs = fetch_point_config->get("filter_attribs");
	const godot::Array filter_attrib_values = fetch_point_config->get("filter_attrib_values");
	const godot::PackedStringArray split_attribs = fetch_point_config->get("split_attribs");

	// A fetch config is a saved set of arguments for the same query API GDScript
	// drives directly, so both paths share one implementation and one cache.
	std::shared_ptr<GeoCache> cache = GeoCache::acquire(session_mgr, node_id, auto_cook);
	if (!cache)
	{
		return godot::Dictionary();
	}

	godot::Ref<HEGoGeoOutput> output;
	output.instantiate();
	output->setup(cache, node_id);
	if (!output->is_valid())
	{
		HEGO_LOG_DEBUG(HEGo::Util::Log::Category::OUTPUT, "fetch_points: no loose-point mesh part found.");
		return godot::Dictionary();
	}

	// The filter decides whether there is anything to return, so read those
	// attributes first and skip the rest when nothing passes.
	godot::Ref<HEGoGeoSelection> selection = output->select_all();
	for (int i = 0; i < filter_attribs.size(); i++)
	{
		output->load_attributes_now(godot::PackedStringArray({filter_attribs[i]}));
		selection = selection->filter_by(filter_attribs[i], filter_attrib_values[i]);
		if (selection->size() == 0)
		{
			return godot::Dictionary();
		}
	}

	output->load_attributes_now(read_attribs);
	output->load_attributes_now(split_attribs);
	output->load_attributes_now(godot::PackedStringArray({"P"}));

	HEGO_LOG_DEBUG(HEGo::Util::Log::Category::OUTPUT,
			godot::String("fetch_points: ") + godot::String::num_int64(selection->size()) + " of " + godot::String::num_int64(output->get_point_count()) +
					" points passed the filter");

	const godot::Variant split = split_recursive(selection, split_attribs, 0, read_attribs);
	return split.get_type() == godot::Variant::DICTIONARY ? godot::Dictionary(split) : godot::Dictionary();
}

} // namespace Geo
} // namespace Util
} // namespace HEGo