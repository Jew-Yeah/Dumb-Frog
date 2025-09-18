extends Node2D
# Язык лягушки с обхватом препятствий.
# Физика: цепочка pivot-точек + DampedSpringJoint2D между всеми соседями.
# Визуал: RopeSim (если есть узел "Rope"), иначе Line2D. Рисуется в мировых координатах.

# -------- параметры поведения --------
@export var max_length: float = 340.0                 # дальность выстрела
@export var reel_speed: float = 260.0                 # скорость подмотки первого сегмента
@export var stiffness: float = 70.0                   # жёсткость пружин
@export var damping: float = 6.0                      # затухание пружин
@export var pull_force: float = 1200.0                # доп.тяга (импульсами) вдоль первого сегмента
@export var break_tension: float = 220.0              # порог на разрыв
@export_flags_2d_physics var ray_mask := 1            # слои, по которым язык «видит» препятствия
@export var mouth_offset: Vector2 = Vector2(6, -6)    # точка выхода языка «изо рта»

# анти-дрожь/анти-спам поворотов
@export var pivot_min_dist: float = 8.0               # минимальная дистанция между соседними pivot
@export var unwrap_hysteresis: float = 6.0            # допуск при «соскальзывании» с угла
@export var add_pivot_cooldown: float = 0.06          # минимальный интервал между вставками pivot (сек)

# -------- ссылки на сцену --------
var frog: RigidBody2D
var rope: Node = null          # из RopeSim (например, VerletRope2D/Rope2D) — не обязателен
var line: Line2D = null        # fallback-визуал — не обязателен

# -------- рабочие объекты --------
var target_body: Node2D = null                      # RigidBody2D или StaticBody2D (якорь)
var pivots: Array[StaticBody2D] = []                # поворотные точки на углах
var joints: Array[DampedSpringJoint2D] = []         # пружины между точками
var active: bool = false
var _pivot_cd: float = 0.0


# Рейкаст с ВКЛЮЧЁННОЙ целью: исключаем только жабу (и по желанию первый pivot),
# чтобы ловить кромку того же коллайдера, на котором стоит якорь.
func _raycast_including_target(from: Vector2, to: Vector2) -> Dictionary:
	var space: PhysicsDirectSpaceState2D = get_world_2d().direct_space_state
	var q := PhysicsRayQueryParameters2D.create(from, to)
	var ex: Array[RID] = []
	# исключаем только жабу (чтобы луч не «втывался» в неё)
	if frog is CollisionObject2D:
		ex.append((frog as CollisionObject2D).get_rid())
	q.exclude = ex
	q.collision_mask = ray_mask
	return space.intersect_ray(q)

# ===== API =====
func setup(_frog: RigidBody2D, _rope: Node, _line: Line2D) -> void:
	frog = _frog
	rope = _rope
	line = _line

	if line:
		line.clear_points()
		line.visible = false
		line.width = 2.0
		line.set_as_top_level(true)      # рисуем по миру
	_rope_set_visible(false)

func fire(target_pos: Vector2) -> void:
	if active:
		return

	var mouth_world: Vector2 = frog.global_position + mouth_offset
	var to_vec: Vector2 = target_pos - mouth_world
	if to_vec.length() > max_length:
		to_vec = to_vec.normalized() * max_length

	var hit: Dictionary = _raycast(mouth_world, mouth_world + to_vec, [frog])
	if hit.is_empty():
		return

	var collider: Object = hit["collider"]
	var pos: Vector2 = hit["position"]

	if collider is RigidBody2D:
		target_body = collider as RigidBody2D
	else:
		var anchor := StaticBody2D.new()
		anchor.global_position = pos
		# якорь не должен мешать последующим рейкастам
		anchor.collision_layer = 0
		anchor.collision_mask = 0
		get_tree().current_scene.add_child(anchor)
		target_body = anchor

	pivots.clear()
	_rebuild_joints()
	active = true
	_pivot_cd = 0.0
	if line: line.visible = true
	_rope_set_visible(true)

func release() -> void:
	if not active:
		return

	for j in joints:
		if is_instance_valid(j): j.queue_free()
	joints.clear()

	for p in pivots:
		if is_instance_valid(p): p.queue_free()
	pivots.clear()

	if is_instance_valid(target_body) and target_body is StaticBody2D:
		target_body.queue_free()
	target_body = null

	active = false
	if line:
		line.clear_points()
		line.visible = false
	_rope_set_visible(false)

func _physics_process(delta: float) -> void:
	if _pivot_cd > 0.0:
		_pivot_cd -= delta

	if not active or not is_instance_valid(target_body):
		return

	_update_wrap_points()

	# подмотка первого сегмента
	if joints.size() > 0:
		joints[0].length = max(0.0, joints[0].length - reel_speed * delta)

	# доптяжка по первому сегменту (равные и противоположные импульсы)
	var pts: PackedVector2Array = _get_points_world()
	if pts.size() >= 2:
		var a: Vector2 = pts[0]
		var b: Vector2 = pts[1]
		var dir: Vector2 = (b - a).normalized()
		frog.apply_central_impulse(dir * pull_force * delta)
		if target_body is RigidBody2D:
			(target_body as RigidBody2D).apply_central_impulse(-dir * pull_force * delta)

	# разрыв при перенатяжении первого сегмента
	if joints.size() > 0 and pts.size() >= 2:
		var t: float = max(0.0, pts[0].distance_to(pts[1]) - joints[0].length)
		if t > break_tension:
			release()
			return

	# обновляем визуал(ы)
	if line:
		line.points = pts
	_rope_set_polyline(pts)

