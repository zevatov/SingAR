import os.path

# Path to the app bundle to be packaged
app_path = defines.get("app", "build/SingAR.app")
app_name = os.path.basename(app_path)

# Disk image format
format = defines.get("format", "UDZO")

# Files to copy into the root of the DMG
files = [app_path]

# Symlinks to create in the root of the DMG
symlinks = {
    "Applications": "/Applications"
}

# Hide extension for app (.app -> SingAR)
hide_extensions = [app_name]

# Hide hidden files explicitly with SetFile -a V
hide = [".background.png", ".VolumeIcon.icns", ".DS_Store", ".Trashes", ".fseventsd"]

# Background image of the DMG window
background = defines.get("background", "dmg_background.png")

# Volume icon of the mounted DMG
icon = defines.get("icon", "scripts/dmg_assets/icon.icns")

# Size of icons (in points)
icon_size = 120

# Size of label text (in points)
text_size = 12

# Hide Finder window extra UI elements
show_toolbar = False
show_sidebar = False
show_status_bar = False
show_pathbar = False
show_tab_view = False

# Window position and size (top-left coordinates, width and height)
# Window size matches background dimensions (660x480)
window_rect = ((200, 120), (660, 480))

# Positions of the icons relative to the top-left of the window interior.
# Centered horizontally: 180 and 480 (distance 300 points).
# Centered vertically: Y=240 (half of window height).
# Off-screen positions for hidden/system files so they never show even with AppleShowAllFiles=1:
icon_locations = {
    app_name: (180, 240),
    "Applications": (480, 240),
    ".background.png": (2000, 2000),
    ".VolumeIcon.icns": (2000, 2000),
    ".DS_Store": (2000, 2000)
}
