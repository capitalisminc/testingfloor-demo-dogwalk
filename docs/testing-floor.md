# Using DOGWALK as an instrumentation reference

Start with [`source/testing_floor/dogwalk_telemetry.gd`](../source/testing_floor/dogwalk_telemetry.gd). It observes the game’s existing signals and state, keeping game-specific knowledge outside the reusable [`addons/testing_floor`](../addons/testing_floor) client.

## Reuse the addon

Copy `addons/testing_floor` into your project and add `autoload.gd` as an autoload named `TestingFloor`. Give it an ignored `TestingFloor.local.json` containing `write_key` and `app_version`, or set `TESTING_FLOOR_WRITE_KEY` in the process environment. Editor collection requires `enable_in_editor: true`. Without configuration, collection is disabled.

```gdscript
TestingFloor.context_provider = func():
    return {"game_level.id": "forest"}
TestingFloor.activity_source = func():
    return {"player_position": player.global_position}
TestingFloor.track("item_picked_up", {"item.id": "shovel"})
TestingFloor.set_state("items.found", 2)

var id = TestingFloor.track_node("companion", companion, "pinda")
TestingFloor.set_object_state(id, "mood", 8.0)
TestingFloor.remove_object(id, "level_unloaded")
```

Use stable object IDs in events and object tracking so an interaction can be followed along the same object’s path. Use `record_teleport(start, finish, reason)` for save loads and respawns; this resets movement accumulation rather than counting the jump as traveled distance. Call `await TestingFloor.shutdown()` before quitting, or use `TestingFloor.quit_game()` with this autoload.

The client records positions in Godot’s native **meters**, with **Y up**. Player movement and tracked objects are sampled at most **10 times per second**, with a **0.25 m** movement threshold. Gameplay events include the current player and camera positions. Camera activity can also trigger movement pings. Persistent state is diffed once per second and before gameplay events; full state and object keyframes repeat every five minutes.

Events are batched every two seconds or at 100 queued records. Failed requests retry with backoff. The queue and record sizes are bounded. Events pending at quit get a bounded flush; offline play can still lose unsent events when the game closes.

## Choose the right signals

DOGWALK uses three complementary forms of telemetry:

| Form | Examples | Purpose |
| --- | --- | --- |
| Gameplay events | Bark, digging, help request, decoration pickup/placement, gate opening, completion | Useful moments in a recording’s timeline |
| Persistent state | Mood, stamina, leash length, story phase, decorations found/placed | Context that changes over time without filling the timeline |
| Tracked objects | Chocomel, Pinda, four decorations, snowman, gate | Independent paths, positions, and object state |

The original item setter signals even when the value is unchanged, so the integration deduplicates transitions. It caches the new state before recording an event because the game emits several signals before assigning their backing property. Save loading suppresses pickup/placement events while restoring items and records a teleport afterward.

[`testingfloor-telemetry-schema.json`](../testingfloor-telemetry-schema.json) maps native fields to analytics and defines readable labels, colors, and metadata. Movement and routine state transitions stay out of the main timeline by default.

## Recording sync

The addon accepts the recorder’s `--testing-floor=<JSON>` handoff, registers its session in the supplied telemetry directory, and watches `closed.json`. It sends the completion marker after preceding batches are acknowledged. Without a handoff, the visible QR marker carries the session ID and current UTC time; it refreshes every 15 seconds. A handoff with `suppress_qr` hides it, and `--forceqr` restores it.

## Render the analytics map

Run the game with `--audio-driver Dummy -- --tf-capture-map`. The capture job uses a separate overhead camera in the existing 3D world, retaining its materials, lighting, and environment. It writes a PNG and upload manifest under `Artifacts/maps`, then closes. Collection and QR rendering are disabled for the capture.

Map coordinates are **X right, Z up**, with one world unit per meter. The output image is flipped horizontally to match that orientation. The manifest includes the exact center and span used by the camera, and pins the map to the game version.

With the Testing Floor CLI, apply the schema using `set-telemetry-schema --schema testingfloor-telemetry-schema.json` and upload the map using `upload-map --config Artifacts/maps/testingfloor-maps.json`.

## Check and export

Run `python3 tools/test_telemetry.py --godot /path/to/godot` for isolated checks of state, object lifetimes, retry ordering, recording completion, movement, and QR encoding. They use a fake transport and never send events.

For a short gameplay check, run the project with `--audio-driver Dummy -- --tf-test --tf-smoke-test`. It starts a new game, moves Chocomel, pauses and resumes, checks the emitted events, and closes automatically. Its report is saved under `Artifacts/smoke-game.json`.

Install the matching Godot export templates and use the supplied macOS, Windows Desktop, and Linux release presets. Run `python3 tools/configure.py --require-key` first when producing an instrumented build. Only the client telemetry key is exported; `.env`, management API credentials, tools, and generated artifacts are excluded.
