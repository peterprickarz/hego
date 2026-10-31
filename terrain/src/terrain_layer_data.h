#ifndef STRATA_LAYER_DATA_H
#define STRATA_LAYER_DATA_H

#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/core/binder_common.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/string_name.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector2i.hpp>
#include <godot_cpp/variant/vector3.hpp>
#include <godot_cpp/variant/rect2.hpp>
#include <godot_cpp/variant/rect2i.hpp>

#include <cstdint>
#include <map>
#include <utility>
#include <vector>

namespace Strata {

// Native samples are uniquely owned by a 256 x 256 tile. Ownership is binary;
// interpolation coverage is computed on demand and is never persisted as paint.
class StrataLayerData : public godot::Resource {

    GDCLASS(StrataLayerData, godot::Resource)

public:
    static constexpr int TILE_SIZE = 256;
    static constexpr int TILE_SAMPLE_COUNT = TILE_SIZE * TILE_SIZE;
    static constexpr int64_t FORMAT_VERSION = 2;
    // Per-channel value storage. The public API is always float: unorm channels clamp values to
    // 0..1 on write, quantize to nearest, and return the dequantized value (q / 255 or q / 65535).
    enum ValueFormat {
        VALUE_FLOAT32 = 0,
        VALUE_UNORM8 = 1,
        VALUE_UNORM16 = 2,
    };
    static constexpr int64_t MAX_DENSE_SAMPLES = 20 * 1024 * 1024;

    StrataLayerData();
    void set_format_version(int64_t p_version);
    int64_t get_format_version() const;
    void set_sample_spacing(double p_spacing);
    double get_sample_spacing() const;
    void set_grid_origin(godot::Vector2 p_origin);
    godot::Vector2 get_grid_origin() const;
    void set_channels(const godot::Dictionary &p_channels);
    godot::Dictionary get_channels() const;

