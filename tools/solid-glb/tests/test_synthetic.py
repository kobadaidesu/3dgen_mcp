"""Tests on synthetic photos: boxes, tapered and per-layer shapes, a round base and standing cards seen in perspective
(no real photos, no Node.js)."""
import json, struct, sys, tempfile, unittest
from pathlib import Path

import cv2
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import solidglb as sg

W_MM, D_MM = 200.0, 120.0
KNOBS = [(60.0, 50.0), (140.0, 70.0)]          # true centres (x from the left, z from the back), 24 mm wide


def synthetic_photo(folder):
    """Render the top of the box through a pinhole camera; returns the photo size and the corner pixels."""
    ppm = 5.0
    top = np.full((int(D_MM * ppm), int(W_MM * ppm), 3), (205, 180, 120), np.uint8)
    for x in range(0, top.shape[1], 50):
        cv2.line(top, (x, 0), (x + 200, top.shape[0]), (150, 120, 90), 6)
    for x, z in KNOBS:
        cv2.circle(top, (int(x * ppm), int(z * ppm)), int(12 * ppm), (40, 40, 40), -1)
        cv2.circle(top, (int(x * ppm), int(z * ppm)), int(8 * ppm), (90, 90, 90), -1)
    w, h, f = 1200, 900, 1100.0
    ax, ay = np.radians(28), np.radians(12)                      # tilt and turn of the plane
    Rx = np.array([[1, 0, 0], [0, np.cos(ax), -np.sin(ax)], [0, np.sin(ax), np.cos(ax)]])
    Ry = np.array([[np.cos(ay), 0, np.sin(ay)], [0, 1, 0], [-np.sin(ay), 0, np.cos(ay)]])
    P = np.array([[0, 0], [W_MM, 0], [W_MM, D_MM], [0, D_MM]], float)
    X = np.c_[P - [W_MM / 2, D_MM / 2], np.zeros(4)] @ (Ry @ Rx).T + [0, 0, 330.0]
    px = np.stack([f * X[:, 0] / X[:, 2] + w / 2, f * X[:, 1] / X[:, 2] + h / 2], 1)
    Hm = cv2.getPerspectiveTransform((P * ppm).astype(np.float32), px.astype(np.float32))
    photo = np.full((h, w, 3), (236, 236, 232), np.uint8)
    cv2.warpPerspective(top, Hm, (w, h), dst=photo, borderMode=cv2.BORDER_TRANSPARENT)
    cv2.imwrite(str(folder / 'top.png'), photo)
    to_photo = lambda pts: cv2.perspectiveTransform((np.asarray(pts, np.float32) * ppm)[None], Hm)[0] / [w, h]
    return px / [w, h], to_photo


class SlabTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(); d = Path(cls.tmp.name)
        corners, to_photo = synthetic_photo(d)
        inner = to_photo([[2, 2], [W_MM - 2, 2], [W_MM - 2, D_MM - 2], [2, D_MM - 2]])
        cfg = {'template': 'slab', 'top': {'photo': 'top.png', 'corners': corners.tolist(), 'width_mm': W_MM},
               'outline': inner.tolist(), 'outline_round_mm': 4,
               'layers': [{'name': 'base', 'height_mm': 20, 'inset_mm': 3}, {'name': 'lid', 'height_mm': 4, 'texture': 'top'}],
               'features': [{'name': 'knobs', 'shape': 'button', 'diameter_mm': 24, 'height_mm': 6, 'texture': 'top',
                             'at': to_photo([[x + 2.0, z - 1.5] for x, z in KNOBS]).tolist()}],          # deliberately off
               'side_marks': [{'name': 'port', 'layer': 'base', 'side': 'back', 'size_mm': [9, 3]}]}
        (d / 'cfg.json').write_text(json.dumps(cfg))
        cls.out = d / 'out'; cls.out.mkdir()
        cls.rep = sg.build_slab(cfg, d, cls.out)
        raw = (cls.out / 'model.glb').read_bytes()
        cls.magic, _, cls.total = struct.unpack('<4sII', raw[:12])
        n = struct.unpack('<I', raw[12:16])[0]
        cls.gltf = json.loads(raw[20:20 + n]); cls.raw = raw

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_depth_comes_from_the_perspective(self):
        self.assertTrue(self.rep['depth_from_photo'])
        self.assertAlmostEqual(self.rep['size_mm']['depth'], D_MM, delta=D_MM * 0.03)
        self.assertAlmostEqual(self.rep['focal_px'], 1100, delta=60)

    def test_round_parts_move_onto_the_circles(self):
        self.assertEqual(self.rep['features_snapped'], 2)
        for f, (x, z) in zip(self.rep['feature_list'], KNOBS):
            self.assertAlmostEqual(f["x_mm"], x, delta=0.8)
            self.assertAlmostEqual(f['z_mm'], z, delta=0.8)
            self.assertGreater(f['moved_mm'], 1.0)

    def test_glb_is_well_formed(self):
        self.assertEqual(self.magic, b'glTF'); self.assertEqual(self.total, len(self.raw))
        names = [m['name'] for m in self.gltf['meshes']]
        self.assertEqual(names, ['base', 'lid', 'knobs', 'port'])
        pos = [self.gltf['accessors'][p['attributes']['POSITION']] for m in self.gltf['meshes'] for p in m['primitives']]
        lo = np.min([a['min'] for a in pos], 0); hi = np.max([a['max'] for a in pos], 0)
        self.assertAlmostEqual(lo[1], 0.0, places=6)                                  # sits on y = 0
        self.assertAlmostEqual(hi[1], 0.030, delta=1e-4)                              # 20 + 4 + 6 mm
        self.assertAlmostEqual(hi[0] - lo[0], (W_MM - 4) / 1000, delta=0.002)
        for a in self.gltf['accessors']:
            self.assertGreater(a['count'], 0)

    def test_layers_stack_from_the_bottom(self):
        L = self.rep['layers']
        self.assertEqual([(l['y0_mm'], l['y1_mm']) for l in L], [(0.0, 20.0), (20.0, 24.0)])


class GeometryTest(unittest.TestCase):
    def test_aspect_of_a_square_seen_straight_on_falls_back_to_side_lengths(self):
        ratio, focal = sg.quad_aspect([[100, 100], [500, 100], [500, 300], [100, 300]], 600, 400)
        self.assertAlmostEqual(ratio, 2.0, places=6); self.assertIsNone(focal)

    def test_inset_shrinks_the_outline(self):
        sq = np.array([[0, 0], [100, 0], [100, 60], [0, 60]], float)
        p = sg.shape_outline(sq, inset_mm=5)
        self.assertAlmostEqual(np.ptp(p[:, 0]), 90, delta=0.6); self.assertAlmostEqual(np.ptp(p[:, 1]), 50, delta=0.6)

    def test_prism_faces_point_outwards(self):
        sq = np.array([[0, 0], [10, 0], [10, 10], [0, 10]], float) - 5
        pos, nrm, tri, _ = sg.prism(sq, 0, 4)['side']
        fn = np.cross(pos[tri[:, 1]] - pos[tri[:, 0]], pos[tri[:, 2]] - pos[tri[:, 0]])
        centre = pos[tri].mean(1) - [0, 2, 0]
        self.assertTrue((np.sum(fn * centre, 1) > 0).all())



# ------------------------------------------------------------------ oblique scenes (world mm: y up, front +Z)
unit = lambda v: np.asarray(v, float) / np.linalg.norm(v, axis=-1, keepdims=True)


def camera(el, az=0.0, dist=500.0, target=(0, 0, 0), f=1000.0, w=1200, h=900):
    """Pinhole camera looking at target from elevation el / azimuth az (degrees, from the front towards +X)."""
    T = np.array(target, float); e, a = np.radians(el), np.radians(az)
    eye = T + dist * np.array([np.sin(a) * np.cos(e), np.sin(e), np.cos(a) * np.cos(e)])
    fwd = unit(T - eye); right = unit(np.cross(fwd, [0, 1, 0])); R = np.stack([right, np.cross(fwd, right), fwd])
    def proj(P):
        X = (np.asarray(P, float).reshape(-1, 3) - eye) @ R.T
        return np.stack([f * X[:, 0] / X[:, 2] + w / 2, f * X[:, 1] / X[:, 2] + h / 2], 1)
    proj.eye, proj.depth, proj.size = eye, (lambda P: ((np.asarray(P, float).reshape(-1, 3) - eye) @ R.T)[:, 2]), np.array([w, h])
    return proj


