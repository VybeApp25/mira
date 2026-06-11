#!/usr/bin/env python3
"""Polymarket read-only skill — no external deps (urllib only)."""
import json, sys, urllib.request, urllib.parse, urllib.error

GAMMA_API = "https://gamma-api.polymarket.com"

def fetch_json(url, timeout=10):
    try:
        req = urllib.request.Request(url, headers={"Accept": "application/json", "User-Agent": "Mira/1.0"})
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        return {"_http_error": e.code, "_msg": e.reason}
    except Exception as e:
        return {"_error": str(e)}

def format_price(p):
    try:
        val = float(p)
        return f"{val*100:.1f}%"
    except Exception:
        return str(p)

def run(args):
    op = args.get("op", "trending")

    # ── trending / active markets ─────────────────────────────────────────────
    if op in ("trending", "list"):
        limit  = int(args.get("limit", 10))
        params = {"limit": limit, "active": "true", "closed": "false", "order": "volume24hr", "ascending": "false"}
        url    = f"{GAMMA_API}/markets?{urllib.parse.urlencode(params)}"
        data   = fetch_json(url)
        if isinstance(data, dict) and "_error" in data:
            return {"success": False, "error": data["_error"]}
        markets = []
        for m in (data if isinstance(data, list) else []):
            outcomes = m.get("outcomes") or []
            prices   = m.get("outcomePrices") or []
            outcome_odds = []
            if isinstance(outcomes, str):
                try: outcomes = json.loads(outcomes)
                except: outcomes = []
            if isinstance(prices, str):
                try: prices = json.loads(prices)
                except: prices = []
            for o, p in zip(outcomes, prices):
                outcome_odds.append({"outcome": o, "probability": format_price(p)})
            markets.append({
                "question":    m.get("question", ""),
                "slug":        m.get("slug", ""),
                "outcomes":    outcome_odds,
                "volume_24h":  m.get("volume24hr", 0),
                "end_date":    m.get("endDate", ""),
                "url":         f"https://polymarket.com/event/{m.get('slug', '')}",
            })
        return {"success": True, "markets": markets, "total": len(markets)}

    # ── search ────────────────────────────────────────────────────────────────
    if op == "search":
        query  = args.get("query", "")
        limit  = int(args.get("limit", 5))
        params = {"limit": limit, "active": "true", "closed": "false", "q": query}
        url    = f"{GAMMA_API}/markets?{urllib.parse.urlencode(params)}"
        data   = fetch_json(url)
        if isinstance(data, dict) and "_error" in data:
            return {"success": False, "error": data["_error"]}
        markets = []
        for m in (data if isinstance(data, list) else []):
            outcomes = m.get("outcomes") or []
            prices   = m.get("outcomePrices") or []
            if isinstance(outcomes, str):
                try: outcomes = json.loads(outcomes)
                except: outcomes = []
            if isinstance(prices, str):
                try: prices = json.loads(prices)
                except: prices = []
            outcome_odds = [{"outcome": o, "probability": format_price(p)} for o, p in zip(outcomes, prices)]
            markets.append({
                "question": m.get("question", ""),
                "slug":     m.get("slug", ""),
                "outcomes": outcome_odds,
                "end_date": m.get("endDate", ""),
                "url":      f"https://polymarket.com/event/{m.get('slug', '')}",
            })
        return {"success": True, "query": query, "markets": markets, "total": len(markets)}

    # ── market detail by slug ─────────────────────────────────────────────────
    if op == "detail":
        slug = args.get("slug", "")
        url  = f"{GAMMA_API}/markets?slug={urllib.parse.quote(slug)}"
        data = fetch_json(url)
        if isinstance(data, dict) and "_error" in data:
            return {"success": False, "error": data["_error"]}
        items = data if isinstance(data, list) else []
        if not items:
            return {"success": False, "error": f"No market found with slug '{slug}'"}
        m = items[0]
        outcomes = m.get("outcomes") or []
        prices   = m.get("outcomePrices") or []
        if isinstance(outcomes, str):
            try: outcomes = json.loads(outcomes)
            except: outcomes = []
        if isinstance(prices, str):
            try: prices = json.loads(prices)
            except: prices = []
        outcome_odds = [{"outcome": o, "probability": format_price(p)} for o, p in zip(outcomes, prices)]
        return {
            "success":    True,
            "question":   m.get("question", ""),
            "description": m.get("description", ""),
            "outcomes":   outcome_odds,
            "volume":     m.get("volume", 0),
            "volume_24h": m.get("volume24hr", 0),
            "end_date":   m.get("endDate", ""),
            "url":        f"https://polymarket.com/event/{slug}",
        }

    return {"success": False, "error": f"Unknown op: {op}. Valid: trending, search, detail"}

if __name__ == "__main__":
    args = json.loads(sys.argv[1]) if len(sys.argv) > 1 else {}
    print(json.dumps(run(args)))
