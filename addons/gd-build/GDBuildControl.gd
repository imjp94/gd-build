const INDEX_DIR = ".gd-build"
const INDEX_FILE_PATH = INDEX_DIR + "/index.cfg"
const INDEX_EXPORT_PRESETS_PATH = INDEX_DIR + "/export_presets.cfg"
const PROJECT_EXPORT_PRESETS_PATH = "res://export_presets.cfg"

const HASH_TYPES = ["none", "md5", "sha256"]

var index_config = ConfigFile.new()
var logger
var dir_access = Directory.new()
var file_access = File.new()


func _init(p_logger):
	logger = p_logger

func index_files(path, index={}):
	var hash_type = OS.get_environment("HASH_TYPE")
	assert(hash_type in HASH_TYPES, "Unexpected hash type %s" % hash_type)

	var dir = Directory.new()
	# Add modified time for project root
	if path == "res://":
		var root_folder_modified_time = file_access.get_modified_time(ProjectSettings.globalize_path(path))
		index[""] = {"modified_time": root_folder_modified_time}
		logger.debug("Index directory %s" % path)
	
	logger.indent()
	if dir.open(path) == OK:
		dir.list_dir_begin(true, true)
		var file_name = dir.get_next()
		while file_name != "":
			var file_path = path.plus_file(file_name)
			var modified_time = file_access.get_modified_time(file_path)
			if dir.current_is_dir():
				# Ignore directory starts with period "."
				if file_name.left(1) == ".":
					file_name = dir.get_next()
					continue
				# Ignore directory with ".gdignore" file
				if dir.file_exists(path.plus_file(file_name).plus_file(".gdignore")):
					file_name = dir.get_next()
					continue

				index[file_name] = {
					"": {"modified_time": modified_time}
				}
				logger.debug("Index directory %s" % file_path)
				index_files(file_path, index[file_name])
			else:
				var file_hash = get_file_hash(file_path, hash_type)
				var file_index = {"modified_time": modified_time}
				index[file_name] = file_index
				if hash_type != "none":
					file_index[hash_type] = file_hash
				logger.debug("Index file %s" % file_name)
			
			file_name = dir.get_next()
	else:
		logger.error("Failed to access path: %s" % path)
	logger.dedent()

	return index

func diff_files(path, index, skip_addition_or_removal=false):
	var hash_type = OS.get_environment("HASH_TYPE")
	assert(hash_type in HASH_TYPES, "Unexpected hash type %s" % hash_type)
	
	var dir = Directory.new()

	var result = {
		"modified": {},
		"added": {},
		"removed": {}
	}

	if path == "res://":
		var root_folder_modified_time = file_access.get_modified_time(ProjectSettings.globalize_path(path))
		skip_addition_or_removal = index[""].modified_time == root_folder_modified_time
	
	if dir.open(path) == OK:
		dir.list_dir_begin(true, true)
		var file_name = dir.get_next()

		# Check if dir/file still exists
		if not skip_addition_or_removal:
			var local_root_index = get_localized_index(index, path)
			if local_root_index: # Directory indexed
				for name in local_root_index.keys():
					var localized_index = local_root_index[name]
					var full_path = path.plus_file(name)
					if localized_index.has(""):
						# Directory
						if not dir.dir_exists(full_path):
							logger.debug("Directory removed %s" % full_path)
							result.removed[full_path] = -1
					else:
						# File
						if full_path == "res://":
							continue
						if full_path.right(full_path.length()-1) == "/":
							continue
						
						if not dir.file_exists(full_path):
							logger.debug("File removed %s" % full_path)
							result.removed[full_path] = -1

		while file_name != "":
			var file_path = path.plus_file(file_name)
			var modified_time = file_access.get_modified_time(file_path)
			var indexed_modified_time = -1
			var localized_index = get_localized_index(index, file_path)
			if dir.current_is_dir():
				indexed_modified_time = localized_index[""].get("modified_time", -1) if localized_index else -1
			else:
				indexed_modified_time = localized_index.get("modified_time", -1) if localized_index else -1
			var is_modified = indexed_modified_time != modified_time
			
			if dir.current_is_dir():
				# Ignore directory starts with period "."
				if file_name.left(1) == ".":
					file_name = dir.get_next()
					continue
				# Ignore directory with ".gdignore" file
				if dir.file_exists(path.plus_file(file_name).plus_file(".gdignore")):
					file_name = dir.get_next()
					continue

				var sub_result
				if indexed_modified_time > 0:
					if is_modified:
						logger.debug("Directory modified %s" % file_path)
						result.modified[file_path] = {
							"modified_time": modified_time
						}

					sub_result = diff_files(file_path, index, not is_modified)
				else:
					logger.debug("Directory added %s" % file_path)
					result.added[file_path] = {
						"modified_time": modified_time
					}
					sub_result = diff_files(file_path, index)

				if sub_result:
					result.modified.merge(sub_result.modified)
					result.added.merge(sub_result.added)
					result.removed.merge(sub_result.removed)
			else:
				if indexed_modified_time > 0:
					if is_modified:
						var file_hash = get_file_hash(file_path, hash_type)
						var index_file_hash = localized_index.get(hash_type, "")
						if hash_type != "none":
							is_modified = str(file_hash) != str(index_file_hash)
						
						if is_modified:
							logger.debug("File modified %s" % file_path)
							var file_index = {"modified_time": modified_time}
							result.modified[file_path] = file_index
							if hash_type != "none":
								file_index[hash_type] = file_hash
				else:
					if not skip_addition_or_removal:
						var file_hash = get_file_hash(file_path, hash_type)
						logger.debug("File added %s" % file_path)
						var file_index = {"modified_time": modified_time}
						result.added[file_path] = file_index
						if hash_type != "none":
							file_index[hash_type] = file_hash

			file_name = dir.get_next()
	else:
		logger.error("Failed to access path: %s" % path)

	return result

