#ifndef STRATA_LAYER_DATA_H
#define STRATA_LAYER_DATA_H

#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
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
    static constexpr int64_t FORMAT_VERSION = 1;
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
    // Registry-order scalar fields (1 to 32), one lattice <=1025². Mechanical top4
    // selection only; all habitat/placement rules remain in the producer.
    static godot::Dictionary pack_material_weights(const godot::Array &p_images);
    // Same packing for editor views of a partially assigned stack: a texel whose weights
    // are all zero becomes four zero weights with ID 0 instead of failing the pack.
    // Adds "unassigned" (texel count) and "empty"; with unassigned texels the coverage
    // and discarded-weight diagnostics describe the assigned texels only.
    static godot::Dictionary pack_material_weights_sparse(const godot::Array &p_images);
    // Captured descriptors: data, origin/step_x/step_y (physical Vector3),
    // mode (0 replace/1 add), height_offset (scalar, normally plane Y).
    static godot::Dictionary compose_dense(const godot::Array &p_layers, godot::StringName p_channel,
            godot::Vector3 p_origin, godot::Vector3 p_step_x, godot::Vector3 p_step_y, godot::Vector2i p_resolution,
            godot::Rect2 p_bounds, bool p_include_coverage = true, double p_subtract_datum = 0.0,
            godot::Vector2i p_index_offset = godot::Vector2i());
    static godot::Dictionary compile_cell_mask(const godot::Array &p_layers, godot::StringName p_channel,
            godot::Rect2 p_bounds, godot::Vector2i p_vertex_resolution, int64_t p_max_work = 268435456, int p_max_fragments = 4096);

protected:
    static void _bind_methods();

private:
    using TileKey = std::pair<int32_t, int32_t>;
    struct Tile {
        std::vector<float> values = std::vector<float>(TILE_SAMPLE_COUNT, 0.0f);
        std::vector<uint8_t> ownership = std::vector<uint8_t>(TILE_SAMPLE_COUNT, 0);
        int owned_count = 0;
        bool operator==(const Tile &p_other) const;
    };
    using Channel = std::map<TileKey, Tile>;
    using Channels = std::map<godot::String, Channel>;
    struct GridSampler;
    struct MaskSampler;
    static godot::Dictionary pack_material_weights_impl(const godot::Array &p_images, bool p_allow_unassigned);

    double sample_spacing = 1.0;
    godot::Vector2 grid_origin;
    Channels channels;
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
    static bool decode_channels(const godot::Dictionary &p_source, Channels &r_channels);
    static bool valid_spacing(double p_spacing);
    static bool valid_origin(godot::Vector2 p_origin);
    const Tile *find_tile(const godot::String &p_channel, godot::Vector2i p_index) const;
    bool edit_dense(const godot::String &p_channel, godot::Vector2i p_index_origin, godot::Vector2i p_size, const godot::Ref<godot::Image> &p_image, const godot::Ref<godot::Image> &p_mask, bool p_write_selected, bool p_erase_unselected);
    void mark_changed();
    void mark_channel_changed(const godot::String &p_channel);
};

} // namespace Strata

#endif
