#!/usr/bin/env python3
"""solid-glb: build a GLB of a simple solid object from a few photos and a JSON config.

Templates
  slab  stacked layers on a base: each layer has its own outline (or the shared one), height and wall profile
        (straight, tapered or dome-like); the top photo (straight down or oblique) is mapped through a pinhole
        camera model onto top faces and camera-facing walls; round features (buttons, knobs, screws), flat
        cut-outs standing upright (cards, textured from their own photo) and small marks on the side walls.
        The base is a rectangle given by 4 corners, or a round base (paper plate) given by points on its rim.

Commands
  grid   PHOTO OUT.jpg [x0 y0 x1 y1] [height]   photo with a labelled grid, to read positions as fractions
  build  CONFIG.json --out DIR                   model.glb, report.json, photo_overlay.jpg, top_rectified.jpg, top_overlay.jpg
  check  DIR                                     validate, render the config's views, compare.jpg

Positions in a config are fractions of the photo (x right, y down) unless a key ends with _mm.
Output: metres, +Y up, base at y = 0, front +Z.
"""
import json, math, struct, subprocess, sys
from pathlib import Path

import cv2
import numpy as np

HERE = Path(__file__).resolve().parent
unit = lambda v: v / np.maximum(np.linalg.norm(v, axis=-1, keepdims=True), 1e-12)


# ------------------------------------------------------------------ photo geometry
def quad_aspect(c, w, h):
    """Real width/depth ratio of a rectangle seen as quad c (back-left, back-right, front-right, front-left)."""
    m = np.c_[np.asarray(c, float) - [w / 2, h / 2], np.ones(4)]
    m1, m2, m4, m3 = m                                      # (0,0) (W,0) (W,D) (0,D)
    flat = (np.linalg.norm(m2 - m1) + np.linalg.norm(m4 - m3)) / (np.linalg.norm(m3 - m1) + np.linalg.norm(m4 - m2))
    k2 = np.dot(np.cross(m1, m4), m3) / np.dot(np.cross(m2, m4), m3)
    k3 = np.dot(np.cross(m1, m4), m2) / np.dot(np.cross(m3, m4), m2)
    n2, n3 = k2 * m2 - m1, k3 * m3 - m1
    if abs(n2[2] * n3[2]) < 1e-9:
        return flat, None
    f2 = -(n2[0] * n3[0] + n2[1] * n3[1]) / (n2[2] * n3[2])
    if not (0.3 * max(w, h)) ** 2 < f2 < (5 * max(w, h)) ** 2:      # implausible focal length: fall back
        return flat, None
    q = lambda n: (n[0] ** 2 + n[1] ** 2) / f2 + n[2] ** 2
    return math.sqrt(q(n2) / q(n3)), math.sqrt(f2)


def levenberg(fun, p, iters=200):
    """Minimise |fun(p)|^2 (Levenberg-Marquardt, numeric Jacobian)."""
    p = np.asarray(p, float); r = fun(p); cost = r @ r; lam = 1e-3
    for _ in range(iters):
        J = np.empty((len(r), len(p)))
        for k in range(len(p)):
            e = 1e-6 * max(1.0, abs(p[k])); dp = p.copy(); dp[k] += e; J[:, k] = (fun(dp) - r) / e
        A, g = J.T @ J, J.T @ r
        while True:
            step = np.linalg.solve(A + lam * np.diag(np.diag(A) + 1e-12), -g)
            rn = fun(p + step); cn = rn @ rn
            if np.isfinite(cn) and cn < cost:
                p, r, cost, lam = p + step, rn, cn, max(lam / 3, 1e-10); break
            lam *= 4
            if lam > 1e10: return p
        if np.linalg.norm(step) < 1e-10 * (1 + np.linalg.norm(p)): break
    return p


def circle_pose(rim, front, R, f, w, h):
    """Pose of a circle of radius R (mm) on a plane from >= 5 rim pixels; returns the square's corner pixels and a report."""
    K = np.array([[f, 0, w / 2], [0, f, h / 2], [0, 0, 1.0]]); Ki = np.linalg.inv(K)
    rays = np.c_[rim, np.ones(len(rim))] @ Ki.T
    def unpack(p):
        return p[2] * unit(Ki @ [p[0], p[1], 1.0]), unit(np.array([p[3], p[4], -1.0]))
    def res(p):
        C, n = unpack(p); d = rays @ n
        d = np.where(np.abs(d) < 1e-9, 1e-9, d)
        return np.linalg.norm(rays * ((n @ C) / d)[:, None] - C, axis=1) - R
    (ex, ey), axes, ang = cv2.fitEllipse(np.asarray(rim, np.float32))
    a = math.radians(ang); d1, d2 = np.array([math.cos(a), math.sin(a)]), np.array([-math.sin(a), math.cos(a)])
    major, minor, mdir = (axes[0], axes[1], d2) if axes[0] >= axes[1] else (axes[1], axes[0], d1)
    tilt = math.tan(math.acos(min(1.0, minor / max(major, 1e-9))))
    sols = []
    for sg in (1, -1):
        p = levenberg(res, [ex, ey, f * R / (major / 2), sg * tilt * mdir[0], sg * tilt * mdir[1]])
        C, n = unpack(p)
        if n @ C > 0: n = -n
        e = K @ (C + 10 * n); c = K @ C
        sols.append({'rms': float(np.sqrt(np.mean(res(p) ** 2))), 'C': C, 'n': n, 'up': e[1] / e[2] < c[1] / c[2]})
    sols.sort(key=lambda s: s['rms'])
    best = sols[0]
    if not best['up'] and sols[1]['up'] and not best['rms'] < 0.7 * sols[1]['rms']:
        best = sols[1]
    C, n = best['C'], best['n']
    rf = Ki @ [front[0], front[1], 1.0]; F = rf * (n @ C) / (rf @ n)
    z = F - C; z = unit(z - n * (n @ z)); x = np.cross(n, z)
    X = np.array([C - R * x - R * z, C + R * x - R * z, C + R * x + R * z, C - R * x + R * z]) @ K.T
    corners = X[:, :2] / X[:, 2:]
    rep = {'rms_mm': round(best['rms'], 2), 'elevation_deg': round(math.degrees(math.asin(-n @ C / np.linalg.norm(C))), 1),
           'distance_mm': round(float(np.linalg.norm(C)), 1), 'corners': np.round(corners / [w, h], 4).tolist()}
    return corners, rep


