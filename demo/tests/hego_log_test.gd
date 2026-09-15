extends SceneTree

var failures := 0


func check(condition: bool, what: String) -> void:
	if condition:
		print("  ok   ", what)
	else:
		print("  FAIL ", what)
		failures += 1


func _initialize() -> void:
	var log := HEGoLog.get_singleton()
	check(log != null, "singleton exists")

	# --- basic recording -------------------------------------------------
	log.clear()
	var start := log.get_cursor()
	log.info("test", "hello info")
	log.debug("test", "hello debug")
	log.warning("test", "hello warning")
	log.error("test", "hello error")

	var entries: Array = log.get_entries_since(start)
	check(entries.size() == 4, "4 entries recorded, got %d" % entries.size())
	check(entries[0]["message"] == "hello info", "message round trips")
	check(entries[0]["category"] == "test", "category round trips")
	check(entries[0]["level"] == HEGoLog.LEVEL_INFO, "level round trips")
	check(entries[0]["level_name"] == "INFO", "level name round trips")
	check(str(entries[0]["time"]).length() == 12, "timestamp formatted (HH:MM:SS.mmm)")
	check(log.get_cursor() == start + 4, "cursor advances by the number of entries")

	# --- cursor only returns what is new ---------------------------------
	var cursor := log.get_cursor()
	log.info("test", "after cursor")
	var new_entries: Array = log.get_entries_since(cursor)
	check(new_entries.size() == 1 and new_entries[0]["message"] == "after cursor", "cursor returns only new entries")

	# --- level filtering --------------------------------------------------
	var warnings: Array = log.get_entries_since(start, HEGoLog.LEVEL_WARNING)
	check(warnings.size() == 2, "min_level filter keeps warning and error, got %d" % warnings.size())

	# --- store level gates recording -------------------------------------
	log.set_store_level(HEGoLog.LEVEL_WARNING)
	cursor = log.get_cursor()
	log.debug("test", "should be dropped")
	log.error("test", "should be kept")
	check(log.get_entries_since(cursor).size() == 1, "entries below the store level are dropped")
	log.set_store_level(HEGoLog.LEVEL_DEBUG)

	# --- categories -------------------------------------------------------
	log.info("other_category", "hi")
	check(log.get_categories().has("test") and log.get_categories().has("other_category"), "categories collected")

	# --- export -----------------------------------------------------------
	var export_path := "user://_hego_log_export_test.log"
	check(log.save_to_file(export_path), "save_to_file reports success")
	var exported := FileAccess.get_file_as_string(export_path)
	check(exported.contains("hello error"), "exported file contains the entries")
	check(exported.contains("[ERROR]"), "exported file contains the level")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(export_path))

	# --- file logging + rotation -----------------------------------------
	var log_dir := "user://_hego_log_test"
	var globalized_dir := ProjectSettings.globalize_path(log_dir)
	if DirAccess.dir_exists_absolute(globalized_dir):
		for f in DirAccess.get_files_at(globalized_dir):
			DirAccess.remove_absolute(globalized_dir.path_join(f))

	ProjectSettings.set_setting("hego/logging/enable_file_logging", true)
	ProjectSettings.set_setting("hego/logging/log_path", log_dir + "/hego.log")
	ProjectSettings.set_setting("hego/logging/max_log_files", 3)

	# Each configure() opens a new session log; the timestamp has a one second
	# resolution, so wait between them to get distinct names.
	for i in range(5):
		log.configure()
		log.info("test", "session %d" % i)
		check(FileAccess.file_exists(log.get_log_file_path()), "session %d wrote a log file" % i)
		OS.delay_msec(1100)

	var files := DirAccess.get_files_at(globalized_dir)
	check(files.size() == 3, "keeps max_log_files (3) session logs, found %d" % files.size())

	var newest := FileAccess.get_file_as_string(log.get_log_file_path())
	check(newest.contains("session 4"), "the newest log holds the newest entries")
	check(newest.contains("[test]"), "log file lines carry the category")

	# --- turning it back off ---------------------------------------------
	ProjectSettings.set_setting("hego/logging/enable_file_logging", false)
	log.configure()
	check(log.get_log_file_path().is_empty(), "no log file when file logging is off")

	for f in DirAccess.get_files_at(globalized_dir):
		DirAccess.remove_absolute(globalized_dir.path_join(f))
	DirAccess.remove_absolute(globalized_dir)

	print("")
	print("failures: ", failures)
	quit(1 if failures > 0 else 0)
