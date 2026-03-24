#include "part_selection.h"

#include "util/log/log.h"

namespace HEGo
{
namespace Util
{
namespace Geo
{
bool get_display_geo_info(HEGoSessionManager *session_mgr, HAPI_NodeId node_id, HAPI_GeoInfo &geo_info, bool auto_cook)
{
	if (auto_cook)
	{
		if (HoudiniApi::CookNode(session_mgr->get_session(), node_id, session_mgr->get_cook_options()) != HAPI_RESULT_SUCCESS)
		{
			HEGo::Util::Log::error("Failed to cook node before geometry fetch.");
			return false;
		}
		session_mgr->wait_for_cook(node_id);
	}

	if (HoudiniApi::GetDisplayGeoInfo(session_mgr->get_session(), node_id, &geo_info) != HAPI_RESULT_SUCCESS)
	{
		HEGo::Util::Log::error("Failed to query display geo info.");
		return false;
	}

	return true;
}

bool find_part_by_type(const HAPI_Session *session, const HAPI_GeoInfo &geo_info, HAPI_PartType part_type, HAPI_PartInfo &part_info)
{
	for (int part_index = 0; part_index < geo_info.partCount; ++part_index)
	{
		HAPI_PartInfo candidate;
		if (HoudiniApi::GetPartInfo(session, geo_info.nodeId, part_index, &candidate) != HAPI_RESULT_SUCCESS)
		{
			continue;
		}

		if (candidate.type == part_type)
		{
			part_info = candidate;
			return true;
		}
	}

	return false;
}

std::vector<HAPI_PartInfo> get_parts_by_type(const HAPI_Session *session, const HAPI_GeoInfo &geo_info, HAPI_PartType part_type)
{
	std::vector<HAPI_PartInfo> parts;

	for (int part_index = 0; part_index < geo_info.partCount; ++part_index)
	{
		HAPI_PartInfo candidate;
		if (HoudiniApi::GetPartInfo(session, geo_info.nodeId, part_index, &candidate) != HAPI_RESULT_SUCCESS)
		{
			continue;
		}

		if (candidate.type == part_type)
		{
			parts.push_back(candidate);
		}
	}

	return parts;
}

} // namespace Geo
} // namespace Util
} // namespace HEGo