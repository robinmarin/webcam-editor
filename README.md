# Webcam Editor

An [Omarchy](https://omarchy.org/) shell plugin for adjusting UVC webcams:
exposure, gain, white balance, focus, zoom and image settings, with a live
preview, right from the bar.

Built for cameras whose automatic exposure gets it wrong. Most webcams expose
the manual controls; there's just nowhere convenient to set them.

## Features

- **Bar widget and panel** that follow your Omarchy theme. Click the webcam icon
  to open it.
- **Live preview** inside the panel. The camera is only in use while the
  preview shows, so it is released for Zoom, the browser and the like as soon
  as you close the panel or switch the preview off.
- **Every control the camera reports**, grouped into Exposure, Image, White
  balance and Focus & framing. Controls locked by an auto mode are greyed out
  until you switch that mode to Manual.
- **Profiles that stick.** Cameras forget their settings when unplugged or on
  reboot. Save a profile and the plugin restores it at login and whenever the
  camera is plugged back in.
- **Keyboard navigation** like the built-in panels: `j`/`k` move between rows,
  `h`/`l` change a value, `Enter` toggles. Right-click a slider to reset it to
  the camera default.

## Requirements

- Omarchy (the plugin runs inside `omarchy-shell`)
- `v4l-utils`: reads and writes the camera controls
- `python`: the bundled `webcam-tuner` helper
- `qt6-multimedia-ffmpeg`: the in-panel preview

Optional, only for the standalone preview window (`webcam-tuner` with no
arguments): `python-gobject`, `gtk4` and `gst-plugins-good`.

```sh
omarchy pkg add v4l-utils
```

## Install

```sh
omarchy plugin add https://github.com/robinmarin/webcam-editor.git --enable
```

The widget is added to the right side of the bar. Move it with
`omarchy bar move badger.webcam ...`.

## Usage

Open the panel from the bar. The buttons at the top:

| Button   | Does                                                          |
|----------|---------------------------------------------------------------|
| Preview  | Shows or hides the live preview                               |
| Save     | Saves the current settings as the profile                     |
| Defaults | Resets the camera to its factory settings                     |

A good starting point when auto exposure misbehaves:

1. Set **Exposure mode** to **Manual** and pick an **Exposure time**.
2. Turn off **Lower framerate in low light**. Left on, the camera drops its
   framerate in dim rooms, which looks laggy.
3. Raise **Gain** only if the picture is still too dark; it adds noise.
4. Set **Anti-flicker** to your mains frequency (50 Hz in Europe, 60 Hz in
   North America) if lights flicker on camera.
5. Press **Save**.

### Settings

The plugin uses `/dev/video0` by default. To pick another camera, set the
`device` option in the widget settings (`v4l2-ctl --list-devices` lists them).

### Command line

The bundled `webcam-tuner` script also works on its own:

```sh
./webcam-tuner                 # standalone window with preview
./webcam-tuner --apply         # restore the saved profile
./webcam-tuner --save          # save current settings as the profile
./webcam-tuner --json          # print controls as JSON
./webcam-tuner -d /dev/video2  # use another device
```

Profiles are stored in `~/.config/webcam-tuner/<device>.json`.

## Known issues

- While the in-panel preview runs, Qt's camera backend writes the exposure
  value back one step lower after each change (157 becomes 156). One step is
  far too small to see, but it means the saved value can differ by one from
  the one you set.

## License

MIT
