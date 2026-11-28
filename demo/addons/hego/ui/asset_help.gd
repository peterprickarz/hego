@tool
extends RefCounted
## Opens an authored web help URL or creates a local, read-only help page.

const CSS := """
:root{color-scheme:light dark;font:16px/1.55 system-ui,sans-serif}
body{max-width:56rem;margin:3rem auto;padding:0 1.5rem 4rem;overflow-wrap:anywhere}
h1,h2,h3,h4{line-height:1.25;margin-top:1.4em}a{color:LinkText}
pre,code{font-family:ui-monospace,monospace}pre{white-space:pre-wrap;padding:.8em;border:1px solid GrayText}
table{border-collapse:collapse;margin:.75em 0}th,td{border:1px solid GrayText;text-align:start;padding:.3em .65em}
.label,dt{font-weight:600}.parameter,.definition{margin:1em 0}.parameter p,.definition p{margin:.25em 0}
img{max-width:100%;height:auto}.ancestors{font-size:.85em}
.ancestors a+a:before,.ancestors .pathsep:after{content:" › ";color:GrayText}
.title .subtitle{display:block;font-size:1rem;font-weight:400;color:GrayText;margin-top:.25em}
.headerlink{opacity:0;font-size:.7em}h2:hover .headerlink,h3:hover .headerlink,.headerlink:focus-within{opacity:1}
#premeta{font-size:.9rem;border:0}#premeta td{border:0;padding:0 .8em 0 0;vertical-align:top}
#premeta ul,#premeta li,#premeta p{display:inline;margin:0;padding:0}#premeta li a{margin-right:.8em}
"""
const ELEMENTS := ["a", "article", "b", "blockquote", "br", "caption", "code", "dd", "details", "div", "dl",
	"dt", "em", "figcaption", "figure", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "i", "img",
	"kbd", "li", "ol", "p", "pre", "section", "span", "strong", "sub", "summary", "sup", "table", "tbody",
	"td", "th", "thead", "tr", "ul"]
const IGNORE_CONTENT := ["head", "script", "style", "iframe", "object", "svg", "form", "template"]
const DOCS := "https://www.sidefx.com/docs/houdini"


static func open_page(page: Dictionary, can_open: Callable = Callable()) -> Error:
	var url := str(page.get("url", "")).strip_edges()
	if is_web_url(url):
		return _launch(url, can_open)
	if str(page.get("text", "")).strip_edges().is_empty():
		return ERR_UNAVAILABLE
	var hfs := HEGoAPI.get_singleton().get_houdini_installation_path()
	var result := {}
	var tree := Engine.get_main_loop() as SceneTree
	if not tree:
		return ERR_UNAVAILABLE
	var task := WorkerThreadPool.add_task(func(): result.merge(prepare_page(page, hfs)))
	while not WorkerThreadPool.is_task_completed(task):
		await tree.process_frame
	WorkerThreadPool.wait_for_task_completion(task)
	if result.error != OK:
		return result.error
	# An absolute OS path preserves spaces and Unicode without constructing a file URI.
	return _launch(result.path, can_open)


static func _launch(target: String, can_open: Callable) -> Error:
	if not can_open.is_null() and (not can_open.is_valid() or not can_open.call()):
		return ERR_SKIP
	return OS.shell_open(target)


static func is_web_url(value: String) -> bool:
	var pattern := RegEx.create_from_string(r"(?i)^https?://[^/\\?#\s]+(?:[/?#][^\s\\]*)?$")
	return pattern.search(value) != null


