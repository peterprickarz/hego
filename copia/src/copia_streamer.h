#ifndef COPIA_STREAMER_H
#define COPIA_STREAMER_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/rect2.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/vector2i.hpp>

#include <cmath>
#include <cstdint>
#include <map>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace Copia {

// The streaming decision of a store: which sections to request, which loaded sections to free,
// what quality (group density, range scale) and creation priority each one gets, and which cell
// directories to read. It holds what the decision reads: the known cells, the object summaries of
// the cell directories read so far, the reach values of each object (resolved by the caller), the
// margins and the sections live in the store (records). One update() call takes the sources and
// returns only the changes. It makes no server call and reads no file, so the caller keeps the
// server work, the reads and the resources. See docs/development/copia_design.md, "Sources" and
// "CopiaStreamer", for the rules it implements.
//
// Kinds: 0 draw, 1 collider (cells), 2 impostor (far cells). A record is a live section, named by
// a handle (a positive integer the streamer gives it; a freed record's handle never names another).
class CopiaStreamer : public godot::RefCounted {
    GDCLASS(CopiaStreamer, godot::RefCounted)

public:
    enum Kind {
        KIND_DRAW = 0,
        KIND_COLLIDER = 1,
        KIND_IMPOSTOR = 2,
    };

    void set_grid(double p_cell_size, double p_far_cell_size);
    void set_margins(double p_load, double p_unload);
    void set_movement_threshold(double p_metres);
    double get_movement_threshold() const;
    // The largest draw reach, collider reach and impostor reach of the known objects (INF for an
    // unlimited range), which decide the cells whose directories are read.
    void set_max_ranges(double p_draw, double p_collider, double p_impostor);

    // An object's values, by path: resolved (false: its sections are freed and never requested),
    // whether it has a mesh, its draw reach (INF: unlimited), whether it has a collider, its
    // collider reach, whether it has an impostor and its impostor reach. Returns its id.
    int64_t set_object(const godot::String &p_path, bool p_resolved, bool p_has_mesh, double p_draw_reach, bool p_has_physics,
            double p_collider_reach, bool p_has_impostor, double p_impostor_reach);

    void set_known(bool p_far, const godot::Vector2i &p_cell, bool p_known);
    void clear_known();
    // A cell's directory has been read: the "objects" of CopiaCells.read_directory (an empty
    // Dictionary for an unreadable file). Clears its pending flag. Returns the object paths no
    // directory had named before.
    godot::PackedStringArray set_directory(bool p_far, const godot::Vector2i &p_cell, const godot::Dictionary &p_objects);
    void erase_directory(bool p_far, const godot::Vector2i &p_cell);
    void set_directory_pending(bool p_far, const godot::Vector2i &p_cell, bool p_pending);
    void clear_pending();
    // Forgets the cells, directories and records (the objects stay).
    void clear_cells();

    // The caller freed a record (idempotent).
    void remove_record(int64_t p_handle);
    // A record read from an older directory than its cell's current one: requested again (in
    // "reloads") at an update that finds it within the load reach.
    void set_record_stale(int64_t p_handle, bool p_stale);
    // A record whose group exists, for get_source_counts().
    void set_record_drawn(int64_t p_handle);
    // The creation priority of a record from the last evaluation: the smallest distance ÷
    // priority among the sources needing it (INF when none did).
    double get_record_priority(int64_t p_handle) const;
    int64_t get_record_count() const;

    // Rectangles (Rect2, local XZ) whose cells are left out: a cell or far cell whose centre lies
    // in one (Rect2.has_point) has no directory read and no section requested, and its live
    // records are freed by the next update. Replaces the previous list.
    void set_excluded_rects(const godot::Array &p_rects);
    godot::Array get_excluded_rects() const;

    // The next update evaluates even if no source moved.
    void mark_dirty();
    int64_t get_evaluation_count() const;

    // Takes the sources (local XZ points, range scales, densities, collider flags, priorities).
    // Without a change since the last evaluation (no source moved more than the movement
    // threshold, no source setting, object, cell, directory or record changed) returns
    // {evaluated: false}. Otherwise returns {evaluated: true, records, densities, scales,
    // directories, requests, request_kinds, request_cells, request_paths, request_densities,
    // request_scales, reloads}: records (PackedInt64Array) the live records whose density or
    // range scale changed, or that are freed (density -1), cells before far cells; directories
    // (PackedInt32Array, far flag, x and z per cell) to read, now pending; requests the new
    // records to load (kind, cell as x and z, object path, density and range scale); reloads the
    // stale records within reach. With p_load false (a build is writing the files) only the
    // records are evaluated, and the next update evaluates again.
    godot::Dictionary update(const godot::PackedVector2Array &p_points, const godot::PackedFloat64Array &p_scales,
            const godot::PackedFloat64Array &p_densities, const godot::PackedByteArray &p_colliders,
            const godot::PackedFloat64Array &p_priorities, bool p_load);

    // For each given source, the drawn records it needs by kind (draw, impostor, collider: three
    // per source), by the unload margin.
    godot::PackedInt32Array get_source_counts(const godot::PackedVector2Array &p_points, const godot::PackedFloat64Array &p_scales,
            const godot::PackedByteArray &p_colliders) const;

protected:
    static void _bind_methods();

private:
    struct Object {
        godot::String path;
        bool resolved = false;
        bool has_mesh = false;
        double draw_reach = 0.0;
        bool has_physics = false;
        double collider_reach = 0.0;
        bool has_impostor = false;
        double impostor_reach = 0.0;
    };

    struct Entry {
        int32_t object = 0;
        bool instances = false;
        bool colliders = false;
    };

