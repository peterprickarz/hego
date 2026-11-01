#ifndef HEGO_HEIGHTFIELD_GRID_H
#define HEGO_HEIGHTFIELD_GRID_H

#include "hapi/houdini_api.h"

#include <godot_cpp/variant/basis.hpp>
#include <godot_cpp/variant/quaternion.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <algorithm>
#include <cmath>
#include <limits>

namespace HEGo::Util::Geo {

struct HeightfieldGrid {
    int width = 0;
    int height = 0;
    godot::Vector3 origin;
    godot::Vector3 step_x;
    godot::Vector3 step_y;
};

inline bool finite_vector(godot::Vector3 value) {
    return std::isfinite(value.x) && std::isfinite(value.y) && std::isfinite(value.z);
}

inline double grid_vector_length(godot::Vector3 value) {
    return std::hypot(static_cast<double>(value.x), static_cast<double>(value.y), static_cast<double>(value.z));
}

inline bool validate_heightfield_grid(const HeightfieldGrid &grid, godot::String &error) {
    if (grid.width <= 0 || grid.height <= 0 || !finite_vector(grid.origin) || !finite_vector(grid.step_x) || !finite_vector(grid.step_y)) {
        error = "Heightfield dimensions must be positive and its origin and steps finite.";
        return false;
    }
    const double sx = grid_vector_length(grid.step_x);
    const double sy = grid_vector_length(grid.step_y);
    if (sx <= 0.0 || sy <= 0.0 || !std::isfinite(sx) || !std::isfinite(sy)) {
        error = "Heightfield sample steps must have finite nonzero lengths.";
        return false;
    }
    const double dot = static_cast<double>(grid.step_x.x) * grid.step_y.x + static_cast<double>(grid.step_x.y) * grid.step_y.y + static_cast<double>(grid.step_x.z) * grid.step_y.z;
    if (std::abs(dot / sx / sy) > 0.000001) {
        error = "Sheared heightfield grids are unsupported; sample steps must be orthogonal.";
        return false;
    }
    const godot::Vector3 opposite = grid.origin + grid.step_x * (grid.width - 1) + grid.step_y * (grid.height - 1);
    if (!finite_vector(opposite)) {
        error = "Heightfield sample positions exceed Vector3 coordinate range.";
        return false;
    }
    return true;
}

// HAPI 22's GET and SET VolumeInfo transforms use different normalization.
// GET returns sample-00 position and half-voxel basis scale. SET expects a
// normalized [-1,1] volume box with its center position. Both were verified
// against real HAPI and hou.Volume.indexToPos, including rectangular grids.
// Coordinates here are SOP-local Houdini coordinates, without axis conversion.
inline bool validate_heightfield_volume_shape(const HAPI_VolumeInfo &volume, godot::String &error) {
    if (volume.type != HAPI_VOLUMETYPE_HOUDINI || volume.storage != HAPI_STORAGETYPE_FLOAT || volume.tupleSize != 1 || volume.zLength != 1 || volume.hasTaper) {
        error = "Only untapered dense scalar float volumes with zLength=1 are supported.";
        return false;
    }
    if (volume.minX != 0 || volume.minY != 0 || volume.minZ != 0) {
        error = "Nonzero volume index minima are unsupported by this dense heightfield transport.";
        return false;
    }
    return true;
}

inline bool heightfield_grid_from_volume(const HAPI_Session *session, const HAPI_VolumeInfo &volume, HeightfieldGrid &grid, godot::String &error) {
    if (!validate_heightfield_volume_shape(volume, error)) return false;
    float matrix[16] = {};
    // The SDK does not reliably fill shear for volumes. This compatibility
    // decoder is used only when indexed probing is unavailable; strict field
    // fetches use actual volumeindextopos queries, including shear validation.
    HAPI_Transform transform_info = volume.transform;
    transform_info.shear[0] = transform_info.shear[1] = transform_info.shear[2] = 0;
    if (HoudiniApi::ConvertTransformQuatToMatrix(session, &transform_info, matrix) != HAPI_RESULT_SUCCESS) {
        error = "Could not evaluate the heightfield volume transform.";
        return false;
    }
    for (float value : matrix) {
        if (!std::isfinite(value)) {
            error = "Heightfield volume transform contains nonfinite values.";
            return false;
        }
    }
    if (volume.xLength <= 0 || volume.yLength <= 0) {
        error = "Heightfield volume has invalid dimensions.";
        return false;
    }
    const godot::Basis basis(godot::Vector3(matrix[0], matrix[1], matrix[2]), godot::Vector3(matrix[4], matrix[5], matrix[6]), godot::Vector3(matrix[8], matrix[9], matrix[10]));
    const godot::Transform3D transform(basis, godot::Vector3(matrix[12], matrix[13], matrix[14]));
    grid.width = volume.xLength;
    grid.height = volume.yLength;
    grid.step_x = basis.get_column(0) * 2.0;
    grid.step_y = basis.get_column(1) * 2.0;
    grid.origin = transform.origin;
    return validate_heightfield_grid(grid, error);
}

inline bool volume_transform_from_heightfield_grid(const HeightfieldGrid &grid, HAPI_Transform &transform, godot::String &error) {
    if (!validate_heightfield_grid(grid, error)) {
        return false;
    }
    const double sx = grid_vector_length(grid.step_x);
    const double sy = grid_vector_length(grid.step_y);
    const godot::Vector3 x_axis = grid.step_x / sx;
    const godot::Vector3 y_axis = grid.step_y / sy;
    const godot::Basis basis(x_axis, y_axis, x_axis.cross(y_axis).normalized());
    const godot::Quaternion rotation = basis.orthonormalized().get_rotation_quaternion();
    const godot::Vector3 center = grid.origin + grid.step_x * ((grid.width - 1) * 0.5) + grid.step_y * ((grid.height - 1) * 0.5);
    const double scales[3] = {sx * grid.width * 0.5, sy * grid.height * 0.5, std::min(sx, sy) * 0.5};
    if (!finite_vector(center)) {
        error = "Heightfield volume center exceeds float32 coordinate range.";
        return false;
    }
    // POD initialization keeps input validation independent of HAPI/session
    // state; no HAPI calls occur while copying the caller's payload.
    transform = HAPI_Transform{};
    for (int axis = 0; axis < 3; ++axis) {
        if (!std::isfinite(scales[axis]) || scales[axis] > std::numeric_limits<float>::max() || static_cast<float>(scales[axis]) <= 0.0f) {
            error = "Heightfield volume scale exceeds finite positive float32 range.";
            return false;
        }
        transform.position[axis] = center[axis];
        transform.scale[axis] = static_cast<float>(scales[axis]);
    }
    transform.rotationQuaternion[0] = rotation.x;
    transform.rotationQuaternion[1] = rotation.y;
    transform.rotationQuaternion[2] = rotation.z;
    transform.rotationQuaternion[3] = rotation.w;
    transform.rstOrder = HAPI_SRT;
    return true;
}

} // namespace HEGo::Util::Geo
#endif
