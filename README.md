# DOGWALK × Testing Floor

This fork of Blender Studio’s [DOGWALK](https://studio.blender.org/projects/dogwalk/) demonstrates [Testing Floor](https://testingfloor.com) in a complete Godot game: recording sync, a gameplay timeline, character and collectible paths, and a rendered level map.

Explore a winter forest as Chocomel, a big dog helping a child collect decorations for a snowman. The original art, lighting, animation, and gameplay are preserved. Our changes add a reusable Godot telemetry addon and game-specific instrumentation.

## Play and explore

Open `project.godot` with **Godot 4.4.1** and run the main scene. Use the mouse to guide Chocomel and click to bark or interact; a controller is also supported. Escape opens the pause menu. Packaged builds start in fullscreen.

- Follow Chocomel and Pinda independently across the forest.
- Watch decorations move from their hiding places to the child and snowman.
- Compare Pinda’s mood and stamina with leash length, getting stuck, and calls for help.
- Match barks, digging, interactions, and the gate puzzle to a recording.

The [integration guide](docs/testing-floor.md) explains which parts to copy into your own game. The [demo’s Testing Floor game](https://testingfloor.com/orgs/example-studio/dogwalk) contains its maps and analytics.

## Connect your own game

Copy `.env.example` to `.env`, add a telemetry write key from your Testing Floor game, and run:

```sh
python3 tools/configure.py
```

Set `TESTING_FLOOR_ENABLE_IN_EDITOR=1` in `.env` to collect during editor play. The game runs normally without a key. Local settings are ignored by Git; release exports include the configured client write key so downloaded games can submit events.

## Credits

Original game: **(CC) Blender Foundation | [studio.blender.org/dogwalk](https://studio.blender.org/projects/dogwalk/)**. Get the original release at [Blender Studio on itch.io](https://blenderstudio.itch.io/dogwalk). This fork starts from the [public Godot source mirror](https://github.com/nikitalita/DOGWALK); the original Blender production files are not included.

See the original [license](LISCENCE.md). The Testing Floor addon and integration are MIT licensed; its QR encoder includes its own [MIT notice](addons/testing_floor/third_party/qr_code/LICENSE.md).
