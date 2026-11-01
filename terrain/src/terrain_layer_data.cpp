#include "terrain_layer_data.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/error_macros.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>

#include <cstring>

#include <algorithm>
#include <cmath>
#include <limits>
#include <set>

using namespace godot;

namespace Strata {

StrataLayerData::StrataLayerData() {
    set_local_to_scene(true);
}

void StrataLayerData::_bind_methods() {
    ClassDB::bind_method(D_METHOD("set_format_version", "version"), &StrataLayerData::set_format_version);
    ClassDB::bind_method(D_METHOD("get_format_version"), &StrataLayerData::get_format_version);
    ClassDB::bind_method(D_METHOD("set_sample_spacing", "spacing"), &StrataLayerData::set_sample_spacing);
    ClassDB::bind_method(D_METHOD("get_sample_spacing"), &StrataLayerData::get_sample_spacing);
    ClassDB::bind_method(D_METHOD("set_grid_origin", "origin"), &StrataLayerData::set_grid_origin);
    ClassDB::bind_method(D_METHOD("get_grid_origin"), &StrataLayerData::get_grid_origin);
    ClassDB::bind_method(D_METHOD("set_channels", "channels"), &StrataLayerData::set_channels);
    ClassDB::bind_method(D_METHOD("get_channels"), &StrataLayerData::get_channels);
    ClassDB::bind_method(D_METHOD("set_sample", "channel", "index", "value"), &StrataLayerData::set_sample);
    ClassDB::bind_method(D_METHOD("erase_sample", "channel", "index"), &StrataLayerData::erase_sample);
    ClassDB::bind_method(D_METHOD("has_sample", "channel", "index"), &StrataLayerData::has_sample);
    ClassDB::bind_method(D_METHOD("get_sample", "channel", "index"), &StrataLayerData::get_sample);
    ClassDB::bind_method(D_METHOD("get_owned_samples", "channel"), &StrataLayerData::get_owned_samples);
    ClassDB::bind_method(D_METHOD("sample_channel", "channel", "position"), &StrataLayerData::sample_channel);
    ClassDB::bind_method(D_METHOD("clear_channel", "channel"), &StrataLayerData::clear_channel);
    ClassDB::bind_method(D_METHOD("set_channel_format", "channel", "format"), &StrataLayerData::set_channel_format);
    ClassDB::bind_method(D_METHOD("get_channel_format", "channel"), &StrataLayerData::get_channel_format);
    ClassDB::bind_method(D_METHOD("get_memory_bytes", "channel"), &StrataLayerData::get_memory_bytes, DEFVAL(StringName()));
    ClassDB::bind_method(D_METHOD("get_channel_names"), &StrataLayerData::get_channel_names);
    ClassDB::bind_method(D_METHOD("snapshot"), &StrataLayerData::snapshot);
    ClassDB::bind_method(D_METHOD("restore", "snapshot"), &StrataLayerData::restore);
    ClassDB::bind_method(D_METHOD("get_revision"), &StrataLayerData::get_revision);
    ClassDB::bind_method(D_METHOD("get_channel_revision", "channel"), &StrataLayerData::get_channel_revision);
    ClassDB::bind_method(D_METHOD("replace_dense", "channel", "index_origin", "image", "ownership"), &StrataLayerData::replace_dense, DEFVAL(Ref<Image>()));
    ClassDB::bind_method(D_METHOD("read_dense", "channel", "index_origin", "resolution"), &StrataLayerData::read_dense);
    ClassDB::bind_method(D_METHOD("patch_dense", "channel", "index_origin", "image", "mask"), &StrataLayerData::patch_dense, DEFVAL(Ref<Image>()));
    ClassDB::bind_method(D_METHOD("erase_dense", "channel", "index_origin", "mask"), &StrataLayerData::erase_dense);
    ClassDB::bind_method(D_METHOD("restore_dense", "channel", "index_origin", "image", "ownership"), &StrataLayerData::restore_dense);
    ClassDB::bind_method(D_METHOD("get_owned_rect", "channel"), &StrataLayerData::get_owned_rect);
    ClassDB::bind_static_method("StrataLayerData", D_METHOD("validate_dense", "image", "ownership"), &StrataLayerData::validate_dense, DEFVAL(Ref<Image>()));
    ClassDB::bind_static_method("StrataLayerData", D_METHOD("pack_material_weights", "images", "weights_format"), &StrataLayerData::pack_material_weights, DEFVAL(int64_t(Image::FORMAT_RGBAF)));
    ClassDB::bind_static_method("StrataLayerData", D_METHOD("pack_material_weights_sparse", "images", "weights_format"), &StrataLayerData::pack_material_weights_sparse, DEFVAL(int64_t(Image::FORMAT_RGBAF)));
    ClassDB::bind_static_method("StrataLayerData", D_METHOD("prepare_control_maps", "ids", "weights", "material_count"), &StrataLayerData::prepare_control_maps);
    ClassDB::bind_static_method("StrataLayerData", D_METHOD("compose_dense", "layers", "channel", "origin", "step_x", "step_y", "resolution", "bounds", "include_coverage", "subtract_datum", "index_offset"), &StrataLayerData::compose_dense, DEFVAL(true), DEFVAL(0.0), DEFVAL(Vector2i()));
    ClassDB::bind_static_method("StrataLayerData", D_METHOD("compile_cell_mask", "layers", "channel", "bounds", "vertex_resolution", "max_work", "max_fragments"), &StrataLayerData::compile_cell_mask, DEFVAL(int64_t(268435456)), DEFVAL(4096));
    ClassDB::bind_static_method("StrataLayerData", D_METHOD("quantize_material_weights", "weights"), &StrataLayerData::quantize_material_weights);
    ClassDB::bind_static_method("StrataLayerData", D_METHOD("downsample_samples", "values", "planes", "source_size", "target_size", "apron", "mode"), &StrataLayerData::downsample_samples);
    ClassDB::bind_static_method("StrataLayerData", D_METHOD("downsample_materials", "ids", "weights", "source_size", "target_size", "apron"), &StrataLayerData::downsample_materials);
    BIND_ENUM_CONSTANT(VALUE_FLOAT32);
    BIND_ENUM_CONSTANT(VALUE_UNORM8);
    BIND_ENUM_CONSTANT(VALUE_UNORM16);
    // Godot omits properties equal to their class defaults. Serializing a
    // standalone version=1 property would therefore lose the declaration.
    // Persist one complete snapshot instead: every nondefault payload carries
    // its version and validates grid plus samples as one transaction. A wholly
    // default empty resource may omit it and reloads as the default empty v1.
    ADD_PROPERTY(PropertyInfo(Variant::INT, "format_version", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NONE), "set_format_version", "get_format_version");
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "sample_spacing", PROPERTY_HINT_RANGE, "0.000001,1000000,0.001,or_greater", PROPERTY_USAGE_EDITOR), "set_sample_spacing", "get_sample_spacing");
    ADD_PROPERTY(PropertyInfo(Variant::VECTOR2, "grid_origin", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR), "set_grid_origin", "get_grid_origin");
    ADD_PROPERTY(PropertyInfo(Variant::DICTIONARY, "channels", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NONE), "set_channels", "get_channels");
    ADD_PROPERTY(PropertyInfo(Variant::DICTIONARY, "serialized_data", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE), "restore", "snapshot");
}

