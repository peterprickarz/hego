#include "parameter_help.h"

#include <godot_cpp/classes/reg_ex.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>

namespace HEGo::Util::Parm
{
namespace
{
using godot::Dictionary;
using godot::PackedStringArray;
using godot::String;

struct Entries
{
	Dictionary ids;
	Dictionary labels;
	Dictionary table_keys;
};

// Duplicate definitions with different text cannot identify one tooltip.
void add_entry(Dictionary &index, const String &key, const String &paragraph)
{
	if (!key.is_empty() && !paragraph.is_empty())
		index[key] = index.has(key) && String(index[key]) != paragraph ? String() : paragraph;
}

int indentation(const String &line)
{
	int i = 0;
	while (i < line.length() && (line[i] == ' ' || line[i] == '\t'))
		++i;
	return i;
}

// A SideFX parameter is a definition term followed by indented properties and
// paragraphs. Stop at its first paragraph boundary or the next sibling block.
int read_wiki_entry(const PackedStringArray &lines, int start, const String &label, Entries &entries)
{
	const int indent = indentation(lines[start]);
	String id, paragraph;
	int i = start + 1;
	for (; i < lines.size(); ++i)
	{
		const String line = lines[i].strip_edges();
		if (line.is_empty())
		{
			if (!paragraph.is_empty()) break;
			continue;
		}
		if (indentation(lines[i]) <= indent) break;
		if (line.begins_with("#id:"))
			id = line.substr(4).strip_edges();
		else if (!line.begins_with("#") && !line.begins_with("//") && !line.begins_with(":include ") && !line.begins_with(":include:"))
		{
			if (!paragraph.is_empty()) paragraph += " ";
			paragraph += line;
		}
	}
	add_entry(id.is_empty() ? entries.labels : entries.ids, id.is_empty() ? label : id, paragraph);
	// Skip the remainder of this entry so a later paragraph or example cannot
	// become another label just because a line happens to end with a colon.
	while (i < lines.size() && (lines[i].strip_edges().is_empty() || indentation(lines[i]) > indent))
		++i;
	return i - 1;
}

PackedStringArray table_cells(const String &line)
{
	return line.trim_prefix("|").trim_suffix("|").split("|");
}

int read_parameter_table(const PackedStringArray &lines, int start, Entries &entries)
{
	// Accept parameter/description tables in Markdown help pages. The explicit
	// header and separator distinguish them from examples and ordinary prose.
	const auto header = table_cells(lines[start].strip_edges());
	if (header.size() < 2 || start + 1 >= lines.size()) return start;
	const auto key = header[0].strip_edges().to_lower();
	if (key != "parameter" && key != "control" && key != "name") return start;
	int description = -1;
	for (int i = 1; i < header.size(); ++i)
	{
		const auto caption = header[i].strip_edges().to_lower();
		if (caption == "description" || caption == "purpose" || caption == "help")
			description = i;
	}
	if (description < 0) return start;
	const auto separator = table_cells(lines[start + 1].strip_edges());
	if (separator.size() != header.size()) return start;
	for (const String &cell : separator)
	{
		const auto rule = cell.strip_edges().trim_prefix(":").trim_suffix(":");
		if (rule.length() < 3 || !rule.replace("-", "").is_empty()) return start;
	}
	int i = start + 2;
	for (; i < lines.size(); ++i)
	{
		const auto cells = table_cells(lines[i].strip_edges());
		if (cells.size() != header.size()) break;
		const auto token = cells[0].strip_edges().trim_prefix("`").trim_suffix("`");
		add_entry(entries.table_keys, token, cells[description].strip_edges());
	}
	return i - 1;
}

Entries parse_entries(const String &page)
{
	const auto lines = page.split("\n");
	Entries entries;
	bool in_wiki = false;
	int markdown_level = 0;
	String fence_end;
	for (int i = 0; i < lines.size(); ++i)
	{
		const String line = lines[i].strip_edges();
		if (!fence_end.is_empty())
		{
			if (line.begins_with(fence_end)) fence_end = String();
			continue;
		}
		if (line.begins_with("```") || line == "{{{")
		{
			fence_end = line == "{{{" ? "}}}" : "```";
			continue;
		}
		if (line.begins_with("@") && indentation(lines[i]) == 0)
		{
			in_wiki = line == "@parameters" || line.begins_with("@parameters ") || line.begins_with("@parameters\t");
			markdown_level = 0;
			continue;
		}
		if (line.begins_with("#") && !in_wiki)
		{
			int level = 0;
			while (level < line.length() && line[level] == '#') ++level;
			if (level < line.length() && line[level] == ' ')
			{
				if (line.substr(level + 1).strip_edges().to_lower() == "parameters")
					markdown_level = level;
				else if (level <= markdown_level)
					markdown_level = 0;
			}
		}
		if (in_wiki && line.ends_with(":") && !line.begins_with("#") && !line.begins_with("//") && (!line.begins_with(":") || line.begins_with("::")))
			i = read_wiki_entry(lines, i, line.trim_prefix("::").trim_suffix(":").strip_edges(), entries);
		else if ((in_wiki || markdown_level) && line.contains("|"))
			i = read_parameter_table(lines, i, entries);
	}
	return entries;
}
} // namespace

void apply_parameter_help(const String &page, std::vector<Dictionary> &rows)
{
	const Entries entries = parse_entries(page);
	if (entries.ids.is_empty() && entries.labels.is_empty() && entries.table_keys.is_empty())
		return;
	// Count distinct authored parameters, not live instances of one multiparm
	// template. Two different controls labelled "Name" must keep their own hints.
	Dictionary label_owners;
	for (const Dictionary &row : rows)
	{
		const String label = row["label"];
		const String owner = row["template_name"];
		add_entry(label_owners, label, owner.is_empty() ? String(row["name"]) : owner);
	}

	// Keep code identifiers intact while removing common wiki/Markdown text
	// styles and link destinations from the plain-text Godot tooltip.
	const auto inline_markup = godot::RegEx::create_from_string(
			R"rx(`([^`]+)`|\[([^\]|]+)\|[^\]]+\]|\[([^\]]+)\]\([^)]+\)|(?<![\p{L}\p{N}_])(\*{1,2}|_{1,2})(?=\S)(.+?)(?<=\S)\4(?![\p{L}\p{N}_]))rx");
	for (Dictionary &row : rows)
	{
		const String name = row["name"], templ = row["template_name"], label = row["label"];
		String tip = entries.ids.get(name, entries.ids.get(templ, ""));
		if (tip.is_empty())
			tip = entries.table_keys.get(name, entries.table_keys.get(templ, ""));
		if (tip.is_empty() && !String(label_owners.get(label, "")).is_empty())
			tip = entries.labels.get(label, entries.table_keys.get(label, ""));
		if (!tip.is_empty())
			row["help"] = inline_markup->sub(tip, "$1$2$3$5", true);
	}
}
} // namespace HEGo::Util::Parm
