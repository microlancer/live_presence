@tool
class_name LivePresence
extends EditorPlugin

var _session_id := "session_" + str(randi() % 10000)
var _last_hash := 0
var _diff_timer := Timer.new()
var _branch: String = ""
var _username: String = ""
var _password: String = ""
var _diff_check_seconds: int = 60
var _server: String = ""
var _socket: WebSocketPeer
var _connect_timer := Timer.new()
var _edited_files: Dictionary = {}
var _res_root: String = ""
var _debug: bool = false

func _print(v: Variant) -> void:
	if _debug:
		print(v)

func _read_configs():
	var cfg = ConfigFile.new()
	cfg.load("res://addons/live_presence/plugin.cfg")
	_branch = cfg.get_value("plugin", "branch")
	_username = cfg.get_value("plugin", "username")
	_password = cfg.get_value("plugin", "password")
	_server = cfg.get_value("plugin", "server")
	_diff_check_seconds = cfg.get_value("plugin", "diff_check_seconds")
	_res_root = cfg.get_value("plugin", "res_root")

var _message_sent: bool = false
var _script_editor: ScriptEditor

func _process(_delta):

	if !_socket:
		return

	_socket.poll()

	if _socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		if not _message_sent:
			_socket.send_text("[\"Ping\"]")
			_message_sent = true

	while _socket.get_available_packet_count() > 0:
		var pkt = _socket.get_packet()
		var text = pkt.get_string_from_utf8()
		_print("packet data Received:" + text)
		_clear_editor_overlay()
		_received_text(text)

	if _socket.get_ready_state() == WebSocketPeer.STATE_CLOSED:
		_print("Connection closed.")
		_try_to_connect()
		set_process(false)

func _enter_tree():
	_print("Started LivePresence plugin")
	_read_configs()

	if _server == "":
		print("No server defined in config.")
		return

	_socket = WebSocketPeer.new()
	_try_to_connect()

	var editor: EditorInterface = get_editor_interface()
	_script_editor = editor.get_script_editor()
	_script_editor.script_changed.connect(_something_changed)
	_script_editor.editor_script_changed.connect(_changed_tabs)
	var filesystem: EditorFileSystem = editor.get_resource_filesystem()
	filesystem.filesystem_changed.connect(_something_changed)

	_print("Diff check every " + str(_diff_check_seconds) + " seconds")
	_diff_timer.wait_time = _diff_check_seconds
	_diff_timer.one_shot = false
	_diff_timer.autostart = true
	add_child(_diff_timer)
	_diff_timer.timeout.connect(_on_diff_timer_timeout)

func _something_changed() -> void:
	_print("script changed")
	_check_diff_and_notify()

func _changed_tabs(script: Script) -> void:
	if script:
		_print("Switched to: " + script.resource_path)
		_print("tab")
		_add_editor_overlay(script)

func _received_text(text: String) -> void:
	_print("Received text: " + text)

	var text_object = JSON.parse_string(text)

	if text_object == null or not "files" in text_object or text_object.files is not Array:
		_print("Not an array, ignored")
		return

	if text_object.username == _username:
		_print("Ignore update from self, can happen after reconnecting.")
		return

	# First, remove all files with the username associated that are not
	# in the _edited_files cache, but not in the new payload. This indicates
	# that the person stopped editing the file.

	for file in _edited_files:
		if file not in text_object.files:
			var users = _edited_files[file]
			_print(text_object.username + " stopped editing the file: " + file)
			users.erase(text_object.username)
			if users.size() > 0:
				_edited_files[file] = users
			else:
				# no need to track anymore
				_edited_files.erase(file)

	# Second, update the dictionary and add the user by file if necessary

	for file in text_object.files:
		if file not in _edited_files:
			_print(text_object.username + " started editing the file: " + file)
			_edited_files[file] = [text_object.username]
		else:
			var users = _edited_files[file]
			if text_object.username not in users:
				_print(text_object.username + " started editing the file: " + file)
				users.append(text_object.username)
				_edited_files[file] = users
			else:
				_print("already on the list")

	_print(_edited_files)

	# pretend changing tabs to update current editor
	_changed_tabs(_script_editor.get_current_script())

func _on_diff_timer_timeout():
	_print("diff timer")
	_check_diff_and_notify()