## Can run on a worker. Reading help never starts a Houdini session or a web server.
static func prepare_page(page: Dictionary, hfs: String, directory := "user://hego/help") -> Dictionary:
	var source := str(page.get("text", ""))
	if source.strip_edges().is_empty():
		return {"error": ERR_UNAVAILABLE}
	var op := str(page.get("op_name", "HDA"))
	var folder := ProjectSettings.globalize_path(directory)
	var error := DirAccess.make_dir_recursive_absolute(folder)
	if error != OK:
		return {"error": error}
	var path := folder.path_join(("v4\n" + hfs + "\n" + op + "\n" + source).sha256_text() + ".html")
	if FileAccess.file_exists(path):
		return {"error": OK, "path": path}
	var wiki := _wiki_path(op)
	var body := ""
	if source.strip_edges().begins_with("<"):
		body = _safe_html(source, wiki)
	elif not _is_markdown(source):
		body = _native_body(source, wiki, hfs)
	if body.strip_edges().is_empty():
		body = _fallback_body(source, wiki)
	var title := op.xml_escape()
	var html := """<!doctype html><html><head><meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src https:; base-uri 'none'; form-action 'none'">
<meta name="referrer" content="no-referrer"><meta name="viewport" content="width=device-width, initial-scale=1"><title>%s</title><style>%s</style></head><body>%s</body></html>
""" % [title, CSS, body]
	var pending := "%s.%d-%d.tmp" % [path, OS.get_process_id(), Time.get_ticks_usec()]
	var file := FileAccess.open(pending, FileAccess.WRITE)
	if not file:
		return {"error": FileAccess.get_open_error()}
	var written := file.store_string(html)
	file.close()
	if written:
		error = DirAccess.rename_absolute(pending, path)
	else:
		error = ERR_FILE_CANT_WRITE
	if error != OK:
		DirAccess.remove_absolute(pending)
		if FileAccess.file_exists(path):
			error = OK
	return {"error": error, "path": path}


static func _wiki_path(op: String) -> String:
	var parts := op.split("/", true, 1)
	var category := parts[0].to_lower() if parts.size() == 2 else "sop"
	var aliases := {"object": "obj", "driver": "out", "particle": "part", "vopnet": "vex"}
	category = aliases.get(category, category)
	if not category.is_valid_identifier():
		category = "sop"
	var version := RegEx.create_from_string(r"^\d+(?:\.\d+)*$")
	return "/nodes/" + category + "/" + _wiki_filename(parts[-1], version).validate_filename()


## SideFX uses namespace--name-version. A scoped operator prefixes that filename with scope@.
static func _wiki_filename(type_name: String, version_pattern: RegEx) -> String:
	var parts := Array(type_name.split("::"))
	var scope := PackedStringArray()
	while not parts.is_empty():
		var version := ""
		if parts.size() > 1 and version_pattern.search(str(parts.back())):
			version = "-" + str(parts.pop_back())
		var name := str(parts.pop_back()).replace("/", "_")
		var name_prefix := ""
		if not parts.is_empty() and not str(parts.back()).contains("/") and not version_pattern.search(str(parts.back())):
			name_prefix = str(parts.pop_back()).replace(":", "$") + "--"
		scope.insert(0, name_prefix + name + version)
	return "@".join(scope)


static func _is_markdown(source: String) -> bool:
	if source.strip_edges().begins_with("=") or source.contains("\n@parameters"):
		return false
	return RegEx.create_from_string(r"(?m)^\s{0,3}#{1,6}[ \t]+|^\s*\|?[ \t]*:?-{3,}:?[ \t]*\|[ \t]*:?-{3,}").search(source) != null


static func _native_body(source: String, wiki: String, hfs: String) -> String:
	var hhelp := hfs.path_join("bin/hhelp.exe" if OS.get_name() == "Windows" else "bin/hhelp")
	if not hfs.is_absolute_path() or not FileAccess.file_exists(hhelp):
		return ""
	var scratch := DirAccess.create_temp("hego-help")
	if not scratch:
		return ""
	var root := scratch.get_current_dir()
	var docs := root.path_join("docs")
	var text_path := docs + wiki + ".txt"
	if DirAccess.make_dir_recursive_absolute(text_path.get_base_dir()) != OK:
		return ""
	var source_file := FileAccess.open(text_path, FileAccess.WRITE)
	if not source_file or not source_file.store_string(source):
		return ""
	source_file.close()
	var config_path := root.path_join("bookish.cfg")
	var config := FileAccess.open(config_path, FileAccess.WRITE)
	if not config:
		return ""
	# The config is Python. Its only interpolated values are OS-created paths,
	# serialized as quoted strings. Asset text is a separate wiki document.
	# hhelp's html command writes through Python's stdout. Use a UTF-8 file
	# directly, independent of the platform's console code page.
	var rendered := root.path_join("article.html")
	var settings := "EXTRA_DOCUMENTS = [%s]\nCACHE_DIR = %s\nimport sys\nsys.stdout = open(%s, 'w', encoding='utf-8')\n" % [
		JSON.stringify(docs), JSON.stringify(root.path_join("cache")), JSON.stringify(rendered)]
	if not config.store_string(settings):
		return ""
	config.close()
	if OS.execute(hhelp, ["--disablehou", "--config", config_path, "html", wiki]) != 0 or not FileAccess.file_exists(rendered):
		return ""
	var html := FileAccess.get_file_as_string(rendered)
	var start := html.find("<main>")
	var end := html.find("</main>", start + 6) if start >= 0 else -1
	return _safe_html(html.substr(start + 6, end - start - 6), wiki) if end > start else ""