func filter_export_presets(export_presets, file_paths):
	var included = {}
	for file_path in file_paths:
		logger.debug("Export presets affected by \"%s\"" % file_path)
		logger.indent()
		for section in export_presets.keys():
			if section.ends_with(".options"):
				continue

			var debug = OS.get_environment("DEBUG") == "true"
			if not debug: # Allow checking full list of excluded/included files in debug mode
				if section in included:
					continue
			
			var export_preset = export_presets[section]
			if is_file_in_export_preset(export_preset, file_path):
				included[section] = export_preset
		logger.dedent()
	return included

func is_file_in_export_preset(export_preset, file_path):
	var export_preset_name = export_preset.get("name", "")
	var exclude_filter = export_preset.get("exclude_filter", "")
	var include_filter = export_preset.get("include_filter", "")
	var export_filter = export_preset.get("export_filter", "")
	var export_files = export_preset.get("export_files", [])
	var platform = export_preset.get("platform", null)

	# Check exclusion
	var is_excluded = false
	for exclusion in exclude_filter.split(",", false):
		is_excluded = is_file_name_match(exclusion, file_path)
		break
	if is_excluded:
		logger.debug("(-) [%s] (%s)" % [export_preset_name, platform])
		return false

	# Check export filter
	if export_filter == "all_resources":
		logger.debug("(+) [%s] (%s)" % [export_preset_name, platform])
		return true

	# Check inclusion
	var is_included = false
	for inclusion in include_filter.split(",", false):
		is_included = is_file_name_match(inclusion, file_path)
		break
	if is_included:
		logger.debug("(+) [%s] (%s)" % [export_preset_name, platform])
		return true

	# Check export files
	for export_file in export_files:
		if export_file == file_path: # export_file is always abosulte path to "res://"
			logger.debug("(+) [%s] (%s)" % [export_preset_name, platform])
			return true
	return false

func patch_index(index, diffs):
	var hash_type = OS.get_environment("HASH_TYPE")
	assert(hash_type in HASH_TYPES, "Unexpected hash type %s" % hash_type)

	# Patch removal
	for diff in diffs.removed.keys():
		var localized_index = index
		var dirs = diff.trim_prefix("res://").split("/", false)
		var last_dir = dirs[dirs.size() - 1]
		for folder in dirs:
			if folder == last_dir:
				if folder.get_extension().empty():
					# Directory
					logger.debug("Patch removed directory %s" % diff)
				else:
					# File
					logger.debug("Patch removed file %s" % diff)
				localized_index.erase(folder)
			else:
				localized_index = localized_index.get(folder)
	# Patch modification
	for diff in diffs.modified.keys():
		var localized_index = index
		for folder in diff.trim_prefix("res://").split("/", false):
			if localized_index == null:
				break
			localized_index = localized_index.get(folder)
		
		if localized_index: # Directory indexed
			var updated_index = diffs.modified[diff]
			if localized_index.has(""):
				# Directory
				logger.debug("Patch modified directory %s" % diff)
				localized_index[""] = updated_index
			else:
				# File
				logger.debug("Patch modified file %s" % diff)
				for property in updated_index:
					localized_index[property] = updated_index[property]

				# Remove other hash strings from provided index, since they will be invalid afterwards
				# Assuming there are other hash, as it should only contain "modified_time" & hashes
				if localized_index.size() > 2:
					for property in localized_index.keys():
						if property in HASH_TYPES and property != hash_type:
							localized_index.erase(property)
	# Patch addition
	for diff in diffs.added.keys():
		var localized_index = index
		for folder in diff.trim_prefix("res://").split("/", false):
			if localized_index.has(folder):
				localized_index = localized_index.get(folder)
			else:
				if folder.get_extension().empty():
					# Directory
					logger.debug("Patch added directory %s" % diff)
					localized_index[folder] = {"": diffs.added[diff]}
				else:
					# File
					logger.debug("Patch added file %s" % diff)
					localized_index[folder] = diffs.added[diff]
	
	return index

