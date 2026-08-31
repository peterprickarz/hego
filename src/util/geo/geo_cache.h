#ifndef HEGO_GEO_CACHE_H
#define HEGO_GEO_CACHE_H

#include "hapi/houdini_api.h"
#include "hego_session_manager.h"

#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/string.hpp>

#include <map>
#include <memory>
#include <string>
#include <vector>

namespace HEGo
{
namespace Util
{
namespace Geo
{

/// One cook's worth of geometry for one node: its display geo, its parts, and every
/// attribute value that has been asked for since that cook.
///
/// A cook drives several outputs (meshes, instancers, spawned objects, curves,
/// terrains) and they overlap heavily: P, N, up, pscale and scale are wanted by most
/// of them. Without a cache each output re-reads them over the HAPI connection, which
/// is the expensive part of fetching output. With one, the first reader pays and the
/// rest are free.
///
/// Validity is tied to the node's total cook count, so a cache invalidates itself as
/// soon as anything recooks the node, whether HEGo asked for it or Houdini did.
///
/// Fetching happens on the scheduler's worker thread, so instances of this class are
/// only ever touched from there; the registry itself is guarded by a mutex.
class GeoCache
{
public:
	/// The cache for this node's current cook, building it if there is none.
	/// Returns null when the display geo cannot be read.
	static std::shared_ptr<GeoCache> acquire(HEGoSessionManager *session_mgr, HAPI_NodeId node_id, bool auto_cook = true);

	/// Drops a node's cache. Only needed when a node goes away; a recook invalidates
	/// itself through the cook count.
	static void invalidate(HAPI_NodeId node_id);

	/// Drops every cache. Called when a session ends, since node ids do not survive it.
	static void invalidate_all();

	const HAPI_GeoInfo &geo_info() const { return my_geo_info; }

	/// Every part of the display geo, in part index order.
	const std::vector<HAPI_PartInfo> &parts() const { return my_parts; }

	/// The parts of one type, e.g. HAPI_PARTTYPE_MESH.
	std::vector<HAPI_PartInfo> parts_of_type(HAPI_PartType part_type) const;

	/// The mesh part holding loose points, i.e. points without vertices, which is
	/// what the point outputs read. Returns null when the geo has none.
	const HAPI_PartInfo *points_part() const;

	/// The value array of one attribute, fetched at most once per cook.
	/// Returns an empty array when the part has no such attribute.
	godot::Array attribute(const HAPI_PartInfo &part, HAPI_AttributeOwner owner, const godot::String &name);

	/// Names of every attribute of one owner on one part, as Houdini reports them.
	/// Cheap: one call per (part, owner), then cached.
	godot::PackedStringArray attribute_names(const HAPI_PartInfo &part, HAPI_AttributeOwner owner);

	/// The named attributes as { "name": ..., "value": ... } dictionaries, which is
	/// how curve and heightfield output hand attributes to GDScript. Detail-style:
	/// only the first value of each attribute is taken.
	godot::Array attribute_pairs(const HAPI_PartInfo &part, HAPI_AttributeOwner owner, const godot::PackedStringArray &names);

	/// Attribute reads served from the cache, and those that went to Houdini.
	/// Used to report what a cook saved.
	int hits() const { return my_hits; }
	int misses() const { return my_misses; }

private:
	static std::string attribute_key(const HAPI_PartInfo &part, HAPI_AttributeOwner owner, const godot::String &name);

	HEGoSessionManager *my_session_mgr = nullptr;
	HAPI_NodeId my_node_id = -1;
	int my_cook_count = -1;

	HAPI_GeoInfo my_geo_info{};
	std::vector<HAPI_PartInfo> my_parts;

	std::map<std::string, godot::Array> my_attributes;
	std::map<std::string, godot::PackedStringArray> my_attribute_names;

	int my_hits = 0;
	int my_misses = 0;
};

} // namespace Geo
} // namespace Util
} // namespace HEGo

#endif // HEGO_GEO_CACHE_H
