## HDA Library Management Control
## Manages available HDA libraries in Houdini and cached libraries for HEGo
@tool
extends Control

const CACHE_FILE_PATH = "res://hego_library.json"

@onready var available_tree: Tree = %AvailableTree
@onready var cached_tree: Tree = %CachedTree
@onready var add_button: Button = %Add
@onready var remove_button: Button = %Remove
@onready var scan_button: Button = %ScanButton


# Storage for cached libraries (persisted across sessions)
var cached_libraries: Dictionary = {}
var available_libraries: Dictionary = {}


func _ready():
	add_button.pressed.connect(_on_add_button_pressed)
	remove_button.pressed.connect(_on_remove_button_pressed)
	scan_button.pressed.connect(_on_scan_button_pressed)
	
	# Load cached libraries from file
	_load_cached_libraries()
	
	# Refresh available libraries when session becomes active
	_refresh_available_libraries()
	_refresh_cached_libraries()


func _refresh_available_libraries():
	available_tree.clear()
	available_libraries.clear()
	
	if not HEGoAPI.get_singleton().is_session_active():
		return
	
	# Get all HDA libraries and organize by directory
	var libraries = HEGoAPI.get_singleton().get_hda_libraries()
	available_libraries = libraries
	
	# Organize libraries by directory for tree structure
	var directories = {}
	for library_name in libraries.keys():
		var library_data = libraries[library_name]
		var file_path = library_data.get("file_path", "")
		
		# Extract directory from file path with better context
		var directory = ""
		if file_path != "":
			directory = _get_readable_directory_name(file_path.get_base_dir())
		else:
			directory = "Unknown Location"
		
		if not directories.has(directory):
			directories[directory] = []
		directories[directory].append({
			"name": library_name,
			"data": library_data
		})
	
	var root = available_tree.create_item()
	
	# Create directory-based tree structure
	for directory in directories.keys():
		var dir_item = available_tree.create_item(root)
		var libs_in_dir = directories[directory]
		
		# Set directory name with total asset count
		var total_assets = 0
		for lib in libs_in_dir:
			total_assets += lib.data.get("asset_count", 0)
		
		dir_item.set_text(0, directory + " (" + str(libs_in_dir.size()) + " libs, " + str(total_assets) + " assets)")
		dir_item.set_metadata(0, {
			"type": "directory",
			"directory": directory,
			"libraries": libs_in_dir
		})
		
		# Start collapsed
		dir_item.collapsed = true
		
		# Add libraries as children
		for lib in libs_in_dir:
			var library_item = available_tree.create_item(dir_item)
			var library_name = lib.name
			var library_data = lib.data
			
			# Set library name and metadata
			library_item.set_text(0, library_name + " (" + str(library_data.asset_count) + " assets)")
			library_item.set_metadata(0, {
				"type": "library",
				"library_name": library_name,
				"data": library_data
			})
			
			# Start collapsed
			library_item.collapsed = true
			
			# Add assets as children
			var assets = library_data.get("assets", [])
			for asset_name in assets:
				var asset_item = available_tree.create_item(library_item)
				asset_item.set_text(0, asset_name)
				asset_item.set_metadata(0, {
					"type": "asset",
					"library_name": library_name,
					"asset_name": asset_name
				})

func _refresh_cached_libraries():
	cached_tree.clear()
	
	# Organize cached libraries by directory too
	var directories = {}
	for library_name in cached_libraries.keys():
		var library_data = cached_libraries[library_name]
		var file_path = library_data.get("file_path", "")
		
		# Extract directory from file path with better context
		var directory = ""
		if file_path != "":
			directory = _get_readable_directory_name(file_path.get_base_dir())
		else:
			directory = "📁 Unknown Location"
		
		if not directories.has(directory):
			directories[directory] = []
		directories[directory].append({
			"name": library_name,
			"data": library_data
		})
	
	var root = cached_tree.create_item()
	
	# Create directory-based tree structure for cached libraries
	for directory in directories.keys():
		var dir_item = cached_tree.create_item(root)
		var libs_in_dir = directories[directory]
		
		# Set directory name with total asset count
		var total_assets = 0
		for lib in libs_in_dir:
			total_assets += lib.data.get("assets", []).size()
		
		dir_item.set_text(0, directory + " (" + str(libs_in_dir.size()) + " libs, " + str(total_assets) + " assets)")
		dir_item.set_metadata(0, {
			"type": "directory",
			"directory": directory,
			"libraries": libs_in_dir
		})
		
		# Start collapsed
		dir_item.collapsed = true
		
		# Add libraries as children
		for lib in libs_in_dir:
			var library_item = cached_tree.create_item(dir_item)
			var library_name = lib.name
			var library_data = lib.data
			
			# Set library name and metadata
			library_item.set_text(0, library_name + " (" + str(library_data.get("assets", []).size()) + " assets)")
			library_item.set_metadata(0, {
				"type": "library",
				"library_name": library_name,
				"data": library_data
			})
			
			# Start collapsed
			library_item.collapsed = true
			
			# Add assets as children
			var assets = library_data.get("assets", [])
			for asset_name in assets:
				var asset_item = cached_tree.create_item(library_item)
				asset_item.set_text(0, asset_name)
				asset_item.set_metadata(0, {
					"type": "asset",
					"library_name": library_name,
					"asset_name": asset_name
				})

