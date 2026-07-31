# Blender에서 클대리 스타일의 얼굴 전용 3D 시안을 생성하고 렌더링한다.

import math
from pathlib import Path

import bpy
from mathutils import Vector


PROJECT_DIR = Path(__file__).resolve().parents[1]
OUTPUT_DIR = PROJECT_DIR / "artifacts" / "blender"
BLEND_PATH = OUTPUT_DIR / "claude-manager-head-v1.blend"
RENDER_PATH = OUTPUT_DIR / "claude-manager-head-v1.png"


def clear_scene():
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    for datablocks in (
        bpy.data.meshes,
        bpy.data.curves,
        bpy.data.materials,
        bpy.data.cameras,
        bpy.data.lights,
    ):
        for datablock in list(datablocks):
            if datablock.users == 0:
                datablocks.remove(datablock)


def make_material(name, color, roughness=0.48, metallic=0.0, specular=0.35):
    material = bpy.data.materials.new(name)
    material.use_nodes = True
    shader = material.node_tree.nodes.get("Principled BSDF")
    shader.inputs["Base Color"].default_value = (*color, 1.0)
    shader.inputs["Roughness"].default_value = roughness
    shader.inputs["Metallic"].default_value = metallic
    if "Specular IOR Level" in shader.inputs:
        shader.inputs["Specular IOR Level"].default_value = specular
    return material


def smooth_object(obj):
    if obj.type == "MESH":
        for polygon in obj.data.polygons:
            polygon.use_smooth = True


def add_uv_sphere(name, location, scale, material, rotation=(0.0, 0.0, 0.0), segments=64, rings=40):
    bpy.ops.mesh.primitive_uv_sphere_add(
        segments=segments,
        ring_count=rings,
        location=location,
        rotation=rotation,
    )
    obj = bpy.context.object
    obj.name = name
    obj.scale = scale
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    obj.data.materials.append(material)
    smooth_object(obj)
    return obj


def add_torus(name, location, major_radius, minor_radius, material, rotation=(0.0, 0.0, 0.0), scale=(1.0, 1.0, 1.0)):
    bpy.ops.mesh.primitive_torus_add(
        major_radius=major_radius,
        minor_radius=minor_radius,
        major_segments=64,
        minor_segments=16,
        location=location,
        rotation=rotation,
    )
    obj = bpy.context.object
    obj.name = name
    obj.scale = scale
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    obj.data.materials.append(material)
    smooth_object(obj)
    return obj


def add_bezier_curve(name, points, bevel_depth, material, bevel_resolution=5, cyclic=False):
    curve_data = bpy.data.curves.new(name=f"{name}Curve", type="CURVE")
    curve_data.dimensions = "3D"
    curve_data.resolution_u = 18
    curve_data.bevel_depth = bevel_depth
    curve_data.bevel_resolution = bevel_resolution
    curve_data.resolution_u = 20
    curve_data.materials.append(material)

    spline = curve_data.splines.new("BEZIER")
    spline.bezier_points.add(len(points) - 1)
    for bezier_point, coordinate in zip(spline.bezier_points, points):
        bezier_point.co = coordinate
        bezier_point.handle_left_type = "AUTO"
        bezier_point.handle_right_type = "AUTO"
    spline.use_cyclic_u = cyclic

    obj = bpy.data.objects.new(name, curve_data)
    bpy.context.collection.objects.link(obj)
    return obj


def add_rounded_cube(name, location, scale, material, bevel=0.18, rotation=(0.0, 0.0, 0.0)):
    bpy.ops.mesh.primitive_cube_add(location=location, rotation=rotation)
    obj = bpy.context.object
    obj.name = name
    obj.scale = scale
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    obj.data.materials.append(material)
    bevel_modifier = obj.modifiers.new(name="Soft edges", type="BEVEL")
    bevel_modifier.width = bevel
    bevel_modifier.segments = 5
    smooth_object(obj)
    return obj


def look_at(obj, target):
    direction = Vector(target) - obj.location
    obj.rotation_euler = direction.to_track_quat("-Z", "Y").to_euler()


