# kanibar

**WaniKani at a glance in your [Omarchy](https://omarchy.org) bar.**

kanibar is an Omarchy shell plugin. It shows your pending WaniKani reviews and lessons in the bar. Click it for a popup with your level progress, SRS stages and the review forecast. It can also remind you in the evening if your reviews aren't done yet.

<p align="center">
  <img src="https://github.com/erfoip/kanibar/releases/download/screenshots/popup.png" alt="kanibar popup with review and lesson counts, level kanji progress, SRS stages and 24-hour forecast" width="360">
</p>

## Features

- **Bar pill:** reviews waiting right now, plus available lessons (`鰐 49 · 69`).
- **Popup:**
  - **Review and lesson counts**, each with a link that opens your reviews or lessons on wanikani.com.
  - **Level progress:** every kanji of your current level, colored by SRS state, and a bar showing how close you are to leveling up.
  - **SRS breakdown:** Apprentice / Guru / Master / Enlightened / Burned.
  - **24-hour review forecast.**
- **Done state:** once your reviews are cleared, the count turns into an accent-colored check.
- **Daily reminder:** an optional notification at a time you choose, sent only if reviews are still waiting.
- **Settings page** inside the popup, so you don't need to edit any config files.
- **Follows your Omarchy theme**, including live theme switches.
- **Official [WaniKani API v2](https://docs.api.wanikani.com/)** with a read-only token. kanibar never changes anything on your account.

## Requirements

- Omarchy with the Quickshell-based shell (`omarchy plugin` available).
- A WaniKani account and a **read-only** personal access token.
- A CJK font for the 鰐 glyph and the kanji grid. Omarchy ships Noto CJK by default.
- `curl` 8.4 or newer, for the API requests. Omarchy ships it.

## Install

```sh
omarchy plugin add https://github.com/erfoip/kanibar.git --enable
```

kanibar appears in the bar's `centerEnd` section, right after the clock. To put it somewhere else:

```sh
omarchy bar move io.github.erfoip.kanibar --section right
```

Prefer `centerBegin` or `centerEnd` for a spot next to the clock. A widget added to `center` itself pushes the clock off center.

### Connect your account

On first launch the pill shows `鰐 —`. Click it, and the popup asks for a token:

<p align="center">
  <img src="https://github.com/erfoip/kanibar/releases/download/screenshots/token.png" alt="Token entry in the kanibar popup" width="360">
</p>

1. Click **Get a token ↗** or go to [wanikani.com/settings/personal_access_tokens](https://www.wanikani.com/settings/personal_access_tokens).
2. Create a token. Leave every permission **unchecked**: kanibar only needs read access.
3. Paste it into the field and press **Enter** (or click **Connect**).

kanibar checks the token's format, verifies it with WaniKani, and only then saves it to `~/.config/kanibar/token`, readable only by you (mode 600). A typo or wrong token shows an error and nothing is saved. If WaniKani rejects a saved token later (for example because you revoked it), the popup asks for a new one.

## Using it

### The bar pill

| Pill        | Meaning                                                             |
|-------------|---------------------------------------------------------------------|
| `鰐 49 · 69` | 49 reviews and 69 lessons available now                             |
| `鰐 49`      | 49 reviews, with lessons hidden (`showLessons` off) or none available |
| `鰐 ✓ · 69`  | All reviews done, lessons still available. The check uses your theme's accent color, matches the digits' height, and briefly pops when you clear the last review |
| `鰐 ✓`       | All reviews done, and no lessons or lessons hidden (the pill hides instead if `hideWhenIdle` is on) |
| `鰐 …`       | Loading for the first time                                          |
| `鰐 !`       | The last request failed. Open the popup for details                 |
| `鰐 —`       | Not connected yet. Click to add a token                             |

| Mouse        | Action                                    |
|--------------|-------------------------------------------|
| Left click   | Open or close the popup                   |
| Middle click | Refresh now                               |
| Right click  | Open the WaniKani dashboard in the browser |

The counts refresh in the background on an interval (see `refreshMinutes`), and again 30 seconds after every full hour, when WaniKani unlocks new reviews. You can turn background refresh off.

### The popup

- **Reviews / Lessons:** the same counts as the pill. When there's something to do, the tile shows **Start reviews ↗** or **Start lessons ↗** and opens that session in your browser. Once your reviews are cleared, the Reviews tile changes to **All done**, with an accent border and the time until your next reviews:

  <p align="center"><img src="https://github.com/erfoip/kanibar/releases/download/screenshots/done.png" alt="kanibar with all reviews done: check mark in the bar and an All done tile" width="360"></p>

- **Level N kanji:** every kanji of your current level, in lesson order:
  - **Solid accent fill:** passed (reached Guru).
  - **Gray fill:** in Apprentice.
  - **Outline:** unlocked, waiting in your lessons.
  - **Faded:** still locked.

  Hover a kanji for its meaning and exact stage (e.g. *Apprentice 3*). The bar above fills as kanji reach Guru. The tick marks WaniKani's level-up threshold: **90% of the level's kanji at Guru**. The header shows how many are still needed.
- **SRS stages:** how many items you have in each stage group across your whole account.
- **Next 24 hours:** reviews unlocking each hour (hover a bar for the exact count).
- **Footer:** when the data was last updated, in your Omarchy language's time format.

Level progress and SRS stages are loaded only while the popup is open, and at most every two minutes. The background refresh stays small (see [API usage](#privacy-and-api-usage)).

## Settings

Click the **gear** in the popup header to open the settings page. Escape or the **←** arrow goes back. Every change takes effect immediately.

<p align="center">
  <img src="https://github.com/erfoip/kanibar/releases/download/screenshots/settings.png" alt="kanibar settings page" width="360">
</p>

Settings are stored in this widget's entry in `~/.config/omarchy/shell.json`. Anything you don't change keeps its default, so you can also edit that file by hand or use [`setSetting`](#command-line-and-keybindings).

### Bar

#### `showLessons`: Show lessons on the bar
*Boolean, default `true`.*
Adds the lesson count after the reviews (`鰐 49 · 69`). Lessons are left out when there are none, even if this is on. Turn it off to see reviews only (`鰐 49`). The popup always shows both.

#### `hideWhenIdle`: Hide when nothing is due
*Boolean, default `false`.*
Hides the pill whenever it would only show the done check: no reviews, and either no lessons or lessons hidden with `showLessons` off. It comes back as soon as something it would show unlocks. Good if you only want to see kanibar when there's work to do. While it's hidden, open the popup with the command `omarchy-shell shell toggle io.github.erfoip.kanibar` (e.g. from a keybinding).

#### `highlightThreshold`: Highlight at
*Integer 0–1000, step 10, default `0` (off).*
Once at least this many reviews are waiting, the pill switches to your theme's **urgent** color as a nudge before the pile gets big. `0` turns the highlight off.

#### `refreshMinutes`: Refresh every (minutes, 0 = off)
*Integer 0–60, default `10`.*
How often the bar counts are fetched in the background. While it's on, kanibar also refreshes just after each full hour, when new reviews unlock. The default suits most people, since reviews only unlock on the hour.

`0` turns background refresh off completely: no interval and no hourly refresh. The counts then update only when you open the popup or middle-click the pill. The daily reminder, if enabled, still checks at its time.

### Daily reminder

<p align="center">
  <img src="https://github.com/erfoip/kanibar/releases/download/screenshots/notification.png" alt="kanibar reminder notification: 49 WaniKani reviews waiting, with a Start reviews button" width="420">
</p>

#### `reminderEnabled`: Remind me if reviews are waiting
*Boolean, default `false`.*
Turns the daily reminder on. Once your reminder time has passed each day, kanibar fetches **fresh** counts. If enough reviews are waiting, it sends a notification with a **Start reviews** button. If you already did your reviews, nothing is sent.

- **At most once a day.** The last reminder date is saved to `~/.local/state/omarchy/kanibar-reminder`, so restarting the shell doesn't send it again.
- **Catches up after sleep.** If your computer was asleep or off at the reminder time, you're reminded when it's back on, any time before midnight.
- **Retries when offline.** If WaniKani can't be reached, kanibar tries again every minute instead of skipping the day.
- Notifications go through Omarchy's notification system, so **Do Not Disturb** is respected.

#### `reminderTime`: At (HH:MM)
*String, 24-hour local time, default `"19:00"`.*
When the reminder becomes due, e.g. `"19:00"` or `"7:30"`. In the settings page, press Enter or click elsewhere to save. An invalid time turns red and isn't saved.

#### `reminderMinReviews`: Only from (reviews)
*Integer 1–500, default `1`.*
The minimum number of waiting reviews needed to send a reminder. Raise it if a handful of leftover reviews shouldn't trigger a notification.

**Send test notification** (settings page) sends the reminder right now with your current counts, so you can see what it looks like. The "already sent today" note appears once today's reminder has fired.

### Account

#### `apiToken`: WaniKani API token (advanced)
*String, default `""`.*
Normally you don't need this: the token you paste into the popup is saved to `~/.config/kanibar/token`. If `apiToken` is set in `shell.json`, it **takes precedence** over that file. That's useful if you manage your config elsewhere, but keep in mind `shell.json` often ends up in dotfiles repositories.

The settings page's **Account** section shows who you're connected as, and has:
- **Change token:** opens the token field. The old token keeps working until the new one is verified.
- **Disconnect:** deletes `~/.config/kanibar/token` and clears the displayed data. (Not shown when the token comes from `apiToken`.)

### Example `shell.json` entry

```json
{
  "id": "io.github.erfoip.kanibar",
  "showLessons": true,
  "hideWhenIdle": false,
  "highlightThreshold": 100,
  "refreshMinutes": 10,
  "reminderEnabled": true,
  "reminderTime": "19:00",
  "reminderMinReviews": 10
}
```

## Command line and keybindings

Everything goes through `omarchy-shell`, so you can bind these to keys in your Hyprland config:

| Command | What it does |
|---|---|
| `omarchy-shell shell toggle io.github.erfoip.kanibar` | Open or close the popup |
| `omarchy-shell io.github.erfoip.kanibar refresh` | Refresh now |
| `omarchy-shell io.github.erfoip.kanibar settings` | Open the popup on the settings page |
| `omarchy-shell io.github.erfoip.kanibar changeToken` | Open the popup on the token field |
| `omarchy-shell io.github.erfoip.kanibar testReminder` | Send the reminder notification now |
| `omarchy-shell io.github.erfoip.kanibar setSetting <key> <json>` | Change a setting, e.g. `setSetting reminderTime '"19:30"'` or `setSetting reminderEnabled true` |

## Theming

All colors come from your current Omarchy theme: the accent color for passed kanji, progress and forecast bars; the foreground color for text and outlines; the urgent color for errors and the highlight. Switching themes updates kanibar instantly, no restart needed.

Animations follow Omarchy's motion rules, and `omarchy toggle animations` turns them off for kanibar as well.

## Languages

kanibar follows the language picked under **Setup > Language**, live, without a restart. Numbers and times use that language's format. Right-to-left languages get a mirrored layout.

Only English ships so far. Translations are welcome:

1. Copy `i18n/en.json` to `i18n/<code>.json`, using an Omarchy language code such as `de`, `ja` or `pt-BR`. The codes are listed in `$OMARCHY_PATH/default/i18n/locales.json`.
2. Translate the values, keeping the `%1`/`%2` placeholders. Entries with `one`/`other` are plurals: give the forms your language needs, e.g. Japanese uses only `other`.
3. Leave out anything you don't want to translate. Missing strings fall back to English.

## Privacy and API usage

- **Read-only.** kanibar only reads from the API. It can't start lessons, submit reviews or change settings on your account.
- **Token storage.** The token is saved to `~/.config/kanibar/token` with mode 600, written through stdin so it never appears in the process list. Before saving, kanibar checks that `~/.config/kanibar` is a real directory you own and sets it to mode 700. A new token then goes into a fresh private file that atomically replaces the old one, so it is never written into an existing file, or a directory, that others might be able to read or change. It's sent only to `api.wanikani.com`, and only if it has the exact format of a WaniKani API token.
- **Defensive by default.** Every request goes to the fixed HTTPS address `api.wanikani.com` through `curl`, gives up after 15 seconds, and is dropped if the response exceeds 2 MB. The token reaches curl on stdin, never on the command line. Redirects are never followed, so the token can't be forwarded to another host, and your `~/.curlrc` is ignored so it can't change that. Data from the API is validated before use: counts are kept within sane ranges, lists are capped, and text such as usernames and kanji meanings is length-limited and always shown as plain text, never interpreted as markup.
- **Requests.**
  - **Background refresh:** 2 requests (`/summary`, `/user`) every `refreshMinutes` and after each full hour. You can turn this off.
  - **Popup details:** 7 more (5 stage counts plus 2 for the current level), only while the popup is open and at most every two minutes.
  - **Daily reminder:** 1 request.

  This is well under WaniKani's limit of 60 requests per minute.
- **Files kanibar writes:**
  - `~/.config/kanibar/token`: your API token.
  - `~/.local/state/omarchy/kanibar-reminder`: the date of the last reminder.
  - Your settings, in `~/.config/omarchy/shell.json`.

## Uninstall

```sh
omarchy plugin remove io.github.erfoip.kanibar
rm -rf ~/.config/kanibar ~/.local/state/omarchy/kanibar-reminder
```

Consider also revoking the token on WaniKani's token page.

## Development

```sh
git clone git@github.com:erfoip/kanibar.git
ln -sfn "$PWD/kanibar" ~/.config/omarchy/plugins/io.github.erfoip.kanibar
omarchy-shell shell rescanPlugins && omarchy plugin enable io.github.erfoip.kanibar

node --test kanibar/test/                          # unit and QML contract tests
omarchy plugin validate "$PWD/kanibar"             # manifest schema
qmllint -I "$OMARCHY_PATH/shell" kanibar/src/*.qml
omarchy restart shell                              # QML hot reload is unreliable
```

| File | Contents |
|---|---|
| `manifest.json` | Plugin contract and settings schema |
| `src/Panel.qml` | Entry point: settings, state, when to fetch, popup layout |
| `src/WaniKaniClient.qml` | HTTPS requests with timeout and size cap |
| `src/TokenStore.qml` | Reads, saves and removes `~/.config/kanibar/token` |
| `src/TokenSession.qml` | Token entry flow: check, save, cancel and disconnect, in a fixed order |
| `src/Reminder.qml` | Daily review reminder and its notification |
| `src/BarPill.qml`, `SettingsPage.qml`, `TokenEntry.qml`, `CountTiles.qml`, `LevelProgress.qml`, `SrsBreakdown.qml`, `ReviewForecast.qml` | Views: read state, emit intent |
| `src/PlainText.qml`, `CaptionText.qml`, `LinkText.qml`, `SectionHeader.qml`, `SettingRow.qml`, `StatTile.qml` | Small building blocks; all text goes through `PlainText` |
| `src/Localization.qml` | Catalog lookup and number/time formatting |
| `src/Model.js` | Pure parsing, validation and placeholder helpers (no QML), unit-tested in `test/` |
| `src/Palette.js` | Colors derived from the bar foreground |
| `i18n/` | Translation catalogs (`en.json`) |
| `test/` | `model.test.js`: Model.js unit tests. `contracts.test.js`: every string exists in `en.json` and is used, every text renders plain text, animations stay within Omarchy's motion rules. `token-store.test.js`, `transport.test.js`: the token save script and curl, run for real. `token-session.test.js`: the token entry flow in Quickshell (skipped without `qs`) |
| `preview.png` | Marketplace preview |

## License

[MIT](LICENSE).

kanibar is an unofficial project and has no affiliation with WaniKani or Tofugu.