func _on_add_button_pressed():
	var selected_items = available_tree.get_selected()
	if not selected_items:
		return
	
	var metadata = selected_items.get_metadata(0)
	if not metadata:
		return
	
	if metadata.type == "directory":
		# Add entire directory of libraries
		var libraries = metadata.libraries
		var added_count = 0
		
		for lib in libraries:
			var library_name = lib.name
			var library_data = lib.data
			
			if not cached_libraries.has(library_name):
				cached_libraries[library_name] = {
					"name": library_data.get("name", library_name),
					"file_path": library_data.get("file_path", ""),
					"id": library_data.get("id", -1),
					"asset_count": library_data.get("asset_count", 0),
					"assets": library_data.get("assets", [])
				}
				added_count += 1
		
		print("Added directory to cache: ", metadata.directory, " (", added_count, " new libraries)")
		
	elif metadata.type == "library":
		# Add entire library
		var library_name = metadata.library_name
		var library_data = metadata.data
		
		# Copy library data to cached libraries
		cached_libraries[library_name] = {
			"name": library_data.get("name", library_name),
			"file_path": library_data.get("file_path", ""),
			"id": library_data.get("id", -1),
			"asset_count": library_data.get("asset_count", 0),
			"assets": library_data.get("assets", [])
		}
		
		print("Added library to cache: ", library_name)
		
	elif metadata.type == "asset":
		# Add single asset
		var library_name = metadata.library_name
		var asset_name = metadata.asset_name
		
		# Ensure library exists in cache
		if not cached_libraries.has(library_name):
			if available_libraries.has(library_name):
				var library_data = available_libraries[library_name]
				cached_libraries[library_name] = {
					"name": library_data.get("name", library_name),
					"file_path": library_data.get("file_path", ""),
					"id": library_data.get("id", -1),
					"asset_count": 0,
					"assets": []
				}
		
		# Add asset if not already in cache
		var assets = cached_libraries[library_name].assets
		if not assets.has(asset_name):
			assets.append(asset_name)
			cached_libraries[library_name].asset_count = assets.size()
			print("Added asset to cache: ", library_name, "/", asset_name)
	
	_save_cached_libraries()
	_refresh_cached_libraries()

func _on_remove_button_pressed():
	var selected_items = cached_tree.get_selected()
	if not selected_items:
		return
	
	var metadata = selected_items.get_metadata(0)
	if not metadata:
		return
	
	if metadata.type == "directory":
		# Remove entire directory of libraries
		var libraries = metadata.libraries
		var removed_count = 0
		
		for lib in libraries:
			var library_name = lib.name
			if cached_libraries.has(library_name):
				cached_libraries.erase(library_name)
				removed_count += 1
		
		print("Removed directory from cache: ", metadata.directory, " (", removed_count, " libraries)")
		
	elif metadata.type == "library":
		# Remove entire library
		var library_name = metadata.library_name
		cached_libraries.erase(library_name)
		print("Removed library from cache: ", library_name)
		
	elif metadata.type == "asset":
		# Remove single asset
		var library_name = metadata.library_name
		var asset_name = metadata.asset_name
		
		if cached_libraries.has(library_name):
			var assets = cached_libraries[library_name].assets
			assets.erase(asset_name)
			cached_libraries[library_name].asset_count = assets.size()
			
			# Remove library if no assets remain
			if assets.size() == 0:
				cached_libraries.erase(library_name)
			
			print("Removed asset from cache: ", library_name, "/", asset_name)
	
	_save_cached_libraries()
	_refresh_cached_libraries()

func _load_cached_libraries():
	var file = FileAccess.open(CACHE_FILE_PATH, FileAccess.READ)
	if file:
		var json_string = file.get_as_text()
		file.close()
		
		var json = JSON.new()
		var parse_result = json.parse(json_string)
		if parse_result == OK:
			cached_libraries = json.data
			print("Loaded cached libraries: ", cached_libraries.keys())
		else:
			print("Failed to parse cached libraries JSON")
	else:
		print("No cached libraries file found, starting fresh")