class Top:
    """The top photo and a pinhole camera model of it. Canonical mm: x_c to the right, z_c towards the front, on the
    reference plane (the top of the `plane` layer, y = y_ref). World: x = x_c - W/2, z = z_c - D/2."""

    def __init__(self, cfg, base):
        self.im = cv2.imread(str(base / cfg['photo']))
        if self.im is None:
            raise SystemExit(f"cannot read {cfg['photo']}")
        h, w = self.im.shape[:2]; fpx = cfg.get('focal_px')
        self.W = float(cfg['width_mm']); self.circle_fit = None
        if cfg.get('circle'):
            self.focal, self.focal_source = (float(fpx), 'config') if fpx else (0.75 * max(w, h), 'assumed')
            ci = cfg['circle']
            if len(ci['rim']) < 5: raise SystemExit('top.circle.rim needs at least 5 points')
            self.c, self.circle_fit = circle_pose(np.array(ci['rim'], float) * [w, h], np.array(ci['front'], float) * [w, h],
                                                  self.W / 2, self.focal, w, h)
            self.D, self.depth_assumed = self.W, False
        else:
            self.c = np.array(cfg['corners'], float) * [w, h]
            ratio, foc = quad_aspect(self.c, w, h)
            self.D = float(cfg.get('depth_mm') or self.W / ratio)
            self.depth_assumed = 'depth_mm' not in cfg
            self.focal, self.focal_source = ((float(fpx), 'config') if fpx else (foc, 'photo') if foc is not None
                                             else (0.75 * max(w, h), 'assumed'))
        dst = np.array([[0, 0], [self.W, 0], [self.W, self.D], [0, self.D]], np.float32)
        self.H = cv2.getPerspectiveTransform(self.c.astype(np.float32), dst)
        f = self.focal; self.K = np.array([[f, 0, w / 2], [0, f, h / 2], [0, 0, 1.0]])
        M = np.linalg.inv(self.K) @ np.linalg.inv(self.H)
        s = 2 / (np.linalg.norm(M[:, 0]) + np.linalg.norm(M[:, 1]))
        if M[2, 2] * s < 0: s = -s
        self.s, self.r1, self.r2, self.t = s, s * M[:, 0], s * M[:, 1], s * M[:, 2]
        self.up = unit(np.cross(self.r2, self.r1))                    # world +Y in camera coordinates
        self.mirrored = bool(-self.t @ self.up <= 0)
        if self.mirrored:
            print('warning: the corners seem to be in mirrored order (back-left, back-right, front-right, front-left '
                  'as seen from the front); heights will be mapped the wrong way', file=sys.stderr)
        self.q = self.H @ self.K @ self.up
        self.cam_c = np.linalg.solve(np.c_[self.r1, self.r2, self.up], -self.t)   # camera (x_c, z_c, h)
        self.y_ref = 0.0

    def mm_at(self, frac, h):
        """Photo points (fractions) lying at height h (mm) above the reference plane -> canonical mm."""
        hh, ww = self.im.shape[:2]
        p = np.c_[np.asarray(frac, float).reshape(-1, 2) * [ww, hh], np.ones(len(np.asarray(frac).reshape(-1, 2)))] @ self.H.T
        h = np.broadcast_to(np.asarray(h, float), (len(p),)); lam = (self.s + h * self.q[2]) / p[:, 2]
        return np.stack([(lam * p[:, 0] - h * self.q[0]) / self.s, (lam * p[:, 1] - h * self.q[1]) / self.s], 1)

    def mm(self, frac):
        return self.mm_at(frac, 0.0)

    def _canon(self, P):
        P = np.asarray(P, float).reshape(-1, 3)
        return P[:, 0] + self.W / 2, P[:, 2] + self.D / 2, P[:, 1] - self.y_ref

    def apparent(self, P):
        """World points (mm) -> where they appear in the rectified top photo (canonical mm)."""
        xc, zc, h = self._canon(P)
        a = self.s * np.stack([xc, zc, np.ones_like(xc)], 1) + h[:, None] * self.q
        a2 = np.where(np.abs(a[:, 2]) < 1e-9, 1e-9, a[:, 2])
        return a[:, :2] / a2[:, None]

    def project(self, P):
        """World points (mm) -> photo pixels."""
        xc, zc, h = self._canon(P)
        X = (xc[:, None] * self.r1 + zc[:, None] * self.r2 + self.t + h[:, None] * self.up) @ self.K.T
        return X[:, :2] / np.where(np.abs(X[:, 2:]) < 1e-9, 1e-9, X[:, 2:])

    def camera_world(self):
        x, z, h = self.cam_c
        return np.array([x - self.W / 2, self.y_ref + h, z - self.D / 2])

    def camera_report(self):
        x, z, h = self.cam_c
        return {'elevation_deg': round(math.degrees(math.atan2(h, math.hypot(x - self.W / 2, z - self.D / 2))), 1),
                'distance_mm': round(float(np.linalg.norm([x - self.W / 2, z - self.D / 2, h])), 1),
                'position_mm': np.round(self.camera_world(), 1).tolist()}

    def rectified(self, ppm, bounds):
        x0, z0, x1, z1 = bounds
        S = np.array([[ppm, 0, -x0 * ppm], [0, ppm, -z0 * ppm], [0, 0, 1]])
        size = (int(round((x1 - x0) * ppm)), int(round((z1 - z0) * ppm)))
        return cv2.warpPerspective(self.im, S @ self.H, size, flags=cv2.INTER_AREA, borderMode=cv2.BORDER_REPLICATE)


# ------------------------------------------------------------------ polygons
RPPM = 8.0   # raster used for rounding / insetting outlines (pixels per mm)


def poly_mask(poly, pad=20.0):
    lo = poly.min(0) - pad
    size = np.ceil((poly.max(0) + pad - lo) * RPPM).astype(int)
    m = np.zeros((size[1], size[0]), np.uint8)
    cv2.fillPoly(m, [np.round((poly - lo) * RPPM).astype(np.int32)], 1)
    return m, lo


def mask_poly(m, lo, eps=0.12):
    cnt = max(cv2.findContours(m, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_NONE)[0], key=cv2.contourArea)
    p = cv2.approxPolyDP(cnt, eps * RPPM, True).reshape(-1, 2).astype(float) / RPPM + lo
    return ccw(p)


def area2(p):
    return np.sum(p[:, 0] * np.roll(p[:, 1], -1) - np.roll(p[:, 0], -1) * p[:, 1])


def ccw(p):
    return p if area2(p) > 0 else p[::-1].copy()


def disk(r_mm):
    k = max(1, int(round(r_mm * RPPM)))
    return cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (2 * k + 1, 2 * k + 1))


def shape_outline(poly, round_mm=0.0, inset_mm=0.0):
    """Round the corners of a polygon and/or move it inwards (negative inset = outwards)."""
    m, lo = poly_mask(np.asarray(poly, float), pad=20.0 + max(0.0, -inset_mm))
    if round_mm > 0:
        m = cv2.morphologyEx(cv2.morphologyEx(m, cv2.MORPH_OPEN, disk(round_mm)), cv2.MORPH_CLOSE, disk(round_mm))
    if abs(inset_mm) > 10:                                  # large offsets: distance transform (a big kernel is slow)
        inside = inset_mm > 0
        dt = cv2.distanceTransform(m if inside else 1 - m, cv2.DIST_L2, cv2.DIST_MASK_PRECISE) / RPPM
        m = ((dt > inset_mm) if inside else (m > 0) | (dt <= -inset_mm)).astype(np.uint8)
    elif inset_mm > 0:
        m = cv2.erode(m, disk(inset_mm))
    elif inset_mm < 0:
        m = cv2.dilate(m, disk(-inset_mm))
    return mask_poly(m, lo)