def build_head_mesh(material):
    bpy.ops.mesh.primitive_uv_sphere_add(segments=96, ring_count=64, location=(0.0, 0.0, 2.35))
    head = bpy.context.object
    head.name = "ClaudeManager_Head"
    for vertex in head.data.vertices:
        normalized_z = vertex.co.z
        height = (normalized_z + 1.0) * 0.5
        cheek = math.sin(math.pi * min(max(height, 0.0), 1.0))
        lower_taper = 0.80 + 0.20 * min(max((height - 0.02) / 0.44, 0.0), 1.0)
        upper_taper = 1.0 - 0.10 * max((height - 0.72) / 0.28, 0.0)
        vertex.co.x *= 1.12 * lower_taper * upper_taper * (0.97 + 0.05 * cheek)
        vertex.co.y *= 0.82 * (0.96 + 0.06 * cheek)
        vertex.co.z *= 1.39
        if vertex.co.y < -0.25 and normalized_z < -0.08:
            vertex.co.y -= 0.045 * (1.0 - height)
    head.data.materials.append(material)
    smooth_object(head)
    return head


def build_hair(materials):
    hair_dark, hair_mid = materials

    cap = add_uv_sphere(
        "Hair_Cap",
        (0.0, 0.14, 3.02),
        (1.15, 0.80, 0.80),
        hair_dark,
    )
    for vertex in cap.data.vertices:
        if vertex.co.z < -0.12:
            vertex.co.z = -0.12 + (vertex.co.z + 0.12) * 0.16

    locks = [
        ("Hair_Lock_LTemple", (-0.91, -0.36, 3.04), (0.31, 0.31, 0.60), (0.0, math.radians(-24), math.radians(-4)), hair_mid),
        ("Hair_Lock_LCrown", (-0.59, -0.29, 3.34), (0.35, 0.36, 0.61), (0.0, math.radians(-49), math.radians(-5)), hair_mid),
        ("Hair_Lock_Crown", (-0.18, -0.37, 3.44), (0.36, 0.37, 0.64), (0.0, math.radians(-64), math.radians(-2)), hair_dark),
        ("Hair_Lock_Sweep1", (0.20, -0.48, 3.41), (0.34, 0.34, 0.66), (0.0, math.radians(-68), math.radians(3)), hair_mid),
        ("Hair_Lock_Sweep2", (0.55, -0.49, 3.30), (0.32, 0.32, 0.62), (0.0, math.radians(-52), math.radians(6)), hair_dark),
        ("Hair_Lock_Right", (0.86, -0.31, 3.09), (0.31, 0.31, 0.55), (0.0, math.radians(-23), math.radians(7)), hair_mid),
        ("Hair_Lock_Fringe1", (-0.10, -0.64, 3.09), (0.19, 0.20, 0.48), (0.0, math.radians(-38), math.radians(-8)), hair_mid),
        ("Hair_Lock_Fringe2", (0.26, -0.67, 3.07), (0.19, 0.19, 0.45), (0.0, math.radians(-28), math.radians(7)), hair_dark),
        ("Hair_Sideburn_Left", (-1.03, -0.17, 2.70), (0.19, 0.21, 0.43), (0.0, math.radians(-4), 0.0), hair_dark),
        ("Hair_Sideburn_Right", (1.03, -0.15, 2.69), (0.19, 0.21, 0.41), (0.0, math.radians(5), 0.0), hair_dark),
    ]
    for name, location, scale, rotation, material in locks:
        add_uv_sphere(name, location, scale, material, rotation=rotation, segments=56, rings=36)

    hair_meshes = [
        obj
        for obj in bpy.context.scene.objects
        if obj.type == "MESH" and (obj.name == "Hair_Cap" or obj.name.startswith("Hair_Lock_"))
    ]
    bpy.ops.object.select_all(action="DESELECT")
    for obj in hair_meshes:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = cap
    bpy.ops.object.join()
    cap.name = "Hair_Sculpt"
    cap.data.remesh_voxel_size = 0.038
    cap.data.remesh_voxel_adaptivity = 0.0
    bpy.ops.object.voxel_remesh()
    polish = cap.modifiers.new(name="Hair sculpt polish", type="SMOOTH")
    polish.factor = 0.52
    polish.iterations = 5
    bpy.context.view_layer.objects.active = cap
    bpy.ops.object.modifier_apply(modifier=polish.name)
    cap.data.materials.clear()
    cap.data.materials.append(hair_dark)
    smooth_object(cap)

