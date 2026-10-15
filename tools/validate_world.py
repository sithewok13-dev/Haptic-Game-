#!/usr/bin/env python3
"""Independent check of a world file (no Swift needed).

Mirrors the wall derivation in Sources/CellarCore/World.swift, then flood-fills
the space a player of `playerRadius` can occupy to prove the exit is reachable
from the start and every room is walkable. Optionally writes an SVG plan.

Usage: python3 tools/validate_world.py Content/basement.json [--svg plan.svg]
"""
import json
import math
import sys
from collections import deque


def edges(r):
    x0, y0, x1, y1 = r["x0"], r["y0"], r["x1"], r["y1"]
    return [((x0, y0), (x1, y0)), ((x1, y0), (x1, y1)), ((x1, y1), (x0, y1)), ((x0, y1), (x0, y0))]


def subtract(edge, openings):
    (ax, ay), (bx, by) = edge
    L = math.hypot(bx - ax, by - ay)
    ux, uy = (bx - ax) / L, (by - ay) / L
    gaps = []
    for (oa, ob) in openings:
        da = abs((oa[0] - ax) * uy - (oa[1] - ay) * ux)
        db = abs((ob[0] - ax) * uy - (ob[1] - ay) * ux)
        if da > 1e-6 or db > 1e-6:
            continue
        ta = (oa[0] - ax) * ux + (oa[1] - ay) * uy
        tb = (ob[0] - ax) * ux + (ob[1] - ay) * uy
        lo, hi = max(0, min(ta, tb)), min(L, max(ta, tb))
        if hi - lo > 1e-6:
            gaps.append((lo, hi))
    gaps.sort()
    pieces, cur = [], 0.0
    for lo, hi in gaps:
        if lo - cur > 1e-6:
            pieces.append(((ax + ux * cur, ay + uy * cur), (ax + ux * lo, ay + uy * lo)))
        cur = max(cur, hi)
    if L - cur > 1e-6:
        pieces.append(((ax + ux * cur, ay + uy * cur), (bx, by)))
    return pieces