func cache_project_export_presets(dest):
	dir_access.copy(PROJECT_EXPORT_PRESETS_PATH, dest)

func load_index_config():
	var result = index_config.load(INDEX_FILE_PATH)
	if result == OK:
		logger.debug("Successfully loaded build index config")
	else:
		logger.error("Failed to load build index config(%d)" % result)
	return result

func save_index_config():
	var result = index_config.save(INDEX_FILE_PATH)
	if result == OK:
		logger.debug("Successfully saved build index config")
	else:
		logger.error("Failed to saved build index config(%d)" % result)
	return result

func has_index_config():
	return dir_access.file_exists(INDEX_FILE_PATH)

func get_build_index():
	return index_config.get_value("index", "build")

func update_build_index(build_index):
	index_config.set_value("index", "build", build_index)

func has_build_index():
	if not has_index_config():
		return false
	if not index_config.has_section("index"):
		return false
	if not index_config.has_section_key("index", "build"):
		return false
	
	var build_index = index_config.get_value("index", "build")
	return not build_index.empty()

func is_initial_build():
	return not has_build_index()

func has_project_export_presets_modified():
	var project_export_presets_md5 = file_access.get_md5(PROJECT_EXPORT_PRESETS_PATH)
	var index_export_presets_md5 = file_access.get_md5(INDEX_EXPORT_PRESETS_PATH)
	return project_export_presets_md5 != index_export_presets_md5

## Diffing export presets, return {section: [section_key]}
func diff_export_presets(ep1, ep2): # ep1 suppose to be source
	var diffs = {}
	for section in ep1.get_sections():
		# New section
		if not ep2.has_section(section):
			diffs[section] = []
		for section_key in ep1.get_section_keys(section):
			# New section key
			if not ep2.has_section_key(section, section_key):
				if not diffs.has(section):
					diffs[section] = []
				diffs[section].append(section_key)
				continue
			
			var v1 = ep1.get_value(section, section_key, null)
			var v2 = ep2.get_value(section, section_key, null)
			if v1 != v2:
				if not diffs.has(section):
					diffs[section] = []
				diffs[section].append(section_key)
	return diffs

## Filter export presets diffs, return {section: [section_key]}
func filter_export_presets_diffs(export_presets_diffs):
	for section in export_presets_diffs.keys():
		if section.ends_with(".options"):
			var base_section_name = section.trim_suffix(".options")
			var properties = export_presets_diffs[section]
			if base_section_name in export_presets_diffs:
				for property in properties:
					if property in export_presets_diffs[base_section_name]:
						continue
					export_presets_diffs[base_section_name].append(property)
			else:
				export_presets_diffs[base_section_name] = properties
			export_presets_diffs.erase(section)
			continue
		else:
			export_presets_diffs[section].erase("name")
			continue
		
		if export_presets_diffs[section].size() == 0:
			export_presets_diffs.erase(section)
			continue
	return export_presets_diffs

# Return the leaf node of index tree, based on the path
func get_localized_index(index, path):
	var localized_index = index
	for folder in path.trim_prefix("res://").split("/", false):
		localized_index = localized_index.get(folder)
		if localized_index == null:
			return null

	return localized_index

func get_file_hash(file_path, hash_type):
	match hash_type:
		"md5":
			return file_access.get_md5(file_path)
		"sha256":
			return file_access.get_sha256(file_path)
		"none":
			return ""

func is_file_name_match(template, value):
	if "*" in template:
		# Replace "*"" with ".*.", otherwise it will throw error
		if is_wildcard_match(template.replace("*", ".*."), value):
			return true
	else:
		if template.is_abs_path():
			if template == value:
				return true
		else:
			if is_wildcard_match("." + template, value):
				return true

	return false

func is_wildcard_match(template, value):
	var regex = RegEx.new()
	regex.compile(template)
	var result = regex.search(value)
	return !!result