int StrataLayerData::bytes_per_value(int p_format) {
    return p_format == VALUE_UNORM8 ? 1 : p_format == VALUE_UNORM16 ? 2 : 4;
}

int64_t StrataLayerData::tile_bytes(int p_format) {
    return int64_t(TILE_SAMPLE_COUNT) * (bytes_per_value(p_format) + 1);
}

StrataLayerData::Tile::Tile(int p_format) : format(uint8_t(p_format)), data(size_t(TILE_SAMPLE_COUNT) * bytes_per_value(p_format), 0) {}

float StrataLayerData::Tile::value(int p_offset) const {
    if (format == VALUE_UNORM8) {
        return float(data[p_offset]) / 255.0f;
    }
    if (format == VALUE_UNORM16) {
        return float(uint32_t(data[p_offset * 2]) | (uint32_t(data[p_offset * 2 + 1]) << 8)) / 65535.0f;
    }
    float result;
    std::memcpy(&result, data.data() + size_t(p_offset) * 4, 4);
    return result;
}

bool StrataLayerData::Tile::store(int p_offset, float p_value) {
    if (format == VALUE_UNORM8) {
        const uint8_t q = uint8_t(std::floor(std::clamp(double(p_value), 0.0, 1.0) * 255.0 + 0.5));
        const bool changed = data[p_offset] != q;
        data[p_offset] = q;
        return changed;
    }
    if (format == VALUE_UNORM16) {
        const uint32_t q = uint32_t(std::floor(std::clamp(double(p_value), 0.0, 1.0) * 65535.0 + 0.5));
        const bool changed = data[p_offset * 2] != (q & 255) || data[p_offset * 2 + 1] != (q >> 8);
        data[p_offset * 2] = uint8_t(q & 255);
        data[p_offset * 2 + 1] = uint8_t(q >> 8);
        return changed;
    }
    const bool changed = std::memcmp(data.data() + size_t(p_offset) * 4, &p_value, 4) != 0;
    std::memcpy(data.data() + size_t(p_offset) * 4, &p_value, 4);
    return changed;
}

