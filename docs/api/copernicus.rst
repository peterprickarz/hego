Copernicus textures
===================

Use :ref:`HEGoTextureInputNode<class_HEGoTextureInputNode>` to send CPU pixels or a
Godot texture to Houdini. Use :ref:`fetch_cop_image()<class_HEGoAssetNode_method_fetch_cop_image>`
to read a layer by its Houdini node path and output name. The two operations can be
used independently.

Texture inputs on a SOP HDA
---------------------------

Select the HEGoNode3D and open **Inputs** in the HEGo bottom panel. On the HDA
socket you want to feed, choose **Add Texture** and assign a Godot **Texture2D**.
Choose **Linear** for masks, normals, and already-linear data, or **sRGB** for
sRGB-encoded colour. The scene stores the Godot texture reference and its
encoding. HEGo uploads the pixels when it syncs the inputs for a cook.

Each assigned texture contributes one point at the origin to the numbered SOP
input. Its string point attribute ``hego_cop_path`` holds the absolute path of
the COP that owns the current image. That path belongs to the live Houdini
session. Use the point supplied on each cook. A dedicated socket with two
textures has points 0 and 1 in the order shown in the panel. If you also assign
scene geometry to the socket, its points come first. In that case, select the
texture points by their nonempty ``hego_cop_path``.

To use the first texture inside the HDA:

1. Connect the HDA's input to a Null SOP named ``IN_TEXTURE``.
2. Add a COP Network SOP named ``copnet1`` next to the Null. Inside it, add a
   Fetch COP. Set its **COP Path** to the HScript expression
   ``points("../../IN_TEXTURE", 0, "hego_cop_path")``. For a second texture on
   the same socket, use point 1 in a second Fetch COP.
3. Wire the Fetch COP into a Channel Split COP named ``channelsplit1``. Godot can
   now read the ``green`` output of ``copnet1/channelsplit1`` independently of the
   HDA's geometry output.

If geometry operators also need those pixels, enable **Use External COP** on the
COP Network SOP, set its **COP Path** to ``channelsplit1``, and use **Single
Output** to select a channel. The SOP exposes that layer as a 2D volume. A
downstream wrangle can then read a texel with ``volumeindex(0, 0, set(x, y, 0))``.
Updating the uploaded image preserves the connection.

Wiring from GDScript
--------------------

To configure the same input as the panel from a script:

.. code-block:: gdscript

    hego_node.agent.set_input(0, {"texture": albedo, "encoding": HEGoTextureInputNode.ENCODING_SRGB})
    await hego_node.cook()

Passing a ``Texture2D`` directly uses linear encoding. An array supplies several
sources to one socket.

For direct control over upload and fetch, use the node's
:ref:`HEGoAssetAgent<class_HEGoAssetAgent>` and the instantiated
:ref:`HEGoAssetNode<class_HEGoAssetNode>`. In this example, ``albedo`` holds
sRGB-encoded pixels. Store the texture input on the scripted node so subsequent
calls can update the same Houdini image.

.. code-block:: gdscript

    var texture_input := HEGoTextureInputNode.new()

    func read_green(agent: HEGoAssetAgent, asset: HEGoAssetNode, albedo: Texture2D) -> Image:
        if await agent.task(texture_input.set_texture(albedo, HEGoTextureInputNode.ENCODING_SRGB)) == null:
            return null
        var wired := await HEGoNodeUtil.checked_task(agent.owner_node, asset.connect_input(texture_input, 0))
        if not wired.ok:
            return null
        return await agent.task(asset.fetch_cop_image("copnet1/channelsplit1", "green"))

The returned ``Image.FORMAT_RF`` stores the green values in its single red component.
Read one with ``image.get_pixel(x, y).r`` or create a Godot texture with
``ImageTexture.create_from_image(image)``. Results use Godot's top-left pixel
origin. Keep masks, normals, and already-linear data in the default
``ENCODING_LINEAR``. Use ``set_image(image, encoding)`` when the source pixels
are already in CPU memory.

For a standalone COP HDA, wire the uploaded source to a compatible input with
``asset.connect_input(texture_input, input_index)`` and fetch an exposed layer with
``asset.fetch_cop_image("", output_name)``. An empty output name selects its first
connector. Absolute paths address other COP nodes in the same Houdini session.
Existing HDAs that expose a COP node-reference parameter can also use
``asset.set_node_parm("source_texture", texture_input)``.

Large transfers
---------------

Uploads use four bytes per channel per pixel, so a 4096 × 4096 RGBA upload occupies
256 MiB before transport overhead. For a shared-memory session whose fixed buffer
is too small, enable ``hego/session/shared_memory_ring_buffer`` in Godot's Project
Settings and restart the Houdini session. This enables the transfer to pass through
shared memory in chunks.
