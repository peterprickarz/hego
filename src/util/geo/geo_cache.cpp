#include "util/geo/geo_cache.h"

#include "util/attrib/fetch_attribs.h"
#include "util/geo/part_selection.h"
#include "util/hego_util.h"
#include "util/log/log.h"

#include <mutex>

namespace HEGo
{
namespace Util
{
namespace Geo
{
namespace
{
std::mutex registry_mutex;
std::map<HAPI_NodeId, std::shared_ptr<GeoCache>> registry;

/// Total cook count of a node and everything under it. Any cook bumps it, which is
/// what tells a cache it is stale. Returns -1 when it cannot be read, which keeps
/// caches from being reused on a session that is going wrong.
int read_cook_count(HEGoSessionManager *session_mgr, HAPI_NodeId node_id)
{
	int count = -1;
	if (HoudiniApi::GetTotalCookCount(session_mgr->get_session(), node_id, HAPI_NODETYPE_ANY, HAPI_NODEFLAGS_ANY, true, &count) != HAPI_RESULT_SUCCESS)
	{
		return -1;
	}
	return count;
}

const char *owner_name(HAPI_AttributeOwner owner)
{
	switch (owner)
	{
		case HAPI_ATTROWNER_VERTEX:
			return "vertex";
		case HAPI_ATTROWNER_POINT:
			return "point";
		case HAPI_ATTROWNER_PRIM:
			return "prim";
		case HAPI_ATTROWNER_DETAIL:
			return "detail";
		default:
			return "invalid";
	}
}
} // namespace

std::shared_ptr<GeoCache> GeoCache::acquire(HEGoSessionManager *session_mgr, HAPI_NodeId node_id, bool auto_cook)
{
	if (session_mgr == nullptr || node_id < 0)
	{
		return nullptr;
	}

	const int cook_count = read_cook_count(session_mgr, node_id);

	{
		std::lock_guard<std::mutex> lock(registry_mutex);
		auto existing = registry.find(node_id);
		if (existing != registry.end() && cook_count >= 0 && existing->second->my_cook_count == cook_count)
		{
			HEGO_LOG_TRACE(HEGo::Util::Log::Category::OUTPUT,
					godot::String("Reusing cached geo for node ") + godot::String::num_int64(static_cast<int64_t>(node_id)) + " (" +
							godot::String::num_int64(existing->second->hits()) + " attribute reads served from cache, " +
							godot::String::num_int64(existing->second->misses()) + " fetched)");
			return existing->second;
		}
	}

	std::shared_ptr<GeoCache> cache(new GeoCache());
	cache->my_session_mgr = session_mgr;
	cache->my_node_id = node_id;

	if (!get_display_geo_info(session_mgr, node_id, cache->my_geo_info, auto_cook))
	{
		return nullptr;
	}

	for (int part_index = 0; part_index < cache->my_geo_info.partCount; ++part_index)
	{
		HAPI_PartInfo part;
		if (HoudiniApi::GetPartInfo(session_mgr->get_session(), cache->my_geo_info.nodeId, part_index, &part) != HAPI_RESULT_SUCCESS)
		{
			HEGo::Util::Log::warning(
					HEGo::Util::Log::Category::OUTPUT, "Failed to read part info at index " + godot::String::num_int64(static_cast<int64_t>(part_index)));
			continue;
		}
		cache->my_parts.push_back(part);

		HEGO_LOG_DEBUG(HEGo::Util::Log::Category::OUTPUT,
				godot::String("part[") + godot::String::num_int64(static_cast<int64_t>(part_index)) +
						"] type=" + godot::String::num_int64(static_cast<int64_t>(part.type)) + " id=" + godot::String::num_int64(static_cast<int64_t>(part.id)) +
						" points=" + godot::String::num_int64(static_cast<int64_t>(part.pointCount)) +
						" vertices=" + godot::String::num_int64(static_cast<int64_t>(part.vertexCount)) +
						" faces=" + godot::String::num_int64(static_cast<int64_t>(part.faceCount)));
	}

	// Read after building: fetching the geo may have cooked the node itself, and the
	// cache describes the state it ended up in.
	cache->my_cook_count = read_cook_count(session_mgr, node_id);

	{
		std::lock_guard<std::mutex> lock(registry_mutex);
		registry[node_id] = cache;
	}

	HEGO_LOG_DEBUG(HEGo::Util::Log::Category::OUTPUT,
			godot::String("Cached geo for node ") + godot::String::num_int64(static_cast<int64_t>(node_id)) + ": " +
					godot::String::num_int64(static_cast<int64_t>(cache->my_parts.size())) + " part(s), cook count " +
					godot::String::num_int64(static_cast<int64_t>(cache->my_cook_count)));

	return cache;
}

void GeoCache::invalidate(HAPI_NodeId node_id)
{
	std::lock_guard<std::mutex> lock(registry_mutex);
	registry.erase(node_id);
}

void GeoCache::invalidate_all()
{
	std::lock_guard<std::mutex> lock(registry_mutex);
	registry.clear();
}

std::vector<HAPI_PartInfo> GeoCache::parts_of_type(HAPI_PartType part_type) const
{
	std::vector<HAPI_PartInfo> result;
	for (const HAPI_PartInfo &part : my_parts)
	{
		if (part.type == part_type)
		{
			result.push_back(part);
		}
	}
	return result;
}

const HAPI_PartInfo *GeoCache::points_part() const
{
	// Points arrive as a mesh part with no vertices; a mesh part with vertices is
	// surface output and belongs to the mesh handler.
	for (const HAPI_PartInfo &part : my_parts)
	{
		if (part.type == HAPI_PARTTYPE_MESH && part.vertexCount == 0)
		{
			return &part;
		}
	}
	return nullptr;
}

std::string GeoCache::attribute_key(const HAPI_PartInfo &part, HAPI_AttributeOwner owner, const godot::String &name)
{
	return std::to_string(part.id) + ":" + std::to_string(static_cast<int>(owner)) + ":" + name.utf8().get_data();
}

godot::Array GeoCache::attribute(const HAPI_PartInfo &part, HAPI_AttributeOwner owner, const godot::String &name)
{
	const std::string key = attribute_key(part, owner, name);

	auto cached = my_attributes.find(key);
	if (cached != my_attributes.end())
	{
		my_hits++;
		return cached->second;
	}

	my_misses++;
	godot::Array values = HEGo::Util::Attribs::fetch_by_name(my_session_mgr->get_session(), my_geo_info, part, owner, name.utf8().get_data());
	my_attributes[key] = values;

	HEGO_LOG_TRACE(HEGo::Util::Log::Category::ATTRIB,
			godot::String("Fetched ") + owner_name(owner) + " attribute '" + name + "' (" + godot::String::num_int64(static_cast<int64_t>(values.size())) +
					" values)");

	return values;
}

godot::Array GeoCache::attribute_pairs(const HAPI_PartInfo &part, HAPI_AttributeOwner owner, const godot::PackedStringArray &names)
{
	godot::Array pairs;
	for (int i = 0; i < names.size(); ++i)
	{
		const godot::String name = names[i];
		if (name.is_empty())
		{
			continue;
		}

		const godot::Array values = attribute(part, owner, name);

		godot::Dictionary pair;
		pair["name"] = name;
		pair["value"] = values.is_empty() ? godot::Variant() : values[0];
		pairs.append(pair);
	}
	return pairs;
}

godot::PackedStringArray GeoCache::attribute_names(const HAPI_PartInfo &part, HAPI_AttributeOwner owner)
{
	const std::string key = attribute_key(part, owner, "");

	auto cached = my_attribute_names.find(key);
	if (cached != my_attribute_names.end())
	{
		return cached->second;
	}

	godot::PackedStringArray names;
	const int count = part.attributeCounts[owner];
	if (count > 0)
	{
		std::vector<HAPI_StringHandle> handles(count);
		if (HoudiniApi::GetAttributeNames(my_session_mgr->get_session(), my_geo_info.nodeId, part.id, owner, handles.data(), count) == HAPI_RESULT_SUCCESS)
		{
			for (const HAPI_StringHandle handle : handles)
			{
				names.append(HEGo::Util::Hapi::get_godot_string(my_session_mgr->get_session(), handle));
			}
		}
		else
		{
			HEGo::Util::Log::warning(HEGo::Util::Log::Category::ATTRIB, godot::String("Failed to list ") + owner_name(owner) + " attributes.");
		}
	}

	my_attribute_names[key] = names;
	return names;
}

} // namespace Geo
} // namespace Util
} // namespace HEGo
