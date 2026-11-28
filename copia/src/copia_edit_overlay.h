#ifndef COPIA_EDIT_OVERLAY_H
#define COPIA_EDIT_OVERLAY_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/color.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/rid.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/transform3d.hpp>

#include <cstdint>
#include <string>
#include <unordered_map>
#include <vector>

namespace Copia {

// Lightweight RenderingServer staging overlay for interactive editor placement and painting.
// Renders uncommitted brush strokes (via per-object dynamic MultiMeshes) and a drag-drop ghost
// instance at 60 FPS without touching disk or rebuilding built cells. Frees all RIDs on destroy.
class CopiaEditOverlay : public godot::RefCounted {
    GDCLASS(CopiaEditOverlay, godot::RefCounted)

public:
    CopiaEditOverlay() = default;
    ~CopiaEditOverlay() override;

    void set_scenario(const godot::RID &p_scenario);
    godot::RID get_scenario() const;
    void set_transform(const godot::Transform3D &p_transform);
    godot::Transform3D get_transform() const;

    // Registers draw visuals for an object path (mesh RID should already carry per-surface
    // materials for MultiMesh rendering, e.g. CopiaObject.get_surface_material_mesh()).
    void set_object_visual(const godot::String &p_object_path, const godot::RID &p_mesh,
            const godot::RID &p_material_override = godot::RID(),
            const godot::Color &p_default_color = godot::Color(1, 1, 1, 1),
            const godot::Color &p_default_custom = godot::Color(0, 0, 0, 0),
            uint32_t p_layers = 1, int p_cast_shadows = 1);

    // Appends uncommitted paint points ({transform, object, object_paths, optional color, custom})
    // to the live MultiMeshes. Returns total staged instance count across all objects.
    int64_t append_points(const godot::Dictionary &p_points);

    // Updates or hides the single drag-drop ghost instance (store-local transform).
    void set_ghost(const godot::String &p_object_path, const godot::Transform3D &p_transform, bool p_visible);
    void hide_ghost();

    int64_t get_staged_count() const;
    void clear_stroke();
    void clear_all();

protected:
    static void _bind_methods();

private:
    struct Visual {
        godot::RID mesh;
        godot::RID material_override;
        godot::Color default_color = godot::Color(1, 1, 1, 1);
        godot::Color default_custom = godot::Color(0, 0, 0, 0);
        uint32_t layers = 1;
        int cast_shadows = 1;
    };

    struct Bucket {
        godot::RID multimesh;
        godot::RID instance;
        int32_t capacity = 0;
        int32_t count = 0;
        godot::PackedFloat32Array buffer; // capacity * 20 floats
    };

    godot::RID scenario;
    godot::Transform3D transform;
    std::unordered_map<std::string, Visual> visuals;
    std::unordered_map<std::string, Bucket> buckets;
    godot::RID ghost_instance;
    std::string ghost_object;
    bool ghost_visible = false;
    int64_t staged_total = 0;

    void ensure_bucket(const std::string &p_path, Bucket &r_bucket, int32_t p_needed);
    void free_bucket(Bucket &r_bucket);
    void free_ghost();
};

} // namespace Copia

#endif // COPIA_EDIT_OVERLAY_H
