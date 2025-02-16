#include "houdini_asset_node.h"
#include "util/log/log.h"

HoudiniAssetNode::HoudiniAssetNode() :
		recook_button(false)
{
	// Constructor code here (if needed)
}

HoudiniAssetNode::~HoudiniAssetNode()
{
	// Destructor code here (if needed)
}

void HoudiniAssetNode::set_hda_resource(const Ref<Resource> &p_hda_resource)
{
	hda_resource = p_hda_resource;
}

Ref<Resource> HoudiniAssetNode::get_hda_resource() const
{
	return hda_resource;
}

void HoudiniAssetNode::set_recook_button(bool p_recook_button)
{
	if (p_recook_button)
	{
		recook();
		// Reset the button state to false after triggering
		recook_button = false;
	}
	else
	{
		recook_button = p_recook_button;
	}
}

bool HoudiniAssetNode::get_recook_button() const
{
	return recook_button;
}

void HoudiniAssetNode::recook()
{
	HEGo::Util::Log::message("Recook called");
}

void HoudiniAssetNode::_bind_methods()
{
	ClassDB::bind_method(D_METHOD("set_hda_resource", "hda_resource"), &HoudiniAssetNode::set_hda_resource);
	ClassDB::bind_method(D_METHOD("get_hda_resource"), &HoudiniAssetNode::get_hda_resource);

	ClassDB::bind_method(D_METHOD("set_recook_button", "recook_button"), &HoudiniAssetNode::set_recook_button);
	ClassDB::bind_method(D_METHOD("get_recook_button"), &HoudiniAssetNode::get_recook_button);

	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "hda_resource", PROPERTY_HINT_RESOURCE_TYPE, "Resource"), "set_hda_resource", "get_hda_resource");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "recook_button", PROPERTY_HINT_NONE, "Recook"), "set_recook_button", "get_recook_button");
}