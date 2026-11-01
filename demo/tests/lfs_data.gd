extends RefCounted
## Git LFS detection for test fixtures. The island's cooked layers and material textures are
## LFS objects; a checkout without `git lfs pull` (CI runs with lfs: false) holds pointer
## files instead, which load as nothing. Tests that read that data check here and skip the
## dependent section with a printed note, so the rest of the suite still runs.

const POINTER_PREFIX := "version https://git-lfs.github.com/spec/"
const ISLAND_TEXTURES := "res://island/materials/textures"

static func is_pointer(path: String) -> bool:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null: return false
	return file.get_buffer(POINTER_PREFIX.length()).get_string_from_ascii() == POINTER_PREFIX

## True when the file exists and holds real data rather than an LFS pointer.
static func present(path: String) -> bool:
	return FileAccess.file_exists(path) and not is_pointer(path)

## True when every island material texture is real data.
static func island_textures_present() -> bool:
	var files := DirAccess.get_files_at(ISLAND_TEXTURES)
	if files.is_empty(): return false
	for file in files:
		if file.ends_with(".import") or file.ends_with(".uid"): continue
		if is_pointer(ISLAND_TEXTURES.path_join(file)): return false
	return true
