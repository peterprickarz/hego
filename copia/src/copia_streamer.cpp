#include "copia_streamer.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/array.hpp>

#include <algorithm>
#include <cmath>
#include <unordered_set>

using namespace godot;

namespace Copia {

namespace {

// GDScript's minf and maxf (Godot's MIN and MAX), with their handling of NaN: a threshold over no
// counting source is NaN, which no reach reaches (loading requests nothing, the records pass frees
// the record), so the same operators are used here.
inline double gd_min(double p_a, double p_b) {
    return p_a < p_b ? p_a : p_b;
}

inline double gd_max(double p_a, double p_b) {
    return p_a > p_b ? p_a : p_b;
}

template <typename P, typename T>
P to_packed(const std::vector<T> &p_values) {
    P result;
    result.resize(int64_t(p_values.size()));
    for (size_t i = 0; i < p_values.size(); i++) {
        result.set(int64_t(i), p_values[i]);
    }
    return result;
}

} // namespace

// --- Grid --------------------------------------------------------------------------------------

CopiaStreamer::Cell *CopiaStreamer::Grid::find(const CellKey &p_key) {
    auto found = cells.find(p_key);
    return found == cells.end() ? nullptr : &found->second;
}

const CopiaStreamer::Cell *CopiaStreamer::Grid::find(const CellKey &p_key) const {
    auto found = cells.find(p_key);
    return found == cells.end() ? nullptr : &found->second;
}

CopiaStreamer::Cell &CopiaStreamer::Grid::get(const CellKey &p_key) {
    return cells[p_key];
}

void CopiaStreamer::Grid::drop_if_empty(const CellKey &p_key) {
    auto found = cells.find(p_key);
    if (found != cells.end() && !found->second.known && !found->second.pending && !found->second.cached) {
        cells.erase(found);
    }
}

// --- Configuration -----------------------------------------------------------------------------

void CopiaStreamer::set_grid(double p_cell_size, double p_far_cell_size) {
    if (cell_size != p_cell_size || far_cell_size != p_far_cell_size) {
        cell_size = p_cell_size;
        far_cell_size = p_far_cell_size;
        rebuild_excluded();
        dirty = true;
    }
}

// --- Excluded rectangles -----------------------------------------------------------------------

void CopiaStreamer::set_excluded_rects(const Array &p_rects) {
    excluded_rects.clear();
    for (int64_t i = 0; i < p_rects.size(); i++) {
        if (p_rects[i].get_type() == Variant::RECT2 || p_rects[i].get_type() == Variant::RECT2I) {
            Rect2 rect = p_rects[i];
            excluded_rects.push_back(rect.abs());
        }
    }
    rebuild_excluded();
    dirty = true;
}

Array CopiaStreamer::get_excluded_rects() const {
    Array result;
    for (const Rect2 &rect : excluded_rects) {
        result.push_back(rect);
    }
    return result;
}

// The cells of both grids whose centre lies in a rectangle, half-open as Rect2.has_point. A
// rectangle over more cells than kMaxEnumerated (or with a non-finite edge) is kept as it is and
// tested per cell.
void CopiaStreamer::rebuild_excluded() {
    static constexpr int64_t kMaxEnumerated = int64_t(1) << 20;
    excluded_cells[0].clear();
    excluded_cells[1].clear();
    excluded_large.clear();
    for (const Rect2 &rect : excluded_rects) {
        double low_x = rect.position.x;
        double low_z = rect.position.y;
        double high_x = double(rect.position.x) + double(rect.size.x);
        double high_z = double(rect.position.y) + double(rect.size.y);
        bool large = !(std::isfinite(low_x) && std::isfinite(low_z) && std::isfinite(high_x) && std::isfinite(high_z));
        for (int g = 0; g < 2 && !large; g++) {
            double size = g == 0 ? cell_size : far_cell_size;
            double span = (high_x - low_x) / size * ((high_z - low_z) / size);
            if (!(size > 0.0) || span > double(kMaxEnumerated)) {
                large = true;
            }
        }
        if (large) {
            excluded_large.push_back(rect);
            continue;
        }
        for (int g = 0; g < 2; g++) {
            double size = g == 0 ? cell_size : far_cell_size;
            int64_t first_x = int64_t(std::floor(low_x / size)) - 1;
            int64_t last_x = int64_t(std::floor(high_x / size)) + 1;
            int64_t first_z = int64_t(std::floor(low_z / size)) - 1;
            int64_t last_z = int64_t(std::floor(high_z / size)) + 1;
            for (int64_t x = first_x; x <= last_x; x++) {
                double centre_x = (double(x) + 0.5) * size;
                if (centre_x < low_x || centre_x >= high_x) {
                    continue;
                }
                for (int64_t z = first_z; z <= last_z; z++) {
                    double centre_z = (double(z) + 0.5) * size;
                    if (centre_z >= low_z && centre_z < high_z) {
                        excluded_cells[g].insert(CellKey{ int32_t(x), int32_t(z) });
                    }
                }
            }
        }
    }
}

bool CopiaStreamer::is_excluded(bool p_far, const CellKey &p_key) const {
    const auto &cells = excluded_cells[p_far ? 1 : 0];
    if (!cells.empty() && cells.find(p_key) != cells.end()) {
        return true;
    }
    if (excluded_large.empty()) {
        return false;
    }
    double size = p_far ? far_cell_size : cell_size;
    double centre_x = (double(p_key.x) + 0.5) * size;
    double centre_z = (double(p_key.z) + 0.5) * size;
    for (const Rect2 &rect : excluded_large) {
        if (centre_x >= rect.position.x && centre_x < double(rect.position.x) + double(rect.size.x) && centre_z >= rect.position.y &&
                centre_z < double(rect.position.y) + double(rect.size.y)) {
            return true;
        }
    }
    return false;
}

void CopiaStreamer::set_margins(double p_load, double p_unload) {
    if (load_margin != p_load || unload_margin != p_unload) {
        load_margin = p_load;
        unload_margin = p_unload;
        dirty = true;
    }
}

void CopiaStreamer::set_movement_threshold(double p_metres) {
    movement_threshold = std::max(p_metres, 0.0);
    dirty = true;
}

double CopiaStreamer::get_movement_threshold() const {
    return movement_threshold;
}

void CopiaStreamer::set_max_ranges(double p_draw, double p_collider, double p_impostor) {
    // Compared bit for bit through ==, so a change from or to NaN also counts.
    if (!(max_draw == p_draw && max_collider == p_collider && max_impostor == p_impostor)) {
        max_draw = p_draw;
        max_collider = p_collider;
        max_impostor = p_impostor;
        dirty = true;
    }
}

int32_t CopiaStreamer::intern(const String &p_path) {
    CharString utf8 = p_path.utf8();
    std::string key(utf8.get_data(), size_t(utf8.length()));
    auto found = object_ids.find(key);
    if (found != object_ids.end()) {
        return found->second;
    }
    int32_t id = int32_t(objects.size());
    Object object;
    object.path = p_path;
    objects.push_back(object);
    object_ids.emplace(std::move(key), id);
    return id;
}

int64_t CopiaStreamer::set_object(const String &p_path, bool p_resolved, bool p_has_mesh, double p_draw_reach, bool p_has_physics,
        double p_collider_reach, bool p_has_impostor, double p_impostor_reach) {
    int32_t id = intern(p_path);
    Object &object = objects[size_t(id)];
    bool same = object.resolved == p_resolved && object.has_mesh == p_has_mesh && object.draw_reach == p_draw_reach &&
            object.has_physics == p_has_physics && object.collider_reach == p_collider_reach &&
            object.has_impostor == p_has_impostor && object.impostor_reach == p_impostor_reach;
    if (!same) {
        object.resolved = p_resolved;
        object.has_mesh = p_has_mesh;
        object.draw_reach = p_draw_reach;
        object.has_physics = p_has_physics;
        object.collider_reach = p_collider_reach;
        object.has_impostor = p_has_impostor;
        object.impostor_reach = p_impostor_reach;
        dirty = true;
    }
    return id;
}

// --- Cells and directories ---------------------------------------------------------------------

void CopiaStreamer::set_known(bool p_far, const Vector2i &p_cell, bool p_known) {
    Grid &grid = grids[p_far ? 1 : 0];
    CellKey key{ p_cell.x, p_cell.y };
    if (p_known) {
        Cell &cell = grid.get(key);
        if (!cell.known) {
            cell.known = true;
            grid.known_count++;
            dirty = true;
        }
        return;
    }
    Cell *cell = grid.find(key);
    if (cell != nullptr && cell->known) {
        cell->known = false;
        grid.known_count--;
        grid.drop_if_empty(key);
        dirty = true;
    }
}

void CopiaStreamer::clear_known() {
    for (Grid &grid : grids) {
        for (auto it = grid.cells.begin(); it != grid.cells.end();) {
            it->second.known = false;
            if (!it->second.pending && !it->second.cached) {
                it = grid.cells.erase(it);
            } else {
                ++it;
            }
        }
        grid.known_count = 0;
    }
    dirty = true;
}

PackedStringArray CopiaStreamer::set_directory(bool p_far, const Vector2i &p_cell, const Dictionary &p_objects) {
    Grid &grid = grids[p_far ? 1 : 0];
    Cell &cell = grid.get(CellKey{ p_cell.x, p_cell.y });
    if (!cell.cached) {
        cell.cached = true;
        grid.cached_count++;
    }
    cell.pending = false;
    cell.entries.clear();
    PackedStringArray new_paths;
    Array keys = p_objects.keys();
    cell.entries.reserve(size_t(keys.size()));
    for (int64_t i = 0; i < keys.size(); i++) {
        String path = keys[i];
        Dictionary summary = p_objects[keys[i]];
        Entry entry;
        entry.object = intern(path);
        entry.instances = int64_t(summary.get("instance_count", 0)) > 0;
        entry.colliders = int64_t(summary.get("collider_count", 0)) > 0;
        cell.entries.push_back(entry);
        if (directory_objects.insert(entry.object).second) {
            new_paths.push_back(path);
        }
    }
    dirty = true;
    return new_paths;
}

void CopiaStreamer::erase_directory(bool p_far, const Vector2i &p_cell) {
    Grid &grid = grids[p_far ? 1 : 0];
    CellKey key{ p_cell.x, p_cell.y };
    Cell *cell = grid.find(key);
    if (cell == nullptr || !cell->cached) {
        return;
    }
    cell->cached = false;
    cell->entries.clear();
    cell->entries.shrink_to_fit();
    grid.cached_count--;
    grid.drop_if_empty(key);
    dirty = true;
}

void CopiaStreamer::set_directory_pending(bool p_far, const Vector2i &p_cell, bool p_pending) {
    Grid &grid = grids[p_far ? 1 : 0];
    CellKey key{ p_cell.x, p_cell.y };
    if (p_pending) {
        Cell &cell = grid.get(key);
        if (!cell.pending) {
            cell.pending = true;
            dirty = true;
        }
        return;
    }
    Cell *cell = grid.find(key);
    if (cell != nullptr && cell->pending) {
        cell->pending = false;
        grid.drop_if_empty(key);
        dirty = true;
    }
}

void CopiaStreamer::clear_pending() {
    for (Grid &grid : grids) {
        for (auto it = grid.cells.begin(); it != grid.cells.end();) {
            it->second.pending = false;
            if (!it->second.known && !it->second.cached) {
                it = grid.cells.erase(it);
            } else {
                ++it;
            }
        }
    }
    dirty = true;
}

void CopiaStreamer::clear_cells() {
    for (Grid &grid : grids) {
        grid.cells.clear();
        grid.known_count = 0;
        grid.cached_count = 0;
    }
    record_slots.clear();
    free_slots.clear();
    record_count = 0;
    live[0].clear();
    live[1].clear();
    directory_objects.clear();
    dirty = true;
}

// --- Records -----------------------------------------------------------------------------------

CopiaStreamer::Record *CopiaStreamer::find_record(int64_t p_handle) {
    uint64_t slot = uint64_t(p_handle) & 0xffffffffu;
    if (slot == 0 || slot > record_slots.size()) {
        return nullptr;
    }
    Record &record = record_slots[slot - 1];
    return record.alive && record.handle == p_handle ? &record : nullptr;
}

const CopiaStreamer::Record *CopiaStreamer::find_record(int64_t p_handle) const {
    return const_cast<CopiaStreamer *>(this)->find_record(p_handle);
}

int64_t CopiaStreamer::add_record(int p_kind, bool p_far, const CellKey &p_cell, int32_t p_object) {
    uint32_t slot;
    if (!free_slots.empty()) {
        slot = free_slots.back();
        free_slots.pop_back();
    } else {
        slot = uint32_t(record_slots.size());
        record_slots.emplace_back();
    }
    Record &record = record_slots[slot];
    uint32_t generation = record.generation + 1;
    record = Record();
    record.generation = generation;
    record.alive = true;
    record.handle = (int64_t(generation) << 32) | int64_t(slot + 1);
    record.kind = p_kind;
    record.cell = p_cell;
    record.object = p_object;
    LiveCell &cell = live[p_far ? 1 : 0][p_cell];
    record.slot = cell.records.size();
    cell.records.push_back(record.handle);
    size_t index = size_t(p_object) * 3 + size_t(p_kind);
    if (cell.by_object.size() <= index) {
        cell.by_object.resize(index + 1, 0);
    }
    cell.by_object[index] = record.handle;
    record_count++;
    return record.handle;
}

void CopiaStreamer::erase_record(Record &p_record) {
    auto &cells = live[p_record.kind == KIND_IMPOSTOR ? 1 : 0];
    auto found = cells.find(p_record.cell);
    if (found != cells.end()) {
        LiveCell &cell = found->second;
        size_t slot = p_record.slot;
        if (slot < cell.records.size() && cell.records[slot] == p_record.handle) {
            int64_t moved = cell.records.back();
            cell.records[slot] = moved;
            cell.records.pop_back();
            if (moved != p_record.handle) {
                find_record(moved)->slot = slot;
            }
        }
        size_t index = size_t(p_record.object) * 3 + size_t(p_record.kind);
        if (index < cell.by_object.size()) {
            cell.by_object[index] = 0;
        }
        if (cell.records.empty()) {
            cells.erase(found);
        }
    }
    p_record.alive = false;
    free_slots.push_back(uint32_t((uint64_t(p_record.handle) & 0xffffffffu) - 1));
    record_count--;
}

void CopiaStreamer::remove_record(int64_t p_handle) {
    Record *record = find_record(p_handle);
    if (record == nullptr) {
        return;
    }
    erase_record(*record);
    dirty = true;
}

void CopiaStreamer::set_record_stale(int64_t p_handle, bool p_stale) {
    Record *record = find_record(p_handle);
    if (record == nullptr) {
        return;
    }
    record->stale = p_stale;
    if (p_stale) {
        dirty = true;
    }
}

void CopiaStreamer::set_record_drawn(int64_t p_handle) {
    Record *record = find_record(p_handle);
    if (record != nullptr) {
        record->drawn = true;
    }
}

double CopiaStreamer::get_record_priority(int64_t p_handle) const {
    const Record *record = find_record(p_handle);
    return record == nullptr ? 0.0 : record->priority;
}

int64_t CopiaStreamer::get_record_count() const {
    return record_count;
}

void CopiaStreamer::mark_dirty() {
    dirty = true;
}

int64_t CopiaStreamer::get_evaluation_count() const {
    return evaluations;
}

// --- Geometry ----------------------------------------------------------------------------------

// Horizontal distance from a point to a cell's square, computed as the GDScript store did: the
// cell's corner in single precision (Vector2(cell) * size), the rest in double precision.
double CopiaStreamer::rect_distance(float p_x, float p_z, const CellKey &p_cell, double p_size) {
    float size = float(p_size);
    float low_x = float(p_cell.x) * size;
    float low_z = float(p_cell.z) * size;
    double x = p_x;
    double z = p_z;
    double dx = gd_max(gd_max(double(low_x) - x, 0.0), x - (double(low_x) + p_size));
    double dz = gd_max(gd_max(double(low_z) - z, 0.0), z - (double(low_z) + p_size));
    return std::sqrt(dx * dx + dz * dz);
}

// The known (or, with p_cached, cached) cells within p_reach of the point: a walk over the cells
// of the reach's square, or over every cell when that square holds more cells than are known.
void CopiaStreamer::cells_in_reach(const Grid &p_grid, bool p_cached, float p_x, float p_z, double p_size, double p_reach,
        std::vector<CellKey> &r_cells) const {
    auto counts = [p_cached](const Cell &p_cell) { return p_cached ? p_cell.cached : p_cell.known; };
    if (std::isinf(p_reach)) {
        for (const auto &entry : p_grid.cells) {
            if (counts(entry.second)) {
                r_cells.push_back(entry.first);
            }
        }
        return;
    }
    int32_t low_x = int32_t(int64_t(std::floor((double(p_x) - p_reach) / p_size)));
    int32_t low_z = int32_t(int64_t(std::floor((double(p_z) - p_reach) / p_size)));
    int32_t high_x = int32_t(int64_t(std::floor((double(p_x) + p_reach) / p_size)));
    int32_t high_z = int32_t(int64_t(std::floor((double(p_z) + p_reach) / p_size)));
    int64_t area = (int64_t(high_x) - int64_t(low_x) + 1) * (int64_t(high_z) - int64_t(low_z) + 1);
    if (area > (p_cached ? p_grid.cached_count : p_grid.known_count)) {
        for (const auto &entry : p_grid.cells) {
            if (counts(entry.second) && rect_distance(p_x, p_z, entry.first, p_size) <= p_reach) {
                r_cells.push_back(entry.first);
            }
        }
        return;
    }
    for (int64_t x = low_x; x <= high_x; x++) {
        for (int64_t z = low_z; z <= high_z; z++) {
            CellKey key{ int32_t(x), int32_t(z) };
            const Cell *cell = p_grid.find(key);
            if (cell != nullptr && counts(*cell) && rect_distance(p_x, p_z, key, p_size) <= p_reach) {
                r_cells.push_back(key);
            }
        }
    }
}

// How far source s reaches into the cell grid: the largest draw range × its range scale or, with
// colliders, the largest collider distance.
double CopiaStreamer::source_reach(size_t p_source) const {
    const Source &source = sources[p_source];
    double reach = max_draw * source.scale;
    if (source.colliders) {
        reach = gd_max(reach, max_collider);
    }
    return reach;
}

void CopiaStreamer::cells_near_sources(const Grid &p_grid, double p_size, bool p_far, std::vector<CellKey> &r_cells) const {
    if (sources.size() == 1) {
        double reach = (p_far ? max_impostor * sources[0].scale : source_reach(0)) + load_margin;
        cells_in_reach(p_grid, true, sources[0].x, sources[0].z, p_size, reach, r_cells);
        return;
    }
    std::vector<CellKey> found;
    std::unordered_set<CellKey, CellKeyHash> seen;
    for (size_t s = 0; s < sources.size(); s++) {
        double reach = (p_far ? max_impostor * sources[s].scale : source_reach(s)) + load_margin;
        found.clear();
        cells_in_reach(p_grid, true, sources[s].x, sources[s].z, p_size, reach, found);
        for (const CellKey &key : found) {
            if (seen.insert(key).second) {
                r_cells.push_back(key);
            }
        }
    }
}

void CopiaStreamer::compute_distances(const CellKey &p_cell, double p_size) {
    distances.resize(sources.size());
    for (size_t s = 0; s < sources.size(); s++) {
        distances[s] = rect_distance(sources[s].x, sources[s].z, p_cell, p_size);
    }
}

// The smallest object reach a section needs to be wanted: min over the sources of
// (distance - margin) / range scale (with p_colliders: distance - margin over the sources with
// colliders). NaN when no source counts, which no reach reaches.
double CopiaStreamer::threshold(double p_margin, bool p_colliders) const {
    double result = NAN;
    for (size_t s = 0; s < sources.size(); s++) {
        if (p_colliders) {
            if (sources[s].colliders) {
                result = gd_min(result, distances[s] - p_margin);
            }
        } else {
            result = gd_min(result, (distances[s] - p_margin) / sources[s].scale);
        }
    }
    return result;
}

void CopiaStreamer::source_thresholds(double p_margin, bool p_colliders, std::vector<double> &r_thresholds) const {
    r_thresholds.resize(sources.size());
    for (size_t s = 0; s < sources.size(); s++) {
        if (p_colliders) {
            r_thresholds[s] = sources[s].colliders ? distances[s] - p_margin : NAN;
        } else {
            r_thresholds[s] = (distances[s] - p_margin) / sources[s].scale;
        }
    }
}

// What the sources needing a record ask for: the largest density and range scale among them (1
// for colliders) and the smallest distance ÷ priority.
void CopiaStreamer::qualify(Record &r_record, double p_reach, double p_margin) const {
    bool collider = r_record.kind == KIND_COLLIDER;
    if (sources.size() == 1) {
        r_record.density = collider ? 1.0 : sources[0].density;
        r_record.scale = collider ? 1.0 : sources[0].scale;
        r_record.priority = distances[0] / sources[0].priority;
        return;
    }
    double best_density = 0.0;
    double best_scale = 0.0;
    double best_priority = INFINITY;
    for (size_t s = 0; s < sources.size(); s++) {
        if (collider) {
            if (!sources[s].colliders || distances[s] - p_margin > p_reach) {
                continue;
            }
        } else if ((distances[s] - p_margin) / sources[s].scale > p_reach) {
            continue;
        }
        best_density = gd_max(best_density, sources[s].density);
        best_scale = gd_max(best_scale, sources[s].scale);
        best_priority = gd_min(best_priority, distances[s] / sources[s].priority);
    }
    if (std::isinf(best_priority)) {
        return; // no source within this margin
    }
    r_record.density = collider ? 1.0 : best_density;
    r_record.scale = collider ? 1.0 : best_scale;
    r_record.priority = best_priority;
}

void CopiaStreamer::requalify(Record &r_record, double p_reach, const std::vector<double> &p_thresholds) const {
    if (sources.size() <= 1) {
        qualify(r_record, p_reach, unload_margin);
        return;
    }
    double best_density = 0.0;
    double best_scale = 0.0;
    double best_priority = INFINITY;
    for (size_t s = 0; s < sources.size(); s++) {
        if (p_reach >= p_thresholds[s]) {
            best_density = gd_max(best_density, sources[s].density);
            best_scale = gd_max(best_scale, sources[s].scale);
            best_priority = gd_min(best_priority, distances[s] / sources[s].priority);
        }
    }
    r_record.priority = best_priority;
    if (r_record.kind == KIND_COLLIDER) {
        return;
    }
    r_record.density = best_density;
    r_record.scale = best_scale;
}

// --- Update ------------------------------------------------------------------------------------

bool CopiaStreamer::sources_changed() const {
    if (sources.size() != evaluated.size()) {
        return true;
    }
    double limit = movement_threshold * movement_threshold;
    for (size_t s = 0; s < sources.size(); s++) {
        const Source &now = sources[s];
        const Source &then = evaluated[s];
        if (now.scale != then.scale || now.density != then.density || now.colliders != then.colliders ||
                now.priority != then.priority) {
            return true;
        }
        double dx = double(now.x) - double(then.x);
        double dz = double(now.z) - double(then.z);
        if (dx * dx + dz * dz > limit) {
            return true;
        }
    }
    return false;
}

// Every live record of one grid: freed when no source needs it any more, else given the quality
// its sources ask for now. Records whose density or range scale changed, and freed ones, are
// added to the output.
void CopiaStreamer::update_records(bool p_far, Output &r_out) {
    auto &cells = live[p_far ? 1 : 0];
    if (cells.empty()) {
        return;
    }
    bool single = sources.size() == 1;
    double single_density = single ? sources[0].density : 1.0;
    double single_scale = single ? sources[0].scale : 1.0;
    double size = p_far ? far_cell_size : cell_size;
    std::vector<CellKey> keys;
    keys.reserve(cells.size());
    for (const auto &entry : cells) {
        keys.push_back(entry.first);
    }
    std::vector<int64_t> handles;
    for (const CellKey &key : keys) {
        auto found = cells.find(key);
        if (found == cells.end()) {
            continue;
        }
        compute_distances(key, size);
        double scaled = threshold(unload_margin, false);
        double unscaled = p_far ? 0.0 : threshold(unload_margin, true);
        double priority = single ? distances[0] / sources[0].priority : 0.0;
        if (single) {
            thresholds.clear();
            collider_thresholds.clear();
        } else {
            source_thresholds(unload_margin, false, thresholds);
            if (!p_far) {
                source_thresholds(unload_margin, true, collider_thresholds);
            }
        }
        bool excluded = is_excluded(p_far, key);
        handles = found->second.records;
        for (int64_t handle : handles) {
            Record *found_record = find_record(handle);
            if (found_record == nullptr) {
                continue;
            }
            Record &record = *found_record;
            const Object &object = objects[size_t(record.object)];
            bool remove = false;
            double old_density = record.density;
            double old_scale = record.scale;
            // A record stays only while some source needs it: its reach reaches the threshold. A
            // threshold over no counting source is NaN, which no reach reaches, so then it is freed.
            if (excluded || !object.resolved) {
                remove = true;
            } else if (record.kind == KIND_COLLIDER) {
                if (!(object.collider_reach >= unscaled)) {
                    remove = true;
                } else if (single) {
                    record.priority = priority;
                } else {
                    requalify(record, object.collider_reach, collider_thresholds);
                }
            } else if (record.kind == KIND_IMPOSTOR) {
                if (!object.has_impostor || !(object.impostor_reach >= scaled)) {
                    remove = true;
                } else if (single && record.density == single_density && record.scale == single_scale) {
                    record.priority = priority;
                } else {
                    requalify(record, object.impostor_reach, thresholds);
                }
            } else if (!(object.draw_reach >= scaled)) {
                remove = true;
            } else if (single && record.density == single_density && record.scale == single_scale) {
                record.priority = priority;
            } else {
                requalify(record, object.draw_reach, thresholds);
            }
            if (remove) {
                r_out.records.push_back(handle);
                r_out.record_densities.push_back(-1.0);
                r_out.record_scales.push_back(-1.0);
                erase_record(record);
            } else if (record.kind != KIND_COLLIDER && (old_density != record.density || old_scale != record.scale)) {
                r_out.records.push_back(handle);
                r_out.record_densities.push_back(record.density);
                r_out.record_scales.push_back(record.scale);
            }
        }
    }
}

void CopiaStreamer::request_directories(Output &r_out) {
    std::vector<CellKey> found;
    for (size_t s = 0; s < sources.size(); s++) {
        found.clear();
        cells_in_reach(grids[0], false, sources[s].x, sources[s].z, cell_size, source_reach(s) + load_margin, found);
        for (const CellKey &key : found) {
            if (is_excluded(false, key)) {
                continue;
            }
            Cell &cell = grids[0].get(key);
            if (!cell.cached && !cell.pending) {
                cell.pending = true;
                r_out.directories.push_back(0);
                r_out.directories.push_back(key.x);
                r_out.directories.push_back(key.z);
            }
        }
    }
    if (grids[1].known_count == 0 || max_impostor <= 0.0) {
        return;
    }
    for (size_t s = 0; s < sources.size(); s++) {
        found.clear();
        cells_in_reach(grids[1], false, sources[s].x, sources[s].z, far_cell_size, max_impostor * sources[s].scale + load_margin, found);
        for (const CellKey &key : found) {
            if (is_excluded(true, key)) {
                continue;
            }
            Cell &cell = grids[1].get(key);
            if (!cell.cached && !cell.pending) {
                cell.pending = true;
                r_out.directories.push_back(1);
                r_out.directories.push_back(key.x);
                r_out.directories.push_back(key.z);
            }
        }
    }
}

// Requests a section in range: a new record, given the quality its sources ask for; an existing
// one read from an older directory is listed for a reload.
void CopiaStreamer::want(LiveCell *&r_live, bool p_far, const CellKey &p_cell, int32_t p_object, int p_kind, double p_reach,
        Output &r_out) {
    if (r_live != nullptr) {
        int64_t existing = r_live->find(p_object, p_kind);
        if (existing != 0) {
            if (find_record(existing)->stale) {
                r_out.reloads.push_back(existing);
            }
            return;
        }
    }
    int64_t handle = add_record(p_kind, p_far, p_cell, p_object);
    r_live = &live[p_far ? 1 : 0][p_cell];
    Record &record = *find_record(handle);
    qualify(record, p_reach, gd_max(load_margin, unload_margin));
    r_out.requests.push_back(handle);
    r_out.request_kinds.push_back(p_kind);
    r_out.request_cells.push_back(p_cell.x);
    r_out.request_cells.push_back(p_cell.z);
    r_out.request_objects.push_back(p_object);
    r_out.request_densities.push_back(record.density);
    r_out.request_scales.push_back(record.scale);
}

void CopiaStreamer::load_cells(Output &r_out) {
    if (sources.empty()) {
        return;
    }
    std::vector<CellKey> near;
    cells_near_sources(grids[0], cell_size, false, near);
    for (const CellKey &key : near) {
        const Cell *cell = grids[0].find(key);
        if (cell == nullptr || !cell->cached || is_excluded(false, key)) {
            continue;
        }
        compute_distances(key, cell_size);
        double scaled = threshold(load_margin, false);
        double unscaled = threshold(load_margin, true);
        auto live_found = live[0].find(key);
        LiveCell *live_cell = live_found == live[0].end() ? nullptr : &live_found->second;
        for (const Entry &entry : cell->entries) {
            const Object &object = objects[size_t(entry.object)];
            if (!object.resolved) {
                continue;
            }
            if (entry.instances && object.has_mesh && object.draw_reach >= scaled) {
                want(live_cell, false, key, entry.object, KIND_DRAW, object.draw_reach, r_out);
            }
            if (entry.colliders && object.has_physics && object.collider_reach >= unscaled) {
                want(live_cell, false, key, entry.object, KIND_COLLIDER, object.collider_reach, r_out);
            }
        }
    }
}

void CopiaStreamer::load_far(Output &r_out) {
    if (grids[1].cached_count == 0 || sources.empty()) {
        return;
    }
    std::vector<CellKey> near;
    cells_near_sources(grids[1], far_cell_size, true, near);
    for (const CellKey &key : near) {
        const Cell *cell = grids[1].find(key);
        if (cell == nullptr || !cell->cached || is_excluded(true, key)) {
            continue;
        }
        compute_distances(key, far_cell_size);
        double scaled = threshold(load_margin, false);
        auto live_found = live[1].find(key);
        LiveCell *live_cell = live_found == live[1].end() ? nullptr : &live_found->second;
        for (const Entry &entry : cell->entries) {
            const Object &object = objects[size_t(entry.object)];
            if (!object.resolved || !object.has_impostor || !entry.instances) {
                continue;
            }
            if (object.impostor_reach >= scaled) {
                want(live_cell, true, key, entry.object, KIND_IMPOSTOR, object.impostor_reach, r_out);
            }
        }
    }
}

Dictionary CopiaStreamer::update(const PackedVector2Array &p_points, const PackedFloat64Array &p_scales,
        const PackedFloat64Array &p_densities, const PackedByteArray &p_colliders, const PackedFloat64Array &p_priorities,
        bool p_load) {
    int64_t count = std::min({ p_points.size(), p_scales.size(), p_densities.size(), p_colliders.size(), p_priorities.size() });
    sources.resize(size_t(count));
    for (int64_t s = 0; s < count; s++) {
        Source &source = sources[size_t(s)];
        Vector2 point = p_points[s];
        source.x = point.x;
        source.z = point.y;
        source.scale = p_scales[s];
        source.density = p_densities[s];
        source.colliders = p_colliders[s] != 0;
        source.priority = p_priorities[s];
    }
    Dictionary result;
    if (!dirty && has_evaluated && !sources_changed()) {
        result["evaluated"] = false;
        return result;
    }
    evaluated = sources;
    has_evaluated = true;
    dirty = false;
    evaluations++;
    Output out;
    update_records(false, out);
    update_records(true, out);
    if (p_load) {
        request_directories(out);
        load_cells(out);
        load_far(out);
    } else {
        dirty = true; // nothing is requested while a build writes; evaluate again next time
    }
    PackedStringArray paths;
    paths.resize(int64_t(out.request_objects.size()));
    for (size_t i = 0; i < out.request_objects.size(); i++) {
        paths.set(int64_t(i), objects[size_t(out.request_objects[i])].path);
    }
    result["evaluated"] = true;
    result["records"] = to_packed<PackedInt64Array>(out.records);
    result["densities"] = to_packed<PackedFloat64Array>(out.record_densities);
    result["scales"] = to_packed<PackedFloat64Array>(out.record_scales);
    result["directories"] = to_packed<PackedInt32Array>(out.directories);
    result["requests"] = to_packed<PackedInt64Array>(out.requests);
    result["request_kinds"] = to_packed<PackedInt32Array>(out.request_kinds);
    result["request_cells"] = to_packed<PackedInt32Array>(out.request_cells);
    result["request_paths"] = paths;
    result["request_densities"] = to_packed<PackedFloat64Array>(out.request_densities);
    result["request_scales"] = to_packed<PackedFloat64Array>(out.request_scales);
    result["reloads"] = to_packed<PackedInt64Array>(out.reloads);
    return result;
}

PackedInt32Array CopiaStreamer::get_source_counts(const PackedVector2Array &p_points, const PackedFloat64Array &p_scales,
        const PackedByteArray &p_colliders) const {
    int64_t count = std::min({ p_points.size(), p_scales.size(), p_colliders.size() });
    PackedInt32Array result;
    result.resize(count * 3);
    result.fill(0);
    if (count == 0) {
        return result;
    }
    std::vector<int32_t> counts(size_t(count * 3), 0);
    for (const Record &record : record_slots) {
        if (!record.alive || !record.drawn) {
            continue;
        }
        const Object &object = objects[size_t(record.object)];
        double reach = -INFINITY;
        int slot = 0;
        if (record.kind == KIND_DRAW) {
            reach = object.resolved ? object.draw_reach : -INFINITY;
        } else if (record.kind == KIND_IMPOSTOR) {
            reach = object.resolved && object.has_impostor ? object.impostor_reach : -INFINITY;
            slot = 1;
        } else {
            reach = object.resolved ? object.collider_reach : -INFINITY;
            slot = 2;
        }
        double size = record.kind == KIND_IMPOSTOR ? far_cell_size : cell_size;
        for (int64_t s = 0; s < count; s++) {
            Vector2 point = p_points[s];
            double distance = rect_distance(point.x, point.y, record.cell, size);
            bool needs = record.kind == KIND_COLLIDER ? (p_colliders[s] != 0 && distance - unload_margin <= reach)
                                                      : ((distance - unload_margin) / p_scales[s] <= reach);
            if (needs) {
                counts[size_t(s * 3 + slot)]++;
            }
        }
    }
    for (size_t i = 0; i < counts.size(); i++) {
        result.set(int64_t(i), counts[i]);
    }
    return result;
}

void CopiaStreamer::_bind_methods() {
    ClassDB::bind_method(D_METHOD("set_grid", "cell_size", "far_cell_size"), &CopiaStreamer::set_grid);
    ClassDB::bind_method(D_METHOD("set_margins", "load", "unload"), &CopiaStreamer::set_margins);
    ClassDB::bind_method(D_METHOD("set_movement_threshold", "metres"), &CopiaStreamer::set_movement_threshold);
    ClassDB::bind_method(D_METHOD("get_movement_threshold"), &CopiaStreamer::get_movement_threshold);
    ClassDB::bind_method(D_METHOD("set_max_ranges", "draw", "collider", "impostor"), &CopiaStreamer::set_max_ranges);
    ClassDB::bind_method(D_METHOD("set_object", "path", "resolved", "has_mesh", "draw_reach", "has_physics", "collider_reach",
                                 "has_impostor", "impostor_reach"),
            &CopiaStreamer::set_object);
    ClassDB::bind_method(D_METHOD("set_known", "far", "cell", "known"), &CopiaStreamer::set_known);
    ClassDB::bind_method(D_METHOD("clear_known"), &CopiaStreamer::clear_known);
    ClassDB::bind_method(D_METHOD("set_directory", "far", "cell", "objects"), &CopiaStreamer::set_directory);
    ClassDB::bind_method(D_METHOD("erase_directory", "far", "cell"), &CopiaStreamer::erase_directory);
    ClassDB::bind_method(D_METHOD("set_directory_pending", "far", "cell", "pending"), &CopiaStreamer::set_directory_pending);
    ClassDB::bind_method(D_METHOD("clear_pending"), &CopiaStreamer::clear_pending);
    ClassDB::bind_method(D_METHOD("clear_cells"), &CopiaStreamer::clear_cells);
    ClassDB::bind_method(D_METHOD("remove_record", "handle"), &CopiaStreamer::remove_record);
    ClassDB::bind_method(D_METHOD("set_record_stale", "handle", "stale"), &CopiaStreamer::set_record_stale);
    ClassDB::bind_method(D_METHOD("set_record_drawn", "handle"), &CopiaStreamer::set_record_drawn);
    ClassDB::bind_method(D_METHOD("get_record_priority", "handle"), &CopiaStreamer::get_record_priority);
    ClassDB::bind_method(D_METHOD("get_record_count"), &CopiaStreamer::get_record_count);
    ClassDB::bind_method(D_METHOD("set_excluded_rects", "rects"), &CopiaStreamer::set_excluded_rects);
    ClassDB::bind_method(D_METHOD("get_excluded_rects"), &CopiaStreamer::get_excluded_rects);
    ClassDB::bind_method(D_METHOD("mark_dirty"), &CopiaStreamer::mark_dirty);
    ClassDB::bind_method(D_METHOD("get_evaluation_count"), &CopiaStreamer::get_evaluation_count);
    ClassDB::bind_method(D_METHOD("update", "points", "scales", "densities", "colliders", "priorities", "load"), &CopiaStreamer::update);
    ClassDB::bind_method(D_METHOD("get_source_counts", "points", "scales", "colliders"), &CopiaStreamer::get_source_counts);
}

} // namespace Copia
