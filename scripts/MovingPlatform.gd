extends AnimatableBody2D

@export var amplitude: float = 120.0  # размах (в пикселях)
@export var speed: float = 1.0        # скорость (циклы в сек примерно = speed/(2π))
@export var vertical: bool = true     # true = вверх/вниз, false = влево/вправо
@export var phase: float = 0.0        # сдвиг фазы, если нужно
@export var tint: Color = Color(1, 0.8, 0.2, 1)

var _base: Vector2
var _t := 0.0
var _prev_pos: Vector2

func _ready() -> void:
	_base = global_position
	_prev_pos = _base
	# красивый цвет, если есть Polygon2D
	if $Polygon2D: $Polygon2D.color = tint

func _physics_process(delta: float) -> void:
	_t += delta * speed
	var off := sin(_t + phase) * amplitude
	var new_pos := _base + (Vector2(0, off) if vertical else Vector2(off, 0))
	var dt: float = max(0.0001, delta) as float
	var vel: Vector2 = (new_pos - _prev_pos) / dt
	global_position = new_pos
	# Сообщаем движку скорость платформы — так риджиды «подхватываются»
	if "constant_linear_velocity" in self:
		self.constant_linear_velocity = vel
	_prev_pos = new_pos