static func _link(target: String, wiki: String) -> String:
	target = target.strip_edges()
	if is_web_url(target) or target.begins_with("#"):
		return target
	if target.begins_with("Node:"):
		target = "/nodes/" + target.trim_prefix("Node:") + ".html"
	if target.is_empty() or target.begins_with("//") or target.contains(":") or target.contains("\\"):
		return ""
	var path := target if target.begins_with("/") else wiki.get_base_dir().path_join(target)
	return DOCS + path.simplify_path()


## Rebuild the article from its semantic elements, dropping application chrome,
## active content and event handlers. SideFX's renderer emits HTML fragments.
static func _safe_html(html: String, wiki: String) -> String:
	var parser := XMLParser.new()
	if parser.open_buffer(("<article>" + html + "</article>").to_utf8_buffer()) != OK:
		return ""
	var out := PackedStringArray()
	var blocked := ""
	while parser.read() == OK:
		var kind := parser.get_node_type()
		if kind == XMLParser.NODE_TEXT:
			if blocked.is_empty():
				out.append(parser.get_node_data().xml_escape())
			continue
		if kind != XMLParser.NODE_ELEMENT and kind != XMLParser.NODE_ELEMENT_END:
			continue
		var tag := parser.get_node_name().to_lower()
		if not blocked.is_empty():
			if kind == XMLParser.NODE_ELEMENT_END and tag == blocked:
				blocked = ""
			continue
		if kind == XMLParser.NODE_ELEMENT and tag in IGNORE_CONTENT and not parser.is_empty():
			blocked = tag
			continue
		if tag not in ELEMENTS:
			continue
		if kind == XMLParser.NODE_ELEMENT_END:
			out.append("</%s>" % tag)
			continue
		var attrs := ""
		for attr in ["id", "class", "title", "alt", "colspan", "rowspan"]:
			if parser.has_attribute(attr):
				attrs += " %s=\"%s\"" % [attr, parser.get_named_attribute_value(attr).xml_escape(true)]
		var attr := "href" if tag == "a" else "src" if tag == "img" else ""
		if not attr.is_empty() and parser.has_attribute(attr):
			var target := _link(parser.get_named_attribute_value(attr), wiki)
			if not target.is_empty():
				attrs += " %s=\"%s\"" % [attr, target.xml_escape(true)]
		out.append("<%s%s>" % [tag, attrs])
		if parser.is_empty() and tag not in ["br", "hr", "img"]:
			out.append("</%s>" % tag)
	return "".join(out)


static func _inline(text: String, wiki: String, links: RegEx) -> String:
	var out := ""
	var cursor := 0
	for match_ in links.search_all(text):
		out += text.substr(cursor, match_.get_start() - cursor).xml_escape()
		cursor = match_.get_end()
		if not match_.get_string(3).is_empty():
			out += "<code>%s</code>" % match_.get_string(3).substr(1, match_.get_string(3).length() - 2).xml_escape()
			continue
		if not match_.get_string(4).is_empty():
			out += "<strong>%s</strong>" % match_.get_string(4).substr(2, match_.get_string(4).length() - 4).xml_escape()
			continue
		if not match_.get_string(5).is_empty():
			out += "<em>%s</em>" % match_.get_string(5).substr(1, match_.get_string(5).length() - 2).xml_escape()
			continue
		var label := match_.get_string(1)
		var target := match_.get_string(2)
		if target.is_empty():
			var pair := label.split("|", true, 1)
			if pair.size() == 2:
				label = pair[0].strip_edges()
				target = pair[1]
			elif label.begins_with("Node:") or is_web_url(label):
				target = label
			else:
				out += match_.get_string().xml_escape()
				continue
		var href := _link(target, wiki)
		out += label.xml_escape() if href.is_empty() else '<a href="%s">%s</a>' % [href.xml_escape(true), label.xml_escape()]
	return out + text.substr(cursor).xml_escape()


