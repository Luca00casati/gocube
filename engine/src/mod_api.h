// GoCubeModApi: the only object a mod's entry script is given (init_mod(registry)).
// It is a native object on purpose: it has no script, no properties and no way
// back into the game, so a sandboxed mod (see src/core/mod_sandbox.gd) can reach
// nothing through it but these methods. Each call goes to a handler the mod
// loader sets; the loader clears it once the mod has loaded.
#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/callable.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>

namespace gocube {

class GoCubeModApi : public godot::RefCounted {
	GDCLASS(GoCubeModApi, godot::RefCounted)

public:
	// handler(kind: String, id: String, def: Dictionary) -> Variant
	void _set_handler(const godot::Callable &handler) { _handler = handler; }

	godot::String register_block(const godot::String &id, const godot::Dictionary &def);
	godot::String register_item(const godot::String &id, const godot::Dictionary &def);
	godot::String register_recipe(const godot::String &id, const godot::Dictionary &def);
	godot::String register_ore(const godot::String &id, const godot::Dictionary &def);
	godot::String register_tree(const godot::String &id, const godot::Dictionary &def);
	godot::String register_biome(const godot::String &id, const godot::Dictionary &def);
	godot::String register_sound_set(const godot::String &id, const godot::Dictionary &def);
	// Copies of what is registered so far ({} if nothing has this id).
	godot::Dictionary get_block(const godot::String &id);
	godot::Dictionary get_item(const godot::String &id);

protected:
	static void _bind_methods();

private:
	godot::Variant _call(const char *kind, const godot::String &id, const godot::Dictionary &def);
	godot::Callable _handler;
};

} // namespace gocube
