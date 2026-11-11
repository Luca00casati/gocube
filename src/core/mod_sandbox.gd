class_name ModSandbox
## Checks a mod's entry script before it is compiled, so a mod can only do what
## the mod API allows: register content through the object init_mod() is given
## (a GoCubeModApi, a native object with nothing behind it), and compute with
## numbers, strings, arrays, dictionaries, vectors and colours.
##
## The check is an allow list over the script's tokens, not a list of bad
## things: every name the script uses must be one of
##   - its own (functions, variables, constants, parameters, loop variables),
##     which may not reuse the name of anything in the engine or the game;
##   - a keyword, a built-in value type, a math/string utility function or a
##     constant from ALLOWED_GLOBALS;
##   - after a dot, a method or property of the value types or the mod API
##     (ALLOWED_MEMBERS), or a constant (ALL_CAPS).
## So no `self`, `load`, classes (OS, FileAccess, ...), autoloads, nodes,
## `call`/`set`, `new`, `await`, annotations or inner classes. The script must
## extend RefCounted (the default).
##
## What it can't stop: a mod that loops forever or fills memory hangs or
## crashes the game while it loads (remove the mod to recover).

const KEYWORDS := ["if", "elif", "else", "for", "while", "match", "when", "break", "continue",
	"pass", "return", "var", "const", "func", "static", "and", "or", "not", "in", "is", "as",
	"true", "false", "null", "void", "PI", "TAU", "INF", "NAN", "assert", "_"]

const ALLOWED_GLOBALS := [
	# value types (also as constructors and type hints)
	"bool", "int", "float", "String", "StringName", "Array", "Dictionary", "Variant",
	"Vector2", "Vector2i", "Vector3", "Vector3i", "Vector4", "Vector4i", "Color",
	"Rect2", "Rect2i", "AABB", "Basis", "Transform2D", "Transform3D", "Quaternion", "Plane",
	"PackedByteArray", "PackedInt32Array", "PackedInt64Array", "PackedFloat32Array",
	"PackedFloat64Array", "PackedStringArray", "PackedVector2Array", "PackedVector3Array",
	"PackedVector4Array", "PackedColorArray",
	# utility functions without side effects (plus printing)
	"abs", "absf", "absi", "ceil", "ceilf", "ceili", "floor", "floorf", "floori",
	"round", "roundf", "roundi", "sign", "signf", "signi", "min", "minf", "mini",
	"max", "maxf", "maxi", "clamp", "clampf", "clampi", "lerp", "lerpf", "inverse_lerp",
	"remap", "snapped", "snappedf", "snappedi", "sqrt", "pow", "exp", "log", "sin", "cos",
	"tan", "asin", "acos", "atan", "atan2", "sinh", "cosh", "tanh", "deg_to_rad",
	"rad_to_deg", "fmod", "fposmod", "posmod", "is_nan", "is_inf", "is_equal_approx",
	"is_zero_approx", "wrap", "wrapf", "wrapi", "move_toward", "smoothstep", "len",
	"range", "str", "typeof", "type_string", "hash", "is_same", "print", "prints",
	"printt", "push_error", "push_warning",
]

const ALLOWED_MEMBERS := [
	# the mod API (GoCubeModApi)
	"register_block", "register_item", "register_recipe", "register_ore", "register_tree",
	"register_biome", "register_sound_set", "get_block", "get_item",
	# String
	"begins_with", "ends_with", "contains", "containsn", "find", "findn", "rfind", "count",
	"countn", "length", "to_lower", "to_upper", "capitalize", "to_snake_case",
	"to_camel_case", "to_pascal_case", "split", "rsplit", "join", "replace", "replacen",
	"strip_edges", "lstrip", "rstrip", "substr", "left", "right", "to_int", "to_float",
	"is_valid_int", "is_valid_float", "is_valid_identifier", "format", "pad_zeros",
	"pad_decimals", "repeat", "get_slice", "get_slice_count", "trim_prefix", "trim_suffix",
	"path_join", "get_extension", "get_basename", "get_file", "get_base_dir", "unicode_at",
	"num", "num_int64", "chr", "similarity", "md5_text", "sha256_text", "c_escape",
	"json_escape", "to_utf8_buffer", "get_string_from_utf8", "is_subsequence_of",
	# Array, Dictionary and the packed arrays
	"append", "append_array", "push_back", "push_front", "pop_back", "pop_front", "pop_at",
	"insert", "erase", "remove_at", "clear", "size", "is_empty", "has", "has_all", "sort",
	"sort_custom", "reverse", "slice", "duplicate", "map", "filter", "reduce", "any", "all",
	"front", "back", "resize", "fill", "bsearch", "pick_random", "shuffle", "keys", "values",
	"get", "merge", "merged", "get_or_add", "find_key",
	# vectors and colours
	"x", "y", "z", "w", "r", "g", "b", "a", "h", "s", "v", "r8", "g8", "b8", "a8",
	"length_squared", "normalized", "dot", "cross", "distance_to", "distance_squared_to",
	"floor", "ceil", "round", "abs", "sign", "snapped", "lerp", "clamp", "min", "max",
	"to_html", "lightened", "darkened", "blend", "inverted", "html", "from_hsv",
	"position", "end",
]