def offset_rings(poly, offsets, step=3.0):
    """Resample a polygon (~every `step` mm, keeping its corners) and move the same points along smoothed outward
    normals by each offset (mm, + = outwards). Returns one ring per offset; the rings correspond point by point.
    The normals are smoothed over ~0.8 x the largest offset along the outline, and each moved point is then put on
    the exact offset outline (nearest point), so the rings keep their distance and do not fold at convex corners."""
    p = ccw(np.asarray(poly, float)); pts = []
    for a, b in zip(p, np.roll(p, -1, 0)):
        k = max(1, int(np.ceil(np.linalg.norm(b - a) / step)))
        pts.append(a + (b - a) * (np.arange(k) / k)[:, None])
    pts = np.concatenate(pts)
    e = np.roll(pts, -1, 0) - pts; en = unit(np.stack([e[:, 1], -e[:, 0]], 1))
    nv = unit(en + np.roll(en, 1, 0))
    gap = np.linalg.norm(e, axis=1).mean(); sigma = min(0.8 * max(abs(d) for d in offsets), len(pts) * gap / 6)
    for _ in range(max(3, int(2 * (sigma / gap) ** 2))):       # [1,2,1]/4 passes: variance 0.5 sample^2 each
        nv = unit(np.roll(nv, 1, 0) + 2 * nv + np.roll(nv, -1, 0))
    return [pts if abs(d) < 1e-9 else nearest_on(pts + nv * d, shape_outline(p, inset_mm=-d)) for d in offsets]


def nearest_on(x, poly):
    """Nearest points on a closed polygon."""
    a = poly[None]; ab = np.roll(poly, -1, 0)[None] - a
    t = np.clip(np.sum((x[:, None] - a) * ab, -1) / np.maximum(np.sum(ab * ab, -1), 1e-12), 0, 1)
    c = a + t[..., None] * ab; k = np.argmin(np.sum((c - x[:, None]) ** 2, -1), 1)
    return c[np.arange(len(x)), k]


def triangulate(poly):
    import mapbox_earcut as earcut
    t = earcut.triangulate_float32(poly.astype(np.float32), np.array([len(poly)], np.uint32)).reshape(-1, 3)
    return t.astype(np.uint32)


# ------------------------------------------------------------------ meshes (mm; x right, y up, z front)
def face_up(pos, tri, want):
    n = np.cross(pos[tri[:, 1]] - pos[tri[:, 0]], pos[tri[:, 2]] - pos[tri[:, 0]])
    flip = n @ np.asarray(want, float) < 0
    tri = tri.copy(); tri[flip] = tri[flip][:, ::-1]
    return tri


def prism(poly, y0, y1, uv_of=None, top_poly=None):
    """Extrude a polygon given in (x, z). Returns {'top','bottom','side'}: (pos, nrm, tri, uv or None).
    uv_of maps 3D positions to UVs (top face only). With top_poly (same point count, corresponding points)
    the walls slope from poly at y0 to top_poly at y1."""
    if top_poly is not None:
        return loft([poly, top_poly], [y0, y1], uv_of)
    poly = ccw(np.asarray(poly, float)); n = len(poly); tri = triangulate(poly)
    cap = lambda y: np.c_[poly[:, 0], np.full(n, y), poly[:, 1]]
    top, bot = cap(y1), cap(y0)
    out = {'top': (top, np.tile([0, 1.0, 0], (n, 1)), face_up(top, tri, (0, 1, 0)), uv_of(top) if uv_of else None),
           'bottom': (bot, np.tile([0, -1.0, 0], (n, 1)), face_up(bot, tri, (0, -1, 0)), None)}
    q = np.roll(poly, -1, 0); e = q - poly
    en = np.stack([e[:, 1], -e[:, 0]], 1); en /= np.maximum(np.linalg.norm(en, axis=1, keepdims=True), 1e-9)
    prev, nxt = np.roll(en, 1, 0), np.roll(en, -1, 0)
    smooth = lambda a, b: np.where((np.sum(a * b, 1) > 0.7)[:, None], (a + b) / np.maximum(np.linalg.norm(a + b, axis=1, keepdims=True), 1e-9), a)
    ns, ne = smooth(en, prev), smooth(en, nxt)                      # normals at the start / end of each edge
    v3 = lambda p, y: np.c_[p[:, 0], np.full(n, y), p[:, 1]]
    n3 = lambda a: np.c_[a[:, 0], np.zeros(n), a[:, 1]]
    pos = np.concatenate([v3(poly, y0), v3(q, y0), v3(q, y1), v3(poly, y1)])
    nrm = np.concatenate([n3(ns), n3(ne), n3(ne), n3(ns)])
    i = np.arange(n, dtype=np.uint32)
    st = np.concatenate([np.stack([i, i + n, i + 2 * n], 1), np.stack([i, i + 2 * n, i + 3 * n], 1)])
    out['side'] = (pos, nrm, fix_winding(pos, nrm, st), None)
    return out


def loft(rings, ys, uv_of=None):
    """Walls through corresponding rings (each (n, 2) in (x, z)) at increasing heights ys; caps from the first and last ring.
    Wall normals are the real face normals, smoothed with neighbours (along the outline and across rings) within ~45 deg."""
    Rg = np.asarray(rings, float)
    if area2(Rg[0]) < 0: Rg = Rg[:, ::-1].copy()
    K, n = Rg.shape[:2]; B = K - 1
    P = np.stack([np.c_[Rg[k][:, 0], np.full(n, float(ys[k])), Rg[k][:, 1]] for k in range(K)])
    top, bot = P[-1], P[0]
    out = {'top': (top, np.tile([0, 1.0, 0], (n, 1)), face_up(top, triangulate(Rg[-1]), (0, 1, 0)), uv_of(top) if uv_of else None),
           'bottom': (bot, np.tile([0, -1.0, 0], (n, 1)), face_up(bot, triangulate(Rg[0]), (0, -1, 0)), None)}
    Q = np.roll(P, -1, 1)
    fn = np.cross((P[1:] + Q[1:] - P[:-1] - Q[:-1]) / 2, Q[:-1] - P[:-1])            # (B, n, 3), outwards
    bad = np.linalg.norm(fn, axis=-1) < 1e-9
    for _ in range(n):                                              # collapsed faces (several points on one corner): borrow a neighbour's normal
        if not bad.any(): break
        nb = np.roll(fn, 1, 1) + np.roll(fn, -1, 1); fn[bad] = nb[bad]; bad = np.linalg.norm(fn, axis=-1) < 1e-9
    fn = unit(fn); fp = np.zeros((B + 2, n, 3)); fp[1:-1] = fn
    bi, ii = np.arange(B)[:, None], np.arange(n)[None, :]
    pos, nrm = [], []
    for dr, dj in ((0, 0), (0, 1), (1, 1), (1, 0)):                 # quad corners, in the order of prism()
        s = np.zeros((B, n, 3))
        for db in (-1, 0):
            for de in (-1, 0):
                c = fp[bi + dr + db + 1, (ii + dj + de) % n]
                s += c * (np.sum(c * fn, -1) > 0.7)[..., None]
        pos.append(P[bi + dr, (ii + dj) % n].reshape(-1, 3)); nrm.append(unit(s).reshape(-1, 3))
    pos, nrm = np.concatenate(pos), np.concatenate(nrm)
    i = np.arange(B * n, dtype=np.uint32); m = B * n
    st = np.concatenate([np.stack([i, i + m, i + 2 * m], 1), np.stack([i, i + 2 * m, i + 3 * m], 1)])
    out['side'] = (pos, nrm, fix_winding(pos, nrm, st), None)
    return out


