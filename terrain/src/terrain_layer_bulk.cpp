#include "terrain_layer_data.h"

#include <godot_cpp/core/error_macros.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>

using namespace godot;

namespace Strata {
namespace {
constexpr int64_t MAX_RESOURCE_TILES = (512LL * 1024 * 1024) / (65536 * 5);

Dictionary failure(const String &message) {
    Dictionary result;
    result["ok"] = false;
    result["message"] = message;
    return result;
}

float load_float(const uint8_t *bytes, int64_t index) {
    float value;
    std::memcpy(&value, bytes + index * sizeof(float), sizeof(float));
    return value;
}

void store_float(uint8_t *bytes, int64_t index, float value) {
    std::memcpy(bytes + index * sizeof(float), &value, sizeof(float));
}

bool valid_size(Vector2i size) {
    return size.x > 0 && size.y > 0 && int64_t(size.x) * size.y <= StrataLayerData::MAX_DENSE_SAMPLES;
}

bool valid_rect(Vector2i origin, Vector2i size) {
    return valid_size(size) && int64_t(origin.x) + size.x - 1 <= std::numeric_limits<int32_t>::max() && int64_t(origin.y) + size.y - 1 <= std::numeric_limits<int32_t>::max();
}

bool finite_vector(Vector3 v) { return std::isfinite(v.x) && std::isfinite(v.y) && std::isfinite(v.z); }

bool valid_grid(Vector3 origin, Vector3 sx, Vector3 sy) {
    if (!finite_vector(origin) || !finite_vector(sx) || !finite_vector(sy) || std::abs(sx.y) > 0.000001 || std::abs(sy.y) > 0.000001) return false;
    const double lx = std::hypot(double(sx.x), double(sx.z));
    const double ly = std::hypot(double(sy.x), double(sy.z));
    return lx > 0 && ly > 0 && std::isfinite(lx) && std::isfinite(ly) && std::abs((double(sx.x) * sy.x + double(sx.z) * sy.z) / lx / ly) <= 0.00001;
}

bool image_bytes(const Ref<Image> &image, PackedByteArray &bytes) {
    if (image.is_null() || image->is_compressed() || image->get_format() != Image::FORMAT_RF || !valid_size(image->get_size())) return false;
    bytes = image->get_data();
    return bytes.size() >= int64_t(image->get_width()) * image->get_height() * int64_t(sizeof(float));
}
} // namespace

Dictionary StrataLayerData::pack_material_weights(const Array &images) {
    return pack_material_weights_impl(images, false);
}

Dictionary StrataLayerData::pack_material_weights_sparse(const Array &images) {
    return pack_material_weights_impl(images, true);
}

Dictionary StrataLayerData::pack_material_weights_impl(const Array &images, bool allow_unassigned) {
    const int count_ids = int(images.size());
    if (count_ids < 1 || count_ids > 32) return failure("Material packing requires 1 to 32 registry-order scalar images.");
    PackedByteArray fields[32];
    Vector2i size;
    for (int id = 0; id < count_ids; ++id) {
        const Ref<Image> image = images[id];
        if (image.is_null() || image->is_compressed() || image->has_mipmaps() ||
                (image->get_format() != Image::FORMAT_RF && image->get_format() != Image::FORMAT_RH))
            return failure("Material fields must be uncompressed RF or RH images without mipmaps.");
        if (id == 0) size = image->get_size();
        if (size.x < 1 || size.y < 1 || size.x > 1025 || size.y > 1025 || image->get_size() != size)
            return failure("Material fields must share one nonempty lattice with each side at most 1025.");
        if (image->get_format() == Image::FORMAT_RH) {
            Ref<Image> converted = image->duplicate();
            converted->convert(Image::FORMAT_RF);
            fields[id] = converted->get_data();
        } else fields[id] = image->get_data();
        if (fields[id].size() != int64_t(size.x) * size.y * 4) return failure("Material scalar image payload has an invalid byte count.");
    }
    const int64_t count = int64_t(size.x) * size.y;
    PackedByteArray ids, weights;
    ids.resize(count * 4); weights.resize(count * 16);
    uint8_t *out_ids = ids.ptrw(), *out_weights = weights.ptrw();
    const uint8_t *inputs[32] = {};
    for (int id = 0; id < count_ids; ++id) inputs[id] = fields[id].ptr();
    int64_t positive[32] = {}, dominant[32] = {}, retained[32] = {};
    double input_mass[32] = {}, retained_mass[32] = {};
    double discarded_sum = 0.0, discarded_max = 0.0;
    int64_t unassigned = 0;
    for (int64_t pixel = 0; pixel < count; ++pixel) {
        double values[32], total = 0.0;
        int top_ids[4] = {0, 0, 0, 0};
        double top[4] = {-1.0, -1.0, -1.0, -1.0};
        for (int id = 0; id < count_ids; ++id) {
            const double value = load_float(inputs[id], pixel);
            if (!std::isfinite(value) || value < 0.0) return failure("Material weights must be finite and nonnegative; previous controls retained.");
            values[id] = value; total += value;
            positive[id] += value > 0.0;
            // Ascending ID traversal and strict comparison provide a stable
            // ascending-ID tie break, independent of Dictionary insertion order.
            for (int slot = 0; slot < 4; ++slot) {
                if (value > top[slot]) {
                    for (int shift = 3; shift > slot; --shift) { top[shift] = top[shift - 1]; top_ids[shift] = top_ids[shift - 1]; }
                    top[slot] = value; top_ids[slot] = id; break;
                }
            }
        }
        if (allow_unassigned && total == 0.0) {
            // Unassigned editor texel: exact zero weights, ID 0, outside every diagnostic.
            for (int slot = 0; slot < 4; ++slot) { out_ids[pixel * 4 + slot] = 0; store_float(out_weights, pixel * 4 + slot, 0.0f); }
            ++unassigned;
            continue;
        }
        if (!(total > 0.0) || !std::isfinite(total)) return failure("Every material texel needs positive total weight; the HDA must provide complete coverage, including underwater.");
        double kept = 0.0;
        for (int slot = 0; slot < 4; ++slot) kept += std::max(top[slot], 0.0);
        const double discarded = std::clamp((total - kept) / total, 0.0, 1.0);
        discarded_sum += discarded; discarded_max = std::max(discarded_max, discarded);
        dominant[top_ids[0]]++;
        for (int id = 0; id < count_ids; ++id) input_mass[id] += values[id] / total;
        for (int slot = 0; slot < 4; ++slot) {
            const int id = top_ids[slot];
            out_ids[pixel * 4 + slot] = uint8_t(id);
            const float normalized = top[slot] > 0.0 ? float(top[slot] / kept) : 0.0f;
            store_float(out_weights, pixel * 4 + slot, normalized);
            if (top[slot] > 0.0) { retained[id]++; retained_mass[id] += normalized; }
        }
    }
    Array coverage;
    for (int id = 0; id < count_ids; ++id) {
        Dictionary entry;
        entry["id"] = id; entry["positive_texels"] = positive[id]; entry["dominant_texels"] = dominant[id]; entry["retained_texels"] = retained[id];
        entry["positive_fraction"] = double(positive[id]) / count; entry["dominant_fraction"] = double(dominant[id]) / count; entry["retained_fraction"] = double(retained[id]) / count;
        entry["mean_input_weight"] = input_mass[id] / count; entry["mean_retained_weight"] = retained_mass[id] / count;
        coverage.append(entry);
    }
    Dictionary result;
    result["ok"] = true; result["ids"] = Image::create_from_data(size.x, size.y, false, Image::FORMAT_RGBA8, ids);
    result["weights"] = Image::create_from_data(size.x, size.y, false, Image::FORMAT_RGBAF, weights);
    result["coverage"] = coverage; result["samples"] = count;
    result["discarded_weight_max"] = discarded_max; result["discarded_weight_mean"] = discarded_sum / count;
    if (allow_unassigned) { result["unassigned"] = unassigned; result["empty"] = unassigned == count; }
    return result;
}

Dictionary StrataLayerData::validate_dense(const Ref<Image> &image, const Ref<Image> &ownership) {
    PackedByteArray values, owners;
    if (!image_bytes(image, values)) return failure("Expected an uncompressed RF image with at most 20 million samples.");
    if (ownership.is_valid() && (!image_bytes(ownership, owners) || ownership->get_size() != image->get_size())) return failure("Ownership must be a matching uncompressed RF image.");
    const int64_t count = int64_t(image->get_width()) * image->get_height();
    const uint8_t *v = values.ptr();
    const uint8_t *o = ownership.is_valid() ? owners.ptr() : nullptr;
    int64_t owned = 0;
    double minimum = std::numeric_limits<double>::infinity(), maximum = -minimum;
    for (int64_t i = 0; i < count; ++i) {
        const float value = load_float(v, i);
        if (!std::isfinite(value)) return failure("All dense field values must be finite float32 scalars.");
        // Image validation describes all pixels, including unowned samples;
        // renderer/cache callers may use the full RF without ownership.
        minimum = std::min<double>(minimum, value); maximum = std::max<double>(maximum, value);
        const float owner = o ? load_float(o, i) : 1.0f;
        if (owner != 0.0f && owner != 1.0f) return failure("Dense field ownership must be binary zero or one.");
        owned += owner == 1.0f;
    }
    Dictionary result;
    result["ok"] = true;
    result["owned_count"] = owned;
    result["samples"] = count;
    result["min"] = minimum; result["max"] = maximum;
    return result;
}

bool StrataLayerData::replace_dense(StringName channel_name, Vector2i origin, const Ref<Image> &image, const Ref<Image> &ownership) {
    const String name = channel_name;
    ERR_FAIL_COND_V_MSG(name.is_empty() || !serialized_version_supported, false, "Invalid dense field channel or format version.");
    const Dictionary validation = validate_dense(image, ownership);
    ERR_FAIL_COND_V_MSG(!bool(validation["ok"]), false, String(validation["message"]));
    const Vector2i size = image->get_size();
    ERR_FAIL_COND_V_MSG(!valid_rect(origin, size), false, "Dense field index rectangle exceeds signed sample coordinates.");
    const PackedByteArray values = image->get_data();
    const PackedByteArray owners = ownership.is_valid() ? ownership->get_data() : PackedByteArray();
    const uint8_t *v = values.ptr();
    const uint8_t *o = ownership.is_valid() ? owners.ptr() : nullptr;
    const TileKey first = tile_key(origin);
    const TileKey last = tile_key(Vector2i(int64_t(origin.x) + size.x - 1, int64_t(origin.y) + size.y - 1));
    std::vector<TileKey> occupied;
    int64_t other_tiles = 0;
    for (const auto &entry : channels) if (entry.first != name) other_tiles += entry.second.size();
    // Check tile memory before allocating. A thin or sparse 20M-sample image
    // must not silently allocate tens of gigabytes of mostly empty tiles.
    for (int64_t ty = first.second; ty <= last.second; ++ty) {
        for (int64_t tx = first.first; tx <= last.first; ++tx) {
            bool any = o == nullptr;
            const int64_t x0 = std::max<int64_t>(origin.x, tx * TILE_SIZE);
            const int64_t y0 = std::max<int64_t>(origin.y, ty * TILE_SIZE);
            const int64_t x1 = std::min<int64_t>(int64_t(origin.x) + size.x, (tx + 1) * TILE_SIZE);
            const int64_t y1 = std::min<int64_t>(int64_t(origin.y) + size.y, (ty + 1) * TILE_SIZE);
            for (int64_t y = y0; o && !any && y < y1; ++y) {
                for (int64_t x = x0; x < x1; ++x) if (load_float(o, (y - origin.y) * size.x + x - origin.x) == 1.0f) { any = true; break; }
            }
            if (any) occupied.emplace_back(tx, ty);
            ERR_FAIL_COND_V_MSG(other_tiles + int64_t(occupied.size()) > MAX_RESOURCE_TILES, false, "Dense import exceeds the 512 MiB native tile budget for this resource.");
        }
    }
    Channel replacement;
    for (const TileKey &key : occupied) {
        Tile &tile = replacement[key];
        const int64_t x0 = std::max<int64_t>(origin.x, int64_t(key.first) * TILE_SIZE);
        const int64_t y0 = std::max<int64_t>(origin.y, int64_t(key.second) * TILE_SIZE);
        const int64_t x1 = std::min<int64_t>(int64_t(origin.x) + size.x, (int64_t(key.first) + 1) * TILE_SIZE);
        const int64_t y1 = std::min<int64_t>(int64_t(origin.y) + size.y, (int64_t(key.second) + 1) * TILE_SIZE);
        for (int64_t y = y0; y < y1; ++y) {
            for (int64_t x = x0; x < x1; ++x) {
                const int64_t source = (y - origin.y) * size.x + x - origin.x;
                if (o && load_float(o, source) == 0.0f) continue;
                const int offset = (y - int64_t(key.second) * TILE_SIZE) * TILE_SIZE + x - int64_t(key.first) * TILE_SIZE;
                tile.values[offset] = load_float(v, source);
                tile.ownership[offset] = 1;
                ++tile.owned_count;
            }
        }
    }
    const auto old = channels.find(name);
    if (old != channels.end() && old->second == replacement) return true;
    if (replacement.empty()) {
        if (old == channels.end()) return true;
        channels.erase(old);
    } else channels[name] = std::move(replacement);
    mark_channel_changed(name);
    return true;
}

// Shared by the three region edits. The mask (binary RF, same size as the rectangle) selects
// samples; selected ones are written from the image when p_write_selected, unselected ones
// are erased when p_erase_unselected. Without a mask every sample is selected.
bool StrataLayerData::edit_dense(const String &name, Vector2i origin, Vector2i size, const Ref<Image> &image, const Ref<Image> &mask, bool write_selected, bool erase_unselected) {
    ERR_FAIL_COND_V_MSG(name.is_empty() || !serialized_version_supported, false, "Invalid dense edit channel or format version.");
    ERR_FAIL_COND_V_MSG(!valid_rect(origin, size), false, "Dense edit rectangle exceeds signed sample coordinates.");
    PackedByteArray values, selection;
    if (write_selected) {
        const Dictionary validation = validate_dense(image, mask);
        ERR_FAIL_COND_V_MSG(!bool(validation["ok"]), false, String(validation["message"]));
        ERR_FAIL_COND_V_MSG(image->get_size() != size, false, "Dense edit image must match the rectangle.");
        values = image->get_data();
    } else {
        ERR_FAIL_COND_V_MSG(!image_bytes(mask, selection) || mask->get_size() != size, false, "Dense erase needs a binary RF mask matching the rectangle.");
        const uint8_t *m = selection.ptr();
        for (int64_t i = 0; i < int64_t(size.x) * size.y; ++i) {
            const float flag = load_float(m, i);
            ERR_FAIL_COND_V_MSG(flag != 0.0f && flag != 1.0f, false, "Dense erase mask must be binary zero or one.");
        }
    }
    if (mask.is_valid() && selection.is_empty()) selection = mask->get_data();
    const uint8_t *v = values.is_empty() ? nullptr : values.ptr();
    const uint8_t *m = selection.is_empty() ? nullptr : selection.ptr();
    // Count the tiles the edit can create before touching anything, as replace_dense does.
    int64_t tiles_total = 0;
    for (const auto &entry : channels) tiles_total += entry.second.size();
    const TileKey first = tile_key(origin);
    const TileKey last = tile_key(Vector2i(int64_t(origin.x) + size.x - 1, int64_t(origin.y) + size.y - 1));
    const int64_t new_tiles = (int64_t(last.first) - first.first + 1) * (int64_t(last.second) - first.second + 1);
    ERR_FAIL_COND_V_MSG(write_selected && tiles_total + new_tiles > MAX_RESOURCE_TILES, false, "Dense edit could exceed the 512 MiB native tile budget for this resource.");
    bool changed = false;
    auto channel_it = channels.find(name);
    if (channel_it == channels.end()) {
        if (!write_selected) return true;
        channel_it = channels.emplace(name, Channel()).first;
    }
    Channel &channel = channel_it->second;
    for (int64_t y = 0; y < size.y; ++y) {
        for (int64_t x = 0; x < size.x; ++x) {
            const int64_t source = y * size.x + x;
            const bool selected = !m || load_float(m, source) == 1.0f;
            const Vector2i index(int32_t(origin.x + x), int32_t(origin.y + y));
            const TileKey key = tile_key(index);
            const int offset = tile_offset(index);
            if (selected ? !write_selected : erase_unselected) {
                auto tile_it = channel.find(key);
                if (tile_it == channel.end() || !tile_it->second.ownership[offset]) continue;
                tile_it->second.ownership[offset] = 0;
                tile_it->second.values[offset] = 0.0f;
                if (--tile_it->second.owned_count == 0) channel.erase(tile_it);
                changed = true;
            } else if (selected) {
                const float value = load_float(v, source);
                Tile &tile = channel[key];
                if (tile.ownership[offset] && tile.values[offset] == value) continue;
                if (!tile.ownership[offset]) { tile.ownership[offset] = 1; ++tile.owned_count; }
                tile.values[offset] = value;
                changed = true;
            }
        }
    }
    if (channel.empty()) channels.erase(name);
    if (changed) mark_channel_changed(name);
    return true;
}

bool StrataLayerData::patch_dense(StringName channel_name, Vector2i origin, const Ref<Image> &image, const Ref<Image> &mask) {
    ERR_FAIL_COND_V_MSG(image.is_null(), false, "Dense patch needs an image.");
    return edit_dense(String(channel_name), origin, image->get_size(), image, mask, true, false);
}

bool StrataLayerData::erase_dense(StringName channel_name, Vector2i origin, const Ref<Image> &mask) {
    ERR_FAIL_COND_V_MSG(mask.is_null(), false, "Dense erase needs a mask.");
    return edit_dense(String(channel_name), origin, mask->get_size(), Ref<Image>(), mask, false, false);
}

bool StrataLayerData::restore_dense(StringName channel_name, Vector2i origin, const Ref<Image> &image, const Ref<Image> &ownership) {
    ERR_FAIL_COND_V_MSG(image.is_null() || ownership.is_null(), false, "Dense restore needs the image and ownership read_dense returned.");
    return edit_dense(String(channel_name), origin, image->get_size(), image, ownership, true, true);
}

Rect2i StrataLayerData::get_owned_rect(StringName channel_name) const {
    const auto found = channels.find(String(channel_name));
    if (found == channels.end()) return Rect2i();
    int64_t min_x = std::numeric_limits<int32_t>::max(), min_y = min_x;
    int64_t max_x = std::numeric_limits<int32_t>::min(), max_y = max_x;
    for (const auto &entry : found->second) {
        for (int offset = 0; offset < TILE_SAMPLE_COUNT; ++offset) if (entry.second.ownership[offset]) {
            const int64_t x = int64_t(entry.first.first) * TILE_SIZE + offset % TILE_SIZE;
            const int64_t y = int64_t(entry.first.second) * TILE_SIZE + offset / TILE_SIZE;
            min_x = std::min(min_x, x); min_y = std::min(min_y, y);
            max_x = std::max(max_x, x); max_y = std::max(max_y, y);
        }
    }
    if (max_x < min_x || max_y < min_y) return Rect2i();
    ERR_FAIL_COND_V_MSG(max_x - min_x + 1 > std::numeric_limits<int32_t>::max() || max_y - min_y + 1 > std::numeric_limits<int32_t>::max(), Rect2i(), "Owned field rectangle exceeds Rect2i range.");
    return Rect2i(Vector2i(min_x, min_y), Vector2i(max_x - min_x + 1, max_y - min_y + 1));
}

Dictionary StrataLayerData::read_dense(StringName channel_name, Vector2i origin, Vector2i size) const {
    if (!valid_rect(origin, size)) return failure("Invalid or oversized dense export rectangle.");
    const int64_t count = int64_t(size.x) * size.y;
    PackedByteArray values, owners;
    values.resize(count * sizeof(float)); owners.resize(count * sizeof(float));
    std::memset(values.ptrw(), 0, values.size()); std::memset(owners.ptrw(), 0, owners.size());
    uint8_t *value_out = values.ptrw();
    uint8_t *owner_out = owners.ptrw();
    int64_t owned = 0;
    const auto channel = channels.find(String(channel_name));
    if (channel != channels.end()) for (const auto &entry : channel->second) {
        const int64_t x0 = std::max<int64_t>(origin.x, int64_t(entry.first.first) * TILE_SIZE);
        const int64_t y0 = std::max<int64_t>(origin.y, int64_t(entry.first.second) * TILE_SIZE);
        const int64_t x1 = std::min<int64_t>(int64_t(origin.x) + size.x, (int64_t(entry.first.first) + 1) * TILE_SIZE);
        const int64_t y1 = std::min<int64_t>(int64_t(origin.y) + size.y, (int64_t(entry.first.second) + 1) * TILE_SIZE);
        for (int64_t y = y0; y < y1; ++y) for (int64_t x = x0; x < x1; ++x) {
            const int offset = (y - int64_t(entry.first.second) * TILE_SIZE) * TILE_SIZE + x - int64_t(entry.first.first) * TILE_SIZE;
            if (!entry.second.ownership[offset]) continue;
            const int64_t target = (y - origin.y) * size.x + x - origin.x;
            store_float(value_out, target, entry.second.values[offset]);
            store_float(owner_out, target, 1.0f);
            ++owned;
        }
    }
    Dictionary result;
    result["ok"] = true;
    result["image"] = Image::create_from_data(size.x, size.y, false, Image::FORMAT_RF, values);
    result["ownership"] = Image::create_from_data(size.x, size.y, false, Image::FORMAT_RF, owners);
    result["owned_count"] = owned;
    return result;
}

struct StrataLayerData::GridSampler {
    Ref<StrataLayerData> source;
    const Channel *channel = nullptr;
    std::vector<const Tile *> lookup;
    int64_t min_tx = 0, min_ty = 0, width = 0, height = 0;
    Vector3 origin, sx, sy;
    double inv_xx = 0, inv_xy = 0, inv_yx = 0, inv_yy = 0;
    double offset = 0;
    int mode = 0;