def seg_dist(p, a, b):
    dx, dy = b[0] - a[0], b[1] - a[1]
    l2 = dx * dx + dy * dy
    t = 0 if l2 == 0 else max(0, min(1, ((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / l2))
    return math.hypot(p[0] - a[0] - dx * t, p[1] - a[1] - dy * t)


def inside(r, p, inset=0.0):
    return r["x0"] + inset <= p[0] <= r["x1"] - inset and r["y0"] + inset <= p[1] <= r["y1"] - inset


def main():
    path = sys.argv[1]
    w = json.load(open(path))
    rooms = {r["id"]: r for r in w["rooms"]}
    R = w["playerRadius"]
    issues = []

    ids = list(rooms)
    for i, a in enumerate(ids):
        for b in ids[i + 1:]:
            ra, rb = rooms[a]["rect"], rooms[b]["rect"]
            ow = min(ra["x1"], rb["x1"]) - max(ra["x0"], rb["x0"])
            oh = min(ra["y1"], rb["y1"]) - max(ra["y0"], rb["y0"])
            if ow > 1e-9 and oh > 1e-9:
                issues.append(f"rooms {a} and {b} overlap")

    walls = []
    for rid, r in rooms.items():
        ops = [(tuple(d["a"]), tuple(d["b"])) for d in w["doorways"] if rid in d["rooms"]]
        for e in edges(r["rect"]):
            walls += subtract(e, ops)

    for d in w["doorways"]:
        width = math.dist(d["a"], d["b"])
        if width < 2 * R + 0.3:
            issues.append(f"doorway {d['id']} too narrow")
        for rid in d["rooms"]:
            if not any(seg_dist(d["a"], *e) < 1e-6 and seg_dist(d["b"], *e) < 1e-6 for e in edges(rooms[rid]["rect"])):
                issues.append(f"doorway {d['id']} not on an edge of {rid}")

    # Flood fill on a 5 cm grid of positions the player's centre may occupy.
    step = 0.05
    xs = [r["rect"]["x0"] for r in rooms.values()] + [r["rect"]["x1"] for r in rooms.values()]
    ys = [r["rect"]["y0"] for r in rooms.values()] + [r["rect"]["y1"] for r in rooms.values()]
    x0, y0 = min(xs), min(ys)
    nx, ny = int((max(xs) - x0) / step) + 1, int((max(ys) - y0) / step) + 1

    def free(i, j):
        p = (x0 + i * step, y0 + j * step)
        if not any(inside(r["rect"], p) for r in rooms.values()):
            return False
        return all(seg_dist(p, a, b) >= R for a, b in walls)

    sx, sy = w["start"]["position"]
    start = (round((sx - x0) / step), round((sy - y0) / step))
    if not free(*start):
        issues.append("start position is not free")
    seen = {start}
    q = deque([start])
    while q:
        i, j = q.popleft()
        for di, dj in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            n = (i + di, j + dj)
            if n in seen or not (0 <= n[0] < nx and 0 <= n[1] < ny):
                continue
            if free(*n):
                seen.add(n)
                q.append(n)

    reached = {rid: 0 for rid in rooms}
    exit_hit = False
    for (i, j) in seen:
        p = (x0 + i * step, y0 + j * step)
        for rid, r in rooms.items():
            if inside(r["rect"], p, 0.01):
                reached[rid] += 1
        if inside(w["exit"]["rect"], p):
            exit_hit = True
    for rid, n in reached.items():
        if n == 0:
            issues.append(f"room {rid} is not reachable on foot")
    if not exit_hit:
        issues.append("exit is not reachable on foot")

    for s in w["sources"]:
        if not any(inside(r["rect"], s["position"], 0.01) for r in rooms.values()):
            issues.append(f"source {s['id']} outside every room")

    print(f"{len(rooms)} rooms, {len(w['doorways'])} openings, {len(walls)} wall segments, {len(w['sources'])} sound sources")
    print(f"walkable cells reached: {len(seen)}; per room: {reached}")
    print(f"exit reachable: {exit_hit}")

    if "--svg" in sys.argv:
        out = sys.argv[sys.argv.index("--svg") + 1]
        S = 30
        X = lambda x: (x - x0 + 1) * S
        Y = lambda y: (max(ys) - y + 1) * S
        parts = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{(max(xs)-x0+2)*S}" height="{(max(ys)-y0+2)*S}" style="background:#111">']
        for rid, r in rooms.items():
            rr = r["rect"]
            parts.append(f'<rect x="{X(rr["x0"])}" y="{Y(rr["y1"])}" width="{(rr["x1"]-rr["x0"])*S}" height="{(rr["y1"]-rr["y0"])*S}" fill="#222"/>')
            parts.append(f'<text x="{X(rr["x0"])+4}" y="{Y(rr["y1"])+14}" fill="#888" font-size="11">{rid}</text>')
        for a, b in walls:
            parts.append(f'<line x1="{X(a[0])}" y1="{Y(a[1])}" x2="{X(b[0])}" y2="{Y(b[1])}" stroke="#ddd" stroke-width="2"/>')
        for d in w["doorways"]:
            parts.append(f'<line x1="{X(d["a"][0])}" y1="{Y(d["a"][1])}" x2="{X(d["b"][0])}" y2="{Y(d["b"][1])}" stroke="#4c4" stroke-width="3"/>')
        for s in w["sources"]:
            parts.append(f'<circle cx="{X(s["position"][0])}" cy="{Y(s["position"][1])}" r="5" fill="#fa0"/><text x="{X(s["position"][0])+7}" y="{Y(s["position"][1])+4}" fill="#fa0" font-size="11">{s["id"]}</text>')
        parts.append(f'<circle cx="{X(sx)}" cy="{Y(sy)}" r="6" fill="#4af"/>')
        e = w["exit"]["rect"]
        parts.append(f'<rect x="{X(e["x0"])}" y="{Y(e["y1"])}" width="{(e["x1"]-e["x0"])*S}" height="{(e["y1"]-e["y0"])*S}" fill="none" stroke="#f4f" stroke-dasharray="4"/>')
        parts.append("</svg>")
        open(out, "w").write("\n".join(parts))
        print(f"wrote {out}")

    if issues:
        print("ISSUES:\n  " + "\n  ".join(issues))
        sys.exit(1)
    print("OK")


if __name__ == "__main__":
    main()
