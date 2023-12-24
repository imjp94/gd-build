tool
extends SceneTree

const _Utils = preload("Utils.gd")
const _Logger = preload("Logger.gd")
const GDBuildControl = preload("GDBuildControl.gd")
const GDBuilder = preload("GDBuilder.gd")

const VERSION = "0.1.0"

const ENV_DEBUG = "DEBUG"
const ENV_DRY_RUN = "DRY_RUN"
const ENV_EXPORT_DEBUG = "EXPORT_DEBUG"
const ENV_FULL_BUILD = "FULL_BUILD"
const ENV_HASH_TYPE = "HASH_TYPE"
const ENV_PLATFORMS = "PLATFORMS"
const ENV_SILENT = "SILENT"
const ENV_VERBOSE = "VERBOSE"
const ENV_VERSION = "VERSION"

const DEFAULT_USER_BUILD_SCRIPT_PATH = "res://build.gd"
const DEFAULT_BASE_BUILD_SCRIPT_PATH = "res://addons/gd-build/build.gd"
const DEFAULT_HASH_TYPE = "md5"

const INIT_BUILD_SCRIPT = \
"""tool
extends "%s"


# Build process started
func _on_build_started(contexts):
	pass

# Build process ended
func _on_build_ended(contexts, results):
	pass

# Before execution of a build
func _on_pre_build(context):
	pass

# After execution of a build
func _on_post_build(context, result):
	pass
""" % DEFAULT_BASE_BUILD_SCRIPT_PATH

var logger = _Logger.new()
var builder = GDBuilder.new(logger)
var build_control = GDBuildControl.new(logger)

var stopwatch = _Utils.Stopwatch.new()

# Run "godot --no-window -s build.gd" to build. Pass platform names(case-sensitive), otherwise, all preset will be exported.
# Always "export" runnable("Export Project" in editor) and "pack" non-runnable("Export PCK/ZIP" in editor)
# Export will be ignored if "export_path" is not set.
func _initialize():
	OS.set_environment(ENV_VERSION, VERSION)
	OS.set_environment(ENV_HASH_TYPE, DEFAULT_HASH_TYPE)

	# NOTE: "--key" or "-key" will always be consumed by godot executable, see https://github.com/godotengine/godot/issues/8721
	var args = OS.get_cmdline_args()
	logger.debug(args)
	# Trim unwanted args passed to godot executable
	for arg in Array(args):
		args.remove(0)
		if "build.gd" in arg:
			break
	
	for arg in args:
		arg = arg.to_lower()
		if "=" in arg:
			var pair = arg.split("=")
			var key = pair[0]
			var value = pair[1] if pair.size() > 1 else ""
			match key:
				"--debug":
					OS.set_environment(ENV_DEBUG, value)
					value = value == "true"
					if value:
						logger.log_level = _Logger.LogLevel.DEBUG
				"--dry-run":
					OS.set_environment(ENV_DRY_RUN, value)
				"--export-debug":
					OS.set_environment(ENV_EXPORT_DEBUG, value)
				"--full-build":
					OS.set_environment(ENV_FULL_BUILD, value)
				"--hash-type":
					OS.set_environment(ENV_HASH_TYPE, value)
					if not (value in GDBuildControl.HASH_TYPES):
						logger.info("Invalid hash type: %s" % value)
						request_quit()
						return
				"--platforms":
					OS.set_environment(ENV_PLATFORMS, value)
					if not GDBuilder.validate_env_platforms():
						logger.info("Invalid platforms: %s" % value)
						request_quit()
						return
				"--silent":
					OS.set_environment(ENV_SILENT, value)
					value = value == "true"
					if value:
						logger.log_level = _Logger.LogLevel.NONE
				"--verbose":
					OS.set_environment(ENV_VERBOSE, value)
					value = value == "true"
					if value:
						logger.log_format = _Logger.DEFAULT_LOG_FORMAT_DETAIL
			logger.debug("[%s, %s]" % [key, value])
	
	stopwatch.start()
	
	if args.size() > 0:
		match args[0]:
			"build":
				command_build()
			"clear-index":
				command_clear_index()
			"index":
				command_index()
			"init":
				command_init()
			"list-export-presets":
				command_list_export_presets()
			"list-platforms":
				command_list_platforms()
			"status":
				command_status()
			"version":
				logger.info(VERSION)
			_:
				logger.info("Unknown command \"%s\"" % args[0])

	request_quit()