def at_y(xz, y):
    xz = np.asarray(xz, float); return np.c_[xz[:, 0], np.full(len(xz), y), xz[:, 1]]


def fill(img, cam, P, color):
    cv2.fillPoly(img, [np.round(cam(P) * 8).astype(np.int32)], color, cv2.LINE_AA, 3)


def rect_xz(x0, z0, x1, z1):
    return np.array([[x0, z0], [x1, z0], [x1, z1], [x0, z1]], float)


def box_faces(img, cam, xz, y0, y1, color):
    """Visible walls (back to front) and the top of a vertical prism."""
    q = np.roll(xz, -1, 0); quads = []
    for a, b in zip(xz, q):
        P = np.array([[a[0], y0, a[1]], [b[0], y0, b[1]], [b[0], y1, b[1]], [a[0], y1, a[1]]])
        quads.append((cam.depth(P).mean(), P))
    for _, P in sorted(quads, key=lambda t: -t[0]):
        fill(img, cam, P, tuple(int(c * 0.75) for c in color))
    fill(img, cam, at_y(xz, y1), color)


def corners_of(cam, W, D, y):
    return cam(at_y(rect_xz(-W / 2, -D / 2, W / 2, D / 2), y)) / cam.size


def read_glb(path):
    raw = Path(path).read_bytes(); n = struct.unpack('<I', raw[12:16])[0]
    g = json.loads(raw[20:20 + n]); bin_ = raw[28 + n:]
    def acc(i):
        a = g['accessors'][i]; v = g['bufferViews'][a['bufferView']]; k = {'SCALAR': 1, 'VEC2': 2, 'VEC3': 3}[a['type']]
        return np.frombuffer(bin_, {5126: '<f4', 5125: '<u4'}[a['componentType']], a['count'] * k, v['byteOffset']).reshape(-1, k)
    def image(mat):
        v = g['bufferViews'][g['images'][g['textures'][g['materials'][mat]['pbrMetallicRoughness']['baseColorTexture']['index']]['source']]['bufferView']]
        return cv2.imdecode(np.frombuffer(bin_, np.uint8, v['byteLength'], v['byteOffset']), cv2.IMREAD_COLOR)
    mesh = {m['name']: m['primitives'] for m in g['meshes']}
    return g, raw, acc, image, mesh


def check_glb(test, g, raw):
    test.assertEqual(raw[:4], b'glTF'); test.assertEqual(struct.unpack('<I', raw[8:12])[0], len(raw))
    for a in g['accessors']:
        test.assertGreater(a['count'], 0)


def build(cfg, d, name='out'):
    out = Path(d) / name; out.mkdir(exist_ok=True)
    rep = sg.build_slab(cfg, Path(d), out)
    return rep, out / 'model.glb'