## Preserve the whole page without requiring an installed SideFX help tool.
static func _fallback_body(source: String, wiki: String) -> String:
	var links := RegEx.create_from_string(r"\[([^\]\n]+)\](?:\(([^)\n]+)\))?|(\x60[^\x60]+\x60)|(\*\*[^*]+\*\*|__[^_]+__)|(\*[^*]+\*|(?<!\w)_[^_]+_(?!\w))")
	var separator := RegEx.create_from_string(r"^\|?[\s:\-|]+(?:\|[\s:\-|]+)+\|?$")
	var out := PackedStringArray()
	var rows := source.replace("\r", "").split("\n")
	var code := false
	var table := false
	var list := ""
	var ordered := RegEx.create_from_string(r"^\d+[.)]\s+")
	for i in rows.size():
		var line := rows[i].strip_edges()
		if line.begins_with("\u0060\u0060\u0060") or line == "{{{" or line == "}}}":
			out.append("</code></pre>" if code else "<pre><code>")
			code = not code
			continue
		if code:
			out.append(rows[i].xml_escape() + "\n")
			continue
		var table_start := line.contains("|") and i + 1 < rows.size() and separator.search(rows[i + 1].strip_edges()) != null
		if table and not line.contains("|"):
			out.append("</table>")
			table = false
		var number := ordered.search(line)
		var list_type := "ol" if number else "ul" if line.begins_with("- ") or line.begins_with("* ") else ""
		if not list.is_empty() and list_type != list:
			out.append("</%s>" % list)
			list = ""
		if table_start or table:
			if table_start:
				out.append("<table>")
			table = true
			if separator.search(line):
				continue
			var cell := "th" if table_start else "td"
			out.append("<tr>")
			for value in line.trim_prefix("|").trim_suffix("|").split("|"):
				out.append("<%s>%s</%s>" % [cell, _inline(value.strip_edges(), wiki, links), cell])
			out.append("</tr>")
		elif not list_type.is_empty():
			if list.is_empty():
				list = list_type
				out.append("<%s>" % list)
			out.append("<li>%s</li>" % _inline(line.substr(number.get_end() if number else 2), wiki, links))
		elif line.begins_with("#id:"):
			out.append('<span id="%s"></span>' % line.substr(4).strip_edges().xml_escape(true))
		elif line.begins_with("@") and line.length() > 1:
			var section := line.substr(1).replace("\t", " ").split(" ", false, 1)
			var title := section[1].strip_edges() if section.size() > 1 else section[0].capitalize()
			out.append('<h2 id="%s">%s</h2>' % [section[0].xml_escape(true), _inline(title, wiki, links)])
		elif line.begins_with("=") and line.ends_with("="):
			var level := clampi(line.length() - line.lstrip("=").length(), 1, 6)
			out.append("<h%d>%s</h%d>" % [level, line.lstrip("=").rstrip("=").strip_edges().xml_escape(), level])
		elif line.begins_with("#") and line.lstrip("#").begins_with(" "):
			var level := clampi(line.length() - line.lstrip("#").length(), 1, 6)
			out.append("<h%d>%s</h%d>" % [level, _inline(line.lstrip("#").strip_edges(), wiki, links), level])
		elif not line.is_empty():
			var cls := ' class="label"' if line.ends_with(":") else ""
			if not cls.is_empty():
				line = line.trim_prefix("::").trim_suffix(":")
			out.append("<p%s>%s</p>" % [cls, _inline(line, wiki, links)])
	if table:
		out.append("</table>")
	if not list.is_empty():
		out.append("</%s>" % list)
	if code:
		out.append("</code></pre>")
	return "\n".join(out)

