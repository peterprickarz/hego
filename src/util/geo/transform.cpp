#include "transform.h"

namespace HEGo
{
namespace Util
{
namespace Geo
{
void set_object_transform(HEGoSessionManager *session_mgr, const HAPI_NodeId node_id, const godot::Transform3D &transform)
{
	HAPI_TransformEuler houdini_transform = godot_to_houdini_transform(transform);
	HAPI_NodeId parent_id = HEGoUtil::get_parent_node_id(session_mgr->get_session(), node_id);
	HOUDINI_CHECK_ERROR(HoudiniApi::SetObjectTransform(session_mgr->get_session(), parent_id, &houdini_transform));
}

HAPI_TransformEuler godot_to_houdini_transform(const godot::Transform3D &transform)
{
	// some hacky basis -> quat -> vector stuff to avoid a bug on get_global_rotation_degrees
	godot::Basis global_basis = transform.get_basis();
	godot::Quaternion global_quat = global_basis.get_rotation_quaternion();
	godot::Vector3 q_rot = global_quat.get_euler_yxz();

	godot::Vector3 origin = transform.origin;
	godot::Vector3 rotation(
			godot::Math::rad_to_deg(q_rot.x),
			godot::Math::rad_to_deg(q_rot.y),
			godot::Math::rad_to_deg(q_rot.z));
	godot::Vector3 scale = global_basis.get_scale();

	HAPI_TransformEuler houdini_transform;
	HoudiniApi::TransformEuler_Init(&houdini_transform);
	houdini_transform.position[0] = origin.x;
	houdini_transform.position[1] = origin.y;
	houdini_transform.position[2] = origin.z;
	houdini_transform.rotationEuler[0] = rotation.x;
	houdini_transform.rotationEuler[1] = rotation.y;
	houdini_transform.rotationEuler[2] = rotation.z;
	houdini_transform.scale[0] = scale.x;
	houdini_transform.scale[1] = scale.y;
	houdini_transform.scale[2] = scale.z;
	houdini_transform.rotationOrder = HAPI_ZXY;
	houdini_transform.rstOrder = HAPI_SRT;

	return houdini_transform;
}

} // namespace Geo
} // namespace Util
} // namespace HEGo