    void prepare(StringName name) {
        const auto found = source->channels.find(String(name));
        if (found == source->channels.end()) return;
        channel = &found->second;
        int64_t max_tx = std::numeric_limits<int32_t>::min(), max_ty = max_tx;
        min_tx = min_ty = std::numeric_limits<int32_t>::max();
        for (const auto &tile : *channel) {
            min_tx = std::min<int64_t>(min_tx, tile.first.first); min_ty = std::min<int64_t>(min_ty, tile.first.second);
            max_tx = std::max<int64_t>(max_tx, tile.first.first); max_ty = std::max<int64_t>(max_ty, tile.first.second);
        }
        width = max_tx - min_tx + 1; height = max_ty - min_ty + 1;
        if (width > 0 && height > 0 && width * height <= 262144) {
            lookup.resize(width * height, nullptr);
            for (const auto &tile : *channel) lookup[(tile.first.second - min_ty) * width + tile.first.first - min_tx] = &tile.second;
        }
    }

    const Tile *tile_at(int32_t x, int32_t y) const {
        const int64_t tx = tile_coordinate(x), ty = tile_coordinate(y);
        if (tx < min_tx || ty < min_ty || tx >= min_tx + width || ty >= min_ty + height) return nullptr;
        if (!lookup.empty()) return lookup[(ty - min_ty) * width + tx - min_tx];
        const auto found = channel->find({int32_t(tx), int32_t(ty)});
        return found == channel->end() ? nullptr : &found->second;
    }

