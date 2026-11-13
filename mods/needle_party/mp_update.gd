extends Node

# The UPDATE NOW button in the panel. Only on a click and never during a session (everyone needs
# the same version). It downloads the release zip from GitHub, checks it, and swaps the mod folder,
# keeping the old one in mods_backup. If anything is wrong the mod stays as it was and the button
# opens the download page instead. The new version runs after the next start of the game.

enum State { IDLE, DOWNLOADING, DONE, FAILED }

const NEW_ZIP := "user://update_new.zip"
const MAX_ZIP := 20 * 1024 * 1024
const MOD_PATH := "mods/needle_party/"
const MIN_FILES := 10

var mp: Node
var state := State.IDLE
var why := ""        # why it failed, for the log
var _http: HTTPRequest = null
var _tag := ""
var _digest := ""


func start(url: String, tag: String, digest: String) -> void:
	if state == State.DOWNLOADING or state == State.DONE or mp.active():
		return
	if url == "":
		_failed("no download address")
		return
	_tag = tag
	_digest = digest
	why = ""
	state = State.DOWNLOADING
	if _http == null:
		_http = HTTPRequest.new()
		_http.use_threads = true
		_http.timeout = 120.0
		_http.max_redirects = 8
		_http.body_size_limit = MAX_ZIP
		_http.download_file = NEW_ZIP
		add_child(_http)
		_http.request_completed.connect(_on_downloaded)
	if _http.request(url, ["User-Agent: NeedleParty-mod"]) != OK:
		_failed("could not start the download")
		return
	mp.ui.refresh()


func _on_downloaded(result: int, code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		_failed("download failed: result %d, http %d" % [result, code])
		return
	var problem := install(NEW_ZIP, _tag, _digest)
	DirAccess.remove_absolute(NEW_ZIP)
	if problem != "":
		_failed(problem)
		return
	state = State.DONE
	print("[MPMod] updated to %s, the new version runs after a restart" % _tag)
	mp.ui.refresh()


func _failed(text: String) -> void:
	state = State.FAILED
	why = text
	print("[MPMod] update failed: %s" % text)
	mp.ui.refresh()


# Returns what went wrong, or "" when the new version is in place.
func install(zip_path: String, tag: String, digest: String) -> String:
	if digest.begins_with("sha256:") and FileAccess.get_sha256(zip_path) != digest.trim_prefix("sha256:"):
		return "the download is damaged"
	var zip := ZIPReader.new()
	if zip.open(zip_path) != OK:
		return "the download is not a zip"
	var game := OS.get_executable_path().get_base_dir()
	var live := game + "/" + MOD_PATH.trim_suffix("/")
	var fresh := live + ".new"
	if not DirAccess.dir_exists_absolute(live):
		zip.close()
		return "the mod folder was not found"
	var found := PackedStringArray()
	var right_version := false
	for inner in zip.get_files():
		# zips made on Windows can have either slash
		var path := str(inner).replace("\\", "/")
		if not path.begins_with(MOD_PATH) or path.ends_with("/") or path.contains(".."):
			continue
		found.append(inner)
		if path == MOD_PATH + "mp.gd":
			right_version = zip.read_file(inner).get_string_from_utf8().contains('const VERSION := "%s"' % tag)
	if found.size() < MIN_FILES or not right_version:
		zip.close()
		return "the download is not version %s of this mod" % tag
	_remove_tree(fresh)
	for inner in found:
		var path := str(inner).replace("\\", "/")
		var target := fresh + "/" + path.trim_prefix(MOD_PATH)
		if DirAccess.make_dir_recursive_absolute(target.get_base_dir()) != OK:
			zip.close()
			_remove_tree(fresh)
			return "this folder cannot be written"
		var out := FileAccess.open(target, FileAccess.WRITE)
		if out == null:
			zip.close()
			_remove_tree(fresh)
			return "this folder cannot be written"
		out.store_buffer(zip.read_file(inner))
		out.close()
	zip.close()
	# the swap: the old one goes to the backup, and comes back if the new one will not go in
	var backups := game + "/mods_backup"
	DirAccess.make_dir_recursive_absolute(backups)
	var kept := "%s/needle_party_%s_%d" % [backups, mp.VERSION, int(Time.get_unix_time_from_system())]
	if DirAccess.rename_absolute(live, kept) != OK:
		_remove_tree(fresh)
		return "the old mod folder cannot be moved"
	if DirAccess.rename_absolute(fresh, live) != OK:
		DirAccess.rename_absolute(kept, live)
		_remove_tree(fresh)
		return "the new mod folder cannot be moved"
	return ""


func _remove_tree(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path):
		return
	for d in DirAccess.get_directories_at(path):
		_remove_tree(path + "/" + d)
	for f in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path + "/" + f)
	DirAccess.remove_absolute(path)