def fix_winding(pos, nrm, tri):
    fn = np.cross(pos[tri[:, 1]] - pos[tri[:, 0]], pos[tri[:, 2]] - pos[tri[:, 0]])
    flip = np.sum(fn * nrm[tri[:, 0]], 1) < 0
    tri = tri.copy(); tri[flip] = tri[flip][:, ::-1]
    return tri.astype(np.uint32)


def lathe(cx, cz, y0, profile, seg=40, uv_of=None):
    """Round feature: profile = [(radius_mm, height_mm), ...] from the outer base up to the centre top."""
    pr = np.asarray(profile, float); th = np.linspace(0, 2 * np.pi, seg, endpoint=False)
    R, Yh = pr[:, 0][:, None], pr[:, 1][:, None]
    pos = np.stack([cx + R * np.cos(th), np.broadcast_to(y0 + Yh, (len(pr), seg)), cz + R * np.sin(th)], -1)
    d = np.gradient(pr, axis=0); pn = np.stack([d[:, 1], -d[:, 0]], 1)        # outward normal in (r, y)
    pn /= np.maximum(np.linalg.norm(pn, axis=1, keepdims=True), 1e-9)
    nrm = np.stack([pn[:, 0][:, None] * np.cos(th), np.broadcast_to(pn[:, 1][:, None], (len(pr), seg)), pn[:, 0][:, None] * np.sin(th)], -1)
    a, b = np.meshgrid(np.arange(len(pr) - 1), np.arange(seg), indexing='ij')
    a, b = a.ravel(), b.ravel(); b2 = (b + 1) % seg
    tri = np.concatenate([np.stack([a * seg + b, (a + 1) * seg + b, (a + 1) * seg + b2], 1),
                          np.stack([a * seg + b, (a + 1) * seg + b2, a * seg + b2], 1)])
    pos, nrm = pos.reshape(-1, 3), nrm.reshape(-1, 3)
    return pos, nrm, fix_winding(pos, nrm, tri), (uv_of(pos) if uv_of else None)


def merge(parts):
    pos, nrm, tri, uv, off = [], [], [], [], 0
    for p, n, t, u in parts:
        pos.append(p); nrm.append(n); tri.append(t + off); uv.append(u); off += len(p)
    has_uv = all(u is not None for u in uv)
    return np.concatenate(pos), np.concatenate(nrm), np.concatenate(tri), (np.concatenate(uv) if has_uv else None)


def subset(part, sel):
    """The triangles of a part where sel is true, with only the vertices they use."""
    pos, nrm, tri, uv = part; used, inv = np.unique(tri[sel], return_inverse=True)
    return pos[used], nrm[used], inv.reshape(-1, 3).astype(np.uint32), (uv[used] if uv is not None else None)


def facing(part, eye, thr=0.35):
    """Triangles whose outward normal points towards eye (unit normal . unit direction > thr)."""
    pos, _, tri, _ = part; a, b, c = pos[tri[:, 0]], pos[tri[:, 1]], pos[tri[:, 2]]
    return np.sum(unit(np.cross(b - a, c - a)) * unit(eye - (a + b + c) / 3), 1) > thr


# ------------------------------------------------------------------ GLB
class Glb:
    def __init__(self):
        self.buf = bytearray(); self.views, self.accs, self.mats, self.meshes, self.nodes = [], [], [], [], []
        self.images, self.textures, self.tris = [], [], 0

    def _view(self, data, target=None):
        while len(self.buf) % 4: self.buf.append(0)
        v = {'buffer': 0, 'byteOffset': len(self.buf), 'byteLength': len(data)}
        if target: v['target'] = target
        self.buf.extend(data); self.views.append(v); return len(self.views) - 1

    def _acc(self, arr, typ, ctype, target, mm=False):
        arr = np.ascontiguousarray(arr)
        a = {'bufferView': self._view(arr.tobytes(), target), 'componentType': ctype,
             'count': int(arr.size if typ == 'SCALAR' else len(arr)), 'type': typ}
        if mm: a['min'], a['max'] = arr.min(0).tolist(), arr.max(0).tolist()
        self.accs.append(a); return len(self.accs) - 1

    def texture(self, bgr, quality=90):
        data = cv2.imencode('.jpg', bgr, [cv2.IMWRITE_JPEG_QUALITY, quality])[1].tobytes()
        self.images.append({'bufferView': self._view(data), 'mimeType': 'image/jpeg'})
        self.textures.append({'source': len(self.images) - 1, 'sampler': 0}); return len(self.textures) - 1

    def material(self, name, color=(0.8, 0.8, 0.8), roughness=0.6, metallic=0.0, texture=None):
        lin = lambda v: ((v + 0.055) / 1.055) ** 2.4 if v > 0.04045 else v / 12.92
        pbr = {'baseColorFactor': [lin(float(v)) for v in color[:3]] + [1.0], 'metallicFactor': float(metallic), 'roughnessFactor': float(roughness)}
        if texture is not None:
            pbr['baseColorFactor'] = [1, 1, 1, 1]; pbr['baseColorTexture'] = {'index': texture}
        self.mats.append({'name': name, 'pbrMetallicRoughness': pbr}); return len(self.mats) - 1

    def mesh(self, name, prims):
        out = []
        for mat, (pos, nrm, tri, uv) in prims:
            at = {'POSITION': self._acc((pos * 1e-3).astype('<f4'), 'VEC3', 5126, 34962, True),
                  'NORMAL': self._acc(nrm.astype('<f4'), 'VEC3', 5126, 34962)}
            if uv is not None: at['TEXCOORD_0'] = self._acc(uv.astype('<f4'), 'VEC2', 5126, 34962)
            out.append({'attributes': at, 'indices': self._acc(tri.astype('<u4').reshape(-1), 'SCALAR', 5125, 34963), 'material': mat, 'mode': 4})
            self.tris += len(tri)
        self.meshes.append({'name': name, 'primitives': out}); self.nodes.append({'name': name, 'mesh': len(self.meshes) - 1})

    def save(self, path, extras):
        n = len(self.nodes)
        g = {'asset': {'version': '2.0', 'generator': 'solid-glb'}, 'scene': 0, 'scenes': [{'nodes': [n]}],
             'nodes': self.nodes + [{'name': 'object', 'children': list(range(n)), 'extras': extras}],
             'meshes': self.meshes, 'materials': self.mats, 'accessors': self.accs, 'bufferViews': self.views}
        if self.textures:
            g.update(textures=self.textures, images=self.images, samplers=[{'magFilter': 9729, 'minFilter': 9987, 'wrapS': 33071, 'wrapT': 33071}])
        while len(self.buf) % 4: self.buf.append(0)
        g['buffers'] = [{'byteLength': len(self.buf)}]
        js = json.dumps(g, separators=(',', ':')).encode(); js += b' ' * ((4 - len(js) % 4) % 4)
        with open(path, 'wb') as f:
            f.write(struct.pack('<4sII', b'glTF', 2, 28 + len(js) + len(self.buf)))
            f.write(struct.pack('<I4s', len(js), b'JSON')); f.write(js)
            f.write(struct.pack('<I4s', len(self.buf), b'BIN\x00')); f.write(bytes(self.buf))
        return 28 + len(js) + len(self.buf)