    void set_sample(godot::StringName p_channel, godot::Vector2i p_index, double p_value);
    void erase_sample(godot::StringName p_channel, godot::Vector2i p_index);
    bool has_sample(godot::StringName p_channel, godot::Vector2i p_index) const;
    double get_sample(godot::StringName p_channel, godot::Vector2i p_index) const;
    godot::Array get_owned_samples(godot::StringName p_channel) const;
    godot::Dictionary sample_channel(godot::StringName p_channel, godot::Vector2 p_position) const;
    void clear_channel(godot::StringName p_channel);
    // Format of a channel's stored values. Changing it is allowed only while the channel has no
    // samples (returns false otherwise, and for an invalid format); the format then persists
    // across clear_channel and serialization. Channels default to VALUE_FLOAT32.
    bool set_channel_format(godot::StringName p_channel, int64_t p_format);
    int64_t get_channel_format(godot::StringName p_channel) const;
    // Retained tile bytes (values + ownership) of one channel, or of all channels when empty.
    int64_t get_memory_bytes(godot::StringName p_channel = godot::StringName()) const;
    godot::PackedStringArray get_channel_names() const;
    godot::Dictionary snapshot() const;
    void restore(const godot::Dictionary &p_snapshot);
    int64_t get_revision() const;
    // Revision at which this channel last changed: a dab on one channel leaves every other
    // channel's value unchanged, so caches keyed on one channel survive edits to the rest.
    // Grid changes and whole-resource loads/restores advance every channel. Comparable only
    // with values from the same resource; get_revision() still advances on every change.
    int64_t get_channel_revision(godot::StringName p_channel) const;
    // Dense imports bound retained tile storage to 512 MiB, including other
    // channels. Legacy sparse edits/restore have no such cap. Atomic replacement
    // temporarily retains both old and new channels plus transport images.
    bool replace_dense(godot::StringName p_channel, godot::Vector2i p_index_origin, const godot::Ref<godot::Image> &p_image, const godot::Ref<godot::Image> &p_ownership = godot::Ref<godot::Image>());
    godot::Dictionary read_dense(godot::StringName p_channel, godot::Vector2i p_index_origin, godot::Vector2i p_resolution) const;
    // Region edits. Each touches only the rectangle it is given and emits one change, so a
    // brush dab or an undo step is a single edit rather than one per sample.
    // patch_dense writes the image's values where the mask is 1 (everywhere with no mask);
    // erase_dense erases samples where the mask is 1; restore_dense is the inverse of
    // read_dense: write where ownership is 1, erase where it is 0.
    bool patch_dense(godot::StringName p_channel, godot::Vector2i p_index_origin, const godot::Ref<godot::Image> &p_image, const godot::Ref<godot::Image> &p_mask = godot::Ref<godot::Image>());
    bool erase_dense(godot::StringName p_channel, godot::Vector2i p_index_origin, const godot::Ref<godot::Image> &p_mask);
    bool restore_dense(godot::StringName p_channel, godot::Vector2i p_index_origin, const godot::Ref<godot::Image> &p_image, const godot::Ref<godot::Image> &p_ownership);
    godot::Rect2i get_owned_rect(godot::StringName p_channel) const;
    static godot::Dictionary validate_dense(const godot::Ref<godot::Image> &p_image, const godot::Ref<godot::Image> &p_ownership = godot::Ref<godot::Image>());
    // Registry-order scalar fields (1 to 32), one lattice up to 20 Mi samples (aggregate input at most 256 Mi samples). Mechanical top4
    // selection only; all habitat/placement rules remain in the producer.
    static godot::Dictionary pack_material_weights(const godot::Array &p_images, int64_t p_weights_format = godot::Image::FORMAT_RGBAF);
    // Same packing for editor views of a partially assigned stack: a texel whose weights
    // are all zero becomes four zero weights with ID 0 instead of failing the pack.
    // Adds "unassigned" (texel count) and "empty"; with unassigned texels the coverage
    // and discarded-weight diagnostics describe the assigned texels only.
    static godot::Dictionary pack_material_weights_sparse(const godot::Array &p_images, int64_t p_weights_format = godot::Image::FORMAT_RGBAF);
    // Validates a categorical-ID/weight image pair for the renderer's control textures and returns
    // {ok, message, weights}: RGBA8 weights stay RGBA8 (bytes of an assigned texel renormalized to sum
    // to 255); any other format is converted and returned as RGBAF with every texel whose four weights sum above zero
    // divided by that sum (double precision, rounded once to float); zero-sum texels are kept as
    // they are. IDs must be RGBA8 bytes below p_material_count; weights finite and nonnegative.
    static godot::Dictionary prepare_control_maps(const godot::Ref<godot::Image> &p_ids, const godot::Ref<godot::Image> &p_weights, int64_t p_material_count);
    // Captured descriptors: data, origin/step_x/step_y (physical Vector3),
    // mode (0 replace/1 add), height_offset (scalar, normally plane Y).
    static godot::Dictionary compose_dense(const godot::Array &p_layers, godot::StringName p_channel,
            godot::Vector3 p_origin, godot::Vector3 p_step_x, godot::Vector3 p_step_y, godot::Vector2i p_resolution,
            godot::Rect2 p_bounds, bool p_include_coverage = true, double p_subtract_datum = 0.0,
            godot::Vector2i p_index_offset = godot::Vector2i());
    // Region composition helpers (pure functions, safe to call from worker threads):
    // quantize_material_weights turns an RGBAF weight image into the RGBA8 bytes of the editor
    // material maps; downsample_samples / downsample_materials are one mip step (see the
    // definitions for the three sample modes).
    static godot::Dictionary quantize_material_weights(const godot::Ref<godot::Image> &p_weights);
    static godot::PackedFloat32Array downsample_samples(const godot::PackedFloat32Array &p_values, int64_t p_planes, godot::Vector2i p_source, godot::Vector2i p_target, int64_t p_apron, int64_t p_mode);
    static godot::Dictionary downsample_materials(const godot::PackedByteArray &p_ids, const godot::PackedByteArray &p_weights, godot::Vector2i p_source, godot::Vector2i p_target, int64_t p_apron);
    static godot::Dictionary compile_cell_mask(const godot::Array &p_layers, godot::StringName p_channel,
            godot::Rect2 p_bounds, godot::Vector2i p_vertex_resolution, int64_t p_max_work = 268435456, int p_max_fragments = 4096);

protected:
    static void _bind_methods();

private:
    using TileKey = std::pair<int32_t, int32_t>;
    struct Tile {
        // Little-endian value bytes: 4, 1 or 2 per sample by format; unowned samples are zero.
        uint8_t format = VALUE_FLOAT32;
        std::vector<uint8_t> data;
        std::vector<uint8_t> ownership = std::vector<uint8_t>(TILE_SAMPLE_COUNT, 0);
        int owned_count = 0;
        Tile() : Tile(VALUE_FLOAT32) {}
        explicit Tile(int p_format);
        float value(int p_offset) const;
        // Stores the (quantized) value; returns whether the stored bytes changed.
        bool store(int p_offset, float p_value);
        void clear(int p_offset);
        bool operator==(const Tile &p_other) const;
    };
    using Channel = std::map<TileKey, Tile>;
    using Channels = std::map<godot::String, Channel>;
    using Formats = std::map<godot::String, int>;
    static int bytes_per_value(int p_format);
    static int64_t tile_bytes(int p_format);
    struct GridSampler;
    struct MaskSampler;
    static godot::Dictionary pack_material_weights_impl(const godot::Array &p_images, bool p_allow_unassigned, int64_t p_weights_format);

    double sample_spacing = 1.0;
    godot::Vector2 grid_origin;
    Channels channels;
    // Non-default formats only (a missing entry is VALUE_FLOAT32).
    Formats formats;
    int64_t revision = 0;
    // See get_channel_revision(): per-channel last change, and the last change of all.
    std::map<godot::String, int64_t> channel_revisions;
    int64_t layout_revision = 0;
    // Canonical Resource storage is one versioned serialized_data snapshot.
    // This guard also rejects later payload setters after an unsupported manual
    // format declaration; restore() validates its own version atomically.
    bool serialized_version_supported = true;

    static int32_t tile_coordinate(int32_t p_index);
    static TileKey tile_key(godot::Vector2i p_index);
    static int tile_offset(godot::Vector2i p_index);
    static bool decode_channels(const godot::Dictionary &p_source, int p_version, const Formats &p_legacy_formats, Channels &r_channels, Formats &r_formats);
    int format_of(const godot::String &p_channel) const;
    Tile &tile_for(Channel &p_channel, const godot::String &p_name, TileKey p_key);
    int64_t retained_bytes(const godot::String &p_except = godot::String()) const;
    static bool valid_spacing(double p_spacing);
    static bool valid_origin(godot::Vector2 p_origin);
    const Tile *find_tile(const godot::String &p_channel, godot::Vector2i p_index) const;
    bool edit_dense(const godot::String &p_channel, godot::Vector2i p_index_origin, godot::Vector2i p_size, const godot::Ref<godot::Image> &p_image, const godot::Ref<godot::Image> &p_mask, bool p_write_selected, bool p_erase_unselected);
    void mark_changed();
    void mark_channel_changed(const godot::String &p_channel);
};

} // namespace Strata

VARIANT_ENUM_CAST(Strata::StrataLayerData::ValueFormat);

#endif
