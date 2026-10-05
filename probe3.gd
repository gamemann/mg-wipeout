extends Node
const WoConfig := preload("res://game/wo_config.gd")
const WoGame := preload("res://game/wo_game.gd")
func _ready():
	DotLog.set_level(DotLog.Level.ERROR)
	var c := WoConfig.new(); c.warmup_seconds = 0; c.countdown_seconds = 0.5; c.minimum_players = 0; c.keep_progress = false
	c.course_ids = PackedStringArray(["wo_first_splash"])
	var g := WoGame.new(); g.config = c; g.register_service = false; add_child(g); g.set_physics_process(false)
	await get_tree().physics_frame; await get_tree().physics_frame
	var p := g.add_player(&"u1", "A"); var _o := g.add_player(&"u2", "B")
	g.start()
	var mover: Dictionary
	for piece in g.stage.pieces:
		if piece["kind"] == "mover": mover = piece
	var spec: Dictionary = mover["spec"]
	for i in 60: g.simulate(1.0/64)
	var top := (spec["from"] as Vector3) + Vector3(0, 0.35, 0)
	# pose at a tick where mover is at from
	var period_ticks := int(float(spec["period"]) * 64)
	g._tick = (g._tick / period_ticks + 1) * period_ticks - 1
	g.stage.pose_at(g._tick + 1)
	p.place_at(top + Vector3(0, 0, -0.5), 0)
	for i in 200:
		var cmd := DotFpsCommand.new(); p.controller.apply_command(cmd)
		g.simulate(1.0/64)
		if i % 16 == 0:
			var st := p.controller.state
			var found = g.stage._by_collider.get(st.ground_id)
			var mz := g.stage.transform_of(mover, float(g._tick)/64.0).origin.z
			print("i=%d mode=%d ground=%s mover_z=%.2f bot_z=%.2f y=%.2f carry=%s" % [i, st.mode, found, mz, st.position.z, st.position.y, g.stage.carry(st.ground_id, st.position, g._tick)])
	get_tree().quit()
