#include "hego_nodes/hego_asset_node.h"

#include "hego_api.h"
#include "hego_asset_node.h"
#include "util/geo/fetch_curves.h"
#include "util/geo/fetch_heightfields.h"
#include "util/geo/fetch_points.h"
#include "util/geo/geo_cache.h"
#include "util/geo/geo_output.h"
#include "util/geo/fetch_surfaces.h"
#include "util/geo/input.h"
#include "util/geo/output.h"
#include "util/log/log.h"
#include "util/node/create_nodes.h"
#include "util/parm/get_parms.h"
#include "util/parm/multiparm_styles.h"
#include "util/parm/presets.h"
#include "util/parm/set_parms.h"
#include "util/hego_enums.h"
#include "util/hego_util.h"
#include "util/task/task_helpers.h"

#include <godot_cpp/classes/dir_access.hpp>
#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/classes/os.hpp>
#include <vector>

using HEGo::Util::Task::fail;
using HEGo::Util::Task::make_failed;
using HEGo::Util::Task::submit;
using HEGo::Util::Task::submit_failable;

namespace HEGo
{

HEGoAssetNode::HEGoAssetNode() {}

HEGoAssetNode::~HEGoAssetNode() {}

bool HEGoAssetNode::refresh_definition_source(const HAPI_Session *session, HAPI_NodeId id)
{
	HAPI_AssetInfo info = HoudiniApi::AssetInfo_Create();
	if (HoudiniApi::GetAssetInfo(session, id, &info) != HAPI_RESULT_SUCCESS) return false;
	const godot::String path = Util::Hapi::get_godot_string(session, info.filePathSH);
	if (!path.is_empty())
	{
		definition_path = path;
		definition_name = Util::Hapi::get_godot_string(session, info.fullOpNameSH);
	}
	return true;
}

godot::Ref<HEGoTask> HEGoAssetNode::instantiate()
{
	if (op_name == "")
	{
		return make_failed("Operator name not set, call set_op_name(name) first!", "Instantiate");
	}

	godot::String op = op_name;
	HAPI_NodeId nid = node_id;
	// A reference, not a raw pointer: the task runs on the worker thread and must not
	// find this node destroyed underneath it if the owning script is freed meanwhile.
	godot::Ref<HEGoAssetNode> self = this;

	return submit("Instantiate " + op_name, nid, [self, op, nid](HEGoSessionManager *mgr) -> godot::Variant {
		HAPI_NodeId result_id = HEGo::Util::Node::instantiate_hda_from_name(mgr, op, nid);
		self->node_id = result_id;

		if (result_id >= 0)
		{
			if (result_id != nid)
			{
				self->definition_path = godot::String();
				self->definition_name = godot::String();
				self->refresh_definition_source(mgr->get_session(), result_id);
			}
			mgr->register_node(self.ptr());
			HEGo::Util::Log::debug(HEGo::Util::Log::Category::NODE, "Successfully instantiated HDA: " + op);
		}
		else
		{
			HEGo::Util::Log::error(HEGo::Util::Log::Category::NODE, "Failed to instantiate HDA: " + op + " (License issue? Check if Houdini Engine has a valid license)");
		}

		return result_id;
	});
}

namespace
{
#ifdef _WIN32
constexpr const char *HOTL_EXECUTABLE = "bin/hotl.exe";
#else
constexpr const char *HOTL_EXECUTABLE = "bin/hotl";
#endif

// HAPI can return the previous library id, with no warning, when a file has
// disappeared or become unreadable since it was installed. hotl reads the source
// independently, including Houdini's expanded (directory) form of an HDA.
bool check_library_source(const godot::String &path, const godot::String &full_name, const godot::String &hotl, godot::String &error)
{
	if (godot::FileAccess::file_exists(hotl))
	{
		godot::PackedStringArray args;
		args.append("-B");
		args.append(path);
		godot::Array output;
		if (godot::OS::get_singleton()->execute(hotl, args, output, true) != 0)
		{
			error = "Could not read the HDA library at " + path;
			if (!output.is_empty()) error += "\n" + godot::String(output[0]).strip_edges();
			return false;
		}
		if (!output.is_empty() && godot::String(output[0]).replace("\r", "").split("\n", false).has(full_name)) return true;
		error = "Could not find " + full_name + " in " + path;
		return false;
	}
	if (godot::DirAccess::dir_exists_absolute(path)) return true;
	godot::Ref<godot::FileAccess> source = godot::FileAccess::open(path, godot::FileAccess::READ);
	if (source.is_valid() && source->get_length() > 0) return true;
	error = "Could not read the HDA library at " + path;
	return false;
}
} // namespace

godot::Ref<HEGoTask> HEGoAssetNode::reload_definition()
{
	const HAPI_NodeId nid = node_id;
	if (nid < 0) return make_failed("Instantiate the HDA before reloading its definition.", "Reload definition");
	const uint64_t generation = get_generation();
	const godot::String op = op_name;
	const godot::String hotl = HEGoAPI::get_singleton()->get_houdini_installation_path().path_join(HOTL_EXECUTABLE);
	godot::Ref<HEGoAssetNode> self = this;
	return submit_failable("Reload definition " + op, nid, [self, nid, generation, op, hotl](HEGoSessionManager *mgr, HEGoTask *task) -> godot::Variant {
		HAPI_Session *session = mgr->get_session();
		if (self->get_generation() != generation || self->get_id() != nid || !self->refresh_definition_source(session, nid))
		{
			fail(task, "Could not read the live definition of " + op);
			return {};
		}
		// Resolve the library Houdini actually chose, including namespaces and versions.
		const godot::String path = self->definition_path;
		const godot::String full_name = self->definition_name;
		if (path.is_empty())
		{
			fail(task, "Houdini reported no on-disk library for " + op);
			return {};
		}
		godot::String read_error;
		if (!check_library_source(path, full_name.is_empty() ? op : full_name, hotl, read_error))
		{
			fail(task, read_error);
			return {};
		}
		HAPI_AssetLibraryId library = -1;
		if (HoudiniApi::LoadAssetLibraryFromFile(session, path.utf8().get_data(), true, &library) != HAPI_RESULT_SUCCESS)
		{
			fail(task, "Could not reload " + path + ": " + godot::String::utf8(Util::Hapi::get_last_error(session).c_str()));
			return {};
		}
		int count = 0;
		if (HoudiniApi::GetAvailableAssetCount(session, library, &count) == HAPI_RESULT_SUCCESS && count > 0)
		{
			std::vector<HAPI_StringHandle> names(count);
			if (HoudiniApi::GetAvailableAssets(session, library, names.data(), count) == HAPI_RESULT_SUCCESS)
			{
				for (const auto name : names)
				{
					const godot::String available = Util::Hapi::get_godot_string(session, name);
					if (available == full_name || available == op)
					{
						Util::Parm::invalidate_multiparm_styles(path);
						return path;
					}
				}
			}
		}
		fail(task, "Could not find " + op + " in the reloaded library " + path);
		return {};
	});
}

godot::Ref<HEGoTask> HEGoAssetNode::asset_task(const godot::String &description, AssetWork work)
{
	const HAPI_NodeId id = get_id();
	if (id < 0) return make_failed("Instantiate the asset before this operation.", description);
	HEGoSessionManager *manager = get_session_manager();
	if (!manager || !manager->get_session()) return make_failed("No Houdini session is available.", description, id);
	const HAPI_Session expected = *manager->get_session();
	const uint64_t generation = get_generation();
	godot::Ref<HEGoAssetNode> self = this;
	return submit_failable(description, id, [self, id, expected, generation, work](HEGoSessionManager *mgr, HEGoTask *task) -> godot::Variant {
		const HAPI_Session *session = mgr ? mgr->get_session() : nullptr;
		if (!session || session->id != expected.id || session->type != expected.type || self->get_generation() != generation || self->get_id() != id ||
			HoudiniApi::IsSessionValid(session) != HAPI_RESULT_SUCCESS)
		{
			fail(task, "Asset or session changed before the operation.");
			return {};
		}
		godot::String error;
		godot::Variant result = work(mgr, id, error);
		if (!error.is_empty()) { fail(task, error); return {}; }
		return result;
	});
}

godot::Ref<HEGoTask> HEGoAssetNode::set_parm(godot::String name, godot::Variant value)
{
	return asset_task("Set parm " + name, [name, value](HEGoSessionManager *mgr, HAPI_NodeId id, godot::String &error) {
		Util::Parm::set_parm(mgr, id, name, value, error);
		return 0;
	});
}

godot::Ref<HEGoTask> HEGoAssetNode::set_parms_batch(godot::Dictionary parms)
{
	const godot::Dictionary captured = parms.duplicate(true);
	return asset_task("Set parms batch", [captured](HEGoSessionManager *mgr, HAPI_NodeId id, godot::String &error) {
		Util::Parm::set_parms(mgr, id, captured, error);
		return 0;
	});
}

namespace
{
struct ParameterSource
{
	godot::Ref<HEGoBaseNode> node;
	HAPI_NodeId id;
	uint64_t generation;