def mat_of(glb, name, m, default):
    m = {**default, **(m or {})}
    return glb.material(name, m.get('color', (0.8, 0.8, 0.8)), m.get('roughness', 0.6), m.get('metallic', 0.0))


# ------------------------------------------------------------------ slab template
FEATURE_PROFILES = {   # (radius factor, height factor) from the outer base up to the centre
    'button': [(1.0, 0), (1.0, 0.42), (0.9, 0.5), (0.84, 0.55), (0.82, 0.88), (0.72, 1.0), (0, 1.0)],
    'dome': [(1.0, 0), (0.98, 0.3), (0.9, 0.62), (0.7, 0.88), (0.4, 0.98), (0, 1.0)],
    'disc': [(1.0, 0), (1.0, 0.85), (0.9, 1.0), (0, 1.0)],
}
CARD_RIGHT = {'front': (0, 1), 'back': (0, -1), 'right': (1, 0), 'left': (-1, 0)}
LAYER_COLOR = (0.85, 0.85, 0.85)


def snap_circles(rect, ppm, origin, feats, tol_mm):
    """Move each round feature onto the nearest circle found in the rectified top photo (same size class).
    origin = canonical mm of the rectified image's top-left pixel."""
    g = cv2.medianBlur(cv2.cvtColor(rect, cv2.COLOR_BGR2GRAY), 5); moved = 0
    for f in feats:
        r = f['diameter_mm'] / 2
        cs = cv2.HoughCircles(g, cv2.HOUGH_GRADIENT, dp=1.5, minDist=r * ppm, param1=90, param2=28,
                              minRadius=int(r * 0.7 * ppm), maxRadius=int(r * 1.25 * ppm))
        if cs is None: continue
        c = cs[0][:, :2] / ppm + origin
        d = np.linalg.norm(c - f['xz'], axis=1); k = int(np.argmin(d))
        if d[k] <= tol_mm:
            f['snap_mm'] = round(float(d[k]), 2); f['xz'] = c[k].astype(float); moved += 1
        else:
            f['nearest_circle_mm'] = round(float(d[k]), 2)
    return moved


def layer_walls(L, h):
    """Wall profile of a layer as [(height above the bottom, inset from the bottom outline)], or None for straight walls."""
    if L.get('profile'):
        pr = [(float(a), float(b)) for a, b in L['profile']]
        if pr[0] != (0.0, 0.0) or any(b[0] <= a[0] for a, b in zip(pr, pr[1:])):
            raise SystemExit(f"layer {L['name']}: profile must start with [0, 0] and have increasing heights")
        if h is not None and abs(h - pr[-1][0]) > 1e-6:
            raise SystemExit(f"layer {L['name']}: height_mm {h} differs from the profile's last height {pr[-1][0]}")
        return pr
    if float(L.get('taper_mm', 0)):
        return [(0.0, 0.0), (h, float(L['taper_mm']))]
    return None


def silhouette(top, parts, shape, origin, ppm):
    """Mask (rectified-image pixels) of where the parts appear in the top photo."""
    m = np.zeros(shape[:2], np.uint8)
    for pos, _, tri, _ in parts:
        px = np.clip(np.round((top.apparent(pos) - origin) * ppm * 16), -1e7, 1e7).astype(np.int32)
        for t in tri:
            cv2.fillConvexPoly(m, px[t], 255, cv2.LINE_8, 4)
    return m


