#include "fetch_curves.h"

#include "util/attrib/fetch_attribs.h"
#include "util/geo/part_selection.h"
#include "util/log/log.h"

#include <algorithm>

namespace HEGo
{
namespace Util
{
namespace Geo
{
godot::Array fetch_curves(HEGoSessionManager *session_mgr, HAPI_NodeId node_id, const godot::PackedStringArray &read_prim_attribs, const godot::PackedStringArray &read_point_attribs, bool auto_cook)
{
    godot::Array curves;

    const HAPI_Result session_valid = HoudiniApi::IsSessionValid(session_mgr->get_session());
	if (session_valid != HAPI_RESULT_SUCCESS)
	{
		HEGo::Util::Log::error("Cannot get curve points: invalid session.");
		return curves;
	}

    HAPI_GeoInfo geo_info;
	if (!get_display_geo_info(session_mgr, node_id, geo_info, auto_cook))
	{
		return curves;
	}

    std::vector<HAPI_PartInfo> curve_parts = get_parts_by_type(session_mgr->get_session(), geo_info, HAPI_PARTTYPE_CURVE);
    std::sort(curve_parts.begin(), curve_parts.end(), [](const HAPI_PartInfo &a, const HAPI_PartInfo &b) { return a.id < b.id; });

    for (const HAPI_PartInfo &part_info : curve_parts)
    {
        HAPI_CurveInfo curve_info;
        if (HoudiniApi::GetCurveInfo(session_mgr->get_session(), geo_info.nodeId, part_info.id, &curve_info) != HAPI_RESULT_SUCCESS)
        {
            HEGo::Util::Log::error("Failed to read curve info for part id " + godot::String::num_int64(part_info.id));
            continue;
        }

        const int curve_count = curve_info.curveCount;

        godot::Array positions = HEGo::Util::Attribs::fetch_vector3(session_mgr->get_session(), geo_info, part_info, HAPI_ATTROWNER_POINT, "P");

        int knot_offset = 0;
        int vert_offset = 0;

        for (int curve_idx = 0; curve_idx < curve_count; ++curve_idx)
        {
            int num_verts = 0;
            if (HoudiniApi::GetCurveCounts(session_mgr->get_session(), geo_info.nodeId, part_info.id, &num_verts, curve_idx, 1) != HAPI_RESULT_SUCCESS)
            {
                HEGo::Util::Log::error("Failed to read curve count for curve index " + godot::String::num_int64(curve_idx) + " in part id " + godot::String::num_int64(part_info.id));
                return curves;
            }

            int order = 0;
            if (HoudiniApi::GetCurveOrders(session_mgr->get_session(), geo_info.nodeId, part_info.id, &order, curve_idx, 1) != HAPI_RESULT_SUCCESS)
            {
                HEGo::Util::Log::error("Failed to read curve order for curve index " + godot::String::num_int64(curve_idx) + " in part id " + godot::String::num_int64(part_info.id));
                return curves;
            }

            if (num_verts < order)
            {
                HEGo::Util::Log::error("Invalid curve data for part id " + godot::String::num_int64(part_info.id) + ": num verts " + 
                    godot::String::num_int64(num_verts) + " is less than order " + godot::String::num_int64(order));
                vert_offset += num_verts;
                knot_offset += num_verts + order;
                continue;
            }

            // Extract positions for this curve only
            godot::PackedVector3Array curve_positions;
            for (int i = 0; i < num_verts; ++i)
            {
                curve_positions.push_back(positions[vert_offset + i]);
            }

            godot::Dictionary curve_data;
            curve_data["type"] = curve_info.curveType;
            curve_data["order"] = order;
            curve_data["positions"] = curve_positions;
            curve_data["prim_attribs"] = HEGo::Util::Attribs::read_attrib_pairs(session_mgr->get_session(), geo_info, part_info, HAPI_ATTROWNER_PRIM, read_prim_attribs);
            curve_data["point_attribs"] = HEGo::Util::Attribs::read_attrib_pairs(session_mgr->get_session(), geo_info, part_info, HAPI_ATTROWNER_POINT, read_point_attribs);

            if (curve_info.hasKnots)
            {
                std::vector<float> knot_array(num_verts + order);
                if (HoudiniApi::GetCurveKnots(session_mgr->get_session(), geo_info.nodeId, part_info.id, knot_array.data(), knot_offset, num_verts + order) != HAPI_RESULT_SUCCESS)
                {
                    HEGo::Util::Log::error("Failed to read curve knots for curve index " + godot::String::num_int64(curve_idx) + " in part id " + godot::String::num_int64(part_info.id));
                    knot_offset += num_verts + order;
                    vert_offset += num_verts;
                    continue;
                }
                
                godot::PackedFloat32Array knots;
                for (float knot : knot_array)
                {
                    knots.push_back(knot);
                }
                curve_data["knots"] = knots;
                knot_offset += num_verts + order;
            }

            vert_offset += num_verts;
            curves.append(curve_data);
        }
    }

    return curves;
}
} // namespace Geo
} // namespace Util
} // namespace HEGo