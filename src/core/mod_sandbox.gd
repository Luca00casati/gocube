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
## `call`/`set`, `new`, `await`, annotations, inner classes or lambdas. The
## script must extend RefCounted (the default).
##
## Time and memory limits: instrument() adds a check of the clock and of the
## memory in use at the start of every loop body and function (which is why
## their bodies must be on lines of their own, and why there are no lambdas or
## map/filter/sort_custom, which could call code without a check). Once
## time_limit_ms have passed, or the script uses memory_limit more bytes than
## when it started, every loop stops and every function returns at once, so
## the mod soon finishes; the loader then undoes it (stopped_by). Recursion is
## refused outright. A single call that asks for a huge amount of memory at
## once (say "x".repeat(1 << 40)) isn't caught by these checks: that is why
## installed mods run in a process of their own (mod_runner.gd), where it can
## only crash that process.
##
## Nothing a script can do depends on the time or chance (no clock, no random
## numbers), so a mod's registrations depend only on its files and what was
## registered before it: the loader keeps them (ModLoader.RESULTS_DIR).

## Time a mod has to load (tests lower it).
static var time_limit_ms := 5000
## Memory a mod may use while it loads, in bytes.
static var memory_limit := 256 << 20

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
	"reverse", "slice", "duplicate",
	"front", "back", "resize", "fill", "bsearch", "keys", "values",
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
		var t: Array = tokens[i]  # [kind, text, line, offset]
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
		if name.begins_with("__"):
			return where + "names starting with __ are reserved"
		if not after_dot and name in ["while", "for", "func"]:
			var starts_line: bool = i == 0 or tokens[i - 1][2] < t[2] or tokens[i - 1][1] == "static"
			if name == "func" and (i + 1 >= tokens.size() or tokens[i + 1][0] != "id" or not starts_line):
				return where + "lambdas aren't available to mods; write a named function"
			var colon := _header_end(tokens, i)
			if colon == -1 or colon + 1 >= tokens.size():
				return where + "can't find the end of this `%s`" % name
			if tokens[colon + 1][2] == tokens[colon][2]:
				return where + "put the body of this `%s` on lines of its own" % name
		if after_dot:
			if not allowed_members.has(name) and not _is_constant(name):
				return where + "`.%s` isn't available to mods (for dictionary keys use d[\"%s\"])" % [name, name]
		elif not allowed_globals.has(name) and not declared.has(name) and not _is_constant_global(name):
			return where + "`%s` isn't available to mods" % name
	return _recursion_problem(tokens)


## Functions calling themselves, directly or through others, are refused: a
## mod's functions can only be called by name (no lambdas or `call`), so the
## calls in its text are all of them. (Deep recursion would overflow the stack
## before the time limit could stop it.)
static func _recursion_problem(tokens: Array) -> String:
	var calls := {}  # function -> {functions it calls}
	var lines := {}
	var current := ""
	for i in tokens.size():
		var t: Array = tokens[i]
		if t[0] != "id" or (i > 0 and tokens[i - 1][1] == "."):
			continue
		if t[1] == "func" and i + 1 < tokens.size():
			current = tokens[i + 1][1]
			calls[current] = calls.get(current, {})
			lines[current] = t[2]
		elif current != "" and i + 1 < tokens.size() and tokens[i + 1][1] == "(" and not (i > 0 and tokens[i - 1][1] == "func"):
			calls[current][t[1]] = true
	var state := {}  # 1 visiting, 2 done
	for f in calls:
		var cycle := _cycle_from(f, calls, state)
		if cycle != "":
			return "line %d: `%s` calls itself (%s); recursion isn't available to mods" % [lines[f], f, cycle]
	return ""


static func _cycle_from(f: String, calls: Dictionary, state: Dictionary) -> String:
	if state.get(f, 0) == 2 or not calls.has(f):
		return ""
	if state.get(f, 0) == 1:
		return f
	state[f] = 1
	for g in calls[f]:
		var c := _cycle_from(g, calls, state)
		if c != "":
			return f + " -> " + c
	state[f] = 2
	return ""


## Index of the ":" ending the header of the while/for/func at token i, or -1
## (the first one outside brackets: a func's parameters are inside its
## parentheses; a for's loop variable may have a type, so after its `in`).
static func _header_end(tokens: Array, i: int) -> int:
	var depth := 0
	var after: bool = tokens[i][1] != "for"
	for k in range(i + 1, tokens.size()):
		var t: Array = tokens[k]
		if t[0] == "op" and t[1] in ["(", "[", "{"]:
			depth += 1
		elif t[0] == "op" and t[1] in [")", "]", "}"]:
			depth -= 1
			if depth < 0:
				return -1
		elif depth == 0:
			if t[0] == "id" and t[1] == "in":
				after = true
			elif t[0] == "op" and t[1] == ":" and after:
				return k
	return -1


