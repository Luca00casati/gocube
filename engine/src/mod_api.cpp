#include "mod_api.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

using namespace godot;

namespace gocube {

Variant GoCubeModApi::_call(const char *kind, const String &id, const Dictionary &def) {
	if (!_handler.is_valid()) {
		UtilityFunctions::push_error("The mod API can only be used while the mod loads (init_mod)");
		return Variant();
	}
	return _handler.call(String(kind), id, def);
}

#define GOCUBE_REGISTER(name, kind) \
	String GoCubeModApi::name(const String &id, const Dictionary &def) { \
		Variant r = _call(kind, id, def); \
		return r.get_type() == Variant::STRING ? String(r) : String(); \
	}
GOCUBE_REGISTER(register_block, "block")
GOCUBE_REGISTER(register_item, "item")
GOCUBE_REGISTER(register_recipe, "recipe")
GOCUBE_REGISTER(register_ore, "ore")
GOCUBE_REGISTER(register_tree, "tree")
GOCUBE_REGISTER(register_biome, "biome")
GOCUBE_REGISTER(register_sound_set, "sound_set")
#undef GOCUBE_REGISTER

Dictionary GoCubeModApi::get_block(const String &id) {
	Variant r = _call("get_block", id, Dictionary());
	return r.get_type() == Variant::DICTIONARY ? Dictionary(r) : Dictionary();
}

Dictionary GoCubeModApi::get_item(const String &id) {
	Variant r = _call("get_item", id, Dictionary());
	return r.get_type() == Variant::DICTIONARY ? Dictionary(r) : Dictionary();
}

void GoCubeModApi::_bind_methods() {
	ClassDB::bind_method(D_METHOD("_set_handler", "handler"), &GoCubeModApi::_set_handler);
	ClassDB::bind_method(D_METHOD("register_block", "id", "def"), &GoCubeModApi::register_block, DEFVAL(Dictionary()));
	ClassDB::bind_method(D_METHOD("register_item", "id", "def"), &GoCubeModApi::register_item, DEFVAL(Dictionary()));
	ClassDB::bind_method(D_METHOD("register_recipe", "id", "def"), &GoCubeModApi::register_recipe);
	ClassDB::bind_method(D_METHOD("register_ore", "id", "def"), &GoCubeModApi::register_ore);
	ClassDB::bind_method(D_METHOD("register_tree", "id", "def"), &GoCubeModApi::register_tree);
	ClassDB::bind_method(D_METHOD("register_biome", "id", "def"), &GoCubeModApi::register_biome);
	ClassDB::bind_method(D_METHOD("register_sound_set", "id", "def"), &GoCubeModApi::register_sound_set);
	ClassDB::bind_method(D_METHOD("get_block", "id"), &GoCubeModApi::get_block);
	ClassDB::bind_method(D_METHOD("get_item", "id"), &GoCubeModApi::get_item);
}

} // namespace gocube
