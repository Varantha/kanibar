# kanibar

WaniKani at a glance in your [Omarchy](https://omarchy.org) bar.

**In the bar** — `鰐 42 · 5`: reviews waiting now, then lessons available.
**Click for the popup** — your level, review and lesson counts with one-click *Start reviews* / *Start lessons*, the time until your next reviews, and a 24-hour review forecast.

Data comes straight from the official [WaniKani API v2](https://docs.api.wanikani.com/). Kanibar refreshes on an interval and again just after each full hour, when new reviews unlock.

## Install

```sh
omarchy plugin add https://github.com/erfoip/kanibar.git --enable
```

### API token

Create a **read-only** personal access token at
[wanikani.com/settings/personal_access_tokens](https://www.wanikani.com/settings/personal_access_tokens), then either:

- paste it into the widget's **WaniKani API token** setting, or
- save it to a file, so it stays out of `shell.json`:

  ```sh
  mkdir -p ~/.config/kanibar && install -m 600 /dev/stdin ~/.config/kanibar/token <<< "YOUR-TOKEN"
  ```

## Usage

| Action        | Result                       |
|---------------|------------------------------|
| Left click    | Toggle the detail popup      |
| Middle click  | Refresh now                  |
| Right click   | Open the WaniKani dashboard  |

```sh
omarchy-shell shell toggle io.github.erfoip.kanibar   # e.g. bind to a key
```

## Settings

| Key                  | Default | Description                                                      |
|----------------------|---------|------------------------------------------------------------------|
| `apiToken`           | `""`    | WaniKani token; falls back to `~/.config/kanibar/token`          |
| `refreshMinutes`     | `10`    | Refresh interval (plus a refresh right after every full hour)    |
| `showLessons`        | `true`  | Show the lesson count next to reviews on the bar                 |
| `hideWhenIdle`       | `false` | Hide the pill while nothing is due                               |
| `highlightThreshold` | `0`     | Use the urgent color once this many reviews wait (0 = off)       |

## Development

```sh
git clone git@github.com:erfoip/kanibar.git
ln -sfn "$PWD/kanibar" ~/.config/omarchy/plugins/io.github.erfoip.kanibar
omarchy-shell shell rescanPlugins && omarchy plugin enable io.github.erfoip.kanibar

node --test test/                                  # Model.js unit tests
omarchy plugin validate "$PWD/kanibar"             # manifest schema
qmllint -I "$OMARCHY_PATH/shell" kanibar/Panel.qml
omarchy restart shell                              # QML hot reload is unreliable
```

Layout: `manifest.json` (contract, settings schema) · `Panel.qml` (bar pill + popup, API calls) · `Model.js` (pure parsing/formatting, tested in `test/`).

## License

[MIT](LICENSE). kanibar is an unofficial project and has no affiliation with WaniKani or Tofugu.
