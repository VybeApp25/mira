# Blender Integration

Automate Blender via WebSocket-based real-time control. Create geometry, manage materials, apply modifiers, and retarget Mixamo animations to custom rigs.

## Prerequisites

1. Blender 4.0+ installed (blender.org)
2. Blender Toolkit WebSocket addon installed and enabled
3. WebSocket server started: View3D → Sidebar (N key) → "Blender Toolkit" → "Start Server" (default port 9400)

Check addon status:
```
~/.claude/plugins/marketplaces/dev-gom-plugins/blender-config.json
```

If Blender is not detected (`blenderExecutable: null`) or the addon is not installed, guide the user through setup before attempting any operation.

## Core Operations

### Geometry Creation
```bash
blender-toolkit create-cube --size 2.0
blender-toolkit create-sphere --radius 1.5 --segments 64
blender-toolkit create-cylinder --radius 1.0 --depth 2.0
blender-toolkit list-objects
blender-toolkit transform --name "Cube" --loc-x 5 --scale-x 2
blender-toolkit duplicate --name "Cube" --new-name "Cube.001" --x 3
```

### Materials
```bash
blender-toolkit material create --name "MetalRed"
blender-toolkit material assign --object "Sphere" --material "MetalRed"
blender-toolkit material set-color --material "MetalRed" --r 0.8 --g 0.1 --b 0.1
blender-toolkit material set-metallic --material "MetalRed" --value 1.0
blender-toolkit material set-roughness --material "MetalRed" --value 0.2
```

### Modifiers
```bash
blender-toolkit modifier add --object "Cube" --type SUBDIVISION --levels 2
blender-toolkit modifier add --object "Cube" --type MIRROR --axis X
blender-toolkit modifier apply --object "Cube" --modifier "Subdivision"
```

### Animation Retargeting (Mixamo → Custom Rig)

**Two-phase workflow:**

Phase 1 — Generate bone mapping and show in Blender UI for review:
```bash
blender-toolkit retarget \
  --target "HeroRig" \
  --file "./Walking.fbx" \
  --name "Walking"
```
The system auto-generates a fuzzy bone mapping. User reviews in Blender: View3D → Sidebar → "Blender Toolkit" → "Bone Mapping Review" → clicks "Apply Retargeting".

Phase 2 — Skip UI review for known-good mappings:
```bash
blender-toolkit retarget \
  --target "RigifyCharacter" \
  --file "./Walking.fbx" \
  --mapping mixamo_to_rigify \
  --skip-confirmation
```

Quality assessment guide:
- Excellent (8-9 critical bones) → safe to skip confirmation
- Good (6-7) → quick review recommended
- Fair (4-5) → thorough review required
- Poor (< 4) → use custom mapping

## Mixamo Downloads

Mixamo has no API — users must download manually:
- Format: FBX (.fbx), Skin: Without Skin, 30 fps, Keyframe Reduction: None
- Guide user to mixamo.com, then wait for the FBX file path before proceeding

## Key Rules

- Always verify Blender WebSocket server is running before any command
- For unknown rigs, always use the two-phase confirmation workflow
- Multiple Blender projects: each gets its own port (9400–9500), auto-managed
- Do not guess armature names — use `list-objects --type ARMATURE` to enumerate
- `shell open` is allowed only to show a finished file to the user; never to navigate or automate Blender itself

## Troubleshooting

| Problem | Fix |
|---------|-----|
| "Blender is not running" | Verify Blender is open, addon enabled, server started |
| "Target armature not found" | List armatures: `blender-toolkit list-objects --type ARMATURE` |
| "Poor quality" mapping | Review bone names in Edit Mode; lower similarity threshold or use custom mapping |
| "Twisted/inverted limbs" | Check left/right mapping and bone roll in Edit Mode |
