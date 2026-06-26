# ifndef HEGO_ENUMS_H
# define HEGO_ENUMS_H

#include <godot_cpp/core/binder_common.hpp>
#include "hapi/houdini_api.h"

namespace HEGo
{
namespace Util
{
    enum CurveType {
        CURVE_TYPE_BEZIER = HAPI_CURVETYPE_BEZIER,
        CURVE_TYPE_NURBS = HAPI_CURVETYPE_NURBS,
        CURVE_TYPE_LINEAR = HAPI_CURVETYPE_LINEAR
    };
}
}

VARIANT_ENUM_CAST(HEGo::Util::CurveType)

# endif // HEGO_ENUMS_H