void StrataLayerData::Tile::clear(int p_offset) {
    const int width = bytes_per_value(format);
    std::memset(data.data() + size_t(p_offset) * width, 0, width);
    ownership[p_offset] = 0;
}

bool StrataLayerData::Tile::operator==(const Tile &p_other) const {
    return format == p_other.format && ownership == p_other.ownership && data == p_other.data;
}

int StrataLayerData::format_of(const String &p_channel) const {
    const auto found = formats.find(p_channel);
    return found == formats.end() ? int(VALUE_FLOAT32) : found->second;
}

StrataLayerData::Tile &StrataLayerData::tile_for(Channel &p_channel, const String &p_name, TileKey p_key) {
    const auto found = p_channel.find(p_key);
    if (found != p_channel.end()) {
        return found->second;
    }
    return p_channel.emplace(p_key, Tile(format_of(p_name))).first->second;
}

int64_t StrataLayerData::retained_bytes(const String &p_except) const {
    int64_t total = 0;
    for (const auto &entry : channels) {
        if (entry.first != p_except) {
            total += int64_t(entry.second.size()) * tile_bytes(format_of(entry.first));
        }
    }
    return total;
}

bool StrataLayerData::set_channel_format(StringName p_channel, int64_t p_format) {
    const String name = p_channel;
    if (name.is_empty() || p_format < VALUE_FLOAT32 || p_format > VALUE_UNORM16) {
        return false;
    }
    if (format_of(name) == p_format) {
        return true;
    }
    if (channels.find(name) != channels.end()) {
        return false;
    }
    if (p_format == VALUE_FLOAT32) {
        formats.erase(name);
    } else {
        formats[name] = int(p_format);
    }
    mark_channel_changed(name);
    return true;
}

int64_t StrataLayerData::get_channel_format(StringName p_channel) const {
    return format_of(String(p_channel));
}

int64_t StrataLayerData::get_memory_bytes(StringName p_channel) const {
    const String name = p_channel;
    if (name.is_empty()) {
        return retained_bytes();
    }
    const auto found = channels.find(name);
    return found == channels.end() ? 0 : int64_t(found->second.size()) * tile_bytes(format_of(name));
}

int32_t StrataLayerData::tile_coordinate(int32_t p_index) {
    // C++ truncates division toward zero; tile addressing requires floor.
    const int32_t quotient = p_index / TILE_SIZE;
    return quotient - (p_index % TILE_SIZE < 0 ? 1 : 0);
}

StrataLayerData::TileKey StrataLayerData::tile_key(Vector2i p_index) {
    return {tile_coordinate(p_index.x), tile_coordinate(p_index.y)};
}

int StrataLayerData::tile_offset(Vector2i p_index) {
    const int x = p_index.x % TILE_SIZE;
    const int y = p_index.y % TILE_SIZE;
    return (y < 0 ? y + TILE_SIZE : y) * TILE_SIZE + (x < 0 ? x + TILE_SIZE : x);
}

bool StrataLayerData::valid_spacing(double p_spacing) {
    return std::isfinite(p_spacing) && p_spacing > 0.0;
}

bool StrataLayerData::valid_origin(Vector2 p_origin) {
    return std::isfinite(p_origin.x) && std::isfinite(p_origin.y);
}

void StrataLayerData::mark_changed() {
    if (revision < std::numeric_limits<int64_t>::max()) {
        ++revision;
    }
    layout_revision = revision;
    emit_changed();
}

void StrataLayerData::mark_channel_changed(const String &p_channel) {
    if (revision < std::numeric_limits<int64_t>::max()) {
        ++revision;
    }
    channel_revisions[p_channel] = revision;
    emit_changed();
}

