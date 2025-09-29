extends RigidBody2D

@export var speed: float = 90.0
@export var patrol_half: float = 140.0
@export var flip_on_wall: bool = true
@export var tint: Color = Color(1, 0.2, 0.2, 1) # цвет врага (красный по умолчанию)

var _origin_x: float
var _dir: int = 1
var _alive: bool = true

func _ready() -> void:
	_origin_x = global_position.x
	add_to_group("enemy")
	_ensure_sprite()

func _integrate_forces(state: PhysicsDirectBodyState2D) -> void:
	if not _alive:
		return
	var v := state.get_linear_velocity()
	v.x = speed * _dir
	state.set_linear_velocity(v)
	if global_position.x > _origin_x + patrol_half: _dir = -1
	elif global_position.x < _origin_x - patrol_half: _dir = 1

func _on_hit_wall() -> void:
	if flip_on_wall: _dir *= -1

func kill() -> void:
	if not _alive: return
	_alive = false
	collision_layer = 0
	collision_mask = 0
	set_deferred("sleeping", true)
	queue_free()

# ---- visuals ---------------------------------------------------------------

func _ensure_sprite() -> void:
	# берём размер из CollisionShape2D (RectangleShape2D)
	var cs := $CollisionShape2D
	var w := 28
	var h := 18
	if cs and cs.shape is RectangleShape2D:
		var sz: Vector2 = (cs.shape as RectangleShape2D).size
		w = int(max(1.0, sz.x))
		h = int(max(1.0, sz.y))

	var spr: Sprite2D = $Sprite2D
	if spr == null:
		spr = Sprite2D.new()
		add_child(spr)

	spr.centered = true
	spr.texture = _make_solid_texture(w, h, tint)
	spr.modulate = Color.WHITE
	spr.visible = true

func _make_solid_texture(w: int, h: int, col: Color) -> Texture2D:
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(col)
	return ImageTexture.create_from_image(img)
