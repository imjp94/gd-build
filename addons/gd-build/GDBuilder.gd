const _Utils = preload("Utils.gd")

signal build_started(contexts)
signal build_ended(contexts, results)
signal pre_build(context)
signal post_build(context, result)

const PLATFORM_ANDROID = "Android"
const PLATFORM_HTML5 = "HTML5"
const PLATFORM_IOS = "iOS"
const PLATFORM_LINUX = "Linux/X11"
const PLATFORM_MAC = "Mac OSX" 
const PLATFORM_UWP = "UWP"
const PLATFORM_WINDOWS = "Windows Desktop"
const ALL_PLATFORMS = [
	PLATFORM_ANDROID, PLATFORM_HTML5, PLATFORM_IOS, PLATFORM_LINUX, PLATFORM_MAC, PLATFORM_UWP, PLATFORM_WINDOWS
]

var logger
var dir_access = Directory.new()
var stopwatch = _Utils.Stopwatch.new()


func _init(p_logger):
	logger = p_logger

func build(export_presets, include_platforms):
	var sections = []
	# Filter export & Remove {SECTION_NAME}.option
	for section in export_presets.keys():
		if "options" in section:
			continue
		
		var export_preset = export_presets[section]
		var name = export_preset.get("name", "")
		var platform = export_preset.get("platform", null)
		var export_path = export_preset.get("export_path", null)
		var is_valid = validate_export_preset(export_preset)
		if not is_valid:
			logger.info("Skip %s from %s due to invalid setting, run \"status\" command to check issues" % [name, platform])
			continue
		if not (platform in include_platforms):
			logger.info("Skip %s from %s as not included" % [name, platform])
			continue
		sections.append(section)

	var build_contexts = {}
	for section in sections:
		var export_preset = export_presets[section]
		var name = export_preset.get("name", null)
		var platform = export_preset.get("platform", null)
		var runnable = export_preset.get("runnable", false)
		var export_path = export_preset.get("export_path", null)

		build_contexts[section] = {
			"name": name,
			"section": section,
			"platform": platform,
			"runnable": runnable,
			"export_path": export_path,
			"export_preset": export_preset.duplicate()
		}

	emit_signal("build_started", build_contexts.duplicate())
	var build_results = {}
	var build_count = 0
	for section in sections:
		build_count += 1
		logger.info("%d/%d" % [build_count, sections.size()])
		var dry_run = OS.get_environment("DRY_RUN") == "true"
		var export_preset = export_presets[section]
		var name = export_preset.get("name", null)
		var runnable = export_preset.get("runnable", false)
		var export_path = export_preset.get("export_path", null)

		if dry_run:
			logger.info("[TEST]")
		
		var cmd = "godot --no-window --quiet %s\"%s\""
		if runnable:
			var export_debug = OS.get_environment("EXPORT_DEBUG") == "true"
			cmd = cmd % ["--export-debug " if export_debug else "--export ", name]
			logger.info("Exporting [%s]%s..." % [name, "(Debug)" if export_debug else ""])
		else:
			var export_debug = OS.get_environment("EXPORT_DEBUG") == "true"
			cmd = cmd % ["--export-debug " if export_debug else "--export-pack ", name]
			logger.info("Packing [%s]%s..." % [name, "(Debug)" if export_debug else ""])

		var export_dir = export_path.trim_suffix(export_path.get_file())
		if not dir_access.dir_exists(export_dir):
			logger.info("Make directory %s" % export_dir)
			dir_access.make_dir_recursive(export_dir)

		var build_context = build_contexts[section]
		emit_signal("pre_build", build_context.duplicate())

		stopwatch.start()
		var result = FAILED
		if not dry_run:
			result = _Utils.execute(ProjectSettings.globalize_path("res://"), cmd, logger)
		else:
			result = OK
		
		if result == OK:
			var export_debug = OS.get_environment("EXPORT_DEBUG") == "true"
			if runnable:
				logger.info("/ Successfully export [%s]%s to \"%s\"" % [name, "(Debug)" if export_debug else "", export_path])
			else:
				logger.info("/ Successfully packed [%s]%s to \"%s\"" % [name, "(Debug)" if export_debug else "", export_path])
		else:
			logger.info("X Failed to export %s, code(%d)" % [name, result])
		logger.info("Elapsed %.3fs" % (stopwatch.stop() / 1000.0))
		
		build_results[section] = result
		emit_signal("post_build", build_context.duplicate(), result)
		logger.info("")
	emit_signal("build_ended", build_contexts.duplicate(), build_results.duplicate())
	return {"build_contexts": build_contexts, "build_results": build_results}

static func platform_alias_to_key(v):
	match v:
		PLATFORM_ANDROID, "android":
			return PLATFORM_ANDROID
		PLATFORM_HTML5, "html", "html5":
			return PLATFORM_HTML5
		PLATFORM_IOS, "ios":
			return PLATFORM_IOS
		PLATFORM_LINUX, "linux", "x11":
			return PLATFORM_LINUX
		PLATFORM_MAC, "mac":
			return PLATFORM_MAC
		PLATFORM_UWP, "uwp":
			return PLATFORM_UWP
		PLATFORM_WINDOWS, "window", "windows":
			return PLATFORM_WINDOWS
		_:
			return ""

static func get_env_platforms():
	var platforms_env = OS.get_environment("PLATFORMS").split(",", false)
	var included_platforms = []
	for platform_name in platforms_env:
		var platform = platform_alias_to_key(platform_name)
		if platform:
			included_platforms.append(platform)
	if included_platforms.size() == 0:
		included_platforms = ALL_PLATFORMS.duplicate()
	return included_platforms

static func get_export_presets_platforms(export_presets):
	var platforms = []
	for section in export_presets:
		if section.ends_with("options"):
			continue
		
		var export_preset = export_presets[section]
		var platform = export_preset.get("platform", "")
		
		if not (platform in platforms):
			platforms.append(platform)
	return platforms

static func is_all_platforms_included(targeting_platforms, platforms):
	if targeting_platforms.size() > platforms.size():
		return false

	for platform in targeting_platforms:
		if not (platform in platforms):
			return false

	return true

static func validate_env_platforms():
	var is_valid = true
	var platforms_env = OS.get_environment("PLATFORMS").split(",", false)
	for platform_name in platforms_env:
		var platform = platform_alias_to_key(platform_name)
		is_valid = is_valid and not platform.empty()
	return is_valid

static func validate_export_preset(export_preset, logger=null):
	var name = export_preset.get("name", "")
	var export_path = export_preset.get("export_path", "")

	var is_export_path_defined = not export_path.empty()
	var is_export_path_valid = export_path.get_file().is_valid_filename() and not (export_path.get_extension()).empty()
	var is_valid = is_export_path_defined and is_export_path_valid
	if not is_valid and logger:
		if not is_export_path_defined:
			logger.info("! Undefined \"export_path\"")
		if not is_export_path_valid:
			logger.info("! Invalid \"export_path\" filename \"%s\"" % export_path)
	return is_valid