    void sample(Vector3 point, double &value, double &coverage) const {
        value = 0; coverage = 0;
        if (!channel) return;
        const double px = double(point.x) - origin.x, py = double(point.z) - origin.z;
        double x = inv_xx * px + inv_xy * py, y = inv_yx * px + inv_yy * py;
        const double nx = std::round(x), ny = std::round(y);
        if (nx >= std::numeric_limits<int32_t>::min() && nx <= std::numeric_limits<int32_t>::max() && ny >= std::numeric_limits<int32_t>::min() && ny <= std::numeric_limits<int32_t>::max()) {
            const Vector3 encoded = origin + sx * nx + sy * ny;
            if (encoded.x == point.x && encoded.z == point.z) { x = nx; y = ny; }
        }
        if (!std::isfinite(x) || !std::isfinite(y) || x <= double(std::numeric_limits<int32_t>::min()) - 1 || y <= double(std::numeric_limits<int32_t>::min()) - 1 || x >= double(std::numeric_limits<int32_t>::max()) + 1 || y >= double(std::numeric_limits<int32_t>::max()) + 1) return;
        const double fx = std::floor(x), fy = std::floor(y), dx = x - fx, dy = y - fy;
        double numerator = 0;
        for (int iy = 0; iy < 2; ++iy) for (int ix = 0; ix < 2; ++ix) {
            const double weight = (ix ? dx : 1 - dx) * (iy ? dy : 1 - dy);
            if (weight <= 0 || fx + ix < std::numeric_limits<int32_t>::min() || fx + ix > std::numeric_limits<int32_t>::max() || fy + iy < std::numeric_limits<int32_t>::min() || fy + iy > std::numeric_limits<int32_t>::max()) continue;
            const int32_t sample_x = fx + ix, sample_y = fy + iy;
            const Tile *tile = tile_at(sample_x, sample_y);
            const int index = tile_offset(Vector2i(sample_x, sample_y));
            if (tile && tile->ownership[index]) { numerator += weight * tile->values[index]; coverage += weight; }
        }
        if (coverage > 0) value = numerator / coverage + offset;
    }
};

// index_offset composes a window of a larger lattice: output texel (x, y) is lattice point
// (x + offset.x, y + offset.y), computed with the same expression as the whole lattice, so
// a window is bit-identical to the matching rectangle of a full composition.
Dictionary StrataLayerData::compose_dense(const Array &layers, StringName channel_name, Vector3 origin, Vector3 sx, Vector3 sy, Vector2i size, Rect2 bounds, bool include_coverage, double subtract_datum, Vector2i index_offset) {
    if (!valid_size(size) || !valid_grid(origin, sx, sy) || !bounds.position.is_finite() || !bounds.size.is_finite() || bounds.size.x < 0 || bounds.size.y < 0 || !std::isfinite(subtract_datum) || layers.size() > 64) return failure("Invalid or oversized dense composition grid/layer count.");
    if (index_offset.x < 0 || index_offset.y < 0 || int64_t(index_offset.x) + size.x > MAX_DENSE_SAMPLES || int64_t(index_offset.y) + size.y > MAX_DENSE_SAMPLES) return failure("Dense composition window offset must be nonnegative and bounded.");
    const int last_x = index_offset.x + size.x - 1, last_y = index_offset.y + size.y - 1;
    if (!finite_vector(origin + sx * last_x) || !finite_vector(origin + sy * last_y) || !finite_vector(origin + sx * last_x + sy * last_y) || !(bounds.position + bounds.size).is_finite()) return failure("Composed grid corners exceed coordinate range.");
    std::vector<GridSampler> samplers;
    for (int i = 0; i < layers.size(); ++i) {
        if (Variant(layers[i]).get_type() != Variant::DICTIONARY) return failure("Composition layers must be captured descriptor Dictionaries.");
        const Dictionary item = layers[i];
        if (!item.has("data") || !item.has("origin") || !item.has("step_x") || !item.has("step_y")) return failure("Composition descriptor lacks data or sampling basis.");
        if (Variant(item["origin"]).get_type() != Variant::VECTOR3 || Variant(item["step_x"]).get_type() != Variant::VECTOR3 || Variant(item["step_y"]).get_type() != Variant::VECTOR3) return failure("Composition sampling basis must contain Vector3 values.");
        GridSampler sampler;
        sampler.source = item["data"];
        sampler.origin = item["origin"]; sampler.sx = item["step_x"]; sampler.sy = item["step_y"];
        sampler.mode = item.get("mode", 0); sampler.offset = item.get("height_offset", 0.0);
        if (sampler.source.is_null() || !valid_grid(sampler.origin, sampler.sx, sampler.sy) || (sampler.mode != 0 && sampler.mode != 1) || !std::isfinite(sampler.offset)) return failure("Invalid captured composition layer.");
        const double determinant = double(sampler.sx.x) * sampler.sy.z - double(sampler.sy.x) * sampler.sx.z;
        sampler.inv_xx = sampler.sy.z / determinant; sampler.inv_xy = -sampler.sy.x / determinant;
        sampler.inv_yx = -sampler.sx.z / determinant; sampler.inv_yy = sampler.sx.x / determinant;
        sampler.prepare(channel_name);
        samplers.push_back(std::move(sampler));
    }
    const int64_t count = int64_t(size.x) * size.y;
    PackedByteArray values, coverage_bytes;
    values.resize(count * sizeof(float));
    if (include_coverage) coverage_bytes.resize(count * sizeof(float));
    uint8_t *out = values.ptrw(); uint8_t *coverage_out = include_coverage ? coverage_bytes.ptrw() : nullptr;
    double minimum = std::numeric_limits<double>::infinity(), maximum = -minimum;
    const bool height_channel = channel_name == StringName("height");
    for (int y = 0; y < size.y; ++y) for (int x = 0; x < size.x; ++x) {
        const Vector3 point = origin + sx * (x + index_offset.x) + sy * (y + index_offset.y);
        if (!finite_vector(point)) return failure("Composed sample positions exceed Vector3 range.");
        double value = 0, coverage = 0;
        if (point.x >= bounds.position.x && point.z >= bounds.position.y && point.x <= bounds.position.x + bounds.size.x && point.z <= bounds.position.y + bounds.size.y) {
            coverage = height_channel ? 1 : 0;
            for (const GridSampler &sampler : samplers) {
                double upper_value, upper_coverage;
                sampler.sample(point, upper_value, upper_coverage);
                if (sampler.mode == 1) value += upper_value * upper_coverage;
                else value += (upper_value - value) * upper_coverage;
                coverage = upper_coverage + coverage * (1 - upper_coverage);
            }
            value -= subtract_datum;
        }
        const float stored = coverage > 0 ? static_cast<float>(value) : 0.0f;
        if (!std::isfinite(stored)) return failure("Composed values exceed finite RF storage.");
        const int64_t index = int64_t(y) * size.x + x;
        store_float(out, index, stored);
        if (coverage_out) store_float(coverage_out, index, static_cast<float>(coverage));
        minimum = std::min<double>(minimum, stored); maximum = std::max<double>(maximum, stored);
    }
    Dictionary result;
    result["ok"] = true;
    result["image"] = Image::create_from_data(size.x, size.y, false, Image::FORMAT_RF, values);
    if (include_coverage) result["coverage"] = Image::create_from_data(size.x, size.y, false, Image::FORMAT_RF, coverage_bytes);
    result["min"] = minimum; result["max"] = maximum;
    result["samples"] = count;
    return result;
}

namespace {
struct MaskPoint { double x = 0, y = 0; };
using MaskPolygon = std::vector<MaskPoint>;
struct MaskRect { double x0, y0, x1, y1; };
struct MaskBudget {
    int64_t used = 0, maximum = 0;
    bool exceeded = false;
    bool take(int64_t count = 1) {
        if (count > maximum - used) { exceeded = true; return false; }
        used += count;
        return true;
    }
};

double mask_cross(MaskPoint a, MaskPoint b, MaskPoint p) { return (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x); }

double mask_area(const MaskPolygon &polygon) {
    double twice = 0;
    for (size_t i = 1; i + 1 < polygon.size(); ++i) twice += mask_cross(polygon[0], polygon[i], polygon[i + 1]);
    return std::abs(twice) * 0.5;
}

MaskPolygon mask_clip(const MaskPolygon &polygon, MaskPoint a, MaskPoint b, bool inside, MaskBudget &budget) {
    MaskPolygon result;
    if (polygon.empty() || !budget.take(polygon.size())) return result;
    MaskPoint previous = polygon.back();
    double previous_distance = mask_cross(a, b, previous);
    bool previous_in = inside ? previous_distance >= 0 : previous_distance <= 0;
    for (MaskPoint current : polygon) {
        const double distance = mask_cross(a, b, current);
        const bool current_in = inside ? distance >= 0 : distance <= 0;
        if (current_in != previous_in) {
            const double t = previous_distance / (previous_distance - distance);
            result.push_back({previous.x + (current.x - previous.x) * t, previous.y + (current.y - previous.y) * t});
        }
        if (current_in) result.push_back(current);
        previous = current; previous_distance = distance; previous_in = current_in;
    }
    return result;
}

MaskPolygon mask_intersect(MaskPolygon polygon, const MaskPolygon &clip, MaskBudget &budget) {
    for (size_t i = 0; i < clip.size() && !polygon.empty(); ++i) polygon = mask_clip(polygon, clip[i], clip[(i + 1) % clip.size()], true, budget);
    return polygon;
}

void mask_subtract(const MaskPolygon &polygon, const MaskPolygon &clip, std::vector<MaskPolygon> &result, MaskBudget &budget) {
    MaskPolygon remaining = polygon;
    for (size_t i = 0; i < clip.size() && !remaining.empty(); ++i) {
        MaskPolygon outside = mask_clip(remaining, clip[i], clip[(i + 1) % clip.size()], false, budget);
        if (mask_area(outside) > 0) result.push_back(std::move(outside));
        remaining = mask_clip(remaining, clip[i], clip[(i + 1) % clip.size()], true, budget);
    }
}
} // namespace

struct StrataLayerData::MaskSampler {
    GridSampler grid;
    bool threshold_mapping = false;
    double threshold = 0.5;
    bool has_holes = false;
    int64_t hole_x0 = 0, hole_y0 = 0, hole_x1 = 0, hole_y1 = 0;
    MaskRect positive_bounds{};