def build_slab(cfg, base, out):
    tcfg = cfg['top']; top = Top(tcfg, base); W, D = top.W, top.D
    ppm = float(cfg.get('texture_px_per_mm', 6)); margin = 4.0; rough = float(cfg.get('top_roughness', 0.35))
    names = [L['name'] for L in cfg['layers']]

    def li(name, what):
        if name not in names: raise SystemExit(f'{what}: no layer named {name!r}')
        return names.index(name)

    spans, walls, y = [], [], 0.0                                          # heights first: outlines are mapped at them
    for L in cfg['layers']:
        h = float(L['height_mm']) if L.get('height_mm') is not None else None
        wl = layer_walls(L, h)
        h = wl[-1][0] if h is None and wl else h
        if h is None: raise SystemExit(f"layer {L['name']}: needs height_mm or profile")
        y0 = float(L['base_mm']) if L.get('base_mm') is not None else y
        spans.append((y0, y0 + h)); walls.append(wl); y = y0 + h
    plane = tcfg.get('plane', names[-1]); top.y_ref = spans[li(plane, 'top.plane')][1]
    world = lambda p: np.stack([p[:, 0] - W / 2, p[:, 1] - D / 2], 1)       # canonical mm -> (x, z)
    outline = (shape_outline(top.mm(cfg['outline']), round_mm=float(cfg.get('outline_round_mm', 0)))
               if cfg.get('outline') else None)
    eye = top.camera_world()

    erase = [top.mm(p) for p in tcfg.get('erase', [])]
    def rectify(b):
        r = top.rectified(ppm, b)
        if erase:
            mk = np.zeros(r.shape[:2], np.uint8)
            for p in erase:
                cv2.fillPoly(mk, [np.round((p - b[:2]) * ppm).astype(np.int32)], 255)
            r = cv2.inpaint(r, mk, max(3, int(round(2 * ppm))), cv2.INPAINT_TELEA)
        return r
    b0 = (-margin, -margin, W + margin, D + margin)
    rect0 = rectify(b0)

    glb = Glb(); meshes, layers, rings = [], [], []    # mesh prims: (key, part); key ('L', i) layer photo, ('P',) plain photo, ('M', material)
    for i, L in enumerate(cfg['layers']):                                  # bottom to top
        y0, y1 = spans[i]; at = L.get('outline_at', 'top'); wl = walls[i]
        if L.get('outline'):
            o = shape_outline(top.mm_at(L['outline'], (y1 if at == 'top' else y0) - top.y_ref),
                              round_mm=float(L.get('outline_round_mm', 0)))
        elif outline is not None:
            o = outline
        else:
            raise SystemExit(f"layer {L['name']}: no outline (give the layer an outline or a shared one)")
        poly = world(shape_outline(o, inset_mm=float(L.get('inset_mm', 0))))
        if wl:
            last = wl[-1][1]
            rg = offset_rings(poly, [(last - b if at == 'top' else -b) for _, b in wl])
            ys = [y0 + a for a, _ in wl]; pr = loft(rg, ys)
        else:
            pr = prism(poly, y0, y1); rg, ys = [poly, poly], [y0, y1]
        mcfg = {'color': LAYER_COLOR, **(L.get('material') or {})}
        m = mat_of(glb, L['name'], L.get('material'), {'color': LAYER_COLOR})
        prims = [(('L', i), pr['top'])] if L.get('texture') == 'top' else [(('M', m), pr['top'][:3] + (None,))]
        if L.get('side_texture') == 'top':
            sel = facing(pr['side'], eye)
            if sel.any(): prims.append((('L', i), subset(pr['side'], sel)))
            prims.append((('M', m), merge(([subset(pr['side'], ~sel)] if (~sel).any() else []) + [pr['bottom']])))
        else:
            prims.append((('M', m), merge([pr['side'], pr['bottom']])))
        meshes.append({'name': L['name'], 'kind': 'layer', 'i': i, 'prims': prims, 'color': mcfg['color']})
        rings.append((rg, ys))
        layers.append({'name': L['name'], 'y0_mm': y0, 'y1_mm': y1, 'points': len(poly), 'ring_points': len(rg[0]),
                       'rings': len(rg), 'taper_mm': round(float(wl[-1][1]), 2) if wl else 0.0,
                       'outline': 'own' if L.get('outline') else 'shared'})
    top_y = max(s[1] for s in spans)

    feats = []
    for grp in cfg.get('features', []):
        on = grp.get('on', names[-1]); yo = spans[li(on, f"feature {grp['name']}")][1]; hh = yo - top.y_ref
        snap = grp.get('snap', True) and abs(hh) < 1e-6
        for at in grp['at']:
            feats.append({'group': grp['name'], 'xz': top.mm_at([at], hh)[0], 'diameter_mm': float(grp['diameter_mm']), 'y': yo, 'snap': snap})
    snapping = [f for f in feats if f['snap']]
    snapped = snap_circles(rect0, ppm, np.array(b0[:2]), snapping, float(cfg.get('snap_tolerance_mm', 4))) if snapping else 0
    for grp in cfg.get('features', []):
        prof = FEATURE_PROFILES[grp.get('shape', 'button')]; r, h = grp['diameter_mm'] / 2, float(grp['height_mm'])
        parts = [lathe(*(world(f['xz'][None])[0]), f['y'], [(a * r, b * h) for a, b in prof])
                 for f in feats if f['group'] == grp['name']]
        if parts:
            key = ('P',) if grp.get('texture') == 'top' else ('M', mat_of(glb, grp['name'], grp.get('material'), {'color': (0.8, 0.8, 0.8)}))
            meshes.append({'name': grp['name'], 'kind': 'feature', 'prims': [(key, merge(parts))]})

    for mk in cfg.get('side_marks', []):                                   # dark rectangles on a side wall of one layer
        k = li(mk['layer'], 'side mark'); (y0, y1), (rg, ys) = spans[k], rings[k]
        w_, h_ = mk['size_mm']; yc = y0 + mk.get('height_frac', 0.5) * (y1 - y0)
        j = int(np.clip(np.searchsorted(ys, yc) - 1, 0, len(ys) - 2)); f_ = (yc - ys[j]) / max(ys[j + 1] - ys[j], 1e-9)
        poly = rg[j] + (rg[j + 1] - rg[j]) * f_                    # the wall at this height
        axis, sign = {'front': (1, 1), 'back': (1, -1), 'right': (0, 1), 'left': (0, -1)}[mk['side']]
        other = 1 - axis; c = (mk.get('along_frac', 0.5) - 0.5) * (W if other == 0 else D)
        a_, b_ = poly, np.roll(poly, -1, 0)                         # where the wall is, at this position along the side
        cross = (a_[:, other] - c) * (b_[:, other] - c) <= 0
        t_ = (c - a_[cross, other]) / np.where(b_[cross, other] == a_[cross, other], 1, b_[cross, other] - a_[cross, other])
        hits = a_[cross, axis] + t_ * (b_[cross, axis] - a_[cross, axis])
        edge = (hits.max() if sign > 0 else hits.min()) + sign * 0.06
        q = np.zeros((4, 3)); q[:, 1] = [yc - h_ / 2, yc - h_ / 2, yc + h_ / 2, yc + h_ / 2]
        q[:, 0 if other == 0 else 2] = [c - w_ / 2, c + w_ / 2, c + w_ / 2, c - w_ / 2]; q[:, 0 if axis == 0 else 2] = edge
        nv = np.zeros(3); nv[0 if axis == 0 else 2] = sign
        m = mat_of(glb, mk.get('name', 'mark'), mk.get('material'), {'color': (0.05, 0.05, 0.05), 'roughness': 0.5})
        meshes.append({'name': mk.get('name', 'mark'), 'kind': 'mark',
                       'prims': [(('M', m), (q, np.tile(nv, (4, 1)), face_up(q, np.array([[0, 1, 2], [0, 2, 3]], np.uint32), nv), None))]})

    cards = []
    for C in cfg.get('cards', []):                                         # flat cut-outs standing upright
        im = cv2.imread(str(base / C['photo']))
        if im is None: raise SystemExit(f"cannot read {C['photo']}")
        hp, wp = im.shape[:2]; ol = np.array(C['outline'], float) * [wp, hp]; lo, hi = ol.min(0), ol.max(0)
        scale = float(C['height_mm']) / (hi[1] - lo[1]) if C.get('height_mm') else float(C['width_mm']) / (hi[0] - lo[0])
        foot = np.array(C['foot'], float) * [wp, hp] if C.get('foot') else np.array([(lo[0] + hi[0]) / 2, hi[1]])
        on = C.get('on', plane); yo = spans[li(on, f"card {C['name']}")][1]
        xz = world(top.mm_at([C['at']], yo - top.y_ref))[0]; F = np.array([xz[0], yo + float(C.get('lift_mm', 0)), xz[1]])
        rx, rz = CARD_RIGHT[C.get('photo_right', 'right')]
        U, V, N = np.array([rx, 0.0, rz]), np.array([0, -1.0, 0]), np.array([-rz, 0.0, rx])
        Rm = np.stack([U, N, V], 1)                                     # local (a, e, b) -> world
        t = float(C.get('thickness_mm', 0.5)); pr = prism((ol - foot) * scale, -t / 2, t / 2)
        tw = lambda p: (p[0] @ Rm.T + F, p[1] @ Rm.T, p[2], p[3])
        edge = mat_of(glb, C['name'], C.get('material'), {'color': (0.9, 0.9, 0.88), 'roughness': 0.8})
        faces = [pr['top'], pr['bottom']]
        if C.get('texture', True):
            pad = 0.02 * (hi - lo); c0 = np.maximum(np.floor(lo - pad), 0).astype(int); c1 = np.minimum(np.ceil(hi + pad), [wp, hp]).astype(int)
            crop = im[c0[1]:c1[1], c0[0]:c1[0]]; k = min(1.0, 1024 / max(crop.shape[:2]))
            crop = cv2.resize(crop, (max(1, round(crop.shape[1] * k)), max(1, round(crop.shape[0] * k))), interpolation=cv2.INTER_AREA)
            uv = lambda p: ((foot + p[:, [0, 2]] / scale - c0) / (c1 - c0))
            faces = [f[:3] + (uv(f[0]),) for f in faces]
            fm = glb.material(C['name'] + '_photo', roughness=float((C.get('material') or {}).get('roughness', 0.8)), texture=glb.texture(crop))
        else:
            fm = edge
        meshes.append({'name': C['name'], 'kind': 'card', 'prims': [(('M', fm), tw(merge(faces))), (('M', edge), tw(pr['side']))]})
        a = (ol[:, 0] - foot[0]) * scale
        cards.append({'name': C['name'], 'size_mm': [round(float((hi - lo)[0] * scale), 1), round(float((hi - lo)[1] * scale), 1)],
                      'thickness_mm': t, 'foot_mm': np.round(F, 1).tolist(), 'normal': N.tolist(),
                      'foot_line': [F + a.min() * U, F + a.max() * U]})

    # texture: cover the apparent positions of everything textured from the top photo
    tex = [p[0] for mm in meshes for k, p in mm['prims'] if k[0] in 'LP']
    b = b0
    if tex:
        A = top.apparent(np.concatenate(tex)); A = A[np.isfinite(A).all(1)]
        b = (max(min(-margin, A[:, 0].min() - margin), -W), max(min(-margin, A[:, 1].min() - margin), -D),
             min(max(W + margin, A[:, 0].max() + margin), 2 * W), min(max(D + margin, A[:, 1].max() + margin), 2 * D))
    rect = rect0 if b == b0 else rectify(b); org = np.array(b[:2])
    uv_of = lambda P: (top.apparent(P) - org) * ppm / [rect.shape[1], rect.shape[0]]
    plain, lmat = [], {}
    def plain_mat():
        if not plain: plain.append(glb.material('top_photo', roughness=rough, texture=glb.texture(rect)))
        return plain[0]
    for mm in meshes:                                 # hidden areas: what is in front gets the layer's own colour
        if mm['kind'] != 'layer' or not any(k[0] == 'L' for k, _ in mm['prims']): continue
        i = mm['i']
        occ = [p for o in meshes if (o['kind'] == 'layer' and o['i'] > i) or o['kind'] in ('feature', 'card') for _, p in o['prims']]
        mask = silhouette(top, occ, rect.shape, org, ppm) if occ else None
        if mask is not None and mask.any():
            k = max(1, int(round(float(cfg.get('hidden_margin_mm', 1)) * ppm)))     # the real object is often a bit bigger than the model
            mask = cv2.dilate(mask, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (2 * k + 1,) * 2))
            img = rect.copy(); img[mask > 0] = np.clip(np.round(np.array(mm['color'][:3], float)[::-1] * 255), 0, 255).astype(np.uint8)
            lmat[i] = glb.material(mm['name'] + '_photo', roughness=rough, texture=glb.texture(img))
            layers[i]['own_texture'] = True; layers[i]['hidden_fraction'] = round(float((mask > 0).mean()), 3)
        else:
            lmat[i] = plain_mat(); layers[i]['own_texture'] = False
    for mm in meshes:
        prims = []
        for k, p in mm['prims']:
            if k[0] == 'L': prims.append((lmat[k[1]], p[:3] + (uv_of(p[0]),)))
            elif k[0] == 'P': prims.append((plain_mat(), p[:3] + (uv_of(p[0]),)))
            else: prims.append((k[1], p))
        glb.mesh(mm['name'], prims)

    allp = np.concatenate([p[0] for mm in meshes for _, p in mm['prims']])
    size = glb.save(out / 'model.glb', {'units': 'metres', 'up': '+Y', 'front': '+Z', 'template': 'slab', 'size_mm': [round(W, 1), round(top_y, 1), round(D, 1)]})

    cv2.imwrite(str(out / 'top_rectified.jpg'), rect)
    ov = rect.copy(); px = lambda p: np.round((p - org) * ppm).astype(np.int32)
    if outline is not None:
        cv2.polylines(ov, [px(outline)], True, (0, 255, 0), 2)
    for rg, ys in rings:
        cv2.polylines(ov, [px(top.apparent(np.c_[rg[-1][:, 0], np.full(len(rg[-1]), ys[-1]), rg[-1][:, 1]]))], True, (255, 255, 0), 1)
    for f in feats:
        c3 = np.array([[f['xz'][0] - W / 2, f['y'], f['xz'][1] - D / 2]])
        cv2.circle(ov, tuple(px(top.apparent(c3))[0]), int(f['diameter_mm'] / 2 * ppm), (0, 0, 255), 2)
    cv2.imwrite(str(out / 'top_overlay.jpg'), ov)

    k = min(1.0, 1400 / top.im.shape[0]); po = cv2.resize(top.im, None, fx=k, fy=k, interpolation=cv2.INTER_AREA)
    pp = lambda P: np.round(top.project(P) * k).astype(np.int32)
    cv2.polylines(po, [np.round(top.c * k).astype(np.int32)], True, (0, 255, 255), 2, cv2.LINE_AA)
    for rg, ys in rings:
        for j, (r_, y_) in enumerate(zip(rg, ys)):                  # bottom ring thin, top ring thick, others thin and dark
            last = j == len(rg) - 1
            cv2.polylines(po, [pp(np.c_[r_[:, 0], np.full(len(r_), y_), r_[:, 1]])], True,
                          (0, 220, 0) if last or j == 0 else (0, 120, 0), 3 if last else 1, cv2.LINE_AA)
    ang = np.linspace(0, 2 * np.pi, 33)
    for f in feats:
        r = f['diameter_mm'] / 2
        cv2.polylines(po, [pp(np.c_[f['xz'][0] - W / 2 + r * np.cos(ang), np.full(33, f['y']), f['xz'][1] - D / 2 + r * np.sin(ang)])], True, (0, 0, 255), 2, cv2.LINE_AA)
    for c in cards:
        cv2.polylines(po, [pp(np.array(c.pop('foot_line')))], False, (255, 0, 255), 3, cv2.LINE_AA)
    cv2.imwrite(str(out / 'photo_overlay.jpg'), po, [cv2.IMWRITE_JPEG_QUALITY, 88])

    rep = {'template': 'slab', 'size_mm': {'width': round(W, 1), 'depth': round(D, 1), 'height': round(top_y, 1)},
           'depth_from_photo': top.depth_assumed, 'focal_px': round(top.focal), 'focal_source': top.focal_source,
           'camera': top.camera_report(), 'reference_plane': plane, 'reference_y_mm': top.y_ref,
           'outline_points': len(outline) if outline is not None else None, 'layers': layers,
           'features': {g['name']: sum(f['group'] == g['name'] for f in feats) for g in cfg.get('features', [])},
           'features_snapped': snapped, 'features_not_snapped': [f['group'] for f in feats if f['snap'] and 'snap_mm' not in f],
           'feature_list': [{'group': f['group'], 'x_mm': round(float(f['xz'][0]), 2), 'z_mm': round(float(f['xz'][1]), 2),
                             'moved_mm': f.get('snap_mm'), 'nearest_circle_mm': f.get('nearest_circle_mm')} for f in feats],
           'cards': cards, 'bbox_mm': {'min': np.round(allp.min(0), 1).tolist(), 'max': np.round(allp.max(0), 1).tolist()},
           'texture_bounds_mm': [round(float(v), 2) for v in b], 'triangles': glb.tris, 'bytes': size}
    if top.circle_fit: rep['circle_fit'] = top.circle_fit
    if top.mirrored: rep['corner_order_mirrored'] = True
    return rep


