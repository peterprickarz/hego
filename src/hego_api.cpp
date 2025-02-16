#include "hego_api.h"

#include "hapi/hego_platform.h"
#include "util/geo/input.h"
#include "util/geo/output.h"
#include "util/geo/transform.h"
#include "util/log/log.h"
#include "util/node/create_nodes.h"
#include "util/parm/set_parms.h"

#include <godot_cpp/variant/utility_functions.hpp>

namespace HEGo
{
const std::string HFS = "C:/Program Files/Side Effects Software/Houdini 20.5.305";

HEGoAPI *HEGoAPI::singleton = nullptr;

HEGoAPI::HEGoAPI() : session_mgr()
{
	singleton = this;
	HEGoPlatform::set_env_vars();
}

HEGoAPI::~HEGoAPI()
{
	if (singleton == this)
	{
		singleton = nullptr;
	}
}

HEGoAPI *HEGoAPI::get_singleton() { return singleton; }

void HEGoAPI::start_session()
{
	HEGoPlatform::initialize_hapi();
	session_mgr.start_session();
	return;
}

void HEGoAPI::stop_session()
{
	session_mgr.stop_session();
	return;
}

HEGoSessionManager *HEGoAPI::get_session_manager() { return &session_mgr; }

void HEGoAPI::_bind_methods()
{
	godot::ClassDB::bind_method(godot::D_METHOD("start_session"), &HEGoAPI::start_session);
	godot::ClassDB::bind_method(godot::D_METHOD("stop_session"), &HEGoAPI::stop_session);

	godot::ClassDB::bind_static_method("HEGoAPI", godot::D_METHOD("get_singleton"), &HEGoAPI::get_singleton);
}
} // namespace HEGo