void StrataLayerData::set_format_version(int64_t p_version) {
    // Do not reinterpret data from a future format as version 1. Rejecting the
    // declaration never changes the accepted grid, samples, or revision.
    serialized_version_supported = p_version == 1 || p_version == FORMAT_VERSION;
    ERR_FAIL_COND_MSG(!serialized_version_supported, "Unsupported terrain layer format version; serialized channels will be rejected. Expected version 1 or 2.");
}

int64_t StrataLayerData::get_format_version() const { return FORMAT_VERSION; }

void StrataLayerData::set_sample_spacing(double p_spacing) {
    ERR_FAIL_COND_MSG(!serialized_version_supported, "Cannot load terrain sample spacing after an unsupported format version.");
    ERR_FAIL_COND_MSG(!valid_spacing(p_spacing), "Terrain sample spacing must be finite and positive.");
    if (sample_spacing != p_spacing) {
        ERR_FAIL_COND_MSG(!channels.empty(), "Cannot change sample spacing on populated terrain. Explicitly resample/rebuild the layer, or restore a complete validated snapshot.");
        sample_spacing = p_spacing;
        mark_changed();
    }
}

double StrataLayerData::get_sample_spacing() const { return sample_spacing; }

void StrataLayerData::set_grid_origin(Vector2 p_origin) {
    ERR_FAIL_COND_MSG(!serialized_version_supported, "Cannot load terrain grid origin after an unsupported format version.");
    ERR_FAIL_COND_MSG(!valid_origin(p_origin), "Terrain grid origin must be finite.");
    if (grid_origin != p_origin) {
        ERR_FAIL_COND_MSG(!channels.empty(), "Cannot change grid origin on populated terrain. Explicitly resample/rebuild the layer, or restore a complete validated snapshot.");
        grid_origin = p_origin;
        mark_changed();
    }
}

Vector2 StrataLayerData::get_grid_origin() const { return grid_origin; }

const StrataLayerData::Tile *StrataLayerData::find_tile(const String &p_channel, Vector2i p_index) const {
    const auto channel_it = channels.find(p_channel);
    if (channel_it == channels.end()) {
        return nullptr;
    }
    const auto tile_it = channel_it->second.find(tile_key(p_index));
    return tile_it == channel_it->second.end() ? nullptr : &tile_it->second;
}

void StrataLayerData::set_sample(StringName p_channel, Vector2i p_index, double p_value) {
    const String name = p_channel;
    ERR_FAIL_COND_MSG(name.is_empty(), "Terrain channel names must not be empty.");
    ERR_FAIL_COND_MSG(!std::isfinite(p_value) || std::abs(p_value) > std::numeric_limits<float>::max(), "Terrain values must be finite float32 values.");
    const float value = static_cast<float>(p_value);
    Tile &tile = tile_for(channels[name], name, tile_key(p_index));
    const int offset = tile_offset(p_index);
    const bool was_owned = tile.ownership[offset] != 0;
    const bool changed = tile.store(offset, value);
    if (was_owned && !changed) {
        return;
    }
    if (!was_owned) {
        tile.ownership[offset] = 1;
        ++tile.owned_count;
    }
    mark_channel_changed(name);
}

void StrataLayerData::erase_sample(StringName p_channel, Vector2i p_index) {
    auto channel_it = channels.find(String(p_channel));
    if (channel_it == channels.end()) {
        return;
    }
    auto tile_it = channel_it->second.find(tile_key(p_index));
    if (tile_it == channel_it->second.end()) {
        return;
    }
    Tile &tile = tile_it->second;
    const int offset = tile_offset(p_index);
    if (!tile.ownership[offset]) {
        return;
    }
    tile.clear(offset);
    if (--tile.owned_count == 0) {
        channel_it->second.erase(tile_it);
        if (channel_it->second.empty()) {
            channels.erase(channel_it);
        }
    }
    mark_channel_changed(String(p_channel));
}

bool StrataLayerData::has_sample(StringName p_channel, Vector2i p_index) const {
    const Tile *tile = find_tile(String(p_channel), p_index);
    return tile && tile->ownership[tile_offset(p_index)] != 0;
}

double StrataLayerData::get_sample(StringName p_channel, Vector2i p_index) const {
    const Tile *tile = find_tile(String(p_channel), p_index);
    const int offset = tile_offset(p_index);
    return tile && tile->ownership[offset] ? double(tile->value(offset)) : 0.0;
}