## Names a script may not declare: they would shadow something of the engine or
## the game that the script could then reach by its bare name (built lazily).
static var _reserved := {}


## What makes `source` unsafe to run as a mod script, as "line N: reason", or "".
static func check(source: String) -> String:
	var tokens = _tokenize(source)
	if tokens is String:
		return tokens
	var declared := {}
	var problem := _collect_declarations(tokens, declared)
	if problem != "":
		return problem
	var allowed_globals := {}
	for n in KEYWORDS + ALLOWED_GLOBALS:
		allowed_globals[n] = true
	var allowed_members := {}
	for n in ALLOWED_MEMBERS:
		allowed_members[n] = true
	var seen_code := false
	for i in tokens.size():
		var t: Array = tokens[i]  # [kind, text, line]
		if t[0] != "id":
			if t[0] == "op":
				seen_code = true
			continue
		var name: String = t[1]
		var where := "line %d: " % t[2]
		var after_dot: bool = i > 0 and tokens[i - 1][0] == "op" and tokens[i - 1][1] == "."
		if name == "extends":
			if seen_code or i + 1 >= tokens.size() or tokens[i + 1][1] != "RefCounted":
				return where + "a mod script can only start with `extends RefCounted`"
			continue
		if i > 0 and tokens[i - 1][1] == "extends":
			continue  # RefCounted, checked above
		seen_code = true
		if after_dot:
			if not allowed_members.has(name) and not _is_constant(name):
				return where + "`.%s` isn't available to mods (for dictionary keys use d[\"%s\"])" % [name, name]
		elif not allowed_globals.has(name) and not declared.has(name) and not _is_constant_global(name):
			return where + "`%s` isn't available to mods" % name
	return ""


static func _is_constant(name: String) -> bool:
	return name == name.to_upper() and name[0] >= "A" and name[0] <= "Z"


## TYPE_INT and friends.
static func _is_constant_global(name: String) -> bool:
	return name.begins_with("TYPE_") and _is_constant(name)


## Splits GDScript source into [kind, text, line] tokens: "id", "op", "str",
## "num". Comments and line breaks are dropped. Returns a String on a problem.
static func _tokenize(src: String):
	var out := []
	var i := 0
	var line := 1
	var n := src.length()
	while i < n:
		var c := src[i]
		var code := src.unicode_at(i)
		if c == "\n":
			line += 1
			i += 1
		elif c == " " or c == "\t" or c == "\r" or c == "\\":
			i += 1
		elif c == "#":
			while i < n and src[i] != "\n":
				i += 1
		elif c == "\"" or c == "'" or ((c == "r" or c == "&" or c == "^") and i + 1 < n and (src[i + 1] == "\"" or src[i + 1] == "'")):
			var raw := c == "r"
			if c != "\"" and c != "'":
				i += 1
			var q := src[i]
			var triple := src.substr(i, 3) == q.repeat(3)
			var close := q.repeat(3) if triple else q
			var start_line := line
			i += close.length()
			while true:
				if i >= n:
					return "line %d: unterminated string" % start_line
				if src[i] == "\\" and not raw:
					if i + 1 < n and src[i + 1] == "\n":
						line += 1
					i += 2
					continue
				if src.substr(i, close.length()) == close:
					i += close.length()
					break
				if src[i] == "\n":
					if not triple:
						return "line %d: unterminated string" % start_line
					line += 1
				i += 1
			out.append(["str", "", start_line])
		elif _is_ident_start(code):
			var s := i
			while i < n and (_is_ident_start(src.unicode_at(i)) or _is_digit(src.unicode_at(i))):
				i += 1
			out.append(["id", src.substr(s, i - s), line])
		elif _is_digit(code) or (c == "." and i + 1 < n and _is_digit(src.unicode_at(i + 1))
				and not (out.size() > 0 and (out[-1][0] in ["id", "str", "num"] or out[-1][1] in [")", "]", "}"]))):
			var s := i
			if src.substr(i, 2) in ["0x", "0X", "0b", "0B"]:
				i += 2
				while i < n and (_is_digit(src.unicode_at(i)) or src[i] in "abcdefABCDEF_"):
					i += 1
			else:
				while i < n and (_is_digit(src.unicode_at(i)) or src[i] == "_"):
					i += 1
				if i < n and src[i] == "." and not (i + 1 < n and _is_ident_start(src.unicode_at(i + 1)) and src[i + 1] not in "eE"):
					i += 1
					while i < n and (_is_digit(src.unicode_at(i)) or src[i] == "_"):
						i += 1
				if i < n and src[i] in "eE":
					i += 1
					if i < n and src[i] in "+-":
						i += 1
					while i < n and _is_digit(src.unicode_at(i)):
						i += 1
			if i < n and _is_ident_start(src.unicode_at(i)):
				return "line %d: bad number" % line
			out.append(["num", src.substr(s, i - s), line])
		elif code > 127:
			return "line %d: only ASCII letters are allowed outside strings and comments" % line
		elif c == "$" or c == "@" or c == "`":
			return "line %d: `%s` isn't available to mods" % [line, c]
		else:
			out.append(["op", c, line])
			i += 1
	return out


