## Offline help rendering and safe link handling. Never launches a browser.
extends SceneTree

const Help := preload("res://addons/hego/ui/asset_help.gd")
var issues := 0


func check(condition: bool, message: String) -> void:
	if not condition:
		push_error(message)
		issues += 1


func _initialize() -> void:
	run.call_deferred()


func run() -> void:
	var temp := DirAccess.create_temp("hego help test")
	var folder := temp.get_current_dir()
	check(Help.is_web_url("https://example.org/tool?q=help#output"), "An authored HTTPS URL can open in the browser")
	check(not Help.is_web_url("file:///some/path") and not Help.is_web_url("javascript:void(0)") and not Help.is_web_url("https://"), "Only absolute HTTP(S) URLs are launched")
	var declined: Error = await Help.open_page({"url": "https://example.org/help"}, func(): return false)
	check(declined == ERR_SKIP, "A superseded request cannot open a browser")
	var empty := Help.prepare_page({"op_name": "Sop/box", "text": ""}, "", folder)
	check(empty.error == ERR_UNAVAILABLE, "Assets without a help page have an explicit result")
	var markdown := "# Test page\n\n| Parameter | Description |\n| --- | --- |\n| Width | Shape width |\n\n[Reference](https://example.org/?a=1&b=2)\n\n**Bold**, *italic* and `width`.\n\nLast paragraph."
	check(Help._is_markdown("## Controls\n\nDetails") and Help._is_markdown("| Name | Value |\n| --- | --- |"), "Partial Markdown pages are recognized without a top-level title")
	check(Help._wiki_path("Sop/test::asset::1.0") == "/nodes/sop/test--asset-1.0"
		and Help._wiki_path("Object/asset::2") == "/nodes/obj/asset-2"
		and Help._wiki_path("Sop/com.corp::Object/alfa::2.0::com.corp::bravo::3.0") == "/nodes/sop/com.corp--Object_alfa-2.0@com.corp--bravo-3.0", "Wiki paths follow Houdini's namespace, version and scope conventions")
	var page := {"text": markdown, "op_name": "Sop/test::asset::1.0"}
	var result := Help.prepare_page(page, "", folder)
	check(result.error == OK, "A local page can be written when Houdini's help tool is unavailable")
	if result.error == OK:
		var html := FileAccess.get_file_as_string(result.path)
		check(html.contains("<h1>Test page</h1>") and html.contains("<th>Parameter</th>") and html.contains("<td>Shape width</td>"), "Markdown headings and tables remain structured")
		check(html.contains("<strong>Bold</strong>") and html.contains("<em>italic</em>") and html.contains("<code>width</code>"), "Basic Markdown emphasis and inline code are rendered")
		check(html.contains('href="https://example.org/?a=1&amp;b=2"') and html.contains("Last paragraph."), "Links and the full page body survive rendering")
		check(Help.prepare_page(page, "", folder).path == result.path, "Identical pages reuse one immutable file")
		page.text = markdown + "\nMore help."
		check(Help.prepare_page(page, "", folder).path != result.path, "Changed help opens a new page")
	var wiki := "= Artist help =\n\n@parameters\n\nWidth:\n    #id: width\n\n    Shape width.\n\n@related\n\n* [Node:sop/box]"
	var article := Help._fallback_body(wiki, "/nodes/sop/test")
	check(article.contains('<h2 id="parameters">Parameters</h2>') and article.contains('id="width"') and article.contains('href="https://www.sidefx.com/docs/houdini/nodes/sop/box.html"'), "SideFX sections, anchors and node links also work in the fallback")
	var titled := Help._fallback_body("@parameters List controls\n\n::Conditional amount:\n    #id: amount\n\n    Scales the result.", "/nodes/sop/test")
	check(titled.contains('<h2 id="parameters">List controls</h2>') and titled.contains('<p class="label">Conditional amount</p>') and titled.contains('id="amount"'), "The fallback renders titled sections and anonymous parameter entries from the test HDA")
	article = Help._safe_html('<h1>Title</h1><div id="width"><a href="#width">Width</a> &amp; height</div><script>doBadThings()</script><a onclick="doMore()" href="file:///unsafe">x</a><p>Last</p>', "/nodes/sop/test")
	check(article.contains("Title") and article.contains('href="#width"') and article.contains("&amp; height") and article.contains("<p>Last</p>"), "Local rendering preserves readable text and fragment links")
	check(not article.contains("doBadThings") and not article.contains("onclick") and not article.contains("file:"), "Active content and local shell links are removed")
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--hfs="):
			var source := wiki.replace("Shape width.", "Width of café 測試.")
			article = Help._native_body(source, "/nodes/sop/hego_help_probe", arg.trim_prefix("--hfs="))
			check(article.contains("café 測試") and article.contains('id="width"'), "SideFX's renderer preserves UTF-8 and named parameters")
			check(article.contains('href="https://www.sidefx.com/docs/houdini/nodes/sop/box.html"'), "SideFX's relative links work in a local browser")
	if issues == 0:
		print("HEGO_ASSET_HELP_PASS")
	quit(issues)

