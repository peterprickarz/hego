#include "register_types.h"

#include "copia_brush.h"
#include "copia_build.h"
#include "copia_cells.h"
#include "copia_colliders.h"
#include "copia_drawer.h"
#include "copia_edit_overlay.h"
#include "copia_file.h"
#include "copia_format.h"
#include "copia_points.h"
#include "copia_sets.h"
#include "copia_streamer.h"

#include <gdextension_interface.h>
#include <godot_cpp/classes/resource_loader.hpp>
#include <godot_cpp/godot.hpp>

using namespace godot;

static Ref<Copia::CopiaFileLoader> copia_file_loader;

void initialize_copia_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
	GDREGISTER_INTERNAL_CLASS(Copia::CopiaParallelJob);
	ClassDB::register_class<Copia::CopiaSets>();
	ClassDB::register_class<Copia::CopiaBuild>();
	ClassDB::register_class<Copia::CopiaCells>();
	ClassDB::register_class<Copia::CopiaDrawer>();
	ClassDB::register_class<Copia::CopiaColliders>();
	ClassDB::register_class<Copia::CopiaPoints>();
	ClassDB::register_class<Copia::CopiaStreamer>();
	ClassDB::register_class<Copia::CopiaBrush>();
	ClassDB::register_class<Copia::CopiaEditOverlay>();
	ClassDB::register_class<Copia::CopiaFile>();
	ClassDB::register_class<Copia::CopiaFileLoader>();
	copia_file_loader.instantiate();
	ResourceLoader::get_singleton()->add_resource_format_loader(copia_file_loader);
}

void uninitialize_copia_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
	if (copia_file_loader.is_valid()) {
		ResourceLoader::get_singleton()->remove_resource_format_loader(copia_file_loader);
		copia_file_loader.unref();
	}
}

extern "C" {
GDExtensionBool GDE_EXPORT copia_library_init(
		GDExtensionInterfaceGetProcAddress p_get_proc_address,
		const GDExtensionClassLibraryPtr p_library,
		GDExtensionInitialization *r_initialization) {
	GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);
	init_obj.register_initializer(initialize_copia_module);
	init_obj.register_terminator(uninitialize_copia_module);
	init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);
	return init_obj.init();
}
}
