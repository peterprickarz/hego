#include "multiparm_styles.h"
#include "hapi/houdini_api.h"
#include "hego_api.h"
#include "util/hego_util.h"

#include <godot_cpp/classes/dir_access.hpp>
#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/classes/os.hpp>
#include <cctype>
#include <map>
#include <string>
#include <vector>

namespace HEGo::Util::Parm
{
namespace
{
using Styles = std::map<std::string, std::string>;
struct AuthoredLayout
{
	Styles multiparms;
	Styles folder_defaults;
};
struct CachedOperator
{
	uint64_t modified = 0;
	int64_t bytes = 0;
	AuthoredLayout layout;
};
// Accessed on the single HAPI worker. Store plain strings across Godot shutdown.
std::map<std::string, std::map<std::string, CachedOperator>> libraries;

struct DialogBlock
{
	std::string keyword;
	std::string name;
	std::string tag_key;
	std::string tag_value;
	std::string group_default;

	bool is_folder() const
	{
		return keyword == "group" || keyword == "groupcollapsible" || keyword == "groupradio" || keyword == "groupsimple";
	}
};

// HAPI drops the authored multiparm layout and folder-default tags. Only collect
// direct properties of the matching DialogScript blocks. Quoted scripts, help
// and comments can contain braces, parameter names and layout keywords.
AuthoredLayout read_styles(const godot::String &path)
{
	AuthoredLayout layout;
	if (!godot::FileAccess::file_exists(path)) return layout;
	const std::string text = godot::FileAccess::get_file_as_string(path).utf8().get_data();
	std::vector<DialogBlock> blocks;
	std::string previous;
	for (size_t i = 0; i < text.size();)
	{
		const char ch = text[i++];
		if (std::isspace(static_cast<unsigned char>(ch))) continue;
		if (ch == '#')
		{
			while (i < text.size() && text[i] != '\n') ++i;
			continue;
		}
		if (ch == '{' || ch == '}')
		{
			if (ch == '{')
				blocks.push_back({previous});
			else if (!blocks.empty())
			{
				const auto &block = blocks.back();
				if (block.keyword == "parmtag" && block.tag_key == "group_default" && blocks.size() >= 2)
				{
					auto &owner = blocks[blocks.size() - 2];
					if (owner.is_folder()) owner.group_default = block.tag_value;
				}
				else if (!block.name.empty())
				{
					if (block.keyword == "multiscroll") layout.multiparms[block.name] = "scroll";
					else if (block.keyword == "multiswitcher") layout.multiparms[block.name] = "tabs";
					else if (block.keyword == "multiparm") layout.multiparms[block.name] = "list";
					else if (block.is_folder() && !block.group_default.empty()) layout.folder_defaults[block.name] = block.group_default;
				}
				blocks.pop_back();
			}
			previous.clear();
			continue;
		}
		std::string token;
		if (ch == '"')
		{
			while (i < text.size() && text[i] != '"')
			{
				if (text[i] == '\\' && i + 1 < text.size()) ++i;
				token += text[i++];
			}
			if (i < text.size()) ++i;
		}
		else
		{
			const size_t start = i - 1;
			while (i < text.size() && !std::isspace(static_cast<unsigned char>(text[i])) &&
					text[i] != '{' && text[i] != '}' && text[i] != '"') ++i;
			token = text.substr(start, i - start);
		}
		if (!blocks.empty())
		{
			auto &block = blocks.back();
			if (block.keyword == "parmtag")
			{
				if (block.tag_key.empty()) block.tag_key = token;
				else block.tag_value = token;
			}
			else if (previous == "name") block.name = token;
		}
		previous = ch == '"' ? "" : token;
	}
	return layout;
}

godot::String dialog_path(const godot::String &directory, const godot::String &op)
{
	const auto list = directory.path_join("Sections.list");
	if (!godot::FileAccess::file_exists(list)) return {};
	for (const godot::String &line : godot::FileAccess::get_file_as_string(list).split("\n", false))
	{
		const auto fields = line.strip_edges().split("\t", false);
		if (fields.size() == 2 && fields[1] == op && fields[0] == fields[0].get_file() && fields[0] != "..")
			return directory.path_join(fields[0]).path_join("DialogScript");
	}
	return {};
}

AuthoredLayout library_styles(const godot::String &path, const godot::String &op)
{
	const bool expanded = godot::DirAccess::dir_exists_absolute(path);
	const auto source = expanded ? dialog_path(path, op) : path;
	if (source.is_empty() || !godot::FileAccess::file_exists(source)) return {};
	auto &operators = libraries[path.utf8().get_data()];
	auto [found, inserted] = operators.try_emplace(op.utf8().get_data());
	auto &entry = found->second;
	const auto modified = godot::FileAccess::get_modified_time(source);
	const auto bytes = godot::FileAccess::get_size(source);
	if (!inserted && entry.modified == modified && entry.bytes == bytes) return entry.layout;
	entry = {modified, bytes, {}};
	if (expanded)
	{
		entry.layout = read_styles(source);
		return entry.layout;
	}
#ifdef _WIN32
	const char *program = "bin/hotl.exe";
#else
	const char *program = "bin/hotl";
#endif
	const auto hotl = HEGoAPI::get_singleton()->get_houdini_installation_path().path_join(program);
	if (!godot::FileAccess::file_exists(hotl)) return {};
	auto temp = godot::DirAccess::create_temp("hego-parameter-layout");
	if (temp.is_null()) return {};
	const auto directory = temp->get_current_dir().path_join("sections");
	godot::PackedStringArray args;
	args.append("-x");
	args.append(directory);
	args.append(path);
	godot::Array output;
	if (godot::OS::get_singleton()->execute(hotl, args, output, true) == 0)
		entry.layout = read_styles(dialog_path(directory, op));
	return entry.layout;
}
}

ParameterLayout get_parameter_layout(const HAPI_Session *session, const HAPI_AssetInfo &info)
{
	ParameterLayout result;
	const auto path = Hapi::get_godot_string(session, info.filePathSH);
	const auto op = Hapi::get_godot_string(session, info.fullOpNameSH);
	if (path.is_empty() || op.is_empty()) return result;
	const auto layout = library_styles(path, op);
	for (const auto &[name, style] : layout.multiparms)
		result.multiparm_styles[godot::String::utf8(name.c_str())] = godot::String::utf8(style.c_str());
	for (const auto &[name, value] : layout.folder_defaults)
		result.folder_defaults[godot::String::utf8(name.c_str())] = godot::String::utf8(value.c_str());
	return result;
}

void invalidate_multiparm_styles(const godot::String &library_path)
{
	libraries.erase(library_path.utf8().get_data());
}
}
