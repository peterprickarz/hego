#include "util/geo/geo_output.h"

#include "hego_api.h"
#include "util/log/log.h"
#include "util/geo/fetch_surfaces.h"
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

void HEGoGeoOutput::load_attributes_now(const godot::PackedStringArray &names, int owner)
{
	if (!is_valid())
	{
		return;
	}
	const HAPI_PartInfo *part = my_cache->points_part();
	for (int i = 0; i < names.size(); ++i)
	{
		my_cache->attribute(*part, to_hapi_owner(owner), names[i]);
	}
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

	// An HDA that does not set the split attribute at all is not an error: the
	// points simply form one unnamed group, which is what the handlers expect when
	// they see a null key. Not having loaded an attribute that does exist is a
	// mistake worth saying out loud.
	const godot::Array values = my_output->get_attribute(name, HEGoGeoOutput::OWNER_POINT);
	if (values.is_empty())
	{
		if (my_output->has_attribute(name, HEGoGeoOutput::OWNER_POINT))
		{
			HEGo::Util::Log::warning(HEGo::Util::Log::Category::OUTPUT,
					godot::String("Cannot split by '") + name + "': it was not loaded. Call load_attributes([\"" + name + "\"]) first.");
		}
		groups[godot::Variant()] = godot::Ref<HEGoGeoSelection>(this);
		return groups;
	}

	// Group the indices first, then wrap each group once, so a split over many
	// distinct values does not allocate a selection per point.
	godot::Dictionary grouped;
	for (const int index : my_indices)
	{
		const godot::Variant key = index < values.size() ? values[index] : godot::Variant();
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


// ─────────────────────────────────────────────
// HEGoGeoSurfaces
// ─────────────────────────────────────────────

bool HEGoGeoSurfaces::setup(const std::shared_ptr<HEGo::Util::Geo::GeoCache> &cache, HAPI_NodeId node_id, const godot::PackedStringArray &point_attribs)
{
	my_cache = cache;
	my_node_id = node_id;
	my_valid = HEGo::Util::Geo::prepare_surface_data(*cache, point_attribs, my_part, my_prims, my_vertex_point_indices, my_point_attrs);
	return my_valid;
}

bool HEGoGeoSurfaces::is_valid() const { return my_valid; }

int HEGoGeoSurfaces::get_primitive_count() const { return my_valid ? my_prims.size() : 0; }

godot::PackedStringArray HEGoGeoSurfaces::get_attribute_names() const
{
	if (!my_valid)
	{
		return godot::PackedStringArray();
	}
	return my_cache->attribute_names(my_part, HAPI_ATTROWNER_PRIM);
}

bool HEGoGeoSurfaces::has_attribute(const godot::String &name) const { return get_attribute_names().has(name); }

godot::PackedStringArray HEGoGeoSurfaces::get_attribute_names_with_prefix(const godot::String &prefix) const
{
	const godot::PackedStringArray names = get_attribute_names();
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

godot::Ref<HEGoTask> HEGoGeoSurfaces::load_attributes(const godot::PackedStringArray &names)
{
	if (!my_valid)
	{
		return HEGo::Util::Task::make_noop("load_attributes (no surfaces)", my_node_id);
	}

	std::shared_ptr<HEGo::Util::Geo::GeoCache> cache = my_cache;
	const HAPI_PartInfo part = my_part;

	return HEGo::Util::Task::submit("load_attributes", my_node_id,
			[cache, part, names](HEGoSessionManager *) -> godot::Variant
			{
				for (int i = 0; i < names.size(); ++i)
				{
					cache->attribute(part, HAPI_ATTROWNER_PRIM, names[i]);
				}
				return godot::Variant();
			});
}

godot::Array HEGoGeoSurfaces::get_attribute(const godot::String &name) const
{
	if (!my_valid || !has_attribute(name))
	{
		return godot::Array();
	}
	return my_cache->attribute(my_part, HAPI_ATTROWNER_PRIM, name);
}

godot::Ref<HEGoGeoPrimSelection> HEGoGeoSurfaces::select_all()
{
	std::vector<int> indices;
	const int count = get_primitive_count();
	indices.reserve(count);
	for (int i = 0; i < count; ++i)
	{
		indices.push_back(i);
	}

	godot::Ref<HEGoGeoPrimSelection> selection;
	selection.instantiate();
	selection->setup(godot::Ref<HEGoGeoSurfaces>(this), indices);
	return selection;
}

godot::Ref<HEGoGeoPrimSelection> HEGoGeoSurfaces::filter_by(const godot::String &name, const godot::Variant &value)
{
	return select_all()->filter_by(name, value);
}

godot::Dictionary HEGoGeoSurfaces::split_by(const godot::String &name) { return select_all()->split_by(name); }

void HEGoGeoSurfaces::_bind_methods()
{
	godot::ClassDB::bind_method(godot::D_METHOD("is_valid"), &HEGoGeoSurfaces::is_valid);
	godot::ClassDB::bind_method(godot::D_METHOD("get_primitive_count"), &HEGoGeoSurfaces::get_primitive_count);
	godot::ClassDB::bind_method(godot::D_METHOD("get_attribute_names"), &HEGoGeoSurfaces::get_attribute_names);
	godot::ClassDB::bind_method(godot::D_METHOD("has_attribute", "name"), &HEGoGeoSurfaces::has_attribute);
	godot::ClassDB::bind_method(godot::D_METHOD("get_attribute_names_with_prefix", "prefix"), &HEGoGeoSurfaces::get_attribute_names_with_prefix);
	godot::ClassDB::bind_method(godot::D_METHOD("load_attributes", "names"), &HEGoGeoSurfaces::load_attributes);
	godot::ClassDB::bind_method(godot::D_METHOD("get_attribute", "name"), &HEGoGeoSurfaces::get_attribute);
	godot::ClassDB::bind_method(godot::D_METHOD("select_all"), &HEGoGeoSurfaces::select_all);
	godot::ClassDB::bind_method(godot::D_METHOD("filter_by", "name", "value"), &HEGoGeoSurfaces::filter_by);
	godot::ClassDB::bind_method(godot::D_METHOD("split_by", "name"), &HEGoGeoSurfaces::split_by);
}

// ─────────────────────────────────────────────
// HEGoGeoPrimSelection
// ─────────────────────────────────────────────

void HEGoGeoPrimSelection::setup(const godot::Ref<HEGoGeoSurfaces> &surfaces, const std::vector<int> &indices)
{
	my_surfaces = surfaces;
	my_indices = indices;
}

int HEGoGeoPrimSelection::size() const { return static_cast<int>(my_indices.size()); }

godot::PackedInt32Array HEGoGeoPrimSelection::get_indices() const
{
	godot::PackedInt32Array indices;
	indices.resize(static_cast<int>(my_indices.size()));
	for (size_t i = 0; i < my_indices.size(); ++i)
	{
		indices.set(static_cast<int>(i), my_indices[i]);
	}
	return indices;
}

godot::Ref<HEGoGeoPrimSelection> HEGoGeoPrimSelection::filter_by(const godot::String &name, const godot::Variant &value)
{
	godot::Ref<HEGoGeoPrimSelection> selection;
	selection.instantiate();
	if (my_surfaces.is_null())
	{
		return selection;
	}

	const godot::Array values = my_surfaces->get_attribute(name);
	if (values.is_empty())
	{
		HEGo::Util::Log::warning(HEGo::Util::Log::Category::OUTPUT,
				godot::String("Cannot filter surfaces by '") + name + "': the attribute is missing or was not loaded.");
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

	selection->setup(my_surfaces, filtered);
	return selection;
}

godot::Dictionary HEGoGeoPrimSelection::split_by(const godot::String &name)
{
	godot::Dictionary groups;
	if (my_surfaces.is_null())
	{
		return groups;
	}

	// As with points, an attribute the HDA never sets groups everything under one
	// null key rather than losing the primitives.
	const godot::Array values = my_surfaces->get_attribute(name);
	if (values.is_empty())
	{
		if (my_surfaces->has_attribute(name))
		{
			HEGo::Util::Log::warning(
					HEGo::Util::Log::Category::OUTPUT, godot::String("Cannot split surfaces by '") + name + "': it was not loaded.");
		}
		groups[godot::Variant()] = godot::Ref<HEGoGeoPrimSelection>(this);
		return groups;
	}

	godot::Dictionary grouped;
	for (const int index : my_indices)
	{
		const godot::Variant key = index < values.size() ? values[index] : godot::Variant();
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

		godot::Ref<HEGoGeoPrimSelection> selection;
		selection.instantiate();
		selection->setup(my_surfaces, indices);
		groups[keys[i]] = selection;
	}

	return groups;
}

godot::Dictionary HEGoGeoPrimSelection::get_surface(const godot::PackedStringArray &read_attribs)
{
	godot::Dictionary surface;
	if (my_surfaces.is_null() || !my_surfaces->is_valid() || my_indices.empty())
	{
		return surface;
	}

	// modify_base_entries() works on a leaf holding "ids" indexing into a primitive
	// array, so hand it exactly this selection's primitives and 0..n-1.
	godot::Array selected_prims;
	godot::Array ids;
	selected_prims.resize(static_cast<int>(my_indices.size()));
	ids.resize(static_cast<int>(my_indices.size()));
	for (size_t i = 0; i < my_indices.size(); ++i)
	{
		selected_prims[static_cast<int>(i)] = my_surfaces->my_prims[my_indices[i]];
		ids[static_cast<int>(i)] = static_cast<int>(i);
	}
	surface["ids"] = ids;

	// Attribute values are indexed by primitive, so they are picked out by the
	// original primitive index rather than by position in this selection.
	for (int i = 0; i < read_attribs.size(); ++i)
	{
		const godot::String name = read_attribs[i];
		const godot::Array values = my_surfaces->get_attribute(name);
		if (values.is_empty())
		{
			continue;
		}

		godot::Array selected;
		selected.resize(static_cast<int>(my_indices.size()));
		for (size_t j = 0; j < my_indices.size(); ++j)
		{
			const int index = my_indices[j];
			selected[static_cast<int>(j)] = index < values.size() ? values[index] : godot::Variant();
		}
		surface[name] = selected;
	}

	HEGo::Util::Geo::modify_base_entries(surface, my_surfaces->my_vertex_point_indices, my_surfaces->my_point_attrs, selected_prims);
	surface.erase("ids");
	return surface;
}

void HEGoGeoPrimSelection::_bind_methods()
{
	godot::ClassDB::bind_method(godot::D_METHOD("size"), &HEGoGeoPrimSelection::size);
	godot::ClassDB::bind_method(godot::D_METHOD("get_indices"), &HEGoGeoPrimSelection::get_indices);
	godot::ClassDB::bind_method(godot::D_METHOD("filter_by", "name", "value"), &HEGoGeoPrimSelection::filter_by);
	godot::ClassDB::bind_method(godot::D_METHOD("split_by", "name"), &HEGoGeoPrimSelection::split_by);
	godot::ClassDB::bind_method(godot::D_METHOD("get_surface", "read_attribs"), &HEGoGeoPrimSelection::get_surface, DEFVAL(godot::PackedStringArray()));
}

} // namespace HEGo