    bool mapped(float value) const { return threshold_mapping ? double(value) + grid.offset >= threshold : value == 1.0f; }

    MaskPoint physical(double x, double y) const {
        return {double(grid.origin.x) + grid.sx.x * x + grid.sy.x * y, double(grid.origin.z) + grid.sx.z * x + grid.sy.z * y};
    }

    MaskPolygon pixel(int64_t x, int64_t y) const {
        MaskPolygon result{physical(x - 0.5, y - 0.5), physical(x + 0.5, y - 0.5), physical(x + 0.5, y + 0.5), physical(x - 0.5, y + 0.5)};
        if (double(grid.sx.x) * grid.sy.z - double(grid.sy.x) * grid.sx.z < 0) std::reverse(result.begin(), result.end());
        return result;
    }

    bool scan(MaskBudget &budget, String &error) {
        if (!grid.channel) return true;
        for (const auto &entry : *grid.channel) {
            if (!budget.take(TILE_SAMPLE_COUNT)) { error = "Categorical source validation exceeds the mask work budget."; return false; }
            for (int offset = 0; offset < TILE_SAMPLE_COUNT; ++offset) {
                if (!entry.second.ownership[offset]) continue;
                const float value = entry.second.values[offset];
                if (!threshold_mapping && (grid.offset != 0 || (value != 0 && value != 1))) {
                    error = "Categorical authoring requires binary Hole/Solid values; choose explicit threshold mapping for continuous procedural fields.";
                    return false;
                }
                if (!mapped(value)) continue;
                const int64_t x = int64_t(entry.first.first) * TILE_SIZE + offset % TILE_SIZE;
                const int64_t y = int64_t(entry.first.second) * TILE_SIZE + offset / TILE_SIZE;
                if (!has_holes) { hole_x0 = hole_x1 = x; hole_y0 = hole_y1 = y; has_holes = true; }
                else { hole_x0 = std::min(hole_x0, x); hole_y0 = std::min(hole_y0, y); hole_x1 = std::max(hole_x1, x); hole_y1 = std::max(hole_y1, y); }
            }
        }
        if (has_holes) {
            positive_bounds = {std::numeric_limits<double>::infinity(), std::numeric_limits<double>::infinity(), -std::numeric_limits<double>::infinity(), -std::numeric_limits<double>::infinity()};
            for (double y : {hole_y0 - 0.5, hole_y1 + 0.5}) for (double x : {hole_x0 - 0.5, hole_x1 + 0.5}) {
                const MaskPoint p = physical(x, y);
                positive_bounds.x0 = std::min(positive_bounds.x0, p.x); positive_bounds.y0 = std::min(positive_bounds.y0, p.y);
                positive_bounds.x1 = std::max(positive_bounds.x1, p.x); positive_bounds.y1 = std::max(positive_bounds.y1, p.y);
            }
        }
        return true;
    }

