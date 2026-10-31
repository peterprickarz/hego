# Godot MCP editor bridge

The demo project carries the editor addon of
[`@satelliteoflove/godot-mcp`](https://github.com/satelliteoflove/godot-mcp), version **4.1.11**
(Godot 4.5 or newer), in `demo/addons/godot_mcp/`. It lets an agent inspect the live editor:
scene tree, resources, viewport screenshots, the editor log and GDScript run inside the editor.
It is a development aid only and is not part of any HEGo or Strata package.

## How it fits together

- The addon runs a WebSocket server inside the editor on `127.0.0.1`.
- The MCP server (`dist/cli.js` of the npm package) is a stdio process started by the agent client.
  It connects to that WebSocket. The addon accepts one client at a time.
- Keep the server and addon versions identical. Update both together; the package installs the
  addon with `node dist/cli.js --install-addon <project>`.

## Port

The addon defaults to port 6550, which another Godot project on the same workstation may own.
This project therefore sets, in `demo/project.godot`:

```ini
[godot_mcp]
port_override_enabled=true
port_override=6560
```

The server selects its port with the `GODOT_PORT` environment variable (default 6550), so both
sides must say 6560. The editor log shows `Server listening on 127.0.0.1:6560` when the addon is up.

## Client configuration

`.mcp.json` is ignored by Git because the paths differ between workstations. A Claude Code entry:

```json
{
  "mcpServers": {
    "godot": {
      "type": "stdio",
      "command": "<node 20+ executable>",
      "args": ["<node_modules>/@satelliteoflove/godot-mcp/dist/cli.js"],
      "env": {"GODOT_PORT": "6560"}
    }
  }
}
```

Open the demo project in the Godot editor first, then reconnect the MCP server in the client.

## Caveats

- On first enable the addon registers an `MCPGameBridge` autoload in `demo/project.godot`. It
  belongs to the demo project only; never copy it, or `addons/godot_mcp`, into the published
  `hego`, `strata`, `hego_strata` or `hego_terrain3d` packages.
- The bridge only activates in debug sessions, but review it before exporting the demo.
- Prefer read-only inspection; the tools can also edit scenes and run scripts in the editor.

## Querying the addon without an MCP client

The addon speaks plain JSON over its WebSocket: send `{"id": "<any>", "command": "<name>",
"params": {...}}` and read one JSON reply with the same `id`, a `status` and a `result`. Node
20+ has a `WebSocket` global, so a ten-line script is enough when the MCP server is not wired
into the agent session. Useful read-only commands: `get_log_messages` (editor errors and
warnings captured by the addon's `Logger`), `get_scene_tree`, `get_selected_nodes`,
`get_node_properties` with `node_path` relative to the edited scene root, and
`capture_editor_screenshot` with `{"viewport": "3d"}` (returns `image_base64`).

`get_node_properties` serializes every property value. On a `StrataLayer` or the textured
preview renderer that means megabytes of sample data and textures, so the call stalls the
editor for seconds and times out; query the terrain or the bridge node instead.