func _save_cached_libraries():
	var file = FileAccess.open(CACHE_FILE_PATH, FileAccess.WRITE)
	if file:
		var json_string = JSON.stringify(cached_libraries)
		file.store_string(json_string)
		file.close()
		print("Saved cached libraries")
	else:
		print("Failed to save cached libraries")

# Get cached libraries for use by other systems (like asset pickers)
func get_cached_libraries() -> Dictionary:
	return cached_libraries

# Get all available assets from cached libraries as a flat array
func get_cached_assets() -> PackedStringArray:
	var assets = PackedStringArray()
	for library_name in cached_libraries.keys():
		var library_data = cached_libraries[library_name]
		var library_assets = library_data.get("assets", [])
		for asset in library_assets:
			# Use SOP format for compatibility with existing HDA system
			var sop_name = "Sop/" + asset if not asset.contains("/") else asset
			assets.append(sop_name)
	return assets

# Get assets organized by library
func get_cached_assets_by_library() -> Dictionary:
	var result = {}
	for library_name in cached_libraries.keys():
		var library_data = cached_libraries[library_name]
		var library_assets = library_data.get("assets", [])
		var formatted_assets = []
		for asset in library_assets:
			var sop_name = "Sop/" + asset if not asset.contains("/") else asset
			formatted_assets.append(sop_name)
		result[library_name] = formatted_assets
	return result

func _get_readable_directory_name(full_path: String) -> String:
	# Convert backslashes to forward slashes for consistency
	var normalized_path = full_path.replace("\\", "/")
	var path_parts = normalized_path.split("/")
	
	# Check for common patterns and make them more readable
	if normalized_path.contains("/Documents/"):
		# User Documents folder
		var docs_index = -1
		for i in range(path_parts.size()):
			if path_parts[i] == "Documents":
				docs_index = i
				break
		
		if docs_index >= 0 and docs_index < path_parts.size() - 1:
			var remaining_parts = path_parts.slice(docs_index + 1)
			return "📄 Documents/" + "/".join(remaining_parts)
	
	elif normalized_path.contains("/Desktop/"):
		# User Desktop folder
		var desktop_index = -1
		for i in range(path_parts.size()):
			if path_parts[i] == "Desktop":
				desktop_index = i
				break
		
		if desktop_index >= 0:
			var remaining_parts = path_parts.slice(desktop_index)
			return "🖥️ " + "/".join(remaining_parts)
	
	elif normalized_path.to_lower().contains("program files") and normalized_path.to_lower().contains("houdini"):
		# Houdini installation directory
		return "🏠 Houdini Installation"
	
	elif normalized_path.contains("/houdini") and (normalized_path.contains("otls") or normalized_path.contains("hda")):
		# Houdini user preferences
		return "⚙️ Houdini Built-in"
	
	# For package folders, try to identify meaningful parts
	elif path_parts.size() >= 3:
		# Check if it looks like a package structure
		var last_parts = path_parts.slice(-3)
		var package_indicators = ["package", "packages", "project", "assets", "hdas", "otls", "tools", "houdini"]
		
		for part in last_parts:
			if part.to_lower() in package_indicators:
				return "📦 Package/" + "/".join(last_parts)
		
		# Show last 3 parts with drive/root context
		if path_parts.size() > 3:
			var drive = path_parts[0] if path_parts[0].contains(":") else ""
			var display_path = "/".join(last_parts)
			if drive != "":
				return "💾 " + drive + "/.../" + display_path
			else:
				return "📁 .../" + display_path
	
	# Fallback: show the last 2 directories
	if path_parts.size() >= 2:
		var last_parts = path_parts.slice(-2)
		return "📁 " + "/".join(last_parts)
	
	# Final fallback
	return "📁 " + normalized_path

func _on_scan_button_pressed():
	if not HEGoAPI.get_singleton().is_session_active():
		print("Cannot scan HDAs: Session is not active")
		return
	
	print("Refreshing available HDA libraries...")
	_refresh_available_libraries()
	print("Library list refreshed. Use File > Load HDA Library to load additional .hda/.otl files if needed.")

# Collapse all tree items in both panels
func collapse_all():
	_collapse_tree_items(available_tree)
	_collapse_tree_items(cached_tree)

func _collapse_tree_items(tree: Tree):
	var root = tree.get_root()
	if root:
		_collapse_item_recursive(root)

func _collapse_item_recursive(item: TreeItem):
	if item:
		item.collapsed = true
		var child = item.get_first_child()
		while child:
			_collapse_item_recursive(child)
			child = child.get_next()

# Refresh both panels (call this when session state changes)
func refresh_all():
	_refresh_available_libraries()
	_refresh_cached_libraries()