cfg_group = lambda cfg, name: next(g for g in cfg['features'] if g['name'] == name)
cfg_layer = lambda cfg, name: next(L for L in cfg['layers'] if L['name'] == name)


# ------------------------------------------------------------------ commands
def cmd_grid(a):
    im = cv2.imread(a[0]); H, W = im.shape[:2]
    box = [float(v) for v in a[2:6]] if len(a) >= 6 else [0, 0, 1, 1]
    hp = int(a[6]) if len(a) >= 7 else 1200
    c = im[int(box[1] * H):int(box[3] * H), int(box[0] * W):int(box[2] * W)]
    c = cv2.resize(c, None, fx=hp / c.shape[0], fy=hp / c.shape[0], interpolation=cv2.INTER_AREA)
    span = max(box[2] - box[0], box[3] - box[1]); step = 0.1 if span > 0.6 else 0.05 if span > 0.25 else 0.02
    for k in np.arange(0, 1.0001, step / 2):
        major = abs(k / step - round(k / step)) < 1e-6
        for ax, (lo, hi, n) in enumerate(((box[0], box[2], c.shape[1]), (box[1], box[3], c.shape[0]))):
            if not lo <= k <= hi: continue
            p = int((k - lo) / (hi - lo) * (n - 1)); col = (0, 255, 255) if major else (0, 150, 150)
            cv2.line(c, (p, 0), (p, c.shape[0]), col, 1) if ax == 0 else cv2.line(c, (0, p), (c.shape[1], p), col, 1)
            if major:
                org = (p + 3, 14) if ax == 0 else (3, p - 4)
                cv2.putText(c, f'{k:.2f}', org, cv2.FONT_HERSHEY_SIMPLEX, 0.45, (0, 0, 0), 3)
                cv2.putText(c, f'{k:.2f}', org, cv2.FONT_HERSHEY_SIMPLEX, 0.45, (0, 255, 255), 1)
    cv2.imwrite(a[1], c, [cv2.IMWRITE_JPEG_QUALITY, 85]); print(f'photo {W}x{H}, grid image {c.shape[1]}x{c.shape[0]}, lines every {step / 2:g}')