Array StrataLayerData::get_owned_samples(StringName p_channel) const {
    Array result;
    const auto channel_it = channels.find(String(p_channel));
    if (channel_it == channels.end()) {
        return result;
    }
    for (const auto &entry : channel_it->second) {
        const Tile &tile = entry.second;
        for (int offset = 0; offset < TILE_SAMPLE_COUNT; ++offset) {
            if (tile.ownership[offset]) {
                result.push_back(Vector2i(entry.first.first * TILE_SIZE + offset % TILE_SIZE,
                        entry.first.second * TILE_SIZE + offset / TILE_SIZE));
            }
        }
    }
    return result;
}

Dictionary StrataLayerData::sample_channel(StringName p_channel, Vector2 p_position) const {
    Dictionary result;
    result["value"] = 0.0;
    result["coverage"] = 0.0;
    ERR_FAIL_COND_V_MSG(!valid_origin(p_position), result, "Terrain sample position must be finite.");
    double x = (static_cast<double>(p_position.x) - grid_origin.x) / sample_spacing;
    double y = (static_cast<double>(p_position.y) - grid_origin.y) / sample_spacing;
    // Out-of-range neighbors are unowned. Bound before integer conversion to
    // avoid undefined conversion/overflow at the signed index limits.
    const double min_index = std::numeric_limits<int32_t>::min();
    const double max_index = std::numeric_limits<int32_t>::max();
    if (!std::isfinite(x) || !std::isfinite(y) || x <= min_index - 1.0 || x >= max_index + 1.0 || y <= min_index - 1.0 || y >= max_index + 1.0) {
        return result;
    }
    // Match the frontend's physical point expression exactly:
    // grid_origin + Vector2(index) * sample_spacing. In float32 Vector2 builds,
    // decimal grids otherwise reconstruct a value just beside the integer.
    // Snap only an exact representable native coordinate, never an epsilon
    // neighborhood: tiny but representable off-grid ownership coverage remains.
    // At extreme origin/spacing ratios multiple indices can encode the same
    // Vector2 coordinate; callers must keep grids within Vector2 precision.
    const auto native_coordinate = [this, min_index, max_index](double p_coordinate, real_t p_world, real_t p_origin) {
        const double nearest = std::round(p_coordinate);
        if (nearest >= min_index && nearest <= max_index) {
            const Vector2 offset = Vector2(static_cast<real_t>(nearest), 0) * static_cast<real_t>(sample_spacing);
            const Vector2 physical = Vector2(p_origin, 0) + offset;
            if (p_world == physical.x) {
                return nearest;
            }
        }
        return p_coordinate;
    };
    x = native_coordinate(x, p_position.x, grid_origin.x);
    y = native_coordinate(y, p_position.y, grid_origin.y);
    const double floor_x = std::floor(x);
    const double floor_y = std::floor(y);
    const double fraction_x = x - floor_x;
    const double fraction_y = y - floor_y;
    double numerator = 0.0;
    double coverage = 0.0;
    const String name = p_channel;
    for (int dy = 0; dy < 2; ++dy) {
        for (int dx = 0; dx < 2; ++dx) {
            const double weight = (dx ? fraction_x : 1.0 - fraction_x) * (dy ? fraction_y : 1.0 - fraction_y);
            const double index_x = floor_x + dx;
            const double index_y = floor_y + dy;
            if (weight <= 0.0 || index_x < min_index || index_x > max_index || index_y < min_index || index_y > max_index) {
                continue;
            }
            const Vector2i index(static_cast<int32_t>(index_x), static_cast<int32_t>(index_y));
            const Tile *tile = find_tile(name, index);
            const int offset = tile_offset(index);
            if (tile && tile->ownership[offset]) {
                numerator += weight * tile->value(offset);
                coverage += weight;
            }
        }
    }
    if (coverage > 0.0) {
        result["value"] = numerator / coverage;
        result["coverage"] = coverage;
    }
    return result;
}

void StrataLayerData::clear_channel(StringName p_channel) {
    if (channels.erase(String(p_channel)) != 0) {
        mark_channel_changed(String(p_channel));
    }
}

PackedStringArray StrataLayerData::get_channel_names() const {
    PackedStringArray names;
    for (const auto &entry : channels) {
        names.push_back(entry.first);
    }
    return names;
}

