#ifndef HEGO_GEO_PART_SELECTION_H
#define HEGO_GEO_PART_SELECTION_H

#include "hapi/houdini_api.h"
#include "hego_session_manager.h"

#include <vector>

namespace HEGo
{
namespace Util
{
namespace Geo
{
bool get_display_geo_info(HEGoSessionManager *session_mgr, HAPI_NodeId node_id, HAPI_GeoInfo &geo_info, bool auto_cook = true);
bool find_part_by_type(const HAPI_Session *session, const HAPI_GeoInfo &geo_info, HAPI_PartType part_type, HAPI_PartInfo &part_info);
std::vector<HAPI_PartInfo> get_parts_by_type(const HAPI_Session *session, const HAPI_GeoInfo &geo_info, HAPI_PartType part_type);
} // namespace Geo
} // namespace Util
} // namespace HEGo

#endif // HEGO_GEO_PART_SELECTION_H