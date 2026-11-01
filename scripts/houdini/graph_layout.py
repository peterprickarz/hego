"""Deterministic stage layout for generated HEGo assets (authoring only).

Native nodes keep their type-derived names; local relative Object Merges expose
cross-stage dependencies without wires spanning the complete asset.
"""
import re

EROSION_STAGES = [
    ("01 Input lattices and exact resampling", [
        [("IN_terrain", 0), ("IN_constraints", 7)], [("grid_info", 0)],
        [("target_grid", -3)], [("resample", 0)]]),
    ("02 Native hydraulic / thermal erosion and debris slump", [
        [("erode_source", -3), ("erode_mask_layers", 4)], [("erode_masks", 4)],
        [("erode", 0)], [("slump_thermal_debris", 3)], [("slump_switch", 0)]]),
    ("03 Protection and exact manual transition", [
        [("check_grid", 0)], [("post", 0)], [("manual_transition", 0)]]),
    ("04 Published simulation and habitat masks", [
        [("mask_grid", 0)], [("mask_layers", 0)], [("masks", 0)]]),
    ("05 Inherit materials and refine from this pass", [
        [("material_layers", 0)], [("material_stage", 0)], [("keep_materials", 0)]]),
    ("06 Publish channels and diagnostics", [
        [("keep_height", -4), ("keep_masks", 4)], [("merge_channels", 0)],
        [("route", 0)], [("clean_attributes", 0)], [("diagnostics", 0)], [("output0", 0)]]),
]
MATERIAL_STAGES = [
    ("01 Input height, simulation masks and prior materials", [
        [("keep_height", -5), ("keep_optional_masks", 2), ("keep_prior_materials", 9)],
        [("strip_input_attributes", -5)], [("registry_channels", -5)]]),
    ("02 Keep stage materials / generate uncovered samples", [[("distribute", 0)]]),
    ("03 Publish registry channels", [[("route", 0)], [("clean_attributes", 0)], [("output0", 0)]]),
]


HANDOFF_NAMES = {
    "IN_terrain": "TERRAIN_INPUT", "IN_constraints": "MANUAL_CONSTRAINTS",
    "grid_info": "GRID_METADATA", "resample": "RESAMPLED_TERRAIN",
    "slump_switch": "SIMULATED_TERRAIN", "post": "PROTECTED_SIMULATION",
    "manual_transition": "FINAL_HEIGHTFIELD", "masks": "SIMULATION_MASKS",
    "keep_materials": "MATERIAL_WEIGHTS", "distribute": "MATERIAL_WEIGHTS",
    "registry_channels": "MATERIAL_GRID", "keep_prior_materials": "PRIOR_MATERIALS",
    "keep_optional_masks": "SIMULATION_MASKS",
}