# ===== внутренние функции =====

func _get_points_world() -> PackedVector2Array:
	var arr: PackedVector2Array = PackedVector2Array()
	arr.append(frog.global_position + mouth_offset)
	for p in pivots:
		arr.append(p.global_position)
	arr.append((target_body as Node2D).global_position)
	return arr

func _rebuild_joints() -> void:
	# убираем старые
	for j in joints:
		if is_instance_valid(j): j.queue_free()
	joints.clear()

	# последовательность узлов: рот (жаба) → pivots → цель
	var nodes: Array[Node2D] = []
	nodes.append(frog)
	for p in pivots:
		nodes.append(p)
	nodes.append(target_body)

	# создаём пружину на каждом соседнем отрезке
	for i in range(nodes.size() - 1):
		var a: Node2D = nodes[i]
		var b: Node2D = nodes[i + 1]
		var j: DampedSpringJoint2D = DampedSpringJoint2D.new()
		j.node_a = (a as Node).get_path()
		j.node_b = (b as Node).get_path()
		j.length = a.global_position.distance_to(b.global_position)
		j.stiffness = stiffness
		j.damping = damping
		get_tree().current_scene.add_child(j)
		joints.append(j)

func _raycast(from: Vector2, to: Vector2, exclude_nodes: Array[Node]) -> Dictionary:
	var space: PhysicsDirectSpaceState2D = get_world_2d().direct_space_state
	var q := PhysicsRayQueryParameters2D.create(from, to)
	var ex: Array[RID] = []
	for n in exclude_nodes:
		if n is CollisionObject2D:
			ex.append((n as CollisionObject2D).get_rid())
	q.exclude = ex
	q.collision_mask = ray_mask
	return space.intersect_ray(q)

func _update_wrap_points() -> void:
	# откуда идём: рот или первый pivot
	var a_point: Vector2
	if pivots.size() > 0:
		a_point = pivots[0].global_position
	else:
		a_point = frog.global_position + mouth_offset

	# куда хотим: следующий pivot или цель
	var b_node: Node2D
	if pivots.size() > 0:
		if pivots.size() > 1:
			b_node = pivots[1]
		else:
			b_node = target_body
	else:
		b_node = target_body

	# если A→B перекрыт стеной → вставляем pivot в точке касания (с анти-спамом и мин.дистанцией)
	if _pivot_cd <= 0.0:
		# ВАЖНО: цель НЕ исключаем -> увидим первую кромку того же коллайдера
		var hit: Dictionary = _raycast_including_target(a_point, b_node.global_position)
		if not hit.is_empty():
			var pos: Vector2 = hit["position"]
			# если попали практически в B (1–2 px), считаем, что препятствия нет
			if pos.distance_to(b_node.global_position) <= 2.0:
				pass
			else:
				if pivots.size() == 0 or pos.distance_to(pivots[0].global_position) >= pivot_min_dist:
					var p := StaticBody2D.new()
					p.global_position = pos
					p.collision_layer = 0
					p.collision_mask  = 0
					get_tree().current_scene.add_child(p)
					pivots.insert(0, p)
					_rebuild_joints()
					_pivot_cd = add_pivot_cooldown
					return


	# разматывание: если путь рот→(второй узел после первого) свободен — снимаем ближний pivot
	if pivots.size() > 0:
		var next_after_first: Node2D
		if pivots.size() > 1:
			next_after_first = pivots[1]
		else:
			next_after_first = target_body

		var clear: Dictionary = _raycast(frog.global_position + mouth_offset, next_after_first.global_position, [frog, next_after_first])
		if clear.is_empty():
			# гистерезис: удаляем pivot только если он «почти на прямой»
			var pivot_world: Vector2 = pivots[0].global_position
			var a_world: Vector2 = frog.global_position + mouth_offset
			var b_world: Vector2 = next_after_first.global_position
			if _point_to_segment_dist(pivot_world, a_world, b_world) <= unwrap_hysteresis:
				var first: StaticBody2D = pivots.pop_front()
				if is_instance_valid(first): first.queue_free()
				_rebuild_joints()

# расстояние от точки P до отрезка AB — для гистерезиса
func _point_to_segment_dist(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab: Vector2 = b - a
	var t: float = 0.0
	var ab_len2: float = ab.length_squared()
	if ab_len2 > 0.0:
		t = clamp((p - a).dot(ab) / ab_len2, 0.0, 1.0)
	var proj: Vector2 = a + ab * t
	return p.distance_to(proj)

# ===== RopeSim helpers (визуал) =====
func _rope_set_visible(v: bool) -> void:
	if rope == null:
		return
	if "visible" in rope:
		rope.visible = v
	elif rope.has_method("set_visible"):
		rope.call("set_visible", v)

# Пытаемся прокинуть полилинию в RopeSim независимо от точного API.
func _rope_set_polyline(pts: PackedVector2Array) -> void:
	if rope == null:
		return
	# 1) Метод set_points(points)
	if rope.has_method("set_points"):
		rope.call("set_points", pts)
		return
	# 2) Свойство "points"
	if "points" in rope:
		rope.points = pts
		return
	# 3) Если узел принимает только два конца (start/end)
	if pts.size() >= 2:
		var a := pts[0]
		var b := pts[pts.size() - 1]
		if "start" in rope and "end" in rope:
			rope.start = a; rope.end = b
			return
		if "a" in rope and "b" in rope:
			rope.a = a; rope.b = b
			return