static func _is_ident_start(code: int) -> bool:
	return (code >= 65 and code <= 90) or (code >= 97 and code <= 122) or code == 95


static func _is_digit(code: int) -> bool:
	return code >= 48 and code <= 57


## Fills `declared` with the script's own names: after func/var/const/for, and
## function and lambda parameters. Returns a problem when one is reserved.
static func _collect_declarations(tokens: Array, declared: Dictionary) -> String:
	var reserved := _reserved_names()
	var depth := 0
	var param_depth := -1  # bracket depth of the parameter list being read
	for i in tokens.size():
		var t: Array = tokens[i]
		if t[0] == "op":
			if t[1] in ["(", "[", "{"]:
				depth += 1
			elif t[1] in [")", "]", "}"]:
				depth -= 1
				if depth < param_depth:
					param_depth = -1
			continue
		if t[0] != "id":
			continue
		var prev: String = tokens[i - 1][1] if i > 0 else ""
		var is_decl: bool = prev in ["func", "var", "const", "for"] and tokens[i - 1][0] == "id"
		if not is_decl and param_depth != -1 and depth == param_depth and prev in ["(", ","] and tokens[i - 1][0] == "op":
			is_decl = true
		if t[1] == "func":
			# The parameter list starts at the next "(": `func name(` or `func(`.
			param_depth = depth + 1
		if is_decl:
			if t[1] != "_" and (reserved.has(t[1]) or t[1] in KEYWORDS or t[1] in ALLOWED_GLOBALS):
				return "line %d: `%s` is a reserved name; pick another" % [t[2], t[1]]
			declared[t[1]] = true
	return ""


static func _reserved_names() -> Dictionary:
	if not _reserved.is_empty():
		return _reserved
	var out := {}
	for c in ClassDB.get_class_list():
		out[c] = true
	for c in Engine.get_singleton_list():
		out[c] = true
	for c in ProjectSettings.get_global_class_list():
		out[c["class"]] = true
	for p in ProjectSettings.get_property_list():
		if p.name.begins_with("autoload/"):
			out[p.name.trim_prefix("autoload/")] = true
	for m in ClassDB.class_get_method_list("RefCounted"):
		out[m.name] = true
	for p in ClassDB.class_get_property_list("RefCounted"):
		out[p.name] = true
	# Built-in functions with side effects or that make objects (not in the
	# ClassDB lists above).
	for f in ["self", "super", "load", "preload", "str_to_var", "bytes_to_var",
			"bytes_to_var_with_objects", "var_to_str", "var_to_bytes", "var_to_bytes_with_objects",
			"inst_to_dict", "dict_to_inst", "instance_from_id", "is_instance_id_valid",
			"is_instance_valid", "type_convert", "convert", "weakref", "get_stack", "print_stack",
			"print_debug", "rid_from_int64", "rid_allocate_id", "randomize", "seed", "rand_from_seed",
			"Callable", "Signal", "Object", "RID", "NodePath", "Color8", "char", "await",
			"signal", "class", "class_name", "enum", "breakpoint", "yield", "trait", "namespace"]:
		out[f] = true
	_reserved = out
	return out
