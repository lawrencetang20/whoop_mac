"""py2app build config for WHOOP.app.

Build (alias mode — references this project's venv, so it's fast and reliable):
    .venv/bin/python setup.py py2app -A

Alias mode produces a real .app bundle whose executable lives *inside* the bundle,
so macOS resolves it to WHOOP.app (applying LSUIElement → a proper menu-bar app),
while still importing whoop_dashboard + dependencies from this project's .venv.
Because it references the venv, keep this project folder and .venv in place.
"""

from setuptools import setup

APP = ["run.py"]
OPTIONS = {
    "argv_emulation": False,
    "iconfile": "icon/WHOOP.icns",
    "plist": {
        "CFBundleName": "WHOOP",
        "CFBundleDisplayName": "WHOOP",
        "CFBundleIdentifier": "com.lawrencetang.whoop",
        "CFBundleShortVersionString": "1.0",
        "CFBundleVersion": "1",
        "LSUIElement": True,            # menu-bar app: no Dock icon
        "LSMinimumSystemVersion": "12.0",
        "NSHighResolutionCapable": True,
    },
}

setup(
    app=APP,
    name="WHOOP",
    options={"py2app": OPTIONS},
    setup_requires=["py2app"],
)
