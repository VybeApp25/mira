# Find My
tools: run_python_skill (device list), open_application (launch FindMy), get_current_context (screenshot)

## When to use
User says: Find My, where is my iPhone, where is my watch, where is my AirPods, find my device,
find my Mac, FindMy, where are my devices, track my phone.

## Listing devices
`run_python_skill(skill:"findmy_devices", args:{})`
Returns: `{success, devices:[{name, owner_first, owner_last}], total, note}`

Present as a list: "Trevon's iPhone (Trevon Barbour)", "Trevon's Apple Watch (Trevon Barbour)", etc.

## Location data — Apple restriction
Real-time device locations are stored in an encrypted database requiring Apple's private
`com.apple.private.find-my.framework.permission` entitlement. Mira cannot read those directly.

### Option A — Open FindMy.app
`open_application(app_name:"FindMy")`
Tell the user: "I've opened FindMy — you can see your device locations there."

### Option B — Screenshot
If the user has FindMy open:
1. Ask the user to focus the FindMy window.
2. Call `get_current_context()` to take a screenshot and describe what you see.
3. Report device locations from the map as described.

## Canonical patterns

### "List my Apple devices"
`run_python_skill` skill:"findmy_devices" → present device list.

### "Where is my iPhone?"
1. `run_python_skill` skill:"findmy_devices" → confirm the device exists.
2. Open FindMy.app OR screenshot whichever is more useful.

### "Where is Skylar's iPhone?"
Same flow — note it shows in the device list as "iPhone (Skylar Wilkes)".

## Constraints
- Never claim to show exact coordinates — only report what is visible in a screenshot.
- If the Biome DB is missing, tell the user FindMy has not been used on this Mac yet.