def build_face(materials):
    skin, skin_shadow, skin_blush, eye_white, iris, pupil, eye_highlight, mouth, frame = materials

    add_uv_sphere("Ear_Left", (-1.08, 0.0, 2.28), (0.23, 0.17, 0.39), skin_shadow, rotation=(0.0, 0.0, math.radians(-7)))
    add_uv_sphere("Ear_Right", (1.08, 0.0, 2.28), (0.23, 0.17, 0.39), skin_shadow, rotation=(0.0, 0.0, math.radians(7)))
    add_uv_sphere("EarInner_Left", (-1.10, -0.16, 2.29), (0.10, 0.035, 0.22), skin_blush)
    add_uv_sphere("EarInner_Right", (1.10, -0.16, 2.29), (0.10, 0.035, 0.22), skin_blush)

    eye_data = [
        ("Left", -0.43),
        ("Right", 0.43),
    ]
    for side, x in eye_data:
        add_uv_sphere(f"EyeWhite_{side}", (x, -0.790, 2.47), (0.225, 0.072, 0.128), eye_white, segments=56, rings=36)
        add_uv_sphere(f"Iris_{side}", (x, -0.860, 2.46), (0.100, 0.026, 0.100), iris, segments=48, rings=32)
        add_uv_sphere(f"Pupil_{side}", (x, -0.884, 2.46), (0.052, 0.015, 0.057), pupil, segments=40, rings=28)
        add_uv_sphere(f"EyeHighlight_{side}", (x - 0.026, -0.900, 2.497), (0.020, 0.009, 0.023), eye_highlight, segments=32, rings=20)

    add_bezier_curve(
        "Eyebrow_Left",
        [(-0.72, -0.82, 2.78), (-0.46, -0.91, 2.84), (-0.18, -0.82, 2.78)],
        0.035,
        frame,
    )
    add_bezier_curve(
        "Eyebrow_Right",
        [(0.18, -0.82, 2.78), (0.46, -0.91, 2.84), (0.72, -0.82, 2.78)],
        0.035,
        frame,
    )

    add_uv_sphere("NoseBridge", (0.0, -0.806, 2.23), (0.105, 0.10, 0.25), skin, segments=56, rings=36)
    add_uv_sphere("NoseTip", (0.0, -0.918, 2.08), (0.13, 0.090, 0.095), skin_shadow, segments=56, rings=36)
    add_bezier_curve(
        "Smile",
        [(-0.27, -0.875, 1.82), (0.0, -0.945, 1.75), (0.27, -0.875, 1.82)],
        0.015,
        mouth,
    )
    add_uv_sphere("LowerLip", (0.0, -0.842, 1.72), (0.15, 0.015, 0.030), skin_blush, segments=48, rings=28)

    glasses_rotation = (math.radians(90), 0.0, 0.0)
    add_torus("Glasses_Left", (-0.43, -0.970, 2.47), 0.300, 0.024, frame, rotation=glasses_rotation, scale=(1.0, 1.0, 0.82))
    add_torus("Glasses_Right", (0.43, -0.970, 2.47), 0.300, 0.024, frame, rotation=glasses_rotation, scale=(1.0, 1.0, 0.82))
    add_bezier_curve("Glasses_Bridge", [(-0.13, -0.980, 2.50), (0.0, -1.000, 2.54), (0.13, -0.980, 2.50)], 0.022, frame)
    add_bezier_curve("Glasses_Arm_Left", [(-0.73, -0.96, 2.53), (-0.94, -0.67, 2.53), (-1.08, -0.30, 2.49)], 0.021, frame)
    add_bezier_curve("Glasses_Arm_Right", [(0.73, -0.96, 2.53), (0.94, -0.67, 2.53), (1.08, -0.30, 2.49)], 0.021, frame)


