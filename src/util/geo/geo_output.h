#ifndef HEGO_GEO_OUTPUT_H
#define HEGO_GEO_OUTPUT_H

#include "hego_task.h"
#include "util/geo/geo_cache.h"

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>

#include <memory>
#include <vector>

namespace HEGo
{

class HEGoGeoSelection;

/// A cooked node's output, queried from GDScript.
///
/// Where the fetch configs describe the wanted attributes and splits ahead of time in
/// a resource, this describes them in code, at the point of use:
/// [codeblock]
/// var output = await _await_task(asset_node.get_geo_output())
/// await _await_task(output.load_attributes(["N", "up", "pscale", "hego_spawn"]))
///
/// for group in output.filter_by("hego_spawn", 1).split_by("hego_node_path"):
///     var points = group.get_points(["N", "up", "pscale"])
/// [/codeblock]
///
/// The geometry itself never leaves C++. Selections are index lists, splitting and
/// filtering happen here, and only the assembled result crosses into GDScript, so a
/// hundred thousand points do not turn into a hundred thousand Variant conversions.
///
/// Attribute values are shared with every other output of the same cook, so asking
/// for P here after the mesh output already read it costs nothing.
class HEGoGeoOutput : public godot::RefCounted
{
	GDCLASS(HEGoGeoOutput, godot::RefCounted)

public:
	/// Who an attribute belongs to, mirroring HAPI_AttributeOwner.
	enum Owner
	{
		OWNER_VERTEX = HAPI_ATTROWNER_VERTEX,
		OWNER_POINT = HAPI_ATTROWNER_POINT,
		OWNER_PRIM = HAPI_ATTROWNER_PRIM,
		OWNER_DETAIL = HAPI_ATTROWNER_DETAIL,
	};

	HEGoGeoOutput() = default;

	/// Built by HEGoAssetNode::get_geo_output(); not meant to be constructed by hand.
	void setup(const std::shared_ptr<HEGo::Util::Geo::GeoCache> &cache, HAPI_NodeId node_id);

	/// Whether this output has geometry with loose points to query.
	bool is_valid() const;

	/// Number of points in the output.
	int get_point_count() const;

	/// Names of every attribute of one owner, as Houdini reports them. Available
	/// without loading anything, so an HDA can be inspected before it is read.
	godot::PackedStringArray get_attribute_names(int owner = OWNER_POINT) const;

	/// Whether an attribute of that name and owner exists.
	bool has_attribute(const godot::String &name, int owner = OWNER_POINT) const;

	/// Names of the attributes starting with [param prefix], for handling whatever
	/// an HDA chose to add without naming each one here.
	godot::PackedStringArray get_attribute_names_with_prefix(const godot::String &prefix, int owner = OWNER_POINT) const;

	/// Reads attributes from Houdini so the queries below can use them. Returns a
	/// task, because this is the only part that talks to the session.
	/// Attributes already read by this cook are served from the cache.
	godot::Ref<HEGoTask> load_attributes(const godot::PackedStringArray &names, int owner = OWNER_POINT);

	/// Loads attributes right here instead of through a task. Only safe on the
	/// worker thread, which is where the fetch functions already run; GDScript wants
	/// load_attributes() instead.
	void load_attributes_now(const godot::PackedStringArray &names, int owner = OWNER_POINT);

	/// The values of a loaded attribute, or an empty array with a warning if it was
	/// never loaded. Synchronous: this only reads what is already in memory.
	godot::Array get_attribute(const godot::String &name, int owner = OWNER_POINT) const;

	/// Every point, as a selection to filter and split further.
	godot::Ref<HEGoGeoSelection> select_all();

	/// The points whose [param name] attribute equals [param value].
	godot::Ref<HEGoGeoSelection> filter_by(const godot::String &name, const godot::Variant &value);

	/// The points grouped by the value of [param name], as { value: selection }.
	godot::Dictionary split_by(const godot::String &name);

protected:
	static void _bind_methods();

private:
	friend class HEGoGeoSelection;

	std::shared_ptr<HEGo::Util::Geo::GeoCache> my_cache;
	HAPI_NodeId my_node_id = -1;
};

/// A set of points of a [HEGoGeoOutput], as an index list.
///
/// Filtering and splitting produce new selections without copying any attribute
/// data; only get_points() assembles values, and only for the points it holds.
class HEGoGeoSelection : public godot::RefCounted
{
	GDCLASS(HEGoGeoSelection, godot::RefCounted)

public:
	HEGoGeoSelection() = default;

	void setup(const godot::Ref<HEGoGeoOutput> &output, const std::vector<int> &indices);

	/// How many points this selection holds.
	int size() const;

	/// The point indices, for callers that want to do their own indexing.
	godot::PackedInt32Array get_indices() const;

	/// The subset whose [param name] attribute equals [param value].
	godot::Ref<HEGoGeoSelection> filter_by(const godot::String &name, const godot::Variant &value);

	/// This selection grouped by the value of [param name], as { value: selection }.
	/// Points the attribute is not set on land under a null key, and an attribute the
	/// HDA does not have at all yields one null-keyed group holding everything.
	godot::Dictionary split_by(const godot::String &name);

	/// The named attributes for the points in this selection, as { name: values },
	/// always including P. This is the point where data crosses into GDScript.
	godot::Dictionary get_points(const godot::PackedStringArray &names = godot::PackedStringArray());

protected:
	static void _bind_methods();

private:
	godot::Ref<HEGoGeoOutput> my_output;
	std::vector<int> my_indices;
};

} // namespace HEGo

VARIANT_ENUM_CAST(HEGo::HEGoGeoOutput::Owner);

#endif // HEGO_GEO_OUTPUT_H