Dictionary StrataLayerData::get_channels() const {
    // Legacy v1 view: every channel as PackedFloat32Array tiles (dequantized for unorm channels).
    Dictionary result;
    for (const auto &channel : channels) {
        Dictionary tiles;
        for (const auto &entry : channel.second) {
            PackedFloat32Array values;
            PackedByteArray ownership;
            values.resize(TILE_SAMPLE_COUNT);
            ownership.resize(TILE_SAMPLE_COUNT);
            float *value_data = values.ptrw();
            uint8_t *ownership_data = ownership.ptrw();
            for (int i = 0; i < TILE_SAMPLE_COUNT; ++i) {
                value_data[i] = entry.second.value(i);
            }
            std::copy(entry.second.ownership.begin(), entry.second.ownership.end(), ownership_data);
            Dictionary tile;
            tile["values"] = values;
            tile["ownership"] = ownership;
            tiles[Vector2i(entry.first.first, entry.first.second)] = tile;
        }
        result[channel.first] = tiles;
    }
    return result;
}

bool StrataLayerData::decode_channels(const Dictionary &p_source, int p_version, const Formats &p_legacy_formats, Channels &r_channels, Formats &r_formats) {
    Channels decoded;
    Formats decoded_formats;
    std::set<String> seen_names;
    const Array channel_keys = p_source.keys();
    for (int64_t c = 0; c < channel_keys.size(); ++c) {
        const Variant channel_key = channel_keys[c];
        ERR_FAIL_COND_V_MSG(channel_key.get_type() != Variant::STRING && channel_key.get_type() != Variant::STRING_NAME, false, "Terrain channel keys must be strings.");
        const String name = channel_key;
        ERR_FAIL_COND_V_MSG(name.is_empty() || !seen_names.insert(name).second, false, "Terrain channel names must be nonempty and unique.");
        const Variant channel_variant = p_source[channel_key];
        ERR_FAIL_COND_V_MSG(channel_variant.get_type() != Variant::DICTIONARY, false, "Terrain channels must contain tile dictionaries.");
        Dictionary tiles = channel_variant;
        int format = VALUE_FLOAT32;
        if (p_version >= 2) {
            const Dictionary entry = channel_variant;
            ERR_FAIL_COND_V_MSG(entry.size() != 2 || !entry.has("format") || !entry.has("tiles"), false, "Version 2 terrain channels require format and tiles.");
            const Variant format_variant = entry["format"];
            const Variant tiles_variant = entry["tiles"];
            ERR_FAIL_COND_V_MSG(format_variant.get_type() != Variant::INT || tiles_variant.get_type() != Variant::DICTIONARY, false, "Version 2 terrain channel format must be an integer and tiles a dictionary.");
            const int64_t declared = format_variant;
            ERR_FAIL_COND_V_MSG(declared < VALUE_FLOAT32 || declared > VALUE_UNORM16, false, "Unknown terrain channel value format.");
            format = int(declared);
            tiles = tiles_variant;
        } else {
            const auto legacy = p_legacy_formats.find(name);
            format = legacy == p_legacy_formats.end() ? int(VALUE_FLOAT32) : legacy->second;
        }
        if (format != VALUE_FLOAT32) {
            decoded_formats[name] = format;
        }
        Channel channel;
        const Array keys = tiles.keys();
        for (int64_t t = 0; t < keys.size(); ++t) {
            const Variant key = keys[t];
            ERR_FAIL_COND_V_MSG(key.get_type() != Variant::VECTOR2I, false, "Terrain tile keys must be Vector2i coordinates.");
            const Vector2i tile_index = key;
            constexpr int32_t min_tile = std::numeric_limits<int32_t>::min() / TILE_SIZE;
            constexpr int32_t max_tile = std::numeric_limits<int32_t>::max() / TILE_SIZE;
            ERR_FAIL_COND_V_MSG(tile_index.x < min_tile || tile_index.x > max_tile || tile_index.y < min_tile || tile_index.y > max_tile, false, "Terrain tile coordinates exceed the signed sample index range.");
            const Variant tile_variant = tiles[key];
            ERR_FAIL_COND_V_MSG(tile_variant.get_type() != Variant::DICTIONARY, false, "Terrain tiles must be dictionaries.");
            const Dictionary tile_dict = tile_variant;
            ERR_FAIL_COND_V_MSG(tile_dict.size() != 2 || !tile_dict.has("values") || !tile_dict.has("ownership"), false, "Terrain tiles require values and ownership arrays.");
            const Variant values_variant = tile_dict["values"];
            const Variant ownership_variant = tile_dict["ownership"];
            ERR_FAIL_COND_V_MSG(ownership_variant.get_type() != Variant::PACKED_BYTE_ARRAY, false, "Terrain tile ownership must be a PackedByteArray.");
            const PackedByteArray ownership = ownership_variant;
            ERR_FAIL_COND_V_MSG(ownership.size() != TILE_SAMPLE_COUNT, false, "Terrain tile arrays must contain exactly 65536 samples.");
            Tile tile(format);
            if (format == VALUE_FLOAT32) {
                ERR_FAIL_COND_V_MSG(values_variant.get_type() != Variant::PACKED_FLOAT32_ARRAY, false, "Float32 terrain tile values must be a PackedFloat32Array.");
                const PackedFloat32Array values = values_variant;
                ERR_FAIL_COND_V_MSG(values.size() != TILE_SAMPLE_COUNT, false, "Terrain tile arrays must contain exactly 65536 samples.");
                for (int i = 0; i < TILE_SAMPLE_COUNT; ++i) {
                    ERR_FAIL_COND_V_MSG(!std::isfinite(values[i]) || ownership[i] > 1, false, "Terrain values must be finite and ownership must be binary.");
                    tile.ownership[i] = ownership[i];
                    tile.owned_count += ownership[i];
                    if (ownership[i]) {
                        tile.store(i, values[i]);
                    }
                }
            } else if (p_version >= 2) {
                ERR_FAIL_COND_V_MSG(values_variant.get_type() != Variant::PACKED_BYTE_ARRAY, false, "Unorm terrain tile values must be a PackedByteArray.");
                const PackedByteArray values = values_variant;
                ERR_FAIL_COND_V_MSG(values.size() != int64_t(tile.data.size()), false, "Unorm terrain tile values have the wrong byte count.");
                const int width = bytes_per_value(format);
                for (int i = 0; i < TILE_SAMPLE_COUNT; ++i) {
                    ERR_FAIL_COND_V_MSG(ownership[i] > 1, false, "Terrain ownership must be binary.");
                    tile.ownership[i] = ownership[i];
                    tile.owned_count += ownership[i];
                    if (ownership[i]) {
                        std::memcpy(tile.data.data() + size_t(i) * width, values.ptr() + int64_t(i) * width, width);
                    }
                }
            } else {
                // Legacy float tiles into a channel that already declares a unorm format (set_channels).
                ERR_FAIL_COND_V_MSG(values_variant.get_type() != Variant::PACKED_FLOAT32_ARRAY, false, "Terrain tile arrays must be PackedFloat32Array values and PackedByteArray ownership.");
                const PackedFloat32Array values = values_variant;
                ERR_FAIL_COND_V_MSG(values.size() != TILE_SAMPLE_COUNT, false, "Terrain tile arrays must contain exactly 65536 samples.");
                for (int i = 0; i < TILE_SAMPLE_COUNT; ++i) {
                    ERR_FAIL_COND_V_MSG(!std::isfinite(values[i]) || ownership[i] > 1, false, "Terrain values must be finite and ownership must be binary.");
                    tile.ownership[i] = ownership[i];
                    tile.owned_count += ownership[i];
                    if (ownership[i]) {
                        tile.store(i, values[i]);
                    }
                }
            }
            // Empty tiles have no native data and need not consume memory.
            if (tile.owned_count > 0) {
                channel.emplace(TileKey(tile_index.x, tile_index.y), std::move(tile));
            }
        }
        // Keep a channel entry only when it has samples; a declared non-default format
        // survives through decoded_formats.
        if (!channel.empty()) {
            decoded.emplace(name, std::move(channel));
        }
    }
    r_channels = std::move(decoded);
    r_formats = std::move(decoded_formats);
    return true;
}