class CameraModelTest(unittest.TestCase):
    W, D = 160.0, 100.0

    def test_heights_map_through_the_camera(self):
        cam = camera(40, az=15, dist=450)
        with tempfile.TemporaryDirectory() as d:
            cv2.imwrite(str(Path(d) / 'top.png'), np.full((900, 1200, 3), 128, np.uint8))
            top = sg.Top({'photo': 'top.png', 'corners': corners_of(cam, self.W, self.D, 0).tolist(), 'width_mm': self.W}, Path(d))
        self.assertEqual(top.focal_source, 'photo'); self.assertAlmostEqual(top.focal, 1000, delta=15)
        self.assertFalse(top.mirrored)
        self.assertAlmostEqual(top.camera_report()['elevation_deg'], 40, delta=1.0)
        P = np.array([[x, h, z] for h in (0, 10, 35, 70) for x, z in ((-50, -30), (0, 0), (60, 40), (30, -45))], float)
        frac = cam(P) / cam.size; canon = P[:, [0, 2]] + [self.W / 2, self.D / 2]
        np.testing.assert_allclose(top.mm_at(frac, P[:, 1]), canon, atol=0.4)          # photo -> mm at a known height
        np.testing.assert_allclose(top.apparent(P), top.mm(frac), atol=0.4)             # mm -> where it shows in the rectified photo
        np.testing.assert_allclose(top.project(P), cam(P), atol=0.6)
        h0 = cv2.perspectiveTransform((frac * cam.size).astype(np.float32)[None], top.H)[0]
        np.testing.assert_allclose(top.mm(frac), h0, atol=1e-3)                         # h = 0 is the old mapping
        back = top.mm_at(frac, P[:, 1])                                                 # and back again
        np.testing.assert_allclose(top.apparent(np.c_[back[:, 0] - self.W / 2, P[:, 1], back[:, 1] - self.D / 2]), top.mm(frac), atol=1e-6)

    def test_round_base_gives_the_square_around_it(self):
        R = 100.0; cam = camera(45, az=25, dist=500)
        th = np.radians([0, 50, 100, 150, 200, 250, 300])
        rim = cam(np.c_[R * np.cos(th), np.zeros(7), R * np.sin(th)]) / cam.size
        front = cam([[0, 0, 50]])[0] / cam.size
        true = cam(at_y(rect_xz(-R, -R, R, R), 0))
        with tempfile.TemporaryDirectory() as d:
            cv2.imwrite(str(Path(d) / 'top.png'), np.full((900, 1200, 3), 128, np.uint8))
            top = sg.Top({'photo': 'top.png', 'circle': {'rim': rim.tolist(), 'front': front.tolist()}, 'width_mm': 2 * R, 'focal_px': 1000}, Path(d))
        self.assertEqual(top.D, top.W); self.assertEqual(top.focal_source, 'config')
        self.assertLess(np.abs(top.c - true).max() / 1200, 0.015)
        self.assertLess(top.circle_fit['rms_mm'], 0.5)
        self.assertAlmostEqual(top.circle_fit['elevation_deg'], 45, delta=2)