func _finalize():
	logger.info("\nFinished, elapsed %.3fs" % (stopwatch.stop() / 1000.0))

func request_quit(exit_code=-1):
	quit(exit_code)
	return true

func command_build():
	logger.info("Building...")
	var export_presets = _Utils.parse_export_presets(GDBuildControl.PROJECT_EXPORT_PRESETS_PATH)
	var targeting_platforms = GDBuilder.get_export_presets_platforms(export_presets)
	logger.indent()
	var export_debug = OS.get_environment("EXPORT_DEBUG") == "true"
	if export_debug:
		logger.info("Export with Debug")
	var include_platforms = GDBuilder.get_env_platforms()
	logger.info("Included platforms: %s " % str(include_platforms))
	var export_presets_count = export_presets.size() / 2 # Half of them are preset.options
	logger.info("%d export preset%s found" % [export_presets_count, "s" if export_presets_count > 1 else ""]) 
	logger.dedent()
	logger.indent()
	logger.lock()
	if not validate_export_presets(export_presets):
		logger.dedent()
		logger.info("Invalid export settings detected, resolve the issues to continue")
		logger.info("Build terminated")	
		logger.info("")
		return
	logger.unlock()
	logger.dedent()
	logger.info("")

	build_control.load_index_config()
	var build_index = build_control.get_build_index()
	var diff_result = {}
	var build_result = {}
	var is_full_build = OS.get_environment(ENV_FULL_BUILD) == "true"
	logger.indent()
	if build_control.is_initial_build() or is_full_build:
		logger.info("Initial build" if not is_full_build else "Full build")
		logger.indent()
		build_result = builder.build(export_presets, include_platforms)
		logger.dedent()
	else:
		logger.info("Incremental build")
		logger.indent()
		stopwatch.start()
		logger.info("Diffing...")
		diff_result = build_control.diff_files("res://", build_index)
		logger.info("Elapsed %.3fs" % (stopwatch.stop() / 1000.0))
		logger.info("")
		var diffs = Array()
		diffs.append_array(diff_result.modified.keys())
		diffs.append_array(diff_result.added.keys())
		diffs.append_array(diff_result.removed.keys())
		logger.lock()
		var filtered_export_presets = filter_export_presets(export_presets, diffs)
		logger.unlock()

		if filtered_export_presets.size() > 0:
			logger.info("%d export presets to rebuild:" % filtered_export_presets.size())
			logger.indent()
			print_export_presets(filtered_export_presets)
			logger.dedent()
			logger.info("")

			builder.connect("build_started", self, "_on_build_started")
			builder.connect("build_ended", self, "_on_build_ended")
			builder.connect("pre_build", self, "_on_pre_build")
			builder.connect("post_build", self, "_on_post_build")
			
			build_result = builder.build(filtered_export_presets, include_platforms)
		else:
			logger.info("Up to date, nothing to build")
		logger.dedent()
	logger.dedent()

	var build_count = 0 if build_result.empty() else build_result.build_results.size()
	var build_success_count = 0
	var build_fail_count = 0
	
	if build_count > 0:
		for result in build_result.build_results.values():
			if result == OK:
				build_success_count += 1
			else:
				build_fail_count += 1

		# TODO: Support index only successful build
		var is_all_targeting_platforms_included = GDBuilder.is_all_platforms_included(targeting_platforms, GDBuilder.get_env_platforms())
		if is_all_targeting_platforms_included:
			logger.info("Indexing...")
			logger.indent()
			if build_fail_count == 0:
				index(build_index, diff_result)
			else:
				logger.info("Index terminated due to %d failed build" % build_fail_count)
			logger.dedent()
		else:
			logger.info("Skip indexing as not all targeting platforms included")
			logger.indent()
			logger.info("Targeting platforms: %s" % str(targeting_platforms))
			logger.info("Selected platforms: %s" % str(include_platforms))
			logger.dedent()

		logger.info("\nBUILD FINISH: %d" % build_count)
		logger.info("SUCCESS: %d, FAILED: %d" % [build_success_count, build_fail_count])

