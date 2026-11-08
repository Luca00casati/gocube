class_name ItemDrop
extends Node3D
## An item lying in the world: falls, bobs, and drifts to the local player when
## close, then goes into their inventory. Merges with the same item nearby;
## disappears after LIFETIME seconds.

signal picked_up(item: String, count: int)

const BOX := Vector3(0.25, 0.25, 0.25)
const GRAVITY := 20.0
const PICKUP_DELAY := 0.5      # don't grab it in the same instant it pops out
const MAGNET_RADIUS := 2.6
const PICKUP_RADIUS := 1.2
const LIFETIME := 300.0

var item := ""
var count := 1
var world: World
var player: Node3D            # the local player (player.gd)
var velocity := Vector3.ZERO
var _age := 0.0
var _sprite: Sprite3D


func setup(item_id: String, amount: int, icon: Texture2D) -> void:
	item = item_id
	count = amount
	_sprite = Sprite3D.new()
	_sprite.texture = icon
	_sprite.pixel_size = 0.011
	_sprite.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_sprite.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	_sprite.shaded = false
	_sprite.alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
	_sprite.position.y = BOX.y
	add_child(_sprite)


func _physics_process(delta: float) -> void:
	_age += delta
	if _age > LIFETIME:
		queue_free()
		return
	var to_player := Vector3.ZERO
	if player and not player.dead and _age > PICKUP_DELAY:
		to_player = player.global_position + Vector3(0, 0.9, 0) - global_position
		if to_player.length() < PICKUP_RADIUS:
			var left: int = player.inventory.add(item, count)
			if left < count:
				picked_up.emit(item, count - left)
			count = left
			if count == 0:
				queue_free()
				return
	if to_player != Vector3.ZERO and to_player.length() < MAGNET_RADIUS and player.inventory.can_fit(item):
		velocity = to_player.normalized() * 6.0  # drift towards the player
		global_position += velocity * delta
	else:
		velocity.y = maxf(velocity.y - GRAVITY * delta, -30.0)
		velocity.x *= 0.92
		velocity.z *= 0.92
		var r: Dictionary = world.move_box(global_position, BOX, velocity * delta)
		global_position = r.position
		if r.on_floor:
			velocity = Vector3(velocity.x * 0.5, 0, velocity.z * 0.5)
	if _sprite:
		_sprite.position.y = BOX.y + 0.08 * sin(_age * 3.0)