class ShapesTest(unittest.TestCase):
    """A base board (reference plane = its top) with a tapered shell, seen obliquely from the front."""
    BASE = rect_xz(-100, -70, 100, 70)
    SHELL = rect_xz(-50, -40, 50, 40)

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(); d = Path(cls.tmp.name); cam = camera(40, az=10, dist=520, target=(0, 15, 0))
        img = np.full((900, 1200, 3), (150, 160, 170), np.uint8)
        box_faces(img, cam, cls.BASE, 0, 5, (40, 40, 200))
        q = cam(at_y(cls.SHELL, 5)); top_ring = at_y(rect_xz(-35, -25, 35, 25), 45)
        for a, b in zip(range(4), [1, 2, 3, 0]):
            P = np.array([at_y(cls.SHELL, 5)[a], at_y(cls.SHELL, 5)[b], top_ring[b], top_ring[a]])
            if cam.depth(P).mean() < cam.depth([[0, 25, 0]])[0]: fill(img, cam, P, (40, 160, 230))
        fill(img, cam, top_ring, (60, 140, 60))
        cv2.imwrite(str(d / 'top.png'), img)
        cfg = {'template': 'slab', 'top': {'photo': 'top.png', 'corners': corners_of(cam, 200, 140, 5).tolist(), 'width_mm': 200, 'plane': 'base'},
               'outline': (cam(at_y(rect_xz(-99, -69, 99, 69), 5)) / cam.size).tolist(),
               'layers': [{'name': 'base', 'height_mm': 5, 'texture': 'top', 'material': {'color': [0.1, 0.6, 0.9]}},
                          {'name': 'shell', 'height_mm': 40, 'taper_mm': 15, 'outline_at': 'bottom', 'texture': 'top', 'side_texture': 'top',
                           'outline': (q / cam.size).tolist()}]}
        cls.rep, path = build(cfg, d); cls.cfg = cfg
        cls.g, cls.raw, acc, image, cls.mesh = read_glb(path); cls.acc, cls.image = staticmethod(acc), staticmethod(image)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def bbox(self, prim):
        a = self.g['accessors'][prim['attributes']['POSITION']]; return np.array(a['min']) * 1000, np.array(a['max']) * 1000

    def test_tapered_layer_is_smaller_on_top(self):
        check_glb(self, self.g, self.raw)
        prims = self.mesh['shell']; lo, hi = self.bbox(prims[0])
        self.assertAlmostEqual(hi[0] - lo[0], 100 - 30, delta=2.5); self.assertAlmostEqual(hi[2] - lo[2], 80 - 30, delta=2.5)
        self.assertAlmostEqual(lo[1], 45, delta=0.01)
        lo, hi = self.bbox(prims[-1])
        self.assertAlmostEqual(hi[0] - lo[0], 100, delta=2); self.assertAlmostEqual(lo[1], 5, delta=0.01)
        L = self.rep['layers'][1]; self.assertEqual(L['taper_mm'], 15); self.assertEqual(L['outline'], 'own')

    def test_side_texture_splits_the_walls(self):
        prims = self.mesh['shell']
        self.assertEqual([('TEXCOORD_0' in p['attributes']) for p in prims], [True, True, False])
        lit, rest = (self.acc(prims[k]['attributes']['NORMAL']) for k in (1, 2))
        self.assertGreater(lit[:, 2].max(), 0.5)            # the front wall faces the camera
        self.assertGreater(lit[:, 2].min(), -0.5)           # the back wall does not
        self.assertLess(rest[:, 2].min(), -0.5)

    def test_hidden_area_gets_the_layer_colour(self):
        prim = self.mesh['base'][0]; img = self.image(prim['material'])
        self.assertTrue(self.rep['layers'][0]['own_texture'])
        b = self.rep['texture_bounds_mm']; ppm = img.shape[1] / (b[2] - b[0])
        px = lambda x, z: img[int((z + 70 - b[1]) * ppm), int((x + 100 - b[0]) * ppm)].astype(int)
        np.testing.assert_allclose(px(0, -55), [230, 153, 26], atol=14)        # behind the shell: material colour
        self.assertGreater(np.abs(px(0, 60) - [230, 153, 26]).max(), 60)      # in front: the photo
        self.assertFalse(self.rep['layers'][1]['own_texture'])
        wide, _ = build({**self.cfg, 'hidden_margin_mm': 6}, self.tmp.name, 'wide')            # a larger margin hides more
        self.assertGreater(wide['layers'][0]['hidden_fraction'], self.rep['layers'][0]['hidden_fraction'] + 0.01)


class LayersAndCardsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(); d = Path(cls.tmp.name); cam = camera(50, az=-20, dist=520, target=(0, 10, 0))
        img = np.full((900, 1200, 3), (150, 160, 170), np.uint8)
        box_faces(img, cam, rect_xz(-75, -50, 75, 50), 0, 10, (200, 200, 200))
        cv2.imwrite(str(d / 'top.png'), img)
        card = np.zeros((300, 400, 3), np.uint8); card[:, :, 2] = np.linspace(0, 255, 400)[None]; card[:, :, 1] = 90
        cv2.imwrite(str(d / 'card.png'), card)
        cls.feet = {'front': (-40, -20), 'back': (40, -20), 'right': (-40, 25), 'left': (40, 25)}
        cards = [{'name': f'c_{k}', 'photo': 'card.png', 'outline': [[0.1, 0.2], [0.9, 0.2], [0.9, 0.8], [0.1, 0.8]], 'height_mm': 45,
                  'at': (cam([[x, 10, z]])[0] / cam.size).tolist(), 'photo_right': k, 'thickness_mm': 2} for k, (x, z) in cls.feet.items()]
        cfg = {'template': 'slab', 'top': {'photo': 'top.png', 'corners': corners_of(cam, 150, 100, 10).tolist(), 'width_mm': 150, 'plane': 'A'},
               'layers': [{'name': 'A', 'height_mm': 10, 'outline': corners_of(cam, 150, 100, 10).tolist()},
                          {'name': 'B', 'height_mm': 20, 'outline': (cam(at_y(rect_xz(-10, -20, 50, 40), 30)) / cam.size).tolist()},
                          {'name': 'C', 'profile': [[0, 0], [18, 5], [26, 12], [32, 26], [35, 45]], 'base_mm': 10,
                           'outline': (cam(at_y(rect_xz(-60, -50, 60, 50), 10)) / cam.size).tolist(), 'outline_at': 'bottom'}],
               'cards': cards}
        cls.rep, path = build(cfg, d)
        cls.g, cls.raw, acc, image, cls.mesh = read_glb(path); cls.acc, cls.image = staticmethod(acc), staticmethod(image)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def extent(self, name):
        ps = [self.acc(p['attributes']['POSITION']) * 1000 for p in self.mesh[name]]
        P = np.concatenate(ps); return P.min(0), P.max(0)

    def test_layers_have_their_own_outlines(self):
        check_glb(self, self.g, self.raw)
        lo, hi = self.extent('A'); np.testing.assert_allclose([lo[0], lo[2], hi[0], hi[2]], [-75, -50, 75, 50], atol=1.5)
        lo, hi = self.extent('B'); np.testing.assert_allclose([lo[0], lo[2], hi[0], hi[2]], [-10, -20, 50, 40], atol=1.5)
        self.assertAlmostEqual(hi[1], 30, places=3)

    def test_profile_rings_follow_the_insets(self):
        L = self.rep['layers'][2]; self.assertEqual((L['y0_mm'], L['y1_mm'], L['rings']), (10, 45, 5))
        P = self.acc(self.mesh['C'][-1]['attributes']['POSITION']) * 1000
        for hgt, ins in [[0, 0], [18, 5], [26, 12], [32, 26]]:
            Q = P[np.abs(P[:, 1] - (10 + hgt)) < 1e-3]
            self.assertAlmostEqual(np.ptp(Q[:, 0]), 120 - 2 * ins, delta=1.5)
            self.assertAlmostEqual(np.ptp(Q[:, 2]), 100 - 2 * ins, delta=1.5)
        T = self.acc(self.mesh['C'][0]['attributes']['POSITION']) * 1000
        self.assertAlmostEqual(np.ptp(T[:, 0]), 30, delta=1.5); self.assertAlmostEqual(T[:, 1].max(), 45, places=3)
        N = self.acc(self.mesh['C'][-1]['attributes']['NORMAL'])
        side = P[:, 1] > 10.5
        self.assertTrue((np.sum(N[side][:, [0, 2]] * P[side][:, [0, 2]], 1) > 0).all())      # walls face outwards

    def test_cards_stand_upright_facing_the_right_way(self):
        size = {c['name']: c for c in self.rep['cards']}
        for k, (x, z) in self.feet.items():
            c = size[f'c_{k}']; self.assertEqual(c['size_mm'], [80.0, 45.0])
            np.testing.assert_allclose(c['foot_mm'], [x, 10, z], atol=0.8)
            lo, hi = self.extent(f'c_{k}'); ext = hi - lo
            self.assertAlmostEqual(lo[1], 10, delta=0.01); self.assertAlmostEqual(ext[1], 45, delta=0.01)
            along, across = (2, 0) if k in ('front', 'back') else (0, 2)
            self.assertAlmostEqual(ext[along], 80, delta=0.01); self.assertAlmostEqual(ext[across], 2, delta=0.01)
            self.assertAlmostEqual((lo[along] + hi[along]) / 2, (x, z)[along // 2], delta=0.8)
            U = np.array({'front': (0, 0, 1), 'back': (0, 0, -1), 'right': (1, 0, 0), 'left': (-1, 0, 0)}[k], float)
            face = self.mesh[f'c_{k}'][0]
            uv = self.acc(face['attributes']['TEXCOORD_0']); P = self.acc(face['attributes']['POSITION'])
            self.assertGreater(np.corrcoef(P @ U, uv[:, 0])[0, 1], 0.99)          # the photo's right is U: not mirrored
            self.assertLess(np.corrcoef(P[:, 1], uv[:, 1])[0, 1], -0.99)          # photo up is world up


# ------------------------------------------------------------------ the craft example (an invented paper-plate turtle)
def rounded_rect(w, d, r, n=10):
    pts = []
    for cx, cz, a0 in ((w / 2 - r, d / 2 - r, 0), (-(w / 2 - r), d / 2 - r, 90), (-(w / 2 - r), -(d / 2 - r), 180), (w / 2 - r, -(d / 2 - r), 270)):
        t = np.radians(np.linspace(a0, a0 + 90, n)); pts += list(zip(cx + r * np.cos(t), cz + r * np.sin(t)))
    return np.array(pts)


def notched_circle(r, n=96, notch=12.0):
    th = np.linspace(0, 2 * np.pi, n, endpoint=False); rr = np.full(n, r)
    for c in np.radians([45, 135, 225, 315]):
        dd = np.abs((th - c + np.pi) % (2 * np.pi) - np.pi)
        rr = np.minimum(rr, r - notch * np.clip(1 - dd / np.radians(8), 0, 1))
    return np.stack([rr * np.cos(th), rr * np.sin(th)], 1)


def craft_scene(folder):
    """Write top.png and head.png of an invented paper-plate turtle; return a config whose positions match them."""
    cam = camera(50, dist=520, target=(0, 20, 0)); fr = lambda P: np.round(cam(P) / cam.size, 3).tolist()
    head = np.full((450, 500, 3), 235, np.uint8); hm = np.zeros((450, 500), np.uint8)
    cv2.fillPoly(hm, [rounded_rect(300, 250, 60).astype(np.int32) + [250, 205]], 255)
    head[hm > 0] = (70, 170, 90)
    for x in (190, 310):
        cv2.circle(head, (x, 170), 28, (255, 255, 255), -1); cv2.circle(head, (x, 175), 12, (20, 20, 20), -1)
    cv2.ellipse(head, (250, 250), (50, 25), 0, 10, 170, (40, 40, 200), 8)
    cv2.imwrite(str(folder / 'head.png'), head)

    img = np.full((900, 1200, 3), (150, 160, 170), np.uint8)
    img = (img * np.linspace(0.85, 1.05, 900)[:, None, None]).clip(0, 255).astype(np.uint8)
    plate = notched_circle(110)
    fill(img, cam, at_y(plate, 0), (170, 185, 195)); fill(img, cam, at_y(plate, 3), (90, 170, 90))
    fill(img, cam, at_y(notched_circle(88, notch=0), 3), (215, 230, 240))
    th = np.linspace(0, 2 * np.pi, 40); fill(img, cam, at_y(np.c_[-85 + 14 * np.cos(th), 30 + 9 * np.sin(th)], 3), (70, 80, 90))   # a shadow
    bot, tp = at_y(rounded_rect(130, 110, 30), 3), at_y(rounded_rect(90, 70, 10), 48)
    quads = []
    for a in range(len(bot)):
        b = (a + 1) % len(bot); P = np.array([bot[a], bot[b], tp[b], tp[a]])
        n = np.cross(P[1] - P[0], P[3] - P[0]); n = -n if n @ (P.mean(0) - [0, 25, 0]) < 0 else n
        if n @ (cam.eye - P.mean(0)) > 0:
            nz = unit(n)[2]; quads.append((cam.depth(P).mean(), P, (40, 140, 240) if nz > 0.6 else (60, 200, 230)))
    for _, P, c in sorted(quads, key=lambda t: -t[0]):
        fill(img, cam, P, c)
    fill(img, cam, tp, (60, 120, 50))
    for x, z in ((-25, -15), (25, -15), (0, 15), (-25, 18), (25, 18)):
        hx = np.radians(np.arange(6) * 60); fill(img, cam, at_y(np.c_[x + 9 * np.cos(hx), z + 9 * np.sin(hx)], 48), (80, 200, 120))
    spots = [(-12, 0), (12, 0)]
    for x, z in spots:
        fill(img, cam, at_y(np.c_[x + 6 * np.cos(th), z + 6 * np.sin(th)], 48), (40, 60, 120))
    to_world = lambda u, v: [0.2 * (u - 250), 3 + 0.2 * (330 - v), 85.0]
    src = np.float32([[0, 0], [500, 0], [500, 450], [0, 450]])
    Hh = cv2.getPerspectiveTransform(src, cam(np.array([to_world(*p) for p in src])).astype(np.float32))
    warped = cv2.warpPerspective(head, Hh, (1200, 900)); wm = cv2.warpPerspective(hm, Hh, (1200, 900))
    img[wm > 128] = warped[wm > 128]
    cv2.imwrite(str(folder / 'top.png'), img)

    rim = np.radians([0, 70, 110, 160, 200, 250, 290])
    head_ol = (rounded_rect(294, 244, 57, n=5) + [250, 205]) / [500, 450]
    return {
        'template': 'slab',
        'top': {'photo': 'top.png', 'width_mm': 220, 'plane': 'plate',
                'circle': {'rim': fr(at_y(np.c_[110 * np.cos(rim), 110 * np.sin(rim)], 3)), 'front': fr([[0, 3, 60]])[0]},
                'erase': [fr(at_y(np.c_[-85 + 22 * np.cos(th[::5]), 30 + 15 * np.sin(th[::5])], 3))]},
        'layers': [
            {'name': 'plate', 'height_mm': 3, 'outline': fr(at_y(notched_circle(108.5)[::3], 3)), 'texture': 'top',
             'material': {'color': [0.93, 0.9, 0.85], 'roughness': 0.8}},
            {'name': 'shell', 'height_mm': 45, 'outline': fr(at_y(rounded_rect(87, 67, 8.5, n=4), 48)), 'outline_at': 'top',
             'taper_mm': 20, 'texture': 'top', 'side_texture': 'top', 'material': {'color': [0.3, 0.55, 0.25], 'roughness': 0.8}}],
        'features': [{'name': 'spots', 'on': 'shell', 'shape': 'dome', 'diameter_mm': 12, 'height_mm': 4, 'texture': 'top',
                      'at': fr(at_y(spots, 48))}],
        'cards': [{'name': 'head', 'photo': 'head.png', 'outline': np.round(head_ol, 3).tolist(), 'height_mm': 48.8,
                   'at': fr([[0, 3, 85]])[0], 'on': 'plate', 'photo_right': 'right', 'thickness_mm': 1,
                   'material': {'color': [0.3, 0.65, 0.35]}}],
        'views': [{'name': 'photo', 'az': 0, 'el': 50, 'photo': 'top.png'}, {'name': 'side', 'az': 70, 'el': 20},
                  {'name': 'back', 'az': 200, 'el': 35}]}


class ExamplesTest(unittest.TestCase):
    EX = Path(__file__).resolve().parents[1] / 'examples'

    def test_craft_example_builds_on_a_synthetic_photo(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d); craft_scene(d)
            cfg = json.loads((self.EX / 'craft.example.json').read_text())
            rep, path = build(cfg, d)
            g, raw, *_ = read_glb(path); check_glb(self, g, raw)
        self.assertLess(rep['circle_fit']['rms_mm'], 1.5)
        self.assertAlmostEqual(rep['circle_fit']['elevation_deg'], 50, delta=3)
        self.assertEqual(rep['size_mm']['depth'], 220.0)
        self.assertEqual([m['name'] for m in g['meshes']], ['plate', 'shell', 'spots', 'head'])
        np.testing.assert_allclose(rep['cards'][0]['foot_mm'], [0, 3, 85], atol=3)
        np.testing.assert_allclose(rep['bbox_mm']['max'][1], 52, atol=1.5)
        self.assertTrue(rep['layers'][0]['own_texture'])

    def test_old_example_still_builds(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d); img = np.zeros((900, 1200, 3), np.uint8); img[:] = (120, 140, 160)
            cv2.circle(img, (600, 450), 200, (60, 60, 60), -1); cv2.imwrite(str(d / 'top.png'), img)
            rep, path = build(json.loads((self.EX / 'slab.example.json').read_text()), d)
            g, raw, *_ = read_glb(path); check_glb(self, g, raw)
        self.assertEqual([m['name'] for m in g['meshes']], ['base', 'lid', 'knobs', 'screws', 'port'])
        self.assertEqual(rep['size_mm']['height'], 34.0)


if __name__ == '__main__':
    unittest.main()