    bool owned(int64_t x, int64_t y, bool &hole, MaskBudget &budget) const {
        if (!budget.take() || x < std::numeric_limits<int32_t>::min() || y < std::numeric_limits<int32_t>::min() || x > std::numeric_limits<int32_t>::max() || y > std::numeric_limits<int32_t>::max()) return false;
        const Tile *tile = grid.tile_at(x, y);
        const int index = tile_offset(Vector2i(x, y));
        if (!tile || !tile->ownership[index]) return false;
        hole = mapped(tile->values[index]);
        return true;
    }

    bool range(const MaskPolygon &polygon, int64_t &x0, int64_t &y0, int64_t &x1, int64_t &y1, bool positive_only = false, bool *complete = nullptr) const {
        double low_x = std::numeric_limits<double>::infinity(), low_y = low_x, high_x = -low_x, high_y = -low_x;
        for (MaskPoint p : polygon) {
            const double px = p.x - grid.origin.x, py = p.y - grid.origin.z;
            const double x = grid.inv_xx * px + grid.inv_xy * py, y = grid.inv_yx * px + grid.inv_yy * py;
            low_x = std::min(low_x, x); low_y = std::min(low_y, y); high_x = std::max(high_x, x); high_y = std::max(high_y, y);
        }
        const double first_x = std::floor(low_x + 0.5), first_y = std::floor(low_y + 0.5);
        const double last_x = std::max(first_x, std::ceil(high_x + 0.5) - 1), last_y = std::max(first_y, std::ceil(high_y + 0.5) - 1);
        const int64_t min_x = positive_only ? hole_x0 : grid.min_tx * TILE_SIZE;
        const int64_t min_y = positive_only ? hole_y0 : grid.min_ty * TILE_SIZE;
        const int64_t max_x = positive_only ? hole_x1 : (grid.min_tx + grid.width) * TILE_SIZE - 1;
        const int64_t max_y = positive_only ? hole_y1 : (grid.min_ty + grid.height) * TILE_SIZE - 1;
        if (complete) *complete = first_x >= min_x && first_y >= min_y && last_x <= max_x && last_y <= max_y;
        if (last_x < min_x || last_y < min_y || first_x > max_x || first_y > max_y) return false;
        x0 = std::max<double>(first_x, min_x); y0 = std::max<double>(first_y, min_y);
        x1 = std::min<double>(last_x, max_x); y1 = std::min<double>(last_y, max_y);
        return x1 >= x0 && y1 >= y0;
    }