    struct CellKey {
        int32_t x = 0;
        int32_t z = 0;
        bool operator==(const CellKey &p_other) const { return x == p_other.x && z == p_other.z; }
        bool operator<(const CellKey &p_other) const { return x != p_other.x ? x < p_other.x : z < p_other.z; }
    };

    struct CellKeyHash {
        size_t operator()(const CellKey &p_key) const {
            return std::hash<uint64_t>()((uint64_t(uint32_t(p_key.x)) << 32) | uint32_t(p_key.z));
        }
    };

    struct Cell {
        bool known = false;
        bool pending = false;
        bool cached = false;
        std::vector<Entry> entries;
    };

    struct Grid {
        std::unordered_map<CellKey, Cell, CellKeyHash> cells;
        int64_t known_count = 0;
        int64_t cached_count = 0;
        Cell *find(const CellKey &p_key);
        const Cell *find(const CellKey &p_key) const;
        Cell &get(const CellKey &p_key);
        void drop_if_empty(const CellKey &p_key);
    };

    struct Record {
        int64_t handle = 0;
        int kind = KIND_DRAW;
        CellKey cell;
        int32_t object = 0;
        double density = 1.0;
        double scale = 1.0;
        double priority = 0.0;
        bool stale = false;
        bool drawn = false;
        bool alive = false;
        uint32_t generation = 0; // of its slot, part of the handle
        size_t slot = 0; // index in its live cell's list
    };

    struct LiveCell {
        std::vector<int64_t> records; // in creation order, swap-removed
        std::vector<int64_t> by_object; // object * 3 + kind -> handle (0: none), grown on demand
        int64_t find(int32_t p_object, int p_kind) const {
            size_t index = size_t(p_object) * 3 + size_t(p_kind);
            return index < by_object.size() ? by_object[index] : 0;
        }
    };

    struct Source {
        float x = 0.0f;
        float z = 0.0f;
        double scale = 1.0;
        double density = 1.0;
        bool colliders = false;
        double priority = 1.0;
    };

    double cell_size = 64.0;
    double far_cell_size = 128.0;
    double load_margin = 16.0;
    double unload_margin = 32.0;
    double movement_threshold = 1.0;
    double max_draw = INFINITY;
    double max_collider = INFINITY;
    double max_impostor = INFINITY;

    std::vector<Object> objects;
    std::unordered_map<std::string, int32_t> object_ids;
    std::unordered_set<int32_t> directory_objects; // objects some directory has named

    Grid grids[2]; // cells, far cells
    // Records in slots; a handle is (generation << 32) | (slot + 1), so a freed slot's old handle
    // never names the record that reuses it.
    std::vector<Record> record_slots;
    std::vector<uint32_t> free_slots;
    int64_t record_count = 0;
    std::map<CellKey, LiveCell> live[2];
    Record *find_record(int64_t p_handle);
    const Record *find_record(int64_t p_handle) const;

    // Excluded cells per grid (cells, far cells), enumerated from the rectangles; rectangles that
    // cover too many cells to enumerate are tested per cell instead.
    std::vector<godot::Rect2> excluded_rects;
    std::unordered_set<CellKey, CellKeyHash> excluded_cells[2];
    std::vector<godot::Rect2> excluded_large;
    void rebuild_excluded();
    bool is_excluded(bool p_far, const CellKey &p_key) const;

    std::vector<Source> evaluated; // the sources of the last evaluation
    bool has_evaluated = false;
    bool dirty = true;
    int64_t evaluations = 0;

    // Work arrays of one update.
    std::vector<Source> sources;
    std::vector<double> distances;
    std::vector<double> thresholds;
    std::vector<double> collider_thresholds;

    int32_t intern(const godot::String &p_path);
    static double rect_distance(float p_x, float p_z, const CellKey &p_cell, double p_size);
    void cells_in_reach(const Grid &p_grid, bool p_cached, float p_x, float p_z, double p_size, double p_reach,
            std::vector<CellKey> &r_cells) const;
    void cells_near_sources(const Grid &p_grid, double p_size, bool p_far, std::vector<CellKey> &r_cells) const;
    double source_reach(size_t p_source) const;
    void compute_distances(const CellKey &p_cell, double p_size);
    double threshold(double p_margin, bool p_colliders) const;
    void source_thresholds(double p_margin, bool p_colliders, std::vector<double> &r_thresholds) const;
    void qualify(Record &r_record, double p_reach, double p_margin) const;
    void requalify(Record &r_record, double p_reach, const std::vector<double> &p_thresholds) const;
    bool sources_changed() const;
    void erase_record(Record &p_record);
    int64_t add_record(int p_kind, bool p_far, const CellKey &p_cell, int32_t p_object);
    // The changes of one update, gathered in plain vectors and returned as packed arrays.
    struct Output {
        std::vector<int64_t> records;
        std::vector<double> record_densities;
        std::vector<double> record_scales;
        std::vector<int32_t> directories;
        std::vector<int64_t> requests;
        std::vector<int32_t> request_kinds;
        std::vector<int32_t> request_cells;
        std::vector<int32_t> request_objects;
        std::vector<double> request_densities;
        std::vector<double> request_scales;
        std::vector<int64_t> reloads;
    };
    void update_records(bool p_far, Output &r_out);
    void request_directories(Output &r_out);
    void load_cells(Output &r_out);
    void load_far(Output &r_out);
    void want(LiveCell *&r_live, bool p_far, const CellKey &p_cell, int32_t p_object, int p_kind, double p_reach, Output &r_out);
};

} // namespace Copia

#endif // COPIA_STREAMER_H
