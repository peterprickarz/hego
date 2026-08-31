#include "util/geo/geo_output.h"

#include "hego_api.h"
#include "util/log/log.h"
#include "util/task/task_helpers.h"

namespace HEGo
{
namespace
{
HAPI_AttributeOwner to_hapi_owner(int owner)
{
	switch (owner)
	{
		case HEGoGeoOutput::OWNER_VERTEX:
		case HEGoGeoOutput::OWNER_POINT:
		case HEGoGeoOutput::OWNER_PRIM:
		case HEGoGeoOutput::OWNER_DETAIL:
			return static_cast<HAPI_AttributeOwner>(owner);
		default:
			return HAPI_ATTROWNER_POINT;
	}
}
} // namespace

// ─────────────────────────────────────────────
// HEGoGeoOutput
// ─────────────────────────────────────────────

void HEGoGeoOutput::setup(const std::shared_ptr<HEGo::Util::Geo::GeoCache> &cache, HAPI_NodeId node_id)
{
	my_cache = cache;
	my_node_id = node_id;
}

bool HEGoGeoOutput::is_valid() const { return my_cache != nullptr && my_cache->points_part() != nullptr; }

int HEGoGeoOutput::get_point_count() const
{
	if (!is_valid())
	{
		return 0;
	}
	return my_cache->points_part()->pointCount;
}

godot::PackedStringArray HEGoGeoOutput::get_attribute_names(int owner) const
{
	if (!is_valid())
	{
		return godot::PackedStringArray();
	}
	return my_cache->attribute_names(*my_cache->points_part(), to_hapi_owner(owner));
}

bool HEGoGeoOutput::has_attribute(const godot::String &name, int owner) const { return get_attribute_names(owner).has(name); }

godot::PackedStringArray HEGoGeoOutput::get_attribute_names_with_prefix(const godot::String &prefix, int owner) const
{
	const godot::PackedStringArray names = get_attribute_names(owner);
	godot::PackedStringArray matching;
	for (int i = 0; i < names.size(); ++i)
	{
		if (names[i].begins_with(prefix))
		{
			matching.append(names[i]);
		}
	}
	return matching;
}

godot::Ref<HEGoTask> HEGoGeoOutput::load_attributes(const godot::PackedStringArray &names, int owner)
{
	if (!is_valid())
	{
		return HEGo::Util::Task::make_noop("load_attributes (no geometry)", my_node_id);
	}

	// Captured by value: the task runs on the worker thread and must not depend on
	// this object still being alive when it gets there.
	std::shared_ptr<HEGo::Util::Geo::GeoCache> cache = my_cache;
	const HAPI_AttributeOwner hapi_owner = to_hapi_owner(owner);

	return HEGo::Util::Task::submit("load_attributes", my_node_id,
			[cache, names, hapi_owner](HEGoSessionManager *) -> godot::Variant
			{
				const HAPI_PartInfo *part = cache->points_part();
				if (part == nullptr)
				{
					return godot::Variant();
				}
				for (int i = 0; i < names.size(); ++i)
				{
					cache->attribute(*part, hapi_owner, names[i]);
				}
				return godot::Variant();
			});
}

godot::Array HEGoGeoOutput::get_attribute(const godot::String &name, int owner) const
{
	if (!is_valid())
	{
		return godot::Array();
	}

	if (!has_attribute(name, owner))
	{
		return godot::Array();
	}

	return my_cache->attribute(*my_cache->points_part(), to_hapi_owner(owner), name);
}

godot::Ref<HEGoGeoSelection> HEGoGeoOutput::select_all()
{
	std::vector<int> indices;
	const int count = get_point_count();
	indices.reserve(count);
	for (int i = 0; i < count; ++i)
	{
		indices.push_back(i);
	}

	godot::Ref<HEGoGeoSelection> selection;
	selection.instantiate();
	selection->setup(godot::Ref<HEGoGeoOutput>(this), indices);
	return selection;
}

godot::Ref<HEGoGeoSelection> HEGoGeoOutput::filter_by(const godot::String &name, const godot::Variant &value) { return select_all()->filter_by(name, value); }

godot::Dictionary HEGoGeoOutput::split_by(const godot::String &name) { return select_all()->split_by(name); }

void HEGoGeoOutput::_bind_methods()
{
	godot::ClassDB::bind_method(godot::D_METHOD("is_valid"), &HEGoGeoOutput::is_valid);
	godot::ClassDB::bind_method(godot::D_METHOD("get_point_count"), &HEGoGeoOutput::get_point_count);
	godot::ClassDB::bind_method(godot::D_METHOD("get_attribute_names", "owner"), &HEGoGeoOutput::get_attribute_names, DEFVAL(OWNER_POINT));
	godot::ClassDB::bind_method(godot::D_METHOD("has_attribute", "name", "owner"), &HEGoGeoOutput::has_attribute, DEFVAL(OWNER_POINT));
	godot::ClassDB::bind_method(godot::D_METHOD("get_attribute_names_with_prefix", "prefix", "owner"), &HEGoGeoOutput::get_attribute_names_with_prefix,
			DEFVAL(OWNER_POINT));
	godot::ClassDB::bind_method(godot::D_METHOD("load_attributes", "names", "owner"), &HEGoGeoOutput::load_attributes, DEFVAL(OWNER_POINT));
	godot::ClassDB::bind_method(godot::D_METHOD("get_attribute", "name", "owner"), &HEGoGeoOutput::get_attribute, DEFVAL(OWNER_POINT));
	godot::ClassDB::bind_method(godot::D_METHOD("select_all"), &HEGoGeoOutput::select_all);
	godot::ClassDB::bind_method(godot::D_METHOD("filter_by", "name", "value"), &HEGoGeoOutput::filter_by);
	godot::ClassDB::bind_method(godot::D_METHOD("split_by", "name"), &HEGoGeoOutput::split_by);

	BIND_ENUM_CONSTANT(OWNER_VERTEX);
	BIND_ENUM_CONSTANT(OWNER_POINT);
	BIND_ENUM_CONSTANT(OWNER_PRIM);
	BIND_ENUM_CONSTANT(OWNER_DETAIL);
}

// ─────────────────────────────────────────────
// HEGoGeoSelection
// ─────────────────────────────────────────────

void HEGoGeoSelection::setup(const godot::Ref<HEGoGeoOutput> &output, const std::vector<int> &indices)
{
	my_output = output;
	my_indices = indices;
}

int HEGoGeoSelection::size() const { return static_cast<int>(my_indices.size()); }

godot::PackedInt32Array HEGoGeoSelection::get_indices() const
{
	godot::PackedInt32Array indices;
	indices.resize(static_cast<int>(my_indices.size()));
	for (size_t i = 0; i < my_indices.size(); ++i)
	{
		indices.set(static_cast<int>(i), my_indices[i]);
	}
	return indices;
}

godot::Ref<HEGoGeoSelection> HEGoGeoSelection::filter_by(const godot::String &name, const godot::Variant &value)
{
	godot::Ref<HEGoGeoSelection> selection;
	selection.instantiate();

	if (my_output.is_null())
	{
		return selection;
	}

	const godot::Array values = my_output->get_attribute(name, HEGoGeoOutput::OWNER_POINT);
	if (values.is_empty())
	{
		HEGo::Util::Log::warning(HEGo::Util::Log::Category::OUTPUT,
				godot::String("Cannot filter by '") + name + "': the attribute is missing or was not loaded. Call load_attributes([\"" + name + "\"]) first.");
		return selection;
	}

	std::vector<int> filtered;
	for (const int index : my_indices)
	{
		if (index < values.size() && values[index] == value)
		{
			filtered.push_back(index);
		}
	}

	selection->setup(my_output, filtered);
	return selection;
}

godot::Dictionary HEGoGeoSelection::split_by(const godot::String &name)
{
	godot::Dictionary groups;
	if (my_output.is_null())
	{
		return groups;
	}

	const godot::Array values = my_output->get_attribute(name, HEGoGeoOutput::OWNER_POINT);
	if (values.is_empty())
	{
		HEGo::Util::Log::warning(HEGo::Util::Log::Category::OUTPUT,
				godot::String("Cannot split by '") + name + "': the attribute is missing or was not loaded. Call load_attributes([\"" + name + "\"]) first.");
		return groups;
	}

	// Group the indices first, then wrap each group once, so a split over many
	// distinct values does not allocate a selection per point.
	godot::Dictionary grouped;
	for (const int index : my_indices)
	{
		if (index >= values.size() || values[index].get_type() == godot::Variant::NIL)
		{
			continue;
		}
		const godot::Variant key = values[index];
		if (!grouped.has(key))
		{
			grouped[key] = godot::PackedInt32Array();
		}
		godot::PackedInt32Array group_indices = grouped[key];
		group_indices.append(index);
		grouped[key] = group_indices;
	}

	const godot::Array keys = grouped.keys();
	for (int i = 0; i < keys.size(); ++i)
	{
		const godot::PackedInt32Array group_indices = grouped[keys[i]];
		std::vector<int> indices;
		indices.reserve(group_indices.size());
		for (int j = 0; j < group_indices.size(); ++j)
		{
			indices.push_back(group_indices[j]);
		}

		godot::Ref<HEGoGeoSelection> selection;
		selection.instantiate();
		selection->setup(my_output, indices);
		groups[keys[i]] = selection;
	}

	return groups;
}

godot::Dictionary HEGoGeoSelection::get_points(const godot::PackedStringArray &names)
{
	godot::Dictionary points;
	if (my_output.is_null())
	{
		return points;
	}

	godot::PackedStringArray wanted = names;
	if (!wanted.has("P"))
	{
		wanted.append("P");
	}

	for (int n = 0; n < wanted.size(); ++n)
	{
		const godot::String name = wanted[n];
		const godot::Array values = my_output->get_attribute(name, HEGoGeoOutput::OWNER_POINT);
		if (values.is_empty())
		{
			continue;
		}

		godot::Array selected;
		selected.resize(static_cast<int>(my_indices.size()));
		for (size_t i = 0; i < my_indices.size(); ++i)
		{
			const int index = my_indices[i];
			selected[static_cast<int>(i)] = index < values.size() ? values[index] : godot::Variant();
		}
		points[name] = selected;
	}

	return points;
}

void HEGoGeoSelection::_bind_methods()
{
	godot::ClassDB::bind_method(godot::D_METHOD("size"), &HEGoGeoSelection::size);
	godot::ClassDB::bind_method(godot::D_METHOD("get_indices"), &HEGoGeoSelection::get_indices);
	godot::ClassDB::bind_method(godot::D_METHOD("filter_by", "name", "value"), &HEGoGeoSelection::filter_by);
	godot::ClassDB::bind_method(godot::D_METHOD("split_by", "name"), &HEGoGeoSelection::split_by);
	godot::ClassDB::bind_method(godot::D_METHOD("get_points", "names"), &HEGoGeoSelection::get_points, DEFVAL(godot::PackedStringArray()));
}

} // namespace HEGo
