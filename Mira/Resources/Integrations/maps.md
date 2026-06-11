# Maps
tool: run_python_skill
sources: OpenStreetMap · Nominatim · Overpass · OSRM (no API key)

## When to use
User says: where is, nearby, directions to, how far, distance between, navigate to, find a, closest, what's around, geocode, address lookup.

## Ops

### Geocode a place name → coordinates
`run_python_skill(skill:"maps", args:{op:"geocode", query:"<place>", limit?:3})`
Returns: `{success, results:[{lat, lon, display_name, type}]}`

### Reverse geocode coordinates → address
`run_python_skill(skill:"maps", args:{op:"reverse", lat:<n>, lon:<n>})`
Returns full address breakdown.

### Find nearby POIs
`run_python_skill(skill:"maps", args:{op:"nearby", near:"<place or address>", category:"<type>", radius_m?:800, limit?:10})`
Returns: `{places:[{name, dist_m, address, phone, opening_hours, website}]}`
Categories: restaurant, cafe, bar, pharmacy, hospital, bank, atm, gas, parking, hotel, supermarket, gym, park, library, bus, subway, train, cinema, museum, police, barber, spa, toilet (44 total).

### Directions / route
`run_python_skill(skill:"maps", args:{op:"route", origin:"<place>", destination:"<place>", mode?:"driving|walking|cycling"})`
Returns: `{distance_km, duration_min, steps:[...]}`

### Distance between two places
`run_python_skill(skill:"maps", args:{op:"distance", from:"<place>", to:"<place>", mode?:"driving"})`
Returns: `{distance_km, duration_min}`

### General search
`run_python_skill(skill:"maps", args:{op:"search", query:"<text>", near?:"<city>", limit?:5})`

## Canonical patterns

### "How far is <A> from <B>?"
op:"distance" → report km and driving time.

### "Find coffee shops near me / near <place>"
op:"nearby", category:"cafe", near:"<place>" → list top 5 with distance.

### "Directions from <A> to <B>"
op:"route" → show distance, time, step-by-step turns.

### "What's the address of <place>?"
op:"geocode" → show display_name of top result.

## Constraints
- Uses public OpenStreetMap data — some POI coverage may be incomplete in rural areas.
- OSRM routing is driving by default; walking/cycling available.
- All network calls time out at 10-15s. If a call fails, report the error message.