func command_clear_index():
	logger.info("Clearing index...")

	logger.indent()
	build_control.load_index_config()
	if not build_control.has_build_index():
		logger.info("No index created yet")
		logger.dedent()
		return
	
	build_control.update_build_index({})
	var dry_run = OS.get_environment("DRY_RUN") == "true"
	if not dry_run:
		if build_control.save_index_config() == OK:
			logger.info("Removed build index")
		var dir_access = Directory.new()
		dir_access.remove(GDBuildControl.INDEX_EXPORT_PRESETS_PATH)
		logger.info("Removed export presets cache")
	else:
		logger.info("[TEST]")
		logger.info("Removed build index")
		logger.info("Removed export presets cache")
	logger.dedent()

func command_index():
	logger.info("Indexing...")
	build_control.load_index_config()
	var build_index = build_control.get_build_index()
	var diff_result = {}

	logger.indent()
	index(build_index)
	logger.dedent()

func command_init():
	logger.info("Init gd-build...")
	var file = File.new()
	logger.indent()
	if file.file_exists(DEFAULT_USER_BUILD_SCRIPT_PATH):
		logger.info("%s already exists!" % DEFAULT_USER_BUILD_SCRIPT_PATH)
	else:
		file.open(DEFAULT_USER_BUILD_SCRIPT_PATH, File.WRITE)
		file.store_string(INIT_BUILD_SCRIPT)
		file.close()
		logger.info("Created %s" % DEFAULT_USER_BUILD_SCRIPT_PATH)
	logger.dedent()

func command_list_export_presets():
	var export_presets = _Utils.parse_export_presets(GDBuildControl.PROJECT_EXPORT_PRESETS_PATH)
	var export_presets_count = export_presets.size() / 2 # Half of them are preset.options
	var platforms = []

	logger.info("Export presets(%d):" % export_presets_count)
	logger.indent()
	var is_valid = true
	for section in export_presets:
		if section.ends_with("options"):
			continue
		
		var export_preset = export_presets[section]
		var name = export_preset.get("name", "")
		var runnable = export_preset.get("runnable", false)
		var platform = export_preset.get("platform", "")
		if not (platform in platforms):
			platforms.append(platform)
		
		logger.info("%s [%s] (%s)" % [">" if runnable else "-", name, platform])
		logger.indent()
		var _is_valid = GDBuilder.validate_export_preset(export_preset, logger)
		is_valid = is_valid and _is_valid
		logger.dedent()
	logger.dedent()
	if not is_valid:
		logger.info("! Invalid export presets detected, resolve issues above to build")
	
	logger.info("")
	logger.info("Platforms(%d): %s" % [platforms.size(), str(platforms)])

func command_list_platforms():
	var export_presets = _Utils.parse_export_presets(GDBuildControl.PROJECT_EXPORT_PRESETS_PATH)
	var platforms = {}

	logger.info("Available platforms: %s" % str(builder.ALL_PLATFORMS))
	logger.info("")
	
	for section in export_presets:
		if section.ends_with("options"):
			continue
		
		var export_preset = export_presets[section]
		var platform = export_preset.get("platform", "")
		
		if platform in platforms:
			platforms[platform].append(export_preset)
		else:
			platforms[platform] = [export_preset]

	logger.info("Exporting to platforms(%d): %s" % [platforms.keys().size(), str(platforms.keys())])
	logger.indent()
	for platform in platforms.keys():
		var _export_presets = platforms[platform]
		logger.info("- %s(%d)" % [platform, _export_presets.size()])
		logger.indent()
		for export_preset in _export_presets:
			var name = export_preset.get("name", "")
			var runnable = export_preset.get("runnable", false)
			logger.info("%s [%s]" % [">" if runnable else "-", name])
		logger.dedent()
	logger.dedent()