	explicit ParameterSource(godot::Ref<HEGoBaseNode> source) : node(source), id(source.is_valid() ? source->get_id() : -1),
			generation(source.is_valid() ? source->get_generation() : 0) {}

	bool compatible(const HAPI_Session *session, const HAPI_ParmInfo &parm, HAPI_NodeId owner) const
	{
		return node.is_valid() && id != owner && node->get_generation() == generation && node->get_id() == id && Util::Parm::accepts_node(session, parm, id);
	}
};
}

godot::Ref<HEGoTask> HEGoAssetNode::get_node_parm_candidates(godot::String name, godot::Array candidates)
{
	std::vector<ParameterSource> sources;
	for (int i = 0; i < candidates.size(); ++i) sources.emplace_back(godot::Ref<HEGoBaseNode>(candidates[i]));
	return asset_task("Filter sources for " + name, [name, sources](HEGoSessionManager *mgr, HAPI_NodeId id, godot::String &error) {
		godot::Array result;
		HAPI_ParmInfo parm;
		const HAPI_Session *session = mgr->get_session();
		if (Util::Parm::get_node_parm_info(session, id, name, parm, error))
			for (const auto &source : sources) result.append(source.compatible(session, parm, id));
		return result;
	});
}

godot::Ref<HEGoTask> HEGoAssetNode::set_node_parm(godot::String name, godot::Ref<HEGoBaseNode> source)
{
	const ParameterSource selected(source);
	return asset_task("Set node parm " + name, [name, selected](HEGoSessionManager *mgr, HAPI_NodeId id, godot::String &error) {
		const HAPI_Session *session = mgr->get_session();
		HAPI_ParmInfo parm;
		if (!Util::Parm::get_node_parm_info(session, id, name, parm, error)) return 0;
		if (selected.node.is_valid() && !selected.compatible(session, parm, id))
		{
			error = "Source node is unavailable or incompatible with parameter '" + name + "'.";
			return 0;
		}
		const godot::CharString parm_name = name.utf8();
		HAPI_NodeId current;
		if (HoudiniApi::GetParmNodeValue(session, id, parm_name.get_data(), &current) != HAPI_RESULT_SUCCESS)
		{
			error = "Could not read node reference '" + name + "'.";
			return 0;
		}
		if (current == selected.id)
		{
			if (current >= 0) return 0;
			// An unresolved literal path also resolves to -1. Clear the actual text in that case.
			HAPI_StringHandle raw;
			int length = 0;
			if (HoudiniApi::GetParmStringValue(session, id, parm_name.get_data(), 0, false, &raw) != HAPI_RESULT_SUCCESS ||
				HoudiniApi::GetStringBufLength(session, raw, &length) != HAPI_RESULT_SUCCESS || length < 1)
			{
				error = "Could not read the existing path for node reference '" + name + "'.";
				return 0;
			}
			if (length == 1) return 0;
		}
		if (HoudiniApi::SetParmNodeValue(session, id, parm_name.get_data(), selected.id) != HAPI_RESULT_SUCCESS ||
			HoudiniApi::GetParmNodeValue(session, id, parm_name.get_data(), &current) != HAPI_RESULT_SUCCESS || current != selected.id)
			error = "HAPI could not apply node reference '" + name + "'.";
		return 0;
	});
}

godot::Ref<HEGoTask> HEGoAssetNode::set_preset(godot::PackedByteArray preset)
{
	if (get_id() < 0)
	{
		return make_failed("Cannot set preset - HDA not instantiated or license issue", "Set preset");
	}

	const HAPI_NodeId nid = node_id;
	HEGoSessionManager *manager = get_session_manager();
	if (!manager || !manager->get_session()) return make_failed("No Houdini session manager is available.", "Set preset", nid);
	const HAPI_Session expected = *manager->get_session();
	const uint64_t generation = get_generation();
	godot::Ref<HEGoAssetNode> self = this;
	return submit_failable("Set preset", nid, [self, nid, preset, expected, generation](HEGoSessionManager *mgr, HEGoTask *task) -> godot::Variant {
		godot::String error;
		const HAPI_Session *session = mgr ? mgr->get_session() : nullptr;
		if (!session || session->id != expected.id || session->type != expected.type || self->get_id() != nid || self->get_generation() != generation || !HEGo::Util::Parm::write_preset(mgr, nid, preset, error)) {
			fail(task, error.is_empty() ? godot::String("Houdini session changed before setting the preset.") : error);
			return godot::Variant();
		}
		return 0;
	});
}

godot::Ref<HEGoTask> HEGoAssetNode::insert_multiparm_instance(int parm_id, int index)
{
	return asset_task("Insert multiparm", [parm_id, index](HEGoSessionManager *mgr, HAPI_NodeId node, godot::String &error) {
		Util::Parm::change_multiparm(mgr, node, parm_id, index, true, error);
		return 0;
	});
}

godot::Ref<HEGoTask> HEGoAssetNode::remove_multiparm_instance(int parm_id, int index)
{
	return asset_task("Remove multiparm", [parm_id, index](HEGoSessionManager *mgr, HAPI_NodeId node, godot::String &error) {
		Util::Parm::change_multiparm(mgr, node, parm_id, index, false, error);
		return 0;
	});
}

godot::Ref<HEGoTask> HEGoAssetNode::get_preset()
{
	if (get_id() < 0)
	{
		return make_failed("Cannot get preset - HDA not instantiated or license issue", "Get preset");
	}

	const HAPI_NodeId nid = node_id;
	HEGoSessionManager *manager = get_session_manager();
	if (!manager || !manager->get_session()) return make_failed("No Houdini session manager is available.", "Get preset", nid);
	const HAPI_Session expected = *manager->get_session();
	const uint64_t generation = get_generation();
	godot::Ref<HEGoAssetNode> self = this;
	return submit_failable("Get preset", nid, [self, nid, expected, generation](HEGoSessionManager *mgr, HEGoTask *task) -> godot::Variant {
		godot::PackedByteArray preset;
		godot::String error;
		const HAPI_Session *session = mgr ? mgr->get_session() : nullptr;
		if (!session || session->id != expected.id || session->type != expected.type || self->get_id() != nid || self->get_generation() != generation || !HEGo::Util::Parm::read_preset(mgr, nid, preset, error)) {
			fail(task, error.is_empty() ? godot::String("Houdini session changed before reading the preset.") : error);
			return godot::Variant();
		}
		return preset;
	});
}

godot::Ref<HEGoTask> HEGoAssetNode::get_parms_dict()
{
	return asset_task("Get parms dict", [](HEGoSessionManager *mgr, HAPI_NodeId node, godot::String &error) {
		godot::Dictionary result;
		Util::Parm::get_parm_dict(mgr, node, result, error);
		return result;
	});
}

godot::Ref<HEGoTask> HEGoAssetNode::get_help_page()
{
	return asset_task("Get asset help", [](HEGoSessionManager *mgr, HAPI_NodeId node, godot::String &error) {
		godot::Dictionary result;
		Util::Parm::get_help_page(mgr->get_session(), node, result, error);
		return result;
	});
}

godot::Ref<HEGoTask> HEGoAssetNode::get_input_names()
{
	if (get_id() < 0)
	{
		return make_failed("Cannot get input names - HDA not instantiated or license issue", "Get input names");
	}

	HAPI_NodeId nid = node_id;

	return submit("Get input names", nid, [nid](HEGoSessionManager *mgr) -> godot::Variant {
		return HEGo::Util::Geo::get_input_names(mgr, nid);
	});
}

godot::Ref<HEGoTask> HEGoAssetNode::cook()
{
	if (get_id() < 0)
	{
		return make_failed("Cannot cook node - HDA not instantiated or license issue", "Cook");
	}

	HAPI_NodeId nid = node_id;

	// A cook Houdini rejects fails its task rather than completing with -1. The -1 was only
	// visible to a caller that knew to look for it, so a script doing the obvious null check
	// on the result ran its output handlers over the previous cook's geometry.
	return submit_failable("Cook", nid, [nid](HEGoSessionManager *mgr, HEGoTask *task) -> godot::Variant {
		if (HoudiniApi::CookNode(mgr->get_session(), nid, mgr->get_cook_options()) != HAPI_RESULT_SUCCESS)
		{
			HEGo::Util::Log::error(HEGo::Util::Log::Category::NODE, "Failed to cook node.");
			fail(task, "Houdini refused to start the cook.");
			return godot::Variant();
		}

		// wait_for_cook is what reports whether the cook actually produced anything. It
		// separates a cook that failed outright from one that finished with errors, which is
		// a warning and still usable output.
		if (!mgr->wait_for_cook(nid))
		{
			fail(task, "The cook finished with fatal errors.");
			return godot::Variant();
		}
		return 0;
	});
}

godot::Ref<HEGoTask> HEGoAssetNode::get_point_output(godot::PackedStringArray preload_attribs)
{
	if (get_id() < 0)
	{
		return make_failed("Cannot read output - HDA not instantiated or license issue", "Get geo output");
	}

	HAPI_NodeId nid = node_id;

	return submit("Get geo output", nid,
			[nid, preload_attribs](HEGoSessionManager *mgr) -> godot::Variant
			{
				std::shared_ptr<HEGo::Util::Geo::GeoCache> cache = HEGo::Util::Geo::GeoCache::acquire(mgr, nid, false);
				if (!cache)
				{
					return godot::Variant();
				}

				godot::Ref<HEGoPointOutput> output;
				output.instantiate();
				output->setup(cache, nid);

				// Loaded here, on the worker thread, so the queries the caller makes
				// afterwards are pure in-memory work on the main thread.
				const HAPI_PartInfo *part = cache->points_part();
				if (part != nullptr)
				{
					for (int i = 0; i < preload_attribs.size(); ++i)
					{
						cache->attribute(*part, HAPI_ATTROWNER_POINT, preload_attribs[i]);
					}
				}

				return output;
			});
}

godot::Ref<HEGoTask> HEGoAssetNode::fetch_points(godot::Ref<godot::Resource> fetch_point_config)
{
	if (get_id() < 0)
	{
		return make_failed("Cannot fetch points - HDA not instantiated or license issue", "Fetch points");
	}

	if (!fetch_point_config.is_valid() || !fetch_point_config->is_class("Resource"))
	{
		return make_failed("Invalid fetch_point_config!", "Fetch points", node_id);
	}

	HAPI_NodeId nid = node_id;

	return submit("Fetch points", nid, [nid, fetch_point_config](HEGoSessionManager *mgr) -> godot::Variant {
		return HEGo::Util::Geo::fetch_points(mgr, nid, fetch_point_config, false);
	});
}

godot::Ref<HEGoTask> HEGoAssetNode::get_output_summary()
{
	if (get_id() < 0)
	{
		return make_failed("Cannot read output - HDA not instantiated or license issue", "Get output summary");
	}

	HAPI_NodeId nid = node_id;

	return submit("Get output summary", nid,
			[nid](HEGoSessionManager *mgr) -> godot::Variant
			{
				std::shared_ptr<HEGo::Util::Geo::GeoCache> cache = HEGo::Util::Geo::GeoCache::acquire(mgr, nid, false);
				if (!cache)
				{
					return godot::Dictionary();
				}

				// The part list is already cached, so this only costs the attribute
				// name lookups, one per part and owner, and those are cached too.
				bool has_mesh = false;
				bool has_points = false;
				for (const HAPI_PartInfo &part : cache->parts())
				{
					if (part.type != HAPI_PARTTYPE_MESH)
					{
						continue;
					}
					if (part.faceCount > 0)
					{
						has_mesh = true;
					}
					if (part.vertexCount == 0)
					{
						has_points = true;
					}
				}

				godot::Dictionary summary;
				summary["has_mesh"] = has_mesh;
				summary["has_points"] = has_points;
				summary["has_curves"] = !cache->parts_of_type(HAPI_PARTTYPE_CURVE).empty();
				summary["has_volumes"] = !cache->parts_of_type(HAPI_PARTTYPE_VOLUME).empty();

				const HAPI_PartInfo *points_part = cache->points_part();
				summary["point_attributes"] = points_part != nullptr ? cache->attribute_names(*points_part, HAPI_ATTROWNER_POINT) : godot::PackedStringArray();

				godot::PackedStringArray prim_attributes;
				for (const HAPI_PartInfo &part : cache->parts())
				{
					if (part.type == HAPI_PARTTYPE_MESH && part.faceCount > 0)
					{
						prim_attributes = cache->attribute_names(part, HAPI_ATTROWNER_PRIM);
						break;
					}
				}
				summary["prim_attributes"] = prim_attributes;

				return summary;
			});
}

godot::Ref<HEGoTask> HEGoAssetNode::get_surface_output(
		godot::PackedStringArray point_attribs, godot::PackedStringArray preload_attribs, godot::PackedStringArray custom_attribs)
{
	if (get_id() < 0)
	{
		return make_failed("Cannot read surfaces - HDA not instantiated or license issue", "Get surface output");
	}

	HAPI_NodeId nid = node_id;

	return submit("Get surface output", nid,
			[nid, point_attribs, preload_attribs, custom_attribs](HEGoSessionManager *mgr) -> godot::Variant
			{
				std::shared_ptr<HEGo::Util::Geo::GeoCache> cache = HEGo::Util::Geo::GeoCache::acquire(mgr, nid, false);
				if (!cache)
				{
					return godot::Variant();
				}

				godot::Ref<HEGoSurfaceOutput> surfaces;
				surfaces.instantiate();
				// Reads the primitive and vertex lists here, on the worker thread, so
				// the queries the caller makes afterwards are pure in-memory work.
				surfaces->setup(cache, nid, point_attribs, custom_attribs);
				surfaces->load_attributes_now(preload_attribs);

				return surfaces;
			});
}

godot::Ref<HEGoTask> HEGoAssetNode::fetch_surfaces(godot::Ref<godot::Resource> fetch_surface_config)
{
	if (get_id() < 0)
	{
		return make_failed("Cannot fetch surfaces - HDA not instantiated or license issue", "Fetch surfaces");
	}

	if (!fetch_surface_config.is_valid() || !fetch_surface_config->is_class("Resource"))
	{
		return make_failed("Invalid fetch_surface_config!", "Fetch surfaces", node_id);
	}

	HAPI_NodeId nid = node_id;

	return submit("Fetch surfaces", nid, [nid, fetch_surface_config](HEGoSessionManager *mgr) -> godot::Variant {
		return HEGo::Util::Geo::fetch_surfaces(mgr, nid, fetch_surface_config, false);
	});
}

godot::Ref<HEGoTask> HEGoAssetNode::get_heightfield_layers(godot::PackedStringArray read_prim_attribs)
{
	if (get_id() < 0)
	{
		return make_failed("Cannot get heightfield layers - HDA not instantiated or license issue", "Get heightfield layers");
	}

	HAPI_NodeId nid = node_id;

	return submit("Get heightfield layers", nid, [nid, read_prim_attribs](HEGoSessionManager *mgr) -> godot::Variant {
		return HEGo::Util::Geo::get_heightfield_layers(mgr, nid, read_prim_attribs, false);
	});
}

godot::Ref<HEGoTask> HEGoAssetNode::fetch_heightfield_layer_image(int part_id)
{
	if (get_id() < 0)
	{
		return make_failed("Cannot fetch heightfield layer - HDA not instantiated or license issue", "Fetch heightfield layer image");
	}

	HAPI_NodeId nid = node_id;

	return submit("Fetch heightfield layer image", nid, [nid, part_id](HEGoSessionManager *mgr) -> godot::Variant {
		return HEGo::Util::Geo::fetch_heightfield_layer_image(mgr, nid, part_id, false);
	});
}

godot::Ref<HEGoTask> HEGoAssetNode::get_heightfield_fields(godot::PackedStringArray read_prim_attribs)
{
	if (get_id() < 0) {
		return make_failed("Cannot fetch explicit fields: asset is not instantiated.", "Get heightfield fields");
	}
	const HAPI_NodeId nid = node_id;
	HEGoSessionManager *manager = get_session_manager();
	if (!manager || !manager->get_session()) return make_failed("No Houdini session manager is available.", "Get heightfield fields", nid);
	const HAPI_Session expected = *manager->get_session();
	return HEGo::Util::Task::submit_failable("Get heightfield fields", nid,
			[nid, read_prim_attribs, expected](HEGoSessionManager *mgr, HEGoTask *task) -> godot::Variant {
				const HAPI_Session *session = mgr ? mgr->get_session() : nullptr;
				if (!session || session->id != expected.id || session->type != expected.type) {
					HEGo::Util::Task::fail(task, "Houdini session changed before the field fetch ran.");
					return godot::Variant();
				}
				godot::Array fields;
				godot::String error;
				if (!HEGo::Util::Geo::fetch_heightfield_fields(mgr, nid, read_prim_attribs, fields, error, true)) {
					HEGo::Util::Task::fail(task, error);
					return godot::Variant();
				}
				return fields;
			});
}

godot::Ref<HEGoTask> HEGoAssetNode::fetch_curves(godot::PackedStringArray read_prim_attribs, godot::PackedStringArray read_point_attribs)
{
	if (get_id() < 0)
	{
		return make_failed("Cannot fetch curves - HDA not instantiated or license issue", "Fetch curves");
	}

	HAPI_NodeId nid = node_id;

	return submit("Fetch curves", nid, [nid, read_prim_attribs, read_point_attribs](HEGoSessionManager *mgr) -> godot::Variant {
		return HEGo::Util::Geo::fetch_curves(mgr, nid, read_prim_attribs, read_point_attribs, false);
	});
}

void HEGoAssetNode::set_op_name(godot::String name) { op_name = name; }

godot::String HEGoAssetNode::get_op_name() const { return op_name; }

void HEGoAssetNode::_bind_methods()
{
	godot::ClassDB::bind_method(godot::D_METHOD("reload_definition"), &HEGoAssetNode::reload_definition);
	godot::ClassDB::bind_method(godot::D_METHOD("set_parm", "parm_name", "value"), &HEGoAssetNode::set_parm);
	godot::ClassDB::bind_method(godot::D_METHOD("set_parms_batch", "parms"), &HEGoAssetNode::set_parms_batch);
	godot::ClassDB::bind_method(godot::D_METHOD("set_node_parm", "parm_name", "source"), &HEGoAssetNode::set_node_parm, DEFVAL(godot::Variant()));
	godot::ClassDB::bind_method(godot::D_METHOD("get_node_parm_candidates", "parm_name", "candidates"), &HEGoAssetNode::get_node_parm_candidates);
	godot::ClassDB::bind_method(godot::D_METHOD("insert_multiparm_instance", "parm_id", "index"), &HEGoAssetNode::insert_multiparm_instance);
	godot::ClassDB::bind_method(godot::D_METHOD("remove_multiparm_instance", "parm_id", "index"), &HEGoAssetNode::remove_multiparm_instance);
	godot::ClassDB::bind_method(godot::D_METHOD("get_preset"), &HEGoAssetNode::get_preset);
	godot::ClassDB::bind_method(godot::D_METHOD("set_preset", "preset"), &HEGoAssetNode::set_preset);
	godot::ClassDB::bind_method(godot::D_METHOD("get_id"), &HEGoAssetNode::get_id);
	godot::ClassDB::bind_method(godot::D_METHOD("get_input_names"), &HEGoAssetNode::get_input_names);
	godot::ClassDB::bind_method(godot::D_METHOD("get_help_page"), &HEGoAssetNode::get_help_page);
	godot::ClassDB::bind_method(godot::D_METHOD("get_parms_dict"), &HEGoAssetNode::get_parms_dict);
	godot::ClassDB::bind_method(godot::D_METHOD("set_op_name", "name"), &HEGoAssetNode::set_op_name);
	godot::ClassDB::bind_method(godot::D_METHOD("get_op_name"), &HEGoAssetNode::get_op_name);
	godot::ClassDB::bind_method(godot::D_METHOD("cook"), &HEGoAssetNode::cook);
	godot::ClassDB::bind_method(godot::D_METHOD("get_point_output", "preload_attribs"), &HEGoAssetNode::get_point_output, DEFVAL(godot::PackedStringArray()));
	godot::ClassDB::bind_method(godot::D_METHOD("fetch_points", "fetch_point_config"), &HEGoAssetNode::fetch_points);
	godot::ClassDB::bind_method(godot::D_METHOD("get_output_summary"), &HEGoAssetNode::get_output_summary);
	godot::ClassDB::bind_method(godot::D_METHOD("get_surface_output", "point_attribs", "preload_attribs", "custom_attribs"),
			&HEGoAssetNode::get_surface_output, DEFVAL(godot::PackedStringArray()), DEFVAL(godot::PackedStringArray()), DEFVAL(godot::PackedStringArray()));
	godot::ClassDB::bind_method(godot::D_METHOD("fetch_surfaces", "fetch_surface_config"), &HEGoAssetNode::fetch_surfaces);
	godot::ClassDB::bind_method(
			godot::D_METHOD("get_heightfield_layers", "read_prim_attribs"), &HEGoAssetNode::get_heightfield_layers, DEFVAL(godot::PackedStringArray()));
	godot::ClassDB::bind_method(godot::D_METHOD("fetch_heightfield_layer_image", "part_id"), &HEGoAssetNode::fetch_heightfield_layer_image);
	godot::ClassDB::bind_method(godot::D_METHOD("get_heightfield_fields", "read_prim_attribs"), &HEGoAssetNode::get_heightfield_fields, DEFVAL(godot::PackedStringArray()));
	godot::ClassDB::bind_method(godot::D_METHOD("fetch_curves", "read_prim_attribs", "read_point_attribs"), &HEGoAssetNode::fetch_curves,
			DEFVAL(godot::PackedStringArray()), DEFVAL(godot::PackedStringArray()));
	godot::ClassDB::bind_method(godot::D_METHOD("reset_node_id"), &HEGoAssetNode::reset_node_id);
	ADD_PROPERTY(godot::PropertyInfo(godot::Variant::STRING, "op_name"), "set_op_name", "get_op_name");

	godot::ClassDB::bind_integer_constant(get_class_static(), "", "CURVE_TYPE_BEZIER", HEGo::Util::CURVE_TYPE_BEZIER);
	godot::ClassDB::bind_integer_constant(get_class_static(), "", "CURVE_TYPE_NURBS", HEGo::Util::CURVE_TYPE_NURBS);
	godot::ClassDB::bind_integer_constant(get_class_static(), "", "CURVE_TYPE_LINEAR", HEGo::Util::CURVE_TYPE_LINEAR);
}

} // namespace HEGo
