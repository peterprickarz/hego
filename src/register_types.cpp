#include "register_types.h"

#include "hego_api.h"

#include "hego_nodes/hego_base_node.h"

#include "hego_nodes/hego_asset_node.h"
#include "hego_nodes/hego_curve_input_node.h"
#include "hego_nodes/hego_input_node.h"
#include "hego_nodes/hego_merge_node.h"
#include "hego_nodes/hego_trackable_node.h"

#include <gdextension_interface.h>
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

using namespace godot;

void initialize_hego_module(ModuleInitializationLevel p_level)
{
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE)
	{
		return;
	}

	ClassDB::register_class<HEGo::HEGoAPI>();
	memnew(HEGo::HEGoAPI);
	GDREGISTER_ABSTRACT_CLASS(HEGo::HEGoTrackableNode);
	GDREGISTER_VIRTUAL_CLASS(HEGo::HEGoBaseNode);
	GDREGISTER_VIRTUAL_CLASS(HEGo::HEGoInputReceiverNode);
	GDREGISTER_VIRTUAL_CLASS(HEGo::HEGoTransformableNode);
	GDREGISTER_VIRTUAL_CLASS(HEGo::HEGoTransformableNamedNode);
	GDREGISTER_VIRTUAL_CLASS(HEGo::HEGoTransformableInputReceiverNode);

	// ClassDB::register_abstract_class<HEGo::HEGoBaseNode>();
	// ClassDB::register_class<HEGo::HEGoInputReceiverNode>(true);
	// ClassDB::register_class<HEGo::HEGoTransformableNode>(true);
	ClassDB::register_class<HEGo::HEGoAssetNode>();
	ClassDB::register_class<HEGo::HEGoMergeNode>();
	ClassDB::register_class<HEGo::HEGoInputNode>();
	ClassDB::register_class<HEGo::HEGoCurveInputNode>();
}

void uninitialize_hego_module(ModuleInitializationLevel p_level)
{
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE)
	{
		return;
	}
}

extern "C"
{
	// Initialization.
	GDExtensionBool GDE_EXPORT hego_library_init(
			GDExtensionInterfaceGetProcAddress p_get_proc_address, const GDExtensionClassLibraryPtr p_library, GDExtensionInitialization *r_initialization)
	{
		godot::GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);

		init_obj.register_initializer(initialize_hego_module);
		init_obj.register_terminator(uninitialize_hego_module);
		init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);

		return init_obj.init();
	}
}