#include "hego_nodes/hego_trackable_node.h"

#include "hego_api.h"
#include "hego_session_manager.h"

namespace HEGo
{
void HEGoTrackableNode::_bind_methods() {}

HEGoTrackableNode::~HEGoTrackableNode()
{
	// The session manager tracks nodes with raw pointers, deliberately, so that it does
	// not keep every node HEGo ever created alive. Removing ourselves here is what makes
	// that safe: without it, stopping a session walks the registry resetting node ids
	// through pointers whose objects are long gone.
	HEGoAPI *api = HEGoAPI::get_singleton();
	if (api == nullptr)
	{
		return;
	}

	HEGoSessionManager *session_mgr = api->get_session_manager();
	if (session_mgr != nullptr)
	{
		session_mgr->unregister_node(this);
	}
}
} // namespace HEGo