## `source` (which passed check()) with the time limit added: a clock check
## at the start of every loop body and function. Lines move down by a few.
static func instrument(source: String) -> String:
	var tokens: Array = _tokenize(source)
	var inserts := []  # [offset, text]
	for i in tokens.size():
		var t: Array = tokens[i]
		if t[0] != "id" or not t[1] in ["while", "for", "func"] or (i > 0 and tokens[i - 1][1] == "."):
			continue
		var colon := _header_end(tokens, i)
		var body: Array = tokens[colon + 1]
		var line_start := source.rfind("\n", body[3]) + 1
		var indent := source.substr(line_start, body[3] - line_start)
		var stop := "break" if t[1] != "func" else "return" + _return_value(tokens, i, colon)
		inserts.append([line_start, "%sif __over(): %s\n" % [indent, stop]])
	# The clock, first thing in the script (static variables start in order).
	var top := 0
	if not tokens.is_empty() and tokens[0][1] == "extends":
		top = source.find("\n", tokens[1][3])
		top = source.length() if top == -1 else top + 1
	inserts.append([top, ("static var __deadline_ms: int = Time.get_ticks_msec() + %d\n" % time_limit_ms)
			+ ("static var __memory_cap: int = OS.get_static_memory_usage() + %d\n" % memory_limit)
			+ "static var __stopped := \"\"\n"
			+ "static func __over() -> bool: __stopped = __stopped if __stopped != \"\" else \"time\" if Time.get_ticks_msec() > __deadline_ms else \"memory\" if OS.get_static_memory_usage() > __memory_cap else \"\"; return __stopped != \"\"\n"])
	inserts.sort_custom(func(a, b): return a[0] > b[0])
	var out := source
	if top == source.length() and not source.ends_with("\n"):
		out += "\n"
	for ins in inserts:
		out = out.insert(ins[0], ins[1])
	return out


## What an instrumented function returns when time is up: nothing, or an
## empty value of its declared type.
static func _return_value(tokens: Array, i: int, colon: int) -> String:
	var type := ""
	var arrow := false
	for j in range(i, colon):
		if arrow:
			type += tokens[j][1]
		elif tokens[j][1] == "-" and tokens[j + 1][1] == ">":
			arrow = true
	type = type.trim_prefix(">")
	if type == "" or type == "void":
		return ""
	if type == "Variant":
		return " null"
	if type.begins_with("Array"):
		return " []"
	if type.begins_with("Dictionary"):
		return " {}"
	return " %s()" % type


## Whether a value is plain data (what JSON has, plus numbers and vectors): no
## objects or callables, which could reach back into a mod.
static func is_plain(v) -> bool:
	match typeof(v):
		TYPE_OBJECT, TYPE_CALLABLE, TYPE_SIGNAL, TYPE_RID:
			return false
		TYPE_ARRAY:
			return v.all(is_plain)
		TYPE_DICTIONARY:
			return v.keys().all(is_plain) and v.values().all(is_plain)
	return true


## What stopped a script made from instrument(): "time", "memory" or "" (nothing).
static func stopped_by(script: GDScript) -> String:
	return str(script.get("__stopped"))


## Why a mod was stopped, for the log and the Mods screen.
static func stop_message(mod_id: String, why: String) -> String:
	if why == "memory":
		return "Mod '%s': used more than %d MB while loading; undoing the mod" % [mod_id, memory_limit >> 20]
	return "Mod '%s': took longer than %.1f s to load (stuck in a loop?); undoing the mod" % [mod_id, time_limit_ms / 1000.0]


static func _is_constant(name: String) -> bool:
	return name == name.to_upper() and name[0] >= "A" and name[0] <= "Z"


## TYPE_INT and friends.
static func _is_constant_global(name: String) -> bool:
	return name.begins_with("TYPE_") and _is_constant(name)


## Splits GDScript source into [kind, text, line, offset] tokens: "id", "op", "str",
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
			var tok_start := i
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
			out.append(["str", "", start_line, tok_start])
		elif _is_ident_start(code):
			var s := i
			while i < n and (_is_ident_start(src.unicode_at(i)) or _is_digit(src.unicode_at(i))):
				i += 1
			out.append(["id", src.substr(s, i - s), line, s])
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
			out.append(["num", src.substr(s, i - s), line, s])
		elif code > 127:
			return "line %d: only ASCII letters are allowed outside strings and comments" % line
		elif c == "$" or c == "@" or c == "`":
			return "line %d: `%s` isn't available to mods" % [line, c]
		else:
			out.append(["op", c, line, i])
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
