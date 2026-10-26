# dmgbuild settings for the Nook installer window; the release workflow runs
#   dmgbuild -s apps/macos/Config/DMG/settings.py -D app=PATH/Nook.app -D background=PATH/background.tiff "Nook VERSION" OUT.dmg
# The window size and icon centers must match WIDTH, HEIGHT, APP_ICON and APPS_ICON in scripts/generate_dmg_background.py,
# which draws the background the icons sit on.
import os.path

application = defines["app"]  # noqa: F821 (dmgbuild provides `defines`)
appname = os.path.basename(application)

format = "UDZO"
filesystem = "HFS+"
files = [application]
symlinks = {"Applications": "/Applications"}
icon_locations = {appname: (170, 318), "Applications": (490, 318)}

background = defines["background"]  # noqa: F821
window_rect = ((200, 120), (660, 460))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
icon_size = 104
text_size = 13
arrange_by = None
grid_spacing = 100
label_pos = "bottom"
