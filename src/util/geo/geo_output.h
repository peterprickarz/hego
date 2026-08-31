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

class HEGoGeoPrimSelection;

/// A cooked node's surface output, queried from GDScript.
///
/// The surface counterpart of [HEGoGeoOutput]: where that one selects points, this
/// selects primitives and turns a group of them into a Godot surface array.
/// [codeblock]
/// var surfaces = await _await_task(asset_node.get_surface_output(["N", "uv"]))
/// await _await_task(surfaces.load_attributes(["hego_mesh_instance", "hego_material"]))
///
/// for instance_name in surfaces.split_by("hego_mesh_instance"):
///     for material in group.split_by("hego_material"):
///         var surface = by_material[material].get_surface(["hego_lod"])
///         # surface["surface_array"] goes straight into ArrayMesh.add_surface_from_arrays
/// [/codeblock]
///
/// The mesh data - the vertex list and the point attributes - is read once for the
/// whole part; each group only compacts the points its own primitives use, and only
/// when get_surface() is called.
class HEGoGeoSurfaces : public godot::RefCounted
{
	GDCLASS(HEGoGeoSurfaces, godot::RefCounted)

public:
	HEGoGeoSurfaces() = default;

	/// Built by HEGoAssetNode::get_surface_output(); not meant to be constructed by hand.
	/// Reads the primitive and vertex lists plus the named point attributes, so it
	/// must run on the worker thread.
	bool setup(const std::shared_ptr<HEGo::Util::Geo::GeoCache> &cache, HAPI_NodeId node_id, const godot::PackedStringArray &point_attribs);

	/// Whether the cook produced a mesh part with faces.
	bool is_valid() const;

	/// Number of primitives in the output.
	int get_primitive_count() const;

	/// Names of every primitive attribute, available without loading anything.
	godot::PackedStringArray get_attribute_names() const;

	/// Whether a primitive attribute of that name exists.
	bool has_attribute(const godot::String &name) const;

	/// The primitive attribute names starting with [param prefix].
	godot::PackedStringArray get_attribute_names_with_prefix(const godot::String &prefix) const;

	/// Reads primitive attributes so filtering, splitting and get_surface() can use them.
	godot::Ref<HEGoTask> load_attributes(const godot::PackedStringArray &names);

	/// The values of a loaded primitive attribute, one per primitive.
	godot::Array get_attribute(const godot::String &name) const;

	/// Every primitive, as a selection to filter and split further.
	godot::Ref<HEGoGeoPrimSelection> select_all();

	/// The primitives whose [param name] attribute equals [param value].
	godot::Ref<HEGoGeoPrimSelection> filter_by(const godot::String &name, const godot::Variant &value);

	/// The primitives grouped by the value of [param name], as { value: selection }.
	godot::Dictionary split_by(const godot::String &name);

protected:
	static void _bind_methods();

private:
	friend class HEGoGeoPrimSelection;

	std::shared_ptr<HEGo::Util::Geo::GeoCache> my_cache;
	HAPI_NodeId my_node_id = -1;
	HAPI_PartInfo my_part{};
	bool my_valid = false;

	// Read once for the whole part and shared by every group.
	godot::Array my_prims; // One Vector2i(first vertex, vertex count) per primitive.
	godot::Array my_vertex_point_indices;
	godot::Dictionary my_point_attrs;
};

/// A set of primitives of a [HEGoGeoSurfaces].
///
/// Like [HEGoGeoSelection], a selection is a list of indices: filtering and
/// splitting cost nothing but the indices, and only get_surface() assembles data.
class HEGoGeoPrimSelection : public godot::RefCounted
{
	GDCLASS(HEGoGeoPrimSelection, godot::RefCounted)

public:
	HEGoGeoPrimSelection() = default;

	void setup(const godot::Ref<HEGoGeoSurfaces> &surfaces, const std::vector<int> &indices);

	/// How many primitives this selection holds.
	int size() const;

	/// The primitive indices.
	godot::PackedInt32Array get_indices() const;

	/// The subset whose [param name] attribute equals [param value].
	godot::Ref<HEGoGeoPrimSelection> filter_by(const godot::String &name, const godot::Variant &value);

	/// This selection grouped by the value of [param name], as { value: selection }.
	godot::Dictionary split_by(const godot::String &name);

	/// Builds the Godot surface for these primitives, as
	/// [code]{ "surface_array": [...], <requested attributes>: [...] }[/code].
	/// The attribute arrays hold one value per primitive in this selection.
	godot::Dictionary get_surface(const godot::PackedStringArray &read_attribs = godot::PackedStringArray());

protected:
	static void _bind_methods();

private:
	godot::Ref<HEGoGeoSurfaces> my_surfaces;
	std::vector<int> my_indices;
};

} // namespace HEGo

VARIANT_ENUM_CAST(HEGo::HEGoGeoOutput::Owner);

#endif // HEGO_GEO_OUTPUT_H
