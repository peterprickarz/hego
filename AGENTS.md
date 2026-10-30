# Demo and test fixtures

Make temporary substitutions, placeholder assets, and artificial demo or benchmark behavior explicit in user-facing explanations and the relevant documentation. When they affect an editing workflow, label them in that workflow too. Do not present these fixtures as completed production features.

Keep artificial stress-test data in dedicated tests or benchmark scenes. The normal terrain showcase should use real assets and its actual procedural generation pipeline unless the user explicitly requests a fixture.

# Houdini network conventions

- Lay out networks top to bottom in cooking dependency order, including Object Merge and parameter-reference dependencies. Sequential stages belong below their inputs; place stage boxes side by side only for independent branches.
- Group processing by stage. After the final changes, fit every network box around its current nodes, include new nodes, remove obsolete labels/empty groups and enable automatic fitting. Put every HDA Output SOP on the lowest row.
- Replace long crossing wires with local relative Object Merges and semantic handoff Nulls. Use uppercase `OUT_` names for output/bridge Nulls and `IN_` names for input Nulls/Object Merges; preserve output connector indices.
- Keep self-explanatory native operators and HDA instances at their default type-derived instance names, including numeric suffixes. Explain special roles in node comments. Use snake_case for custom processing such as VEX wrangles and Python SOPs.
- Colour VEX wrangles green and Object Merges plus their associated handoff Nulls pink.
- Link controls directly to the enclosing HDA parameters; do not add internal CTRL Nulls. Promote controls through each intervening subnet interface one level at a time. Child HDAs use their own interfaces, linked locally by the parent.
- Preserve viewport orientation. Preserve existing node positions unless reorganization is explicitly requested; the user has authorized moving all nodes in the current AI-generated island graphs to meet these conventions.
- Save intended HDA changes to their definitions and finish with matching instances, including nested HDAs. After renaming or removing nodes, repair parameter expressions, VEX/Python path strings, Object Merge paths, callbacks and documentation. Verify the saved definition in a fresh instance, including independent controls and a clean cook.
