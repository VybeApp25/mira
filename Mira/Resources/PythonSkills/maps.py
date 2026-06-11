#!/usr/bin/env python3
"""Maps skill — OpenStreetMap/Nominatim/Overpass/OSRM, no API key."""
import json, sys, urllib.request, urllib.parse, time

NOMINATIM = "https://nominatim.openstreetmap.org"
OVERPASS  = "https://overpass-api.de/api/interpreter"
OSRM      = "https://router.project-osrm.org"
HEADERS   = {"User-Agent": "Mira/1.0 (macOS)", "Accept": "application/json"}

def get(url, timeout=10):
    try:
        req = urllib.request.Request(url, headers=HEADERS)
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read().decode("utf-8"))
    except Exception as e:
        return {"_error": str(e)}

def post(url, data, timeout=15):
    try:
        enc = data.encode("utf-8")
        req = urllib.request.Request(url, data=enc, headers={**HEADERS, "Content-Type": "application/x-www-form-urlencoded"})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read().decode("utf-8"))
    except Exception as e:
        return {"_error": str(e)}

def geocode_place(query):
    """Return (lat, lon, display_name) for a place string, or None."""
    params = urllib.parse.urlencode({"q": query, "format": "json", "limit": 1})
    data = get(f"{NOMINATIM}/search?{params}")
    if isinstance(data, list) and data:
        r = data[0]
        return float(r["lat"]), float(r["lon"]), r.get("display_name", query)
    return None

# ── Overpass POI categories ────────────────────────────────────────────────────
CATEGORY_MAP = {
    "restaurant": 'amenity="restaurant"', "cafe": 'amenity="cafe"',
    "coffee": 'amenity="cafe"', "bar": 'amenity="bar"',
    "fast_food": 'amenity="fast_food"', "pub": 'amenity="pub"',
    "pharmacy": 'amenity="pharmacy"', "hospital": 'amenity="hospital"',
    "doctor": 'amenity="doctors"', "clinic": 'amenity="clinic"',
    "dentist": 'amenity="dentist"', "bank": 'amenity="bank"',
    "atm": 'amenity="atm"', "gas": 'amenity="fuel"', "fuel": 'amenity="fuel"',
    "parking": 'amenity="parking"', "hotel": 'tourism="hotel"',
    "hostel": 'tourism="hostel"', "supermarket": 'shop="supermarket"',
    "grocery": 'shop="grocery"', "convenience": 'shop="convenience"',
    "bakery": 'shop="bakery"', "gym": 'leisure="fitness_centre"',
    "park": 'leisure="park"', "library": 'amenity="library"',
    "school": 'amenity="school"', "university": 'amenity="university"',
    "bus": 'highway="bus_stop"', "subway": 'station="subway"',
    "train": 'railway="station"', "airport": 'aeroway="aerodrome"',
    "taxi": 'amenity="taxi"', "cinema": 'amenity="cinema"',
    "theatre": 'amenity="theatre"', "museum": 'tourism="museum"',
    "gallery": 'tourism="gallery"', "post": 'amenity="post_office"',
    "police": 'amenity="police"', "fire": 'amenity="fire_station"',
    "charging": 'amenity="charging_station"', "bike": 'amenity="bicycle_rental"',
    "laundry": 'shop="laundry"', "barber": 'shop="hairdresser"',
    "spa": 'leisure="spa"', "pool": 'leisure="swimming_pool"',
    "playground": 'leisure="playground"', "toilet": 'amenity="toilets"',
}