def cmd_build(a):
    cfg_path = Path(a[0]).resolve(); out = Path(a[a.index('--out') + 1]); out.mkdir(parents=True, exist_ok=True)
    cfg = json.loads(cfg_path.read_text())
    if cfg['template'] == 'slab':
        rep = build_slab(cfg, cfg_path.parent, out)
    else:
        raise SystemExit(f"unknown template {cfg['template']!r} (this version has only 'slab')")
    rep['config'] = str(cfg_path)
    (out / 'report.json').write_text(json.dumps(rep, indent=1, ensure_ascii=False))
    short = {k: v for k, v in rep.items() if k not in ('layers', 'config', 'feature_list', 'bbox_mm', 'texture_bounds_mm')}
    short['cards'] = len(rep['cards']); short['camera'] = {k: v for k, v in rep['camera'].items() if k != 'position_mm'}
    if 'circle_fit' in short: short['circle_fit'] = {k: v for k, v in rep['circle_fit'].items() if k != 'corners'}
    print(json.dumps(short, ensure_ascii=False))
    far = [f for f in rep.get('feature_list', []) if (f['moved_mm'] or 0) > 2.5]
    if far:
        print('moved more than 2.5 mm by the circle search (check top_overlay.jpg):', json.dumps(far))


def cmd_check(a):
    out = Path(a[0]).resolve(); rep = json.loads((out / 'report.json').read_text())
    cfg_path = Path(rep['config']); cfg = json.loads(cfg_path.read_text())
    views = cfg.get('views') or [{'name': 'top', 'az': 0, 'el': 89.9, 'up': [0, 0, -1]}, {'name': 'front', 'az': 0, 'el': 15}, {'name': 'oblique', 'az': 35, 'el': 30}]
    (out / 'views.json').write_text(json.dumps(views))
    r = subprocess.run(['node', str(HERE / 'render.cjs'), str(out / 'model.glb'), str(out), str(out / 'views.json')], capture_output=True, text=True, cwd=HERE)
    print(r.stdout.strip() or r.stderr.strip()[-600:])
    if r.returncode: raise SystemExit(1)
    Hh, rows = 520, []
    fit = lambda im: cv2.resize(im, (int(im.shape[1] * Hh / im.shape[0]), Hh), interpolation=cv2.INTER_AREA)
    cells = []
    for v in views:
        rd = fit(cv2.imread(str(out / f"{v['name']}.png")))
        if v.get('photo'):
            ph = fit(cv2.imread(str(cfg_path.parent / v['photo'])))
            cells.append(np.hstack([ph, np.full((Hh, 6, 3), 255, np.uint8), rd]))
        else:
            cells.append(rd)
    wmax = max(c.shape[1] for c in cells) * 2 + 16
    row = []
    for c in cells:
        if row and sum(x.shape[1] for x in row) + c.shape[1] + 16 > wmax:
            rows.append(row); row = []
        row.append(c)
    rows.append(row)
    canvas = []
    for row in rows:
        line = np.hstack([np.hstack([c, np.full((Hh, 16, 3), 255, np.uint8)]) for c in row])
        canvas.append(cv2.copyMakeBorder(line, 0, 12, 0, wmax + 32 - line.shape[1], cv2.BORDER_CONSTANT, value=(255, 255, 255)))
    cv2.imwrite(str(out / 'compare.jpg'), np.vstack(canvas), [cv2.IMWRITE_JPEG_QUALITY, 86])
    print('compare.jpg: each cell is photo | render, in the order', [v['name'] for v in views])


if __name__ == '__main__':
    cmds = {'grid': cmd_grid, 'build': cmd_build, 'check': cmd_check}
    if len(sys.argv) < 3 or sys.argv[1] not in cmds:
        raise SystemExit(__doc__)
    cmds[sys.argv[1]](sys.argv[2:])