def build_hoodie(materials):
    hoodie, hoodie_shadow, hoodie_light, drawstring, skin = materials
    add_uv_sphere("Shoulders", (0.0, 0.17, 0.24), (1.55, 0.60, 0.70), hoodie, segments=72, rings=44)
    add_uv_sphere("Neck", (0.0, 0.02, 0.78), (0.40, 0.34, 0.62), skin, segments=56, rings=36)
    add_torus(
        "Hood_Collar",
        (0.0, 0.02, 0.72),
        0.78,
        0.20,
        hoodie_shadow,
        scale=(1.18, 0.80, 0.55),
    )
    add_bezier_curve("Hood_Fold_Left", [(-0.93, -0.35, 0.54), (-0.57, -0.60, 0.40), (-0.13, -0.60, 0.28)], 0.055, hoodie_light)
    add_bezier_curve("Hood_Fold_Right", [(0.93, -0.35, 0.54), (0.57, -0.60, 0.40), (0.13, -0.60, 0.28)], 0.055, hoodie_light)
    add_bezier_curve("Drawstring_Left", [(-0.20, -0.71, 0.55), (-0.22, -0.76, 0.28), (-0.23, -0.74, -0.03)], 0.027, drawstring)
    add_bezier_curve("Drawstring_Right", [(0.20, -0.71, 0.55), (0.22, -0.76, 0.28), (0.23, -0.74, -0.03)], 0.027, drawstring)
    add_uv_sphere("DrawstringTip_Left", (-0.23, -0.74, -0.06), (0.045, 0.035, 0.07), drawstring, segments=32, rings=20)
    add_uv_sphere("DrawstringTip_Right", (0.23, -0.74, -0.06), (0.045, 0.035, 0.07), drawstring, segments=32, rings=20)


def setup_stage(materials):
    backdrop, pedestal = materials
    add_rounded_cube("Portrait_Plinth", (0.0, 0.35, -0.39), (2.18, 1.12, 0.18), pedestal, bevel=0.22)

    bpy.ops.mesh.primitive_plane_add(size=30.0, location=(0.0, 0.0, -0.58))
    floor = bpy.context.object
    floor.name = "Studio_Floor"
    floor.data.materials.append(backdrop)

    bpy.ops.mesh.primitive_plane_add(size=30.0, location=(0.0, 3.0, 5.0), rotation=(math.radians(90), 0.0, 0.0))
    wall = bpy.context.object
    wall.name = "Studio_Backdrop"
    wall.data.materials.append(backdrop)


def setup_lighting_and_camera():
    world = bpy.context.scene.world
    world.use_nodes = True
    world_shader = world.node_tree.nodes.get("Background")
    world_shader.inputs["Color"].default_value = (0.055, 0.065, 0.085, 1.0)
    world_shader.inputs["Strength"].default_value = 0.38

    lights = [
        ("Key_Light", "AREA", (-4.0, -5.0, 7.0), 1050.0, 4.2, (1.0, 0.78, 0.62)),
        ("Fill_Light", "AREA", (4.5, -3.4, 4.4), 760.0, 3.6, (0.56, 0.76, 1.0)),
        ("Rim_Light", "AREA", (2.7, 2.8, 6.0), 920.0, 3.0, (0.52, 0.72, 1.0)),
        ("Front_Softbox", "AREA", (-0.3, -5.0, 2.4), 350.0, 2.5, (1.0, 0.91, 0.82)),
    ]
    for name, light_type, location, energy, size, color in lights:
        light_data = bpy.data.lights.new(name=name, type=light_type)
        light_data.energy = energy
        light_data.shape = "DISK"
        light_data.size = size
        light_data.color = color
        light_object = bpy.data.objects.new(name, light_data)
        bpy.context.collection.objects.link(light_object)
        light_object.location = location
        look_at(light_object, (0.0, 0.0, 1.8))

    camera_data = bpy.data.cameras.new("Portrait_Camera")
    camera = bpy.data.objects.new("Portrait_Camera", camera_data)
    bpy.context.collection.objects.link(camera)
    camera.location = (3.15, -9.25, 3.48)
    camera_data.lens = 76.0
    camera_data.sensor_width = 36.0
    look_at(camera, (0.0, 0.0, 1.65))
    bpy.context.scene.camera = camera


