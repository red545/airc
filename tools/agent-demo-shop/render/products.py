# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""Product photos for the agent demo's made-up shop (Steepwell), rendered with Blender's Cycles.

Every object is modelled here from simple shapes (lathe profiles, curves, boxes); no outside models, textures or brands.
Usage: python3 products.py <out dir> [name ...] [--samples N] [--size W]  (needs the `bpy` module, Blender 4.2+).
"""
import math
import sys

import bpy  # first: it makes bmesh and mathutils importable
import bmesh
from mathutils import Vector

TAU = math.tau


# MARK: Scene

def reset():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    s = bpy.context.scene
    s.render.engine = "CYCLES"
    s.cycles.device = "CPU"
    s.cycles.use_denoising = True
    s.cycles.max_bounces = 10
    s.cycles.transmission_bounces = 10
    s.cycles.glossy_bounces = 6
    try:
        s.view_settings.view_transform = "AgX"
        s.view_settings.look = "AgX - Medium High Contrast"
        s.view_settings.exposure = -0.55
    except TypeError:
        pass
    s.render.film_transparent = False
    s.render.image_settings.file_format = "PNG"
    s.render.image_settings.color_depth = "8"
    w = bpy.data.worlds.new("world")
    w.use_nodes = True
    bg = w.node_tree.nodes["Background"]
    bg.inputs[0].default_value = (0.92, 0.9, 0.87, 1)
    bg.inputs[1].default_value = 0.35
    s.world = w
    return s


def mat(name, color, rough=0.5, metal=0.0, coat=0.0, aniso=0.0, transmission=0.0, ior=1.45, emission=None, strength=0.0, alpha=1.0):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    p = m.node_tree.nodes["Principled BSDF"]
    p.inputs["Base Color"].default_value = (*color, 1)
    p.inputs["Roughness"].default_value = rough
    p.inputs["Metallic"].default_value = metal
    p.inputs["IOR"].default_value = ior
    if coat:
        p.inputs["Coat Weight"].default_value = coat
        p.inputs["Coat Roughness"].default_value = 0.08
    if aniso:
        p.inputs["Anisotropic"].default_value = aniso
    if transmission:
        p.inputs["Transmission Weight"].default_value = transmission
    if emission:
        p.inputs["Emission Color"].default_value = (*emission, 1)
        p.inputs["Emission Strength"].default_value = strength
    if alpha < 1:
        p.inputs["Alpha"].default_value = alpha
    return m


def wood(name, light=(0.24, 0.12, 0.06), dark=(0.09, 0.045, 0.02), scale=2.5, rough=0.42):
    """Procedural grain: stretched noise through a wave texture, no image files."""
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    p = nt.nodes["Principled BSDF"]
    p.inputs["Roughness"].default_value = rough
    tc = nt.nodes.new("ShaderNodeTexCoord")
    mp = nt.nodes.new("ShaderNodeMapping")
    mp.inputs["Scale"].default_value = (9, 9, 0.5)
    wave = nt.nodes.new("ShaderNodeTexWave")
    wave.bands_direction = "X"
    wave.inputs["Scale"].default_value = scale
    wave.inputs["Distortion"].default_value = 6
    wave.inputs["Detail"].default_value = 3
    ramp = nt.nodes.new("ShaderNodeValToRGB")
    ramp.color_ramp.elements[0].color = (*dark, 1)
    ramp.color_ramp.elements[1].color = (*light, 1)
    nt.links.new(tc.outputs["Object"], mp.inputs["Vector"])
    nt.links.new(mp.outputs["Vector"], wave.inputs["Vector"])
    nt.links.new(wave.outputs["Fac"], ramp.inputs["Fac"])
    nt.links.new(ramp.outputs["Color"], p.inputs["Base Color"])
    return m


def link(obj):
    bpy.context.scene.collection.objects.link(obj)
    return obj


def lathe(name, profile, material, steps=96, smooth=True, subsurf=1, loc=(0, 0, 0)):
    """Spins an (r, z) profile around Z."""
    me = bpy.data.meshes.new(name)
    bm = bmesh.new()
    verts = [bm.verts.new((r, 0, z)) for r, z in profile]
    edges = [bm.edges.new((verts[i], verts[i + 1])) for i in range(len(verts) - 1)]
    bmesh.ops.spin(bm, geom=verts + edges, axis=(0, 0, 1), cent=(0, 0, 0), angle=TAU, steps=steps, use_duplicate=False)
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-5)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm.to_mesh(me)
    bm.free()
    o = link(bpy.data.objects.new(name, me))
    o.location = loc
    o.data.materials.append(material)
    if smooth:
        for f in o.data.polygons:
            f.use_smooth = True
    if subsurf:
        md = o.modifiers.new("sub", "SUBSURF")
        md.levels = md.render_levels = subsurf
    return o


def lip(o, z0, z1, reach, rise=0.06):
    """Pulls the top front (+X) of a lathed body out into a pouring lip."""
    for v in o.data.vertices:
        x, y, z = v.co
        if z <= z0:
            continue
        r = math.hypot(x, y)
        w = max(0.0, math.cos(math.atan2(y, x))) ** 5 * min(1.0, r / 0.3)
        t = min(1.0, (z - z0) / (z1 - z0)) ** 2
        v.co.x += reach * w * t
        v.co.z += rise * w * t


def tube(name, points, radius, material, radii=None, res=24, caps=True):
    """A smooth bevelled curve through points (bezier, auto handles); radii scales the bevel along it."""
    cu = bpy.data.curves.new(name, "CURVE")
    cu.dimensions = "3D"
    cu.bevel_depth = radius
    cu.bevel_resolution = 8
    cu.resolution_u = res
    cu.use_fill_caps = caps
    sp = cu.splines.new("BEZIER")
    sp.bezier_points.add(len(points) - 1)
    for i, p in enumerate(points):
        bp = sp.bezier_points[i]
        bp.co = p
        bp.handle_left_type = bp.handle_right_type = "AUTO"
        if radii:
            bp.radius = radii[i]
    o = link(bpy.data.objects.new(name, cu))
    o.data.materials.append(material)
    return o


def box(name, size, material, loc=(0, 0, 0), bevel=0.02, segments=6):
    me = bpy.data.meshes.new(name)
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1)
    bm.to_mesh(me)
    bm.free()
    o = link(bpy.data.objects.new(name, me))
    o.scale = size
    o.location = loc
    o.data.materials.append(material)
    bpy.context.view_layer.objects.active = o
    o.select_set(True)
    bpy.ops.object.transform_apply(scale=True)
    o.select_set(False)
    if bevel:
        md = o.modifiers.new("bevel", "BEVEL")
        md.width = bevel
        md.segments = segments
    for f in o.data.polygons:
        f.use_smooth = True
    return o


def text(body, size, material, loc, rot=(math.radians(90), 0, 0), font_bold=False):
    cu = bpy.data.curves.new("t", "FONT")
    cu.body = body
    cu.size = size
    cu.align_x = "CENTER"
    cu.align_y = "CENTER"
    cu.extrude = 0.001
    o = link(bpy.data.objects.new("text", cu))
    o.location = loc
    o.rotation_euler = rot
    o.data.materials.append(material)
    return o


def area(name, loc, target, size, energy, color=(1, 1, 1), shape="RECTANGLE", size_y=None):
    l = bpy.data.lights.new(name, "AREA")
    l.energy = energy
    l.color = color
    l.shape = shape
    l.size = size
    if size_y:
        l.size_y = size_y
    o = link(bpy.data.objects.new(name, l))
    o.location = loc
    aim(o, target)
    return o


def aim(o, target):
    d = Vector(target) - o.location
    o.rotation_euler = d.to_track_quat("-Z", "Y").to_euler()


def camera(loc, target, lens=85, shift_y=0.0):
    c = bpy.data.cameras.new("cam")
    c.lens = lens
    c.shift_y = shift_y
    c.dof.use_dof = False
    o = link(bpy.data.objects.new("cam", c))
    o.location = loc
    aim(o, target)
    bpy.context.scene.camera = o
    return o


def sweep(color, rough=0.85, width=40, depth=30, height=20, curve=3.0):
    """A seamless paper backdrop: a floor that bends up into a wall."""
    wall_y = 5.0
    # floor from the front to the bend, a quarter circle, then the wall up
    pts = [(-depth / 2, 0)]
    for i in range(0, 17):
        a = i / 16 * (math.pi / 2)
        pts.append((wall_y - curve + curve * math.sin(a), curve - curve * math.cos(a)))
    pts.append((wall_y, height))
    me = bpy.data.meshes.new("sweep")
    bm = bmesh.new()
    rows = []
    for x, z in pts:
        rows.append([bm.verts.new((-width / 2, x, z)), bm.verts.new((width / 2, x, z))])
    for a, b in zip(rows, rows[1:]):
        bm.faces.new((a[0], a[1], b[1], b[0]))
    bm.to_mesh(me)
    bm.free()
    o = link(bpy.data.objects.new("sweep", me))
    for f in o.data.polygons:
        f.use_smooth = True
    o.data.materials.append(mat("paper", color, rough=rough))
    return o


def studio(color, key=520, fill=150, rim=300, cam_loc=(0, -9.5, 3.6), target=(0, 0, 0.9), lens=70, shift_y=0.0, light_scale=1.0):
    """Soft product lighting: a big key softbox left, a fill right, a rim behind, on a paper sweep."""
    sweep(color)
    area("key", (-4.5 * light_scale, -4.0 * light_scale, 5.5 * light_scale), (0, 0, 0.8), 4.5, key, (1.0, 0.97, 0.93))
    area("fill", (5.0 * light_scale, -3.5 * light_scale, 2.6 * light_scale), (0, 0, 0.8), 5.0, fill, (0.93, 0.96, 1.0))
    area("rim", (1.5, 4.5, 4.5), (0, 0, 1.0), 3.0, rim)
    area("top", (0, -0.5, 7.5), (0, 0, 0), 6.0, 120)
    camera(cam_loc, target, lens=lens, shift_y=shift_y)


# MARK: Products

def pour_kettle(body_color=(0.035, 0.037, 0.04), x=0.0, y=0.0, rot=0.0, display="93°"):
    """Steepwell Pour: a gooseneck kettle, matte slate, walnut handle and knob, on its temperature base."""
    body = mat("pour-body", body_color, rough=0.48, coat=0.25)
    trim = mat("pour-trim", (0.6, 0.6, 0.6), rough=0.22, metal=1.0, aniso=0.5)
    walnut = wood("walnut")
    base_m = mat("pour-base", (0.025, 0.025, 0.028), rough=0.35)
    lcd = mat("pour-lcd", (0.0, 0.0, 0.0), emission=(1.0, 0.62, 0.28), strength=6.0)
    parts = []
    parts.append(lathe("base", [(0, 0), (0.86, 0), (0.9, 0.025), (0.9, 0.13), (0.86, 0.16), (0, 0.16)], base_m))
    parts.append(lathe("ring", [(0.70, 0.158), (0.72, 0.17), (0.72, 0.19), (0.70, 0.195)], trim, subsurf=0))
    parts.append(lathe("body", [(0, 0.17), (0.64, 0.17), (0.70, 0.2), (0.72, 0.3), (0.72, 1.06), (0.70, 1.16), (0.62, 1.23),
                                (0.52, 1.26), (0.5, 1.265), (0.0, 1.265)], body))
    parts.append(lathe("lid", [(0, 1.39), (0.2, 1.385), (0.4, 1.35), (0.5, 1.30), (0.53, 1.27), (0.53, 1.255), (0, 1.255)], body))
    parts.append(lathe("knob", [(0, 1.38), (0.11, 1.38), (0.12, 1.43), (0.1, 1.5), (0.0, 1.51)], walnut))
    # Handle: out from the top of the body, down, back in near the base.
    parts.append(tube("handle", [(-0.66, 0, 1.08), (-1.05, 0, 1.12), (-1.2, 0, 0.92), (-1.14, 0, 0.55), (-0.92, 0, 0.38), (-0.7, 0, 0.38)],
                      0.085, walnut, radii=[0.8, 1.0, 1.05, 1.05, 0.95, 0.8]))
    # The gooseneck: low out of the body, up in an S, a fine tip.
    parts.append(tube("spout", [(0.6, 0, 0.34), (0.95, 0, 0.36), (1.22, 0, 0.62), (1.3, 0, 1.0), (1.46, 0, 1.26), (1.72, 0, 1.24)],
                      0.075, body, radii=[1.25, 1.1, 0.95, 0.8, 0.65, 0.5]))
    # The base's temperature readout, facing front-left.
    t = text(display, 0.11, lcd, (0, -0.905, 0.085))
    parts.append(t)
    for p in parts:
        p.rotation_euler.z += 0  # keep
    group(parts, x, y, rot)
    return parts


def rapid_kettle(x=0.0, y=0.0, rot=0.0):
    """Steepwell Rapid: a 1.7 L brushed-steel jug kettle, black handle and base, a blue-lit window."""
    steel = mat("rapid-steel", (0.72, 0.72, 0.71), rough=0.28, metal=1.0, aniso=0.75)
    black = mat("rapid-black", (0.02, 0.02, 0.022), rough=0.4, coat=0.2)
    window = mat("rapid-window", (0.05, 0.12, 0.2), rough=0.08, coat=1.0)
    glow = mat("rapid-glow", (0.0, 0.0, 0.0), emission=(0.35, 0.65, 1.0), strength=9.0)
    parts = []
    parts.append(lathe("base", [(0, 0), (0.9, 0), (0.93, 0.03), (0.93, 0.12), (0.88, 0.15), (0, 0.15)], black))
    parts.append(lathe("glow", [(0.80, 0.148), (0.82, 0.152), (0.82, 0.16), (0.80, 0.162)], glow, subsurf=0))
    parts.append(lathe("bottom", [(0, 0.16), (0.78, 0.16), (0.82, 0.2), (0.82, 0.3)], black))
    b = lathe("body", [(0.82, 0.3), (0.8, 0.6), (0.74, 1.0), (0.67, 1.35), (0.62, 1.55), (0.6, 1.6), (0.56, 1.6), (0.3, 1.6), (0.0, 1.6)], steel)
    lip(b, 1.2, 1.6, 0.3, 0.07)
    parts.append(b)
    parts.append(lathe("lid", [(0, 1.66), (0.3, 1.655), (0.47, 1.63), (0.5, 1.6), (0, 1.6)], black))
    parts.append(lathe("button", [(0, 1.7), (0.14, 1.7), (0.15, 1.66), (0, 1.66)], steel))
    parts.append(tube("handle", [(-0.62, 0, 1.52), (-1.02, 0, 1.5), (-1.16, 0, 1.2), (-1.08, 0, 0.6), (-0.86, 0, 0.4), (-0.78, 0, 0.42)],
                      0.1, black, radii=[0.85, 1.0, 1.0, 1.0, 0.9, 0.8]))
    group(parts, x, y, rot)
    return parts


def cone(color=(0.82, 0.72, 0.58), x=0.0, y=0.0, z=0.0, rot=0.0):
    ceramic = mat("cone", color, rough=0.32, coat=0.4)
    p = [lathe("cone", [(0.0, 0.18), (0.34, 0.18), (0.34, 0.0), (0.44, 0.0), (0.44, 0.11), (0.78, 0.12), (0.8, 0.16), (0.46, 0.19),
                         (0.84, 0.98), (0.88, 1.04), (0.82, 1.06), (0.3, 0.29), (0.0, 0.29)], ceramic, steps=128)]
    group(p, x, y, rot, z)
    return p


def carafe(x=0.0, y=0.0, rot=0.0, coffee=True):
    glass = mat("glass", (1, 1, 1), rough=0.0, transmission=1.0, ior=1.47)
    brew = mat("coffee", (0.05, 0.022, 0.008), rough=0.04, ior=1.34)
    oak = wood("oak", light=(0.72, 0.55, 0.36), dark=(0.5, 0.35, 0.2), scale=9)
    parts = [lathe("carafe", [(0, 0), (0.55, 0), (0.62, 0.05), (0.66, 0.35), (0.58, 0.72), (0.44, 0.95), (0.42, 1.2), (0.48, 1.3),
                               (0.46, 1.32), (0.39, 1.22), (0.40, 0.95), (0.54, 0.72), (0.62, 0.36), (0.58, 0.08), (0.5, 0.04), (0, 0.04)], glass, steps=128)]
    if coffee:
        parts.append(lathe("brew", [(0, 0.045), (0.5, 0.045), (0.57, 0.09), (0.61, 0.36), (0.58, 0.55), (0, 0.55)], brew))
    parts.append(lathe("collar", [(0.43, 0.86), (0.53, 0.86), (0.5, 1.06), (0.43, 1.06)], oak, subsurf=0))
    group(parts, x, y, rot)
    return parts


def mug(color, x=0.0, y=0.0, rot=0.0):
    ceramic = mat("mug", color, rough=0.55, coat=0.15)
    inner = mat("mug-in", (0.93, 0.91, 0.87), rough=0.2, coat=0.6)
    parts = [lathe("mug", [(0, 0.0), (0.42, 0.0), (0.46, 0.03), (0.48, 0.8), (0.47, 0.84), (0.44, 0.84), (0.43, 0.08), (0, 0.08)], ceramic),
             lathe("mug-in", [(0.43, 0.79), (0.425, 0.1), (0.0, 0.1)], inner, subsurf=0)]
    parts.append(tube("mug-handle", [(-0.44, 0, 0.66), (-0.72, 0, 0.62), (-0.74, 0, 0.36), (-0.46, 0, 0.24)], 0.055, ceramic))
    group(parts, x, y, rot)
    return parts


def grinder(x=0.0, y=0.0, rot=0.0):
    steel = mat("g-steel", (0.7, 0.7, 0.69), rough=0.22, metal=1.0, aniso=0.6)
    dark = mat("g-dark", (0.03, 0.03, 0.03), rough=0.6)
    walnut = wood("g-walnut")
    parts = [lathe("g-body", [(0, 0), (0.3, 0), (0.32, 0.03), (0.32, 1.3), (0.3, 1.33), (0, 1.33)], steel),
             lathe("g-grip", [(0.325, 0.55), (0.335, 0.58), (0.335, 0.98), (0.325, 1.0)], dark, subsurf=0),
             lathe("g-cap", [(0, 1.33), (0.12, 1.33), (0.12, 1.42), (0, 1.42)], steel)]
    arm = box("g-arm", (1.05, 0.12, 0.06), steel, loc=(0.42, 0, 1.45), bevel=0.025)
    parts.append(arm)
    parts.append(lathe("g-knob", [(0, 1.48), (0.1, 1.48), (0.12, 1.62), (0.09, 1.72), (0, 1.74)], walnut))
    parts[-1].location.x = 0.86
    parts[-1].location.z = 0
    group(parts, x, y, rot)
    return parts


def scale_(x=0.0, y=0.0, rot=0.0, reading="18.0 g"):
    black = mat("s-black", (0.03, 0.03, 0.032), rough=0.38, coat=0.3)
    pad = mat("s-pad", (0.06, 0.06, 0.065), rough=0.8)
    lcd = mat("s-lcd", (0, 0, 0), emission=(0.95, 0.97, 1.0), strength=5.0)
    parts = [box("s-body", (1.5, 1.5, 0.13), black, loc=(0, 0, 0.065), bevel=0.05),
             box("s-pad", (1.3, 1.1, 0.02), pad, loc=(0, 0.12, 0.135), bevel=0.01)]
    parts.append(text(reading, 0.09, lcd, (0, -0.62, 0.135), rot=(0, 0, 0)))
    group(parts, x, y, rot)
    return parts


def group(parts, x, y, rot, z=0.0):
    e = link(bpy.data.objects.new("grp", None))
    for p in parts:
        p.parent = e
    e.location = (x, y, z)
    e.rotation_euler.z = rot
    return e


# MARK: Shots

SAND = (0.86, 0.82, 0.76)
SHOTS = {}


def shot(name, size=(1200, 1200)):
    def deco(f):
        SHOTS[name] = (f, size)
        return f
    return deco


@shot("pour")
def _():
    studio((0.80, 0.78, 0.74), cam_loc=(0.4, -9.5, 3.2), target=(0.1, 0, 0.82), lens=101)
    pour_kettle(rot=math.radians(-28))


@shot("pour-side")
def _():
    studio((0.80, 0.78, 0.74), cam_loc=(6.5, -7.0, 2.6), target=(0.25, 0, 0.8), lens=92)
    pour_kettle(rot=math.radians(-28))


@shot("pour-sage")
def _():
    studio((0.80, 0.82, 0.76), cam_loc=(0.4, -9.5, 3.2), target=(0.1, 0, 0.82), lens=101)
    pour_kettle(body_color=(0.36, 0.45, 0.38), rot=math.radians(-28))


@shot("rapid")
def _():
    studio((0.82, 0.83, 0.85), cam_loc=(0.3, -9.5, 3.4), target=(0.0, 0, 0.88), lens=78)
    rapid_kettle(rot=math.radians(-34))


@shot("rapid-side")
def _():
    studio((0.82, 0.83, 0.85), cam_loc=(-5.5, -7.5, 5.0), target=(0.0, 0, 0.85), lens=88)
    rapid_kettle(rot=math.radians(-34))


@shot("cone")
def _():
    studio((0.84, 0.79, 0.72), cam_loc=(0, -9.5, 4.6), target=(0, 0, 0.62), lens=124)
    cone()


@shot("carafe")
def _():
    studio((0.80, 0.80, 0.78), cam_loc=(0, -9.5, 3.4), target=(0, 0, 0.75), lens=114, key=700)
    carafe()


@shot("mugs")
def _():
    studio((0.82, 0.79, 0.74), cam_loc=(0, -9.5, 3.6), target=(0, 0, 0.5), lens=104)
    mug((0.82, 0.76, 0.66), x=-0.62, y=0.1, rot=math.radians(200))
    mug((0.33, 0.42, 0.34), x=0.62, y=-0.2, rot=math.radians(150))


@shot("grinder")
def _():
    studio((0.78, 0.76, 0.73), cam_loc=(0.5, -9.5, 3.6), target=(0.2, 0, 0.85), lens=107)
    grinder(rot=math.radians(-30))


@shot("scale")
def _():
    studio((0.80, 0.79, 0.77), cam_loc=(0, -6.5, 5.5), target=(0, 0, 0.1), lens=91)
    scale_()


@shot("hero", (2400, 1200))
def _():
    """A morning counter: the Pour kettle, a cone on a carafe on the scale, two mugs; window light from the left."""
    s = bpy.context.scene
    s.world.node_tree.nodes["Background"].inputs[0].default_value = (0.95, 0.9, 0.84, 1)
    s.world.node_tree.nodes["Background"].inputs[1].default_value = 0.25
    oak = wood("counter", light=(0.78, 0.62, 0.45), dark=(0.6, 0.45, 0.3), scale=3, rough=0.55)
    counter = box("counter", (30, 8, 0.4), oak, loc=(0, 2.0, -0.2), bevel=0.04)
    counter.rotation_euler.z = math.radians(90)
    counter.rotation_euler.z = 0
    wall = box("wall", (30, 0.2, 14), mat("plaster", (0.88, 0.83, 0.76), rough=0.95), loc=(0, 4.2, 6.5), bevel=0)
    pour_kettle(x=1.9, y=0.6, rot=math.radians(-25))
    scale_(x=4.3, y=0.4, rot=math.radians(4), reading="")
    carafe(x=4.3, y=0.45, rot=0)
    cone(x=4.3, y=0.45, z=1.18)
    mug((0.82, 0.76, 0.66), x=5.9, y=0.0, rot=math.radians(210))
    mug((0.33, 0.42, 0.34), x=6.7, y=1.3, rot=math.radians(160))
    sun = bpy.data.lights.new("sun", "SUN")
    sun.energy = 4.2
    sun.angle = math.radians(4)
    sun.color = (1.0, 0.92, 0.8)
    so = link(bpy.data.objects.new("sun", sun))
    so.rotation_euler = (math.radians(58), math.radians(-12), math.radians(-62))
    area("fill", (3, -8, 5), (0, 0, 1), 8, 900, (0.92, 0.95, 1.0))
    area("bounce", (-3, -6, 1.5), (0, 0, 1), 6, 250, (1.0, 0.95, 0.88))
    camera((2.4, -8.6, 2.4), (2.4, 0.8, 1.0), lens=36)


def main():
    args = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else sys.argv[1:]
    out = args[0]
    samples, size = 160, None
    names = []
    i = 1
    while i < len(args):
        if args[i] == "--samples":
            samples = int(args[i + 1]); i += 2
        elif args[i] == "--size":
            size = int(args[i + 1]); i += 2
        else:
            names.append(args[i]); i += 1
    for name in names or list(SHOTS):
        f, (w, h) = SHOTS[name]
        s = reset()
        f()
        s.cycles.samples = samples
        if size:
            h = round(h * size / w); w = size
        s.render.resolution_x, s.render.resolution_y = w, h
        s.render.resolution_percentage = 100
        s.render.filepath = f"{out}/{name}.png"
        bpy.ops.render.render(write_still=True)
        print("rendered", name, flush=True)


if __name__ == "__main__":
    main()