def organize(hou, sub, stages, notes):
    """Apply the user's graph conventions; no geometry or algorithm changes."""
    for box in sub.networkBoxes():
        box.destroy()
    for note in sub.stickyNotes():
        note.destroy()
    stage_of = {name: i for i, (_, rows) in enumerate(stages) for row in rows for name, _ in row}
    original = {n.name(): n for n in sub.children()}
    bridges, imports = {}, {i: {} for i in range(len(stages))}
    # Read the original wires before replacing cross-stage connections.
    edges = [(n, c.inputIndex(), c.inputNode(), c.outputIndex())
             for n in sub.children() for c in n.inputConnections()
             if c.inputNode() is not None and c.inputNode().name() in stage_of
             and stage_of[n.name()] != stage_of[c.inputNode().name()]]
    for dest, slot, source, output in edges:
        key = (source.name(), output)
        semantic = HANDOFF_NAMES.get(source.name(), source.name().upper())
        if key not in bridges:
            out = sub.createNode("null", "OUT_" + semantic + ("_%d" % output if output else ""))
            out.setInput(0, source, output)
            out.setComment("Handoff: " + source.name().replace("_", " "))
            bridges[key] = out
        stage = stage_of[dest.name()]
        if key not in imports[stage]:
            incoming = sub.createNode("object_merge", "IN_" + semantic + "_S%d" % (stage + 1))
            incoming.parm("objpath1").set("../" + bridges[key].name())
            incoming.parm("xformtype").set("none")
            incoming.setComment("Local handoff from stage %02d" % (stage_of[source.name()] + 1))
            imports[stage][key] = incoming
        dest.setInput(slot, imports[stage][key])
    # Native names are allocated deterministically, including numeric suffixes.
    counts = {}
    rename = {}
    for name, node in original.items():
        kind = node.type().name().split("::")[0]
        if kind in ("attribwrangle", "volumewrangle", "python", "output"):
            continue
        if kind == "null":
            target = name.upper()
        else:
            counts[kind] = counts.get(kind, 0) + 1
            target = kind + str(counts[kind])
        if target != name:
            rename[name] = target
    # Repair literal path strings in VEX/Python as well as expressions.
    for node in sub.children():
        for parm in node.parms():
            if parm.parmTemplate().type() != hou.parmTemplateType.String:
                continue
            try:
                text = parm.unexpandedString()
            except hou.Error:
                continue
            repaired = text
            for old, new in rename.items():
                repaired = re.sub(r'(?<=/)' + re.escape(old) + r'(?=[/"\s\x27]|$)', new, repaired)
            if repaired != text:
                parm.set(repaired)
    for old, new in rename.items():
        original[old].setName(new)
    pink, green = hou.Color((0.85, 0.42, 0.68)), hou.Color((0.32, 0.7, 0.38))
    y = 0.0
    for stage, (label, rows) in enumerate(stages):
        members = []
        incoming = list(imports[stage].values())
        if label.startswith("03 Protection"):
            incoming = [imports[stage][(name, 0)] for name in
                        ("slump_switch", "grid_info", "resample", "IN_constraints")]
        for i, node in enumerate(incoming):
            if label.startswith(("03 Protection", "05 ")):
                x = i * 4.5
            elif label.startswith("04 "):
                x = (i + 1) * 4.5
            elif label.startswith("06 "):
                x = (-4., 4., 0., 4.5, 9.)[i]
            else:
                x = (i - (len(incoming) - 1) / 2) * 4.5
            node.setPosition(hou.Vector2(x, y))
            members.append(node)
        if incoming:
            y -= 2.5
        for row in rows:
            for name, x in row:
                node = original[name]
                node.setPosition(hou.Vector2(x, y))
                text = notes.get(name, name.replace("_", " "))
                node.setComment(text[1] if isinstance(text, tuple) else text)
                members.append(node)
            y -= 2.5
        outgoing = sorted([node for (name, _), node in bridges.items() if stage_of[name] == stage],
                          key=lambda node: (node.inputs()[0].position().x(), -node.inputs()[0].position().y()))
        for i, node in enumerate(outgoing):
            source = node.inputs()[0]
            if label.startswith("01 Input lattices"):
                x = 12.0 if source == original["IN_constraints"] else -6.0
                node.setPosition(hou.Vector2(x, source.position().y() - 1.25))
            else:
                node.setPosition(hou.Vector2((i - (len(outgoing) - 1) / 2) * 4.5, y))
            members.append(node)
        if outgoing and not label.startswith("01 Input lattices"):
            y -= 2.5
        if label.startswith("06 "):
            # Diagnostic side inputs are consumed here, so give them local
            # inlets beside diagnostics rather than bypass wires through the
            # complete routing chain. Height also has an earlier value output.
            diag = original["diagnostics"]
            local_y = diag.position().y() + 1.25
            for source_name, x in (("grid_info", 4.5), ("material_stage", 13.5)):
                imports[stage][(source_name, 0)].setPosition(hou.Vector2(x, local_y))
            early = imports[stage][("manual_transition", 0)]
            local = sub.createNode("object_merge", "IN_FINAL_HEIGHTFIELD_DIAGNOSTICS")
            local.parm("objpath1").set(early.parm("objpath1").evalAsString())
            local.parm("xformtype").set("none")
            local.setComment("Local final-height diagnostics input from stage 03")
            local.setPosition(hou.Vector2(9., local_y))
            diag.setInput(2, local)
            members.append(local)
        box = sub.createNetworkBox("stage_%02d" % (stage + 1))
        box.setComment(label)
        box.setColor(hou.Color((0.18 + stage * .025, .23, .27)))
        for node in members:
            box.addItem(node)
        box.fitAroundContents()
        box.setAutoFit(True)
        y -= 3.0
    for node in sub.children():
        kind = node.type().name().split("::")[0]
        if kind in ("attribwrangle", "volumewrangle"):
            node.setColor(green)
        elif kind in ("object_merge", "null"):
            node.setColor(pink)
        node.setGenericFlag(hou.nodeFlag.DisplayComment, True)
    for i, item in enumerate(sub.indirectInputs()):
        item.setPosition(hou.Vector2(i * 7, 3))


def document_definition(hou, definition, group, title, description, inputs, outputs):
    """Embed wiki hints once and leave explicit parameter Help fields empty."""
    lines = ['= ' + title + ' =', '', description, '', '@inputs', ''] + inputs + ['', '@outputs', ''] + outputs + ['', '== Usage ==', '',
        'Set the target layer path, connect the documented scalar heightfields and cook explicitly. '
        'Draft settings and cropped test inputs are not a production island bake.', '',
        '== Limitations ==', '',
        'Dense finite orthogonal horizontal scalar fields only. No VDBs or vector outputs. '
        'Material fields use the registry IDs and at most four normalized contributors; resampling can require the shared soft limiter.', '', '@parameters', '']
    def clear(template):
        children = template.parmTemplates() if isinstance(template, hou.FolderParmTemplate) else ()
        if children:
            template.setParmTemplates([clear(c) for c in children])
        else:
            hint = template.help() or ('Controls ' + template.label().lower() + '.')
            lines.extend([template.label() + ':', '    #id: ' + template.name(), '', '    ' + hint.replace('\n', ' '), ''])
        template.setHelp('')
        return template
    cleaned = hou.ParmTemplateGroup()
    for template in group.parmTemplates():
        cleaned.append(clear(template))
    definition.setParmTemplateGroup(cleaned)
    definition.addSection('Help', '\n'.join(lines) + '\n')
