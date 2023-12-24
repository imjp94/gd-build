static func parse_export_presets(path):
	var export_presets_config = ConfigFile.new()
	var result = export_presets_config.load(path)
	if result != OK:
		printerr("Failed to load export_presets.cfg(%d)" % result)
		return

	var sections = {}
	for section in export_presets_config.get_sections():
		var section_value = {}
		for section_key in export_presets_config.get_section_keys(section):
			section_value[section_key] = export_presets_config.get_value(section, section_key)
		sections[section] = section_value

	return sections

static func execute(cwd, command, logger=null, blocking=true, output=[], read_stderr=false):
	var cmd = "cd %s && %s" % [cwd, command]
	# NOTE: OS.execute() seems to ignore read_stderr
	var exit = FAILED
	match OS.get_name():
		"Windows":
			cmd = cmd if read_stderr else "%s 2> nul" % cmd
			if logger:
				logger.debug("Execute \"%s\"" % cmd)
			exit = OS.execute("cmd", ["/C", cmd], blocking, output, read_stderr)
		"X11", "OSX", "Server":
			cmd = cmd if read_stderr else "%s 2>/dev/null" % cmd
			if logger:
				logger.debug("Execute \"%s\"" % cmd)
			exit = OS.execute("bash", ["-c", cmd], blocking, output, read_stderr)
		var unhandled_os:
			if logger:
				logger.error("Unexpected OS: %s" % unhandled_os)
	if logger:
		logger.debug("Execution ended(code:%d): %s" % [exit, output])
	return exit	

## Stopwatch utility that support counting multiple time
class Stopwatch extends Reference:
	var _start_timestamps = []

	func start():
		var timestamp = Time.get_ticks_msec()
		_start_timestamps.push_back(timestamp)
		return timestamp

	func stop():
		var start_timestamp = _start_timestamps.pop_back()
		var timestamp = Time.get_ticks_msec()
		if start_timestamp:
			return timestamp - start_timestamp
		return 0

	func reset():
		_start_timestamps.clear()

	func size():
		return _start_timestamps.size()