func command_status():
	var is_initial_build = false
	if not build_control.has_index_config():
		is_initial_build = true
	
	if build_control.load_index_config() != OK:
		is_initial_build = true
	
	var has_build_index = build_control.has_build_index()
	if not has_build_index:
		is_initial_build = true

	var export_presets = _Utils.parse_export_presets(GDBuildControl.PROJECT_EXPORT_PRESETS_PATH)
	var filtered_export_presets = {}
	if not is_initial_build:
		var build_index = build_control.get_build_index()
		stopwatch.start()
		logger.info("Diffing...")
		logger.indent()
		var diff_result = build_control.diff_files("res://", build_index)
		logger.dedent()
		logger.info("Elapsed %.3fs" % (stopwatch.stop() / 1000.0))
		logger.info("")

		var added_count = diff_result.added.size()
		var modified_count = diff_result.modified.size()
		var removed_count = diff_result.removed.size()
		var changed_count = added_count + modified_count + removed_count
		if changed_count > 0:
			logger.info("%d files changed:" % changed_count)
			logger.indent()
			if diff_result.added.size():
				logger.info("- Added(%d) %s" % [added_count, str(diff_result.added.keys())])
			if diff_result.modified.size():
				logger.info("- Modified(%d) %s" % [modified_count, str(diff_result.modified.keys())])
			if diff_result.removed.size():
				logger.info("- Removed(%d) %s" % [removed_count, str(diff_result.removed.keys())])
			logger.dedent()
			logger.info("")
		
		var diffs = Array()
		diffs.append_array(diff_result.modified.keys())
		diffs.append_array(diff_result.added.keys())
		diffs.append_array(diff_result.removed.keys())
		filtered_export_presets = filter_export_presets(export_presets.duplicate(), diffs)

		if filtered_export_presets.size() > 0:
			logger.info("%d export presets to rebuild:" % filtered_export_presets.size())
			logger.indent()
			print_export_presets(filtered_export_presets)
			logger.dedent()
			logger.info("")

	var is_valid = true
	for section in export_presets:
		if section.ends_with("options"):
			continue
		
		var export_preset = export_presets[section]
		var name = export_preset.get("name", "")
		var runnable = export_preset.get("runnable", false)
		var platform = export_preset.get("platform", "")
		logger.lock()
		var _is_valid = GDBuilder.validate_export_preset(export_preset, logger)
		is_valid = is_valid and _is_valid
		logger.unlock()

		if not _is_valid:
			logger.info("%s [%s] (%s)" % [">" if runnable else "-", name, platform])
			logger.indent()
			GDBuilder.validate_export_preset(export_preset, logger)
			logger.dedent()

	if is_valid:
		if is_initial_build:
			logger.info("No build index found, execute \"build\" command to start initial build")
		else:
			if filtered_export_presets.size() > 0:
				logger.info("Build outdated, execute \"build\" command to rebuild")
			else:
				logger.info("Build up to date")
	else:
		logger.info("! Invalid export presets detected, resolve issues above to build")