func _get_git_diff_hash() -> int:
	_print(_edited_files)
	_print("Running git diff against: " + _branch)
	var args = ["diff", _branch]
	var output = []
	var exit_code = OS.execute("git", args, output, true)
	if exit_code != 0:
		push_error("Git diff failed: %s" % output)
		return 0
	return hash(output)

func _get_git_diff_files() -> Array:
	_print("Running git diff (name only) against: " + _branch)
	var args = ["diff", "--name-only", _branch]
	var output = []
	var exit_code = OS.execute("git", args, output, true)
	if exit_code != 0:
		push_error("Git diff failed: %s" % output)
		return []
	var result = output[0].strip_edges()
	if result == "":
		return []
	return result.split("\n")

func _get_hash(files: Array) -> int:
	return hash("".join(files))

func _check_diff_and_notify():
	_print("Performing git diff against " + _branch)
	var hash: int = _get_git_diff_hash()
	if hash != _last_hash:
		_print("Hash changed: " + str(hash) + " Old: " + str(_last_hash))
		_last_hash = hash
		var files_to_report = _get_git_diff_files()
		_notify_server(files_to_report)
	else:
		_print("No changes")

func _start_reconnect_attempts() -> void:
	_connect_timer.wait_time = 5
	_connect_timer.one_shot = false
	_connect_timer.autostart = true
	_connect_timer.timeout.connect(_try_to_connect)
	add_child(_connect_timer)

func _notify_server(files: Array) -> void:
	_print("notify server")

	var data := {
		"username": _username,
		"session_id": _session_id,
		"files": files
	}
	var json_string := JSON.stringify(data)

	if _socket.get_ready_state() != _socket.STATE_OPEN:
		_print("Not connected to LivePresence server. Attempting to connect again.")
		_start_reconnect_attempts()

	else:
		print("Socket looks good, sending.")
		var err: Error = _socket.send_text(json_string)
		print("Got: " + str(err))

func _try_to_connect() -> void:
	_print("Trying to connect")
	if _socket.get_ready_state() != _socket.STATE_OPEN:
		var err = _socket.connect_to_url(_server)
		if err != OK:
			print("Unable to connect to server at: " + _server)
			set_process(false)
			return
		else:
			await get_tree().create_timer(5).timeout  # wait a bit for connection
			_socket.send_text("[\"Ping\"]")
			print("Connected to LivePresence server at: " + _server)
			_connect_timer.stop()
	else:
		_print("Already open")

func _clear_editor_overlay() -> void:
	var script_editor := get_editor_interface().get_script_editor()
	var parent = script_editor.get_current_editor().get_base_editor()
	for child in parent.get_children():
		if child is Panel:
			child.queue_free()

func _add_editor_overlay(script: Script) -> void:
	_print("Adding editor overlay: " + script.resource_path)
	var script_editor := get_editor_interface().get_script_editor()
	var parent = script_editor.get_current_editor().get_base_editor()

	await get_tree().process_frame

	# Clear any previous labels
	for child in parent.get_children():
		if child is Panel:
			child.queue_free()

	var path: String = script.resource_path.trim_prefix("res://")
	if _res_root != "":
		path = _res_root + path
	if path in _edited_files:
		_print("Being edited by someone else: " + path)
	else:
		_print("Not being edited by anyone else: " + path)
		return

	var label := Label.new()
	if _edited_files[path].size() == 1:
		label.text = "✏️ " + _edited_files[path][0] + " is editing"
	else:
		label.text = "✏️ " + " and ".join(_edited_files[path]) + " are editing"
	label.name = "LiveEditors"
	label.self_modulate = Color.ORANGE_RED
	label.add_theme_color_override("font_color", Color.BLACK)
	label.self_modulate.a = 1.0#Color(255, 255, 255, 0.2)

	var panel := Panel.new()
	var stylebox: StyleBox = StyleBoxFlat.new()
	stylebox.bg_color = Color.YELLOW
	stylebox.set_corner_radius_all(10)
	stylebox.set_border_width_all(0)
	panel.add_theme_stylebox_override("panel", stylebox)
	panel.add_child(label)
	panel.size.x = label.get_minimum_size().x
	panel.size.y = label.get_minimum_size().y + 4
	panel.position.x = parent.size.x - panel.size.x
	panel.modulate.a = 0.65
	parent.add_child(panel)
