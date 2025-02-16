#ifndef HOUDINI_ASSET_NODE_H
#define HOUDINI_ASSET_NODE_H

#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/core/class_db.hpp>

using namespace godot;

class HoudiniAssetNode : public Node3D
{
    GDCLASS(HoudiniAssetNode, Node3D);

private:
    Ref<Resource> hda_resource;
    bool recook_button;

protected:
    static void _bind_methods();

public:
    HoudiniAssetNode();
    ~HoudiniAssetNode();

    void set_hda_resource(const Ref<Resource> &p_hda_resource);
    Ref<Resource> get_hda_resource() const;

    void set_recook_button(bool p_recook_button);
    bool get_recook_button() const;

private:
    void recook();
};

#endif // HOUDINI_ASSET_NODE_H