    bool fully_owned(const MaskPolygon &polygon, MaskBudget &budget) const {
        int64_t x0, y0, x1, y1;
        bool complete = false;
        if (!range(polygon, x0, y0, x1, y1, false, &complete) || !complete) return false;
        for (int64_t y = y0; y <= y1; ++y) for (int64_t x = x0; x <= x1; ++x) { bool hole; if (!owned(x, y, hole, budget)) return false; }
        return true;
    }
};

Dictionary StrataLayerData::compile_cell_mask(const Array &layers, StringName channel_name, Rect2 bounds, Vector2i resolution, int64_t max_work, int max_fragments) {
    if (resolution.x < 2 || resolution.y < 2) return failure("Canonical masks need a positive cell lattice.");
    const Vector2i cells = resolution - Vector2i(1, 1);
    if (!valid_size(cells) || !bounds.position.is_finite() || !bounds.size.is_finite() || !(bounds.position + bounds.size).is_finite() || bounds.size.x <= 0 || bounds.size.y <= 0 || layers.size() > 64 || max_work < 1 || max_work > 1073741824 || max_fragments < 1 || max_fragments > 16384) return failure("Invalid or oversized categorical cell compilation request.");
    MaskBudget budget{0, max_work, false};
    std::vector<MaskSampler> sources;
    MaskRect candidates{std::numeric_limits<double>::infinity(), std::numeric_limits<double>::infinity(), -std::numeric_limits<double>::infinity(), -std::numeric_limits<double>::infinity()};
    for (int i = 0; i < layers.size(); ++i) {
        if (Variant(layers[i]).get_type() != Variant::DICTIONARY) return failure("Categorical sources need captured descriptor Dictionaries.");
        const Dictionary item = layers[i];
        if (!item.has("data") || Variant(item.get("origin", Variant())).get_type() != Variant::VECTOR3 || Variant(item.get("step_x", Variant())).get_type() != Variant::VECTOR3 || Variant(item.get("step_y", Variant())).get_type() != Variant::VECTOR3) return failure("Categorical source lacks its data or physical basis.");
        MaskSampler source;
        source.grid.source = item["data"]; source.grid.origin = item["origin"]; source.grid.sx = item["step_x"]; source.grid.sy = item["step_y"];
        source.grid.offset = item.get("height_offset", 0.0);
        if (source.grid.source.is_null() || !valid_grid(source.grid.origin, source.grid.sx, source.grid.sy) || !std::isfinite(source.grid.offset)) return failure("Invalid categorical source data or basis.");
        source.grid.prepare(channel_name);
        if (!source.grid.channel) continue;
        if (int(item.get("mode", 0)) != 0) return failure("Hole and navigation categories require Replace ownership; Add is unsupported.");
        const String mapping = item.get("mapping", "binary");
        if (mapping != "binary" && mapping != "threshold") return failure("Unknown categorical source mapping.");
        source.threshold_mapping = mapping == "threshold"; source.threshold = item.get("threshold", 0.5);
        if (!std::isfinite(source.threshold)) return failure("Categorical conversion threshold must be finite.");
        const double determinant = double(source.grid.sx.x) * source.grid.sy.z - double(source.grid.sy.x) * source.grid.sx.z;
        source.grid.inv_xx = source.grid.sy.z / determinant; source.grid.inv_xy = -source.grid.sy.x / determinant;
        source.grid.inv_yx = -source.grid.sx.z / determinant; source.grid.inv_yy = source.grid.sx.x / determinant;
        String error;
        if (!source.scan(budget, error)) return failure(error);
        if (source.has_holes) {
            candidates.x0 = std::min(candidates.x0, source.positive_bounds.x0); candidates.y0 = std::min(candidates.y0, source.positive_bounds.y0);
            candidates.x1 = std::max(candidates.x1, source.positive_bounds.x1); candidates.y1 = std::max(candidates.y1, source.positive_bounds.y1);
        }
        sources.push_back(std::move(source));
    }
    PackedByteArray mask;
    int64_t affected = 0;
    const double dx = double(bounds.size.x) / cells.x, dy = double(bounds.size.y) / cells.y;
    candidates.x0 = std::max<double>(candidates.x0, bounds.position.x); candidates.y0 = std::max<double>(candidates.y0, bounds.position.y);
    candidates.x1 = std::min(candidates.x1, double(bounds.position.x) + bounds.size.x); candidates.y1 = std::min(candidates.y1, double(bounds.position.y) + bounds.size.y);
    if (candidates.x1 > candidates.x0 && candidates.y1 > candidates.y0) {
        const int x0 = std::clamp<int>(std::floor((candidates.x0 - bounds.position.x) / dx), 0, cells.x - 1);
        const int y0 = std::clamp<int>(std::floor((candidates.y0 - bounds.position.y) / dy), 0, cells.y - 1);
        const int x1 = std::clamp<int>(std::ceil((candidates.x1 - bounds.position.x) / dx) - 1, 0, cells.x - 1);
        const int y1 = std::clamp<int>(std::ceil((candidates.y1 - bounds.position.y) / dy) - 1, 0, cells.y - 1);
        for (int y = y0; y <= y1; ++y) for (int x = x0; x <= x1; ++x) {
            const double left = double(bounds.position.x) + x * dx, top = double(bounds.position.y) + y * dy;
            const MaskPolygon cell{{left, top}, {left + dx, top}, {left + dx, top + dy}, {left, top + dy}};
            bool excluded = false;
            // A lower Hole survives only where every higher source is unowned.
            // Subtract exact owned categorical sample regions before cell
            // reduction. This preserves even subcell holes and upper Solid.
            for (int index = int(sources.size()) - 1; index >= 0 && !excluded && !budget.exceeded; --index) {
                const MaskSampler &source = sources[index];
                if (!source.has_holes) continue;
                int64_t ix0, iy0, ix1, iy1;
                if (!source.range(cell, ix0, iy0, ix1, iy1, true)) continue;
                for (int64_t iy = iy0; iy <= iy1 && !excluded && !budget.exceeded; ++iy) for (int64_t ix = ix0; ix <= ix1 && !excluded && !budget.exceeded; ++ix) {
                    bool hole = false;
                    if (!source.owned(ix, iy, hole, budget) || !hole) continue;
                    MaskPolygon region = mask_intersect(source.pixel(ix, iy), cell, budget);
                    if (mask_area(region) <= 0) continue;
                    std::vector<MaskPolygon> fragments{std::move(region)};
                    for (size_t upper = index + 1; upper < sources.size() && !fragments.empty() && !budget.exceeded; ++upper) {
                        std::vector<MaskPolygon> next;
                        for (const MaskPolygon &fragment : fragments) {
                            if (sources[upper].fully_owned(fragment, budget)) continue;
                            int64_t ux0, uy0, ux1, uy1;
                            if (!sources[upper].range(fragment, ux0, uy0, ux1, uy1)) { next.push_back(fragment); continue; }
                            std::vector<MaskPolygon> remaining{fragment};
                            for (int64_t uy = uy0; uy <= uy1 && !remaining.empty() && !budget.exceeded; ++uy) for (int64_t ux = ux0; ux <= ux1 && !remaining.empty() && !budget.exceeded; ++ux) {
                                bool ignored;
                                if (!sources[upper].owned(ux, uy, ignored, budget)) continue;
                                const MaskPolygon cover = sources[upper].pixel(ux, uy);
                                std::vector<MaskPolygon> pieces;
                                for (const MaskPolygon &piece : remaining) mask_subtract(piece, cover, pieces, budget);
                                remaining = std::move(pieces);
                                if (remaining.size() + next.size() > size_t(max_fragments)) { budget.exceeded = true; break; }
                            }
                            for (MaskPolygon &piece : remaining) next.push_back(std::move(piece));
                        }
                        fragments = std::move(next);
                    }
                    if (!fragments.empty() && !budget.exceeded) excluded = true;
                }
            }
            if (budget.exceeded) return failure("Categorical overlay exceeds its explicit work/fragment budget; no partial mask was published.");
            if (excluded) {
                if (mask.is_empty()) { mask.resize(int64_t(cells.x) * cells.y); std::memset(mask.ptrw(), 0, mask.size()); }
                mask.ptrw()[int64_t(y) * cells.x + x] = 255;
                ++affected;
            }
        }
    }
    Dictionary result;
    result["ok"] = true; result["mask"] = mask; result["cells"] = cells;
    result["image"] = mask.is_empty() ? Ref<Image>() : Image::create_from_data(cells.x, cells.y, false, Image::FORMAT_L8, mask);
    result["count"] = affected; result["work"] = budget.used;
    result["policy"] = "Categorical Replace ownership resolved before conservative any-overlap cell reduction";
    result["boundary_expansion"] = "Overlapping source regions expand to whole target cells, up to one target cell at each boundary";
    return result;
}

} // namespace Strata
