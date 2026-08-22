import bpy
import sys

modules = ["io_scene_ueformat", "io_scene_psk_psa", "io_scene_fbx"]
failed = []

for module in modules:
    try:
        bpy.ops.preferences.addon_enable(module=module)
        print(f"ADDON_ENABLED={module}")
    except Exception as exc:
        failed.append((module, repr(exc)))
        print(f"ADDON_FAILED={module} ERROR={exc!r}")

bpy.context.preferences.view.show_developer_ui = True
bpy.ops.wm.save_userpref()
print(f"BLENDER_VERSION={bpy.app.version_string}")
print(f"USER_CONFIG={bpy.utils.user_resource('CONFIG')}")

if failed:
    print(f"FAILED_ADDONS={failed!r}", file=sys.stderr)
    raise SystemExit(1)