func filter_export_presets(export_presets, diffs):
	var filtered_export_presets = build_control.filter_export_presets(export_presets.duplicate(), diffs)
	var include_platforms = GDBuilder.get_env_platforms()
	for section in filtered_export_presets.keys():
		var export_preset = filtered_export_presets[section]
		var platform = export_preset.get("platform", null)
		if not (platform in include_platforms):
			filtered_export_presets.erase(section)
	if filtered_export_presets.size() > 0:
		logger.info("%d export presets affected by file changed:" % filtered_export_presets.size())
		logger.indent()
		print_export_presets(filtered_export_presets)
		logger.dedent()
		logger.info("")

	if build_control.has_project_export_presets_modified():
		var project_export_presets_cfg = ConfigFile.new()
		project_export_presets_cfg.load(GDBuildControl.PROJECT_EXPORT_PRESETS_PATH)
		var index_export_presets_cfg = ConfigFile.new()
		index_export_presets_cfg.load(GDBuildControl.INDEX_EXPORT_PRESETS_PATH)
		var export_presets_diffs = build_control.diff_export_presets(project_export_presets_cfg, index_export_presets_cfg)
		var filtered_export_presets_diffs = build_control.filter_export_presets_diffs(export_presets_diffs.duplicate())
		var modified_export_presets = {}

		for section in filtered_export_presets_diffs.keys():
			var export_preset = export_presets[section]
			modified_export_presets[section] = export_preset

		if modified_export_presets.size() > 0:
			logger.info("%d export presets modified:" % modified_export_presets.size())
			logger.indent()
			print_export_presets(modified_export_presets)
			logger.dedent()
			logger.info("")
			for section in modified_export_presets.keys():
				if not (section in filtered_export_presets):
					var export_preset = export_presets[section]
					filtered_export_presets[section] = export_preset

	return filtered_export_presets

func index(build_index, diff_result={}):
	var is_full_build = OS.get_environment(ENV_FULL_BUILD) == "true"
	if build_control.is_initial_build() or is_full_build:
		logger.info("Full index")
		stopwatch.start()
		build_index = build_control.index_files("res://")
		logger.info("Elapsed %.3fs" % (stopwatch.stop() / 1000.0))
	else:
		if diff_result.empty():
			stopwatch.start()
			logger.info("Diffing...")
			diff_result = build_control.diff_files("res://", build_index)
			logger.info("Elapsed %.3fs" % (stopwatch.stop() / 1000.0))

		logger.info("Patch index")
		var patched_build_index = build_control.patch_index(build_index.duplicate(), diff_result)
		if patched_build_index: # In case of error in patching, it will be null
			build_index = patched_build_index
	logger.indent()
	var dry_run = OS.get_environment("DRY_RUN") == "true"
	if not dry_run:
		build_control.update_build_index(build_index)
		build_control.save_index_config()
		build_control.cache_project_export_presets(GDBuildControl.INDEX_EXPORT_PRESETS_PATH)
	else:
		logger.info("[TEST]")
	logger.info("Save index")
	logger.info("Index export presets")
	logger.dedent()

func validate_export_presets(export_presets):
	var is_valid = true
	logger.indent()
	for section in export_presets:
		if section.ends_with("options"):
			continue
		
		var export_preset = export_presets[section]
		var name = export_preset.get("name", "")
		var runnable = export_preset.get("runnable", false)
		var platform = export_preset.get("platform", "")
		logger.info("%s [%s] (%s)" % [">" if runnable else "-", name, platform])
		logger.indent()
		if not GDBuilder.validate_export_preset(export_preset, logger):
			is_valid = false
		logger.dedent()
	logger.dedent()
	return is_valid

func print_export_presets(export_presets):
	for section in export_presets.keys():
		var export_preset = export_presets[section]
		var name = export_preset.get("name", "")
		var runnable = export_preset.get("runnable", false)
		var platform = export_preset.get("platform", "")
		logger.info("%s [%s] (%s)" % [">" if runnable else "-", name, platform])

# Build process started
func _on_build_started(contexts):
	pass

# Build process ended
func _on_build_ended(contexts, results):
	pass

# Before execution of a build
func _on_pre_build(context):
	pass

# After execution of a build
func _on_post_build(context, result):
	pass