void StrataLayerData::set_channels(const Dictionary &p_channels) {
    ERR_FAIL_COND_MSG(!serialized_version_supported, "Cannot load terrain channels after an unsupported format version. Declare format version 1 or 2, or restore a complete snapshot.");
    // Legacy float-tile form (what get_channels returns). Channel formats already declared on
    // this resource are kept; their values are quantized on load.
    Channels decoded;
    Formats ignored;
    if (!decode_channels(p_channels, 1, formats, decoded, ignored)) {
        return;
    }
    if (channels != decoded) {
        channels = std::move(decoded);
        mark_changed();
    }
}

Dictionary StrataLayerData::snapshot() const {
    // Format 2: channels[name] = {format:int, tiles:{Vector2i: {values, ownership}}}. Float32
    // tiles carry PackedFloat32Array values; unorm tiles carry little-endian PackedByteArray
    // values (1 or 2 bytes per sample). Ownership is one byte (0/1) per sample. Channels with a
    // non-default format but no samples are kept (empty tiles) so the format round-trips.
    Dictionary result;
    result["format_version"] = FORMAT_VERSION;
    result["sample_spacing"] = sample_spacing;
    result["grid_origin"] = grid_origin;
    Dictionary out_channels;
    const auto emit = [&](const String &p_name, const Channel *p_channel) {
        const int format = format_of(p_name);
        Dictionary tiles;
        if (p_channel) {
            for (const auto &entry : *p_channel) {
                PackedByteArray ownership;
                ownership.resize(TILE_SAMPLE_COUNT);
                std::copy(entry.second.ownership.begin(), entry.second.ownership.end(), ownership.ptrw());
                Dictionary tile;
                if (format == VALUE_FLOAT32) {
                    PackedFloat32Array values;
                    values.resize(TILE_SAMPLE_COUNT);
                    std::memcpy(values.ptrw(), entry.second.data.data(), entry.second.data.size());
                    tile["values"] = values;
                } else {
                    PackedByteArray values;
                    values.resize(int64_t(entry.second.data.size()));
                    std::memcpy(values.ptrw(), entry.second.data.data(), entry.second.data.size());
                    tile["values"] = values;
                }
                tile["ownership"] = ownership;
                tiles[Vector2i(entry.first.first, entry.first.second)] = tile;
            }
        }
        Dictionary channel;
        channel["format"] = int64_t(format);
        channel["tiles"] = tiles;
        out_channels[p_name] = channel;
    };
    for (const auto &channel : channels) {
        emit(channel.first, &channel.second);
    }
    for (const auto &declared : formats) {
        if (channels.find(declared.first) == channels.end()) {
            emit(declared.first, nullptr);
        }
    }
    result["channels"] = out_channels;
    return result;
}