def run(args):
    op = args.get("op", "geocode")

    # ── geocode ────────────────────────────────────────────────────────────────
    if op == "geocode":
        query = args.get("query", "")
        params = urllib.parse.urlencode({"q": query, "format": "json", "addressdetails": 1, "limit": int(args.get("limit", 3))})
        data = get(f"{NOMINATIM}/search?{params}")
        if isinstance(data, dict) and "_error" in data:
            return {"success": False, "error": data["_error"]}
        results = []
        for r in (data if isinstance(data, list) else []):
            results.append({
                "lat": float(r["lat"]), "lon": float(r["lon"]),
                "display_name": r.get("display_name", ""),
                "type": r.get("type", ""), "importance": r.get("importance", 0),
            })
        if not results:
            return {"success": False, "error": f"No results for '{query}'"}
        return {"success": True, "query": query, "results": results}

    # ── reverse ────────────────────────────────────────────────────────────────
    if op == "reverse":
        lat, lon = args.get("lat"), args.get("lon")
        if lat is None or lon is None:
            return {"success": False, "error": "reverse requires lat and lon"}
        params = urllib.parse.urlencode({"lat": lat, "lon": lon, "format": "json", "addressdetails": 1})
        data = get(f"{NOMINATIM}/reverse?{params}")
        if isinstance(data, dict) and "_error" in data:
            return {"success": False, "error": data["_error"]}
        if "error" in data:
            return {"success": False, "error": data["error"]}
        addr = data.get("address", {})
        return {
            "success": True, "lat": float(lat), "lon": float(lon),
            "display_name": data.get("display_name", ""),
            "address": addr,
        }

    # ── nearby ─────────────────────────────────────────────────────────────────
    if op == "nearby":
        near = args.get("near", "")
        category = args.get("category", "restaurant").lower().replace(" ", "_")
        radius_m = int(args.get("radius_m", 800))
        limit = int(args.get("limit", 10))

        geo = geocode_place(near)
        if geo is None:
            return {"success": False, "error": f"Could not geocode '{near}'"}
        lat, lon, display = geo

        tag = CATEGORY_MAP.get(category)
        if tag is None:
            tag = f'name~"{category}",i'  # fuzzy name match fallback
        overpass_query = f"""[out:json][timeout:15];
(
  node[{tag}](around:{radius_m},{lat},{lon});
  way[{tag}](around:{radius_m},{lat},{lon});
);
out center {limit};"""
        data = post(OVERPASS, f"data={urllib.parse.quote(overpass_query)}")
        if isinstance(data, dict) and "_error" in data:
            return {"success": False, "error": data["_error"]}

        places = []
        for el in data.get("elements", [])[:limit]:
            tags = el.get("tags", {})
            clat = el.get("lat") or (el.get("center") or {}).get("lat")
            clon = el.get("lon") or (el.get("center") or {}).get("lon")
            if not clat: continue
            # crude distance
            dlat, dlon = float(clat) - lat, float(clon) - lon
            dist_m = int(((dlat*111000)**2 + (dlon*111000*0.85)**2)**0.5)
            places.append({
                "name":    tags.get("name", "Unnamed"),
                "lat": float(clat), "lon": float(clon),
                "dist_m":  dist_m,
                "address": " ".join(filter(None, [tags.get("addr:housenumber",""), tags.get("addr:street",""), tags.get("addr:city","")])),
                "website": tags.get("website", ""),
                "phone":   tags.get("phone", ""),
                "opening_hours": tags.get("opening_hours", ""),
            })
        places.sort(key=lambda x: x["dist_m"])
        return {
            "success": True, "center": display,
            "category": category, "radius_m": radius_m,
            "places": places, "total": len(places),
        }

    # ── route ──────────────────────────────────────────────────────────────────
    if op in ("route", "directions"):
        origin = args.get("origin", "")
        dest   = args.get("destination", args.get("dest", ""))
        mode   = args.get("mode", "driving")  # driving | walking | cycling
        osrm_profile = {"driving": "car", "walking": "foot", "cycling": "bike"}.get(mode, "car")

        geo_a = geocode_place(origin)
        geo_b = geocode_place(dest)
        if geo_a is None: return {"success": False, "error": f"Could not find '{origin}'"}
        if geo_b is None: return {"success": False, "error": f"Could not find '{dest}'"}

        lat_a, lon_a, name_a = geo_a
        lat_b, lon_b, name_b = geo_b
        url = f"{OSRM}/route/v1/{osrm_profile}/{lon_a},{lat_a};{lon_b},{lat_b}?overview=false&steps=true"
        data = get(url)
        if isinstance(data, dict) and "_error" in data:
            return {"success": False, "error": data["_error"]}
        if data.get("code") != "Ok":
            return {"success": False, "error": data.get("message", "Route not found")}

        route = data["routes"][0]
        dist_km = round(route["distance"] / 1000, 1)
        dur_min = int(route["duration"] / 60)
        steps = []
        for leg in route.get("legs", []):
            for step in leg.get("steps", []):
                instr = step.get("maneuver", {}).get("type", "")
                mod   = step.get("maneuver", {}).get("modifier", "")
                name  = step.get("name", "")
                d     = round(step.get("distance", 0) / 1000, 2)
                steps.append(f"{instr} {mod} onto {name} ({d} km)".strip())
        return {
            "success": True, "origin": name_a, "destination": name_b,
            "mode": mode, "distance_km": dist_km, "duration_min": dur_min,
            "steps": steps[:20],
        }

    # ── distance ───────────────────────────────────────────────────────────────
    if op == "distance":
        place_a = args.get("from", args.get("origin", ""))
        place_b = args.get("to", args.get("destination", ""))
        mode    = args.get("mode", "driving")
        osrm_profile = {"driving": "car", "walking": "foot", "cycling": "bike"}.get(mode, "car")

        geo_a = geocode_place(place_a)
        geo_b = geocode_place(place_b)
        if geo_a is None: return {"success": False, "error": f"Could not find '{place_a}'"}
        if geo_b is None: return {"success": False, "error": f"Could not find '{place_b}'"}

        lat_a, lon_a, name_a = geo_a
        lat_b, lon_b, name_b = geo_b
        url = f"{OSRM}/route/v1/{osrm_profile}/{lon_a},{lat_a};{lon_b},{lat_b}?overview=false"
        data = get(url)
        if isinstance(data, dict) and "_error" in data:
            # fallback to straight-line haversine
            import math
            r = 6371
            dlat = math.radians(lat_b - lat_a)
            dlon = math.radians(lon_b - lon_a)
            a = math.sin(dlat/2)**2 + math.cos(math.radians(lat_a)) * math.cos(math.radians(lat_b)) * math.sin(dlon/2)**2
            dist_km = round(r * 2 * math.atan2(math.sqrt(a), math.sqrt(1-a)), 1)
            return {"success": True, "from": name_a, "to": name_b, "distance_km": dist_km, "type": "straight_line"}
        if data.get("code") != "Ok":
            return {"success": False, "error": data.get("message", "Route not found")}
        route = data["routes"][0]
        return {
            "success": True, "from": name_a, "to": name_b, "mode": mode,
            "distance_km": round(route["distance"] / 1000, 1),
            "duration_min": int(route["duration"] / 60),
        }

    # ── search ──────────────────────────────────────────────────────────────────
    if op == "search":
        query  = args.get("query", "")
        near   = args.get("near", "")
        limit  = int(args.get("limit", 5))
        params = {"q": query, "format": "json", "addressdetails": 1, "limit": limit}
        if near:
            geo = geocode_place(near)
            if geo:
                params["viewbox"] = f"{geo[1]-0.3},{geo[0]+0.3},{geo[1]+0.3},{geo[0]-0.3}"
                params["bounded"] = 1
        url = f"{NOMINATIM}/search?{urllib.parse.urlencode(params)}"
        data = get(url)
        if isinstance(data, dict) and "_error" in data:
            return {"success": False, "error": data["_error"]}
        results = [{"name": r.get("display_name",""), "lat": float(r["lat"]), "lon": float(r["lon"]), "type": r.get("type","")} for r in (data or [])]
        return {"success": True, "query": query, "results": results}

    return {"success": False, "error": f"Unknown op: {op}. Valid: geocode, reverse, nearby, route, distance, search"}

if __name__ == "__main__":
    args = json.loads(sys.argv[1]) if len(sys.argv) > 1 else {}
    print(json.dumps(run(args)))
