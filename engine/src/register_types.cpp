// Entry point of the GoCube voxel engine GDExtension.
#include "gocube_world.h"
#include "mod_api.h"

#include <gdextension_interface.h>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

using namespace godot;

void gocube_register(ModuleInitializationLevel level) {
	if (level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
	GDREGISTER_CLASS(gocube::GoCubeWorld);
	GDREGISTER_CLASS(gocube::GoCubeModApi);
}

void gocube_unregister(ModuleInitializationLevel level) {}

extern "C" GDExtensionBool GDE_EXPORT gocube_init(GDExtensionInterfaceGetProcAddress get_proc_address,
		const GDExtensionClassLibraryPtr library, GDExtensionInitialization *initialization) {
	GDExtensionBinding::InitObject init(get_proc_address, library, initialization);
	init.register_initializer(gocube_register);
	init.register_terminator(gocube_unregister);
	init.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);
	return init.init();
}