def configure_render():
    scene = bpy.context.scene
    scene.render.engine = "BLENDER_EEVEE"
    scene.render.resolution_x = 900
    scene.render.resolution_y = 900
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = "PNG"
    scene.render.image_settings.color_mode = "RGBA"
    scene.render.film_transparent = False
    scene.render.filepath = str(RENDER_PATH)
    scene.render.image_settings.color_depth = "8"
    scene.render.resolution_percentage = 100
    scene.render.use_file_extension = True
    scene.render.film_transparent = False
    scene.view_settings.look = "AgX - Medium High Contrast"


def main():
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    clear_scene()

    skin = make_material("Skin", (0.68, 0.34, 0.16), roughness=0.58, specular=0.25)
    skin_shadow = make_material("Skin Shadow", (0.56, 0.22, 0.09), roughness=0.60, specular=0.22)
    skin_blush = make_material("Skin Blush", (0.46, 0.12, 0.09), roughness=0.68, specular=0.14)
    eye_white = make_material("Eye White", (0.92, 0.93, 0.91), roughness=0.25, specular=0.50)
    iris = make_material("Warm Brown Iris", (0.16, 0.055, 0.018), roughness=0.22, specular=0.55)
    pupil = make_material("Pupil", (0.008, 0.006, 0.005), roughness=0.18, specular=0.55)
    eye_highlight = make_material("Eye Highlight", (1.0, 1.0, 1.0), roughness=0.08, specular=0.70)
    mouth = make_material("Mouth", (0.35, 0.055, 0.035), roughness=0.46, specular=0.22)
    frame = make_material("Glasses Frame", (0.012, 0.015, 0.018), roughness=0.28, metallic=0.15, specular=0.50)

    hair_dark = make_material("Hair Dark", (0.012, 0.014, 0.018), roughness=0.52, specular=0.34)
    hair_mid = make_material("Hair Mid", (0.026, 0.029, 0.035), roughness=0.48, specular=0.36)

    hoodie = make_material("Forest Hoodie", (0.010, 0.074, 0.046), roughness=0.72, specular=0.16)
    hoodie_shadow = make_material("Hood Shadow", (0.005, 0.034, 0.025), roughness=0.78, specular=0.12)
    hoodie_light = make_material("Hood Seam", (0.022, 0.120, 0.076), roughness=0.68, specular=0.14)
    drawstring = make_material("Hood Drawstring", (0.012, 0.038, 0.032), roughness=0.70, specular=0.10)

    backdrop = make_material("Warm Studio", (0.82, 0.84, 0.88), roughness=0.88, specular=0.10)
    pedestal = make_material("Portrait Plinth", (0.070, 0.085, 0.115), roughness=0.50, metallic=0.08, specular=0.28)

    build_head_mesh(skin)
    build_hair((hair_dark, hair_mid))
    build_face((skin, skin_shadow, skin_blush, eye_white, iris, pupil, eye_highlight, mouth, frame))
    build_hoodie((hoodie, hoodie_shadow, hoodie_light, drawstring, skin))
    setup_stage((backdrop, pedestal))
    setup_lighting_and_camera()
    configure_render()

    bpy.ops.wm.save_as_mainfile(filepath=str(BLEND_PATH))
    bpy.ops.render.render(write_still=True)
    print(f"BLENDER_MCP_RENDER={RENDER_PATH}")
    print(f"BLENDER_MCP_BLEND={BLEND_PATH}")


main()
