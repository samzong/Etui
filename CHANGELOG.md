# Changelog


## [0.1.1] (2026-10-18)


### Features

* **awake:** add keep awake toggle
* **awake:** add independent closed-lid sleep setting (#3)
* **screenshot:** add rectangle and arrow markup before copying captures (#4)
* **screenshot:** add text marks and edit captures in place (#6)
* **clean:** reclaim disk space from the launcher (#9)
* **display:** turn off the built-in display while an external monitor is connected (#12)

### Fixes

* **makefile:** strip header dashes from make help in C locale (#2)
* **switcher:** focus windows across Spaces like Cmd-Tab (#5)
* **pinyin:** show candidate index numbers in label color (#11)

### Documentation

* **readme:** explain étui project name origin
## [0.1.0] (2026-09-30)


### Features

* **launcher:** filter hidden apps from catalog via hidden.json
* **views:** render panel with liquid glass on macOS 26
* add app icon and logo
* **catalog:** list system settings panes alongside apps
* add window tiling shortcuts and multi-hotkey support
* apply display names to app entries with alias fallback
* **clipboard:** add clip panel with cmd+shift+v toggle
* **tile:** shift windows to neighboring screens via shortcuts
* **translate:** add translate panel with configurable client
* **catalog:** add Finder to the searchable catalog
* **switcher:** search and switch to open windows and Chrome and Combe tabs (#1)
* **screenshot:** add area, window, and scrolling capture
* **ime:** add Chinese Pinyin input method
* **pinyin:** add lone Shift toggle for shared English mode

### Fixes

* **catalog:** allow bundles without appl package type
* **search:** bypass input method with direct field editor
* **views:** use each settings pane's own icon
* **catalog:** match app extensions case-insensitively
* **views:** clip glass panel layer to its corner radius
* **launcher:** harden clipboard writes and paste activation
* **translate:** let Return insert newlines in the source editor
* **clipboard:** skip clearing contents when clipboard unchanged
* **launcher:** list only multi-window or tabbed app windows

### Refactors

* extract shared text primitives and panel chrome
* **translate:** move language direction into style prompts

### Documentation

* add project guidance for coding agents
* **readme:** document shortcuts and translate config