void StrataLayerData::restore(const Dictionary &p_snapshot) {
    // Snapshots require an explicit integer version. Version 1 (every channel float32 tiles) and
    // version 2 (per-channel format) are accepted; missing, floating-point and other versions
    // reject the entire snapshot without mutation.
    ERR_FAIL_COND_MSG(!p_snapshot.has("format_version") || !p_snapshot.has("sample_spacing") || !p_snapshot.has("grid_origin") || !p_snapshot.has("channels"), "Terrain snapshot requires format_version, sample_spacing, grid_origin and channels.");
    const Variant version_variant = p_snapshot["format_version"];
    ERR_FAIL_COND_MSG(version_variant.get_type() != Variant::INT || (static_cast<int64_t>(version_variant) != 1 && static_cast<int64_t>(version_variant) != FORMAT_VERSION), "Unsupported terrain snapshot format_version; expected integer version 1 or 2.");
    const int version = int(static_cast<int64_t>(version_variant));
    const Variant spacing_variant = p_snapshot["sample_spacing"];
    const Variant origin_variant = p_snapshot["grid_origin"];
    const Variant channels_variant = p_snapshot["channels"];
    ERR_FAIL_COND_MSG((spacing_variant.get_type() != Variant::FLOAT && spacing_variant.get_type() != Variant::INT) || origin_variant.get_type() != Variant::VECTOR2 || channels_variant.get_type() != Variant::DICTIONARY, "Terrain snapshot has invalid field types.");
    const double spacing = spacing_variant;
    const Vector2 origin = origin_variant;
    ERR_FAIL_COND_MSG(!valid_spacing(spacing) || !valid_origin(origin), "Terrain snapshot spacing and origin must be finite, and spacing positive.");
    Channels decoded;
    Formats decoded_formats;
    if (!decode_channels(channels_variant, version, Formats(), decoded, decoded_formats)) {
        return;
    }
    serialized_version_supported = true;
    if (sample_spacing != spacing || grid_origin != origin || channels != decoded || formats != decoded_formats) {
        sample_spacing = spacing;
        grid_origin = origin;
        channels = std::move(decoded);
        formats = std::move(decoded_formats);
        mark_changed();
    }
}

int64_t StrataLayerData::get_revision() const { return revision; }

int64_t StrataLayerData::get_channel_revision(StringName p_channel) const {
    const auto found = channel_revisions.find(String(p_channel));
    return std::max(layout_revision, found == channel_revisions.end() ? int64_t(0) : found->second);
}

} // namespace Strata
