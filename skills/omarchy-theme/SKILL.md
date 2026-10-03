---
name: omarchy-theme
description: >
  Expert knowledge for authoring, installing and debugging Omarchy 4.0 themes.
  REQUIRED before creating anything under ~/.config/omarchy/themes/, editing a
  colors.toml or icons.theme, or debugging "my terminal/editor/bar does not
  match my theme". Covers the real theme layout (a directory with colors.toml +
  icons.theme + per-app files — there is NO theme.json), the semantic palette
  and the 26-key source format, the alias/auto-derivation resolver that expands
  it to 58 keys (color0-15, cursor, muted, selection, purple, brown, bright_*),
  mode detection, the `$OMARCHY_PATH/default/themed/*.tpl` templating engine
  with `{{ color }}` / `_strip` / `_rgb` / `mix` placeholders, backgrounds,
  per-app theme-set helpers, and the theme-set hook. Triggers: omarchy theme,
  colors.toml, icons.theme, theme.json, make a theme, custom theme, theme set,
  theme install, theme colors, accent color, background image, theme not
  applying, terminal colors wrong, omarchy theme refresh, .tpl template.
---

# Omarchy Theme Skill

A theme is a **directory of files**, not a single JSON manifest. The palette
lives in `colors.toml`; every application config in the theme is either a
literal themed file or rendered from a `*.tpl` template.

**There is no `theme.json`.** If you have seen one in a guide or generated one
before, it is wrong for this version and the shell will ignore it.

## 0. Verified state of this machine

| Fact | Value |
| --- | --- |
| Omarchy | `4.0.0.r6713.ga85e29a-1` |
| User themes | `~/.config/omarchy/themes/<slug>/` |
| Shipped themes | `/usr/share/omarchy/themes/` (catppuccin, catppuccin-latte, ethereal, everforest, flexoki-light, gruvbox, hackerman, kanagawa, last-horizon, lumon, …) |
| Local theme | `0xleovision` |
| Staged/live palette | `~/.local/state/omarchy/current/theme/colors.toml` |
| Active slug | `~/.local/state/omarchy/current/theme.name` |
| Transient during switch | `~/.local/state/omarchy/current/next-theme/` |
| Background | `~/.local/state/omarchy/current/background` (symlink) |
| Built-in templates | `$OMARCHY_PATH/default/themed/*.tpl` (19 files) |
| User templates | `~/.config/omarchy/themed/*.tpl` — **take priority** |

## 1. Theme directory layout

```bash
omarchy theme list        # available
omarchy theme set <slug>  # apply
omarchy theme current     # active slug
omarchy theme dir         # which directory is actually being used (prefers user copy)
omarchy theme refresh     # re-render the current theme from its templates
omarchy theme switcher    # TUI
omarchy theme install <git-url>
omarchy theme remove <slug>
omarchy theme update      # git-managed themes
omarchy theme extras      # user themes that came from a git clone
```

```
<theme-dir>/
    colors.toml        REQUIRED — the palette (see §2)
    icons.theme        GTK icon theme NAME, e.g. "Yaru-purple"
    backgrounds/       wallpaper images / videos
    unlock.png         lock-screen branding shown by the theme
    preview.png        picker thumbnail
    preview-unlock.png
    <app configs>      alacritty.toml, ghostty.conf, kitty.conf, foot.ini,
                       helix.toml, neovim.lua, btop.theme, chromium.theme,
                       vscode.json, claude.json, hermes.yaml, keyboard.rgb,
                       hyprland.lua, gum_env.lua, obsidian.css,
                       hyprland-preview-share-picker.css
```

`icons.theme` is a **single line holding a GTK icon theme name** (shipped
themes use `Yaru-purple`), not a key/value palette.

Precedence: `~/.config/omarchy/themes/<slug>/` wins over
`/usr/share/omarchy/themes/<slug>/`. `omarchy theme dir` tells you which copy
is live — use it when a theme edit "does nothing".

## 2. colors.toml — the source palette

26 keys, semantic names, lowercase hex. This is the real shipped format
(`catppuccin`):

```toml
mode = "dark"

accent = "#89b4fa"
selection = "#45475a"
muted = "#585b70"

background = "#1e1e2e"
dark_background = "#161622"
darker_background = "#101019"
lighter_background = "#313244"

foreground = "#cdd6f4"
dark_foreground = "#6c7086"
light_foreground = "#bac2de"
bright_foreground = "#cdd6f4"

red = "#f38ba8"
yellow = "#f9e2af"
orange = "#f6b6ab"
green = "#a6e3a1"
cyan = "#94e2d5"
blue = "#89b4fa"
magenta = "#f5c2e7"
brown = "#7b5b55"

bright_red = "#f38ba8"
bright_yellow = "#f9e2af"
bright_green = "#a6e3a1"
bright_cyan = "#94e2d5"
bright_blue = "#89b4fa"
bright_magenta = "#f5c2e7"
```

### You only need a subset

Every omitted key is **derived**, not defaulted to black. The resolver
(`omarchy-theme-color`, §3) fills the rest in, so a minimal viable theme is
short:

```toml
mode = "dark"
background = "#1a1b26"
foreground = "#c0caf5"
accent     = "#7aa2f7"
muted      = "#414868"
red     = "#f7768e"
yellow  = "#e0af68"
green   = "#9ece6a"
cyan    = "#449dab"
blue    = "#7aa2f7"
magenta = "#ad8ee6"
```

Write `mode` explicitly. Auto-detection is a fallback, not a plan.

### Derivation rules (exact)

Derived when the key is absent:

| Derived key | Rule |
| --- | --- |
| `dark_background` | `mix(background, #000000, 25%)` |
| `darker_background` | `mix(background, #000000, 50%)` |
| `lighter_background` | `color0`, else `background` |
| `dark_foreground` | `color8`, else `foreground` |
| `light_foreground` | `color7`, else `foreground` |
| `bright_foreground` | `color15`, else `foreground` |
| `cursor` | `bright_foreground` |
| `muted` | `color8`, else `dark_foreground` |
| `selection` | `selection_background` → `color8` → `color0` → `background` |
| `selection_background` | `selection` |
| `selection_foreground` | `bright_foreground` |
| `orange` | `yellow` |
| `brown` | `mix(orange, #000000, 50%)` |
| `purple` | `magenta` |
| `bright_purple` | `bright_magenta` |
| `bright_red` … `bright_magenta` | `mix(<base>, #ffffff, 20%)` each |

`mix(a, b, pct)` blends `a` toward `b`. Percentages (`25%`) and fractions
(`0.25`) are both accepted.

Because `brown` derives from `orange` which derives from `yellow`, and all the
`bright_*` shades come from a 20% white mix, a hand-tuned `brown` or
`bright_blue` is worth writing explicitly — the derived value will not match
your intent.

### ANSI aliases

Consumers (terminals, tmux, editors) reference ANSI names. They are kept in
sync automatically:

```
color0=background   color1=red      color2=green    color3=yellow
color4=blue         color5=magenta  color6=cyan     color7=foreground
color8=muted        color9=bright_red   color10=bright_green
color11=bright_yellow   color12=bright_blue   color13=bright_magenta
color14=bright_cyan color15=bright_foreground
```

Legacy short names (`bg`, `fg`, `dark_bg`, `bright_fg`, …) also resolve, so
**old user templates keep working** against a modern palette. Do not "fix" a
template that uses `{{ bg }}`.

### Mode detection precedence

1. the `mode` key in `colors.toml`
2. legacy `theme_type` key
3. a `light.mode` file sitting beside `colors.toml`
4. luminance of `background`
5. `dark`

## 3. Inspecting the resolved palette

`omarchy-theme-color` is the resolver shared by templates, OSC sequences, tmux,
GNOME and the previews — the same cascade runs everywhere, so what it prints is
what apps get. It is a hidden command, so it is absent from
`omarchy commands`, but the route works:

```bash
omarchy theme color --all                 # every resolved key<TAB>value
omarchy theme color --raw                 # only keys literally in the file
omarchy theme color accent                # one value
omarchy theme color selection background  # key, then fallback key
```

On this machine `--all` prints **58** keys from the 26 in `colors.toml`. Use
it to answer "why is my selection colour wrong" instead of guessing.

## 4. Templates — how app configs get themed

App configs in a theme are either literal themed files or **templates**. Built-in
templates live in `$OMARCHY_PATH/default/themed/`; drop a file with the same
name in `~/.config/omarchy/themed/` and it **overrides** the built-in. That is
the supported way to customise a themed app config.

Shipped: `alacritty.toml.tpl`, `btop.theme.tpl`, `chromium.theme.tpl`,
`claude.json.tpl`, `foot.ini.tpl`, `ghostty.conf.tpl`, `gum_env.lua.tpl`,
`helix.toml.tpl`, `hermes.yaml.tpl`, `hyprland.lua.tpl`,
`hyprland-preview-share-picker.css.tpl`, `keyboard.rgb.tpl`, `kitty.conf.tpl`,
`neovim.lua.tpl`, `obsidian.css.tpl`, `pi.json.tpl`, `shell.toml.tpl`,
`t3code.json.tpl`, `vscode-theme.json.tpl`.

Template files are named after the config they produce, with a `.tpl` suffix.
Rendering strips `.tpl` and writes into the staged theme dir
(`~/.local/state/omarchy/current/next-theme/<config>`), which then replaces
`current/theme/`:

```
~/.config/omarchy/themed/ghostty.conf.tpl   ->  <staged theme>/ghostty.conf
```

Two rules that explain most "my template is ignored" reports:

1. **User templates are rendered first, built-in templates second** — so a user
   template wins over a built-in of the same output filename.
2. **A template never overwrites a file the theme already ships.** If
   `<theme-dir>/ghostty.conf` exists, `ghostty.conf.tpl` is skipped entirely.
   To make a template apply, either remove the theme's literal file or stop
   shipping it.

### Placeholders

```qml
{{ background }}          semantic key
{{ color0 }} … {{ color15 }}   ANSI keys
{{ accent }} {{ selection }} {{ muted }} {{ cursor }} {{ brown }} {{ purple }}
```

Modifiers:

| Form | Produces |
| --- | --- |
| `{{ background }}` | `#1a1b26` |
| `{{ background_strip }}` | `1a1b26` (no `#`) |
| `{{ background_rgb }}` | `26,27,38` (decimal, comma-separated) |

Mixing:

```
{{ mix background foreground 50% }}
{{ mix accent #ffffff 20% }}
```

Gradients: `{{ hypr_gradient … }}`, `{{ gradient_start … }}`,
`{{ shell_gradient … }}`.

### Example

```toml
# ~/.config/omarchy/themed/alacritty.toml.tpl
[colors.primary]
background = "{{ background }}"
foreground = "{{ foreground }}"

[colors.cursor]
text = "{{ background }}"
cursor = "{{ cursor }}"

[colors.selection]
text = "{{ selection_foreground }}"
background = "{{ selection_background }}"

[colors.normal]
black   = "{{ color0 }}"
red     = "{{ red }}"
green   = "{{ green }}"
yellow  = "{{ yellow }}"
blue    = "{{ blue }}"
magenta = "{{ magenta }}"
cyan    = "{{ cyan }}"
white   = "{{ foreground }}"

[colors.bright]
black   = "{{ muted }}"
red     = "{{ bright_red }}"
green   = "{{ bright_green }}"
yellow  = "{{ bright_yellow }}"
blue    = "{{ bright_blue }}"
magenta = "{{ bright_magenta }}"
cyan    = "{{ bright_cyan }}"
white   = "{{ bright_foreground }}"
```

`omarchy theme set` waits for template rendering before starting the
transition, so a template that references an undefined key or hangs will stall
theme switching. If `omarchy theme set` seems to freeze, suspect a broken
template or a slow `theme-set.d` hook.

## 5. Backgrounds

```bash
omarchy theme bg set <path>     # image or video
omarchy theme bg next           # cycle within the theme's backgrounds/
omarchy theme bg current        # print current
omarchy theme bg install        # open the theme's user background folder
omarchy theme bg cache          # cache switcher thumbnails
omarchy theme bg-switcher       # TUI
```

Backgrounds live in `<theme-dir>/backgrounds/`; the active one is a symlink at
`~/.local/state/omarchy/current/background`. Omarchy remembers your per-theme
background across theme switches.

Videos are supported. A video background is not cached like a still, so
`bg next` across video backgrounds is slower.

## 6. Per-app theme helpers

`omarchy theme set` renders templates, then calls per-app setters for the apps
that need a nudge beyond a config file. These are the routes that exist:

```bash
omarchy theme set templates        # render every *.tpl (normally automatic)
omarchy theme set foot             # running Foot terminals
omarchy theme set gnome            # GNOME colour mode + icon settings
omarchy theme set browser          # Chromium / Chrome / Edge / Brave
omarchy theme set browser policy   # write theme colour into browser policy dirs
omarchy theme set vscode           # VS Code, VSCodium, Cursor
omarchy theme set claude           # Claude Code
omarchy theme set hermes           # Hermes skin
omarchy theme set obsidian         # all Obsidian vaults
omarchy theme set pi               # Omarchy Pi
omarchy theme set t3code           # T3 Code
omarchy theme set tmux             # tmux environment
omarchy theme set hunk             # running Hunk sessions
omarchy theme set keyboard         # supported keyboards
omarchy theme set keyboard asus rog
omarchy theme set keyboard f16     # Framework Laptop 16
omarchy theme set herdr machines   # mirror theme to herdr machines running Omarchy
```

Discover the live set with:

```bash
omarchy commands --all --json \
  | jq -r '.commands[] | select(.group=="theme") | .route'
```

**Terminals, editors and `btop` have no `set-*` command** — alacritty,
ghostty, kitty, foot, helix, neovim, btop and chromium are handled purely by
templates (§4). If you are looking for `omarchy theme set-alacritty`, it does
not exist; write or fix `alacritty.toml.tpl` instead. `foot` is the exception:
it has both a template and a `set foot` nudge for *running* instances.

Two more utilities worth knowing:

```bash
omarchy theme colors from alacritty   # generate colors.toml from a palette
omarchy theme osc                     # print OSC escape sequences for the theme
```

## 7. Reacting to theme changes

Theme switching fires the `theme-set` hook with the slug as `$1`:

```bash
#!/bin/bash
# ~/.config/omarchy/hooks/theme-set.d/50-gtk-accent
set -u
THEME_NAME="${1:-}"
[[ -n $THEME_NAME ]] || exit 0
omarchy theme color accent >/dev/null || true
```

The hook is how this machine syncs GTK/libadwaita accent colour and Nautilus
palette. See the `omarchy` skill §7 for the hook contract.

`omarchy theme color accent` is the supported way to read a live palette value
from a hook — read `~/.local/state/omarchy/current/theme/colors.toml` only when
you need the raw file.

## 8. Making a theme

```bash
mkdir -p ~/.config/omarchy/themes/mytheme/backgrounds
$EDITOR ~/.config/omarchy/themes/mytheme/colors.toml   # start from §2's minimal set
echo "Yaru-purple" > ~/.config/omarchy/themes/mytheme/icons.theme
cp ~/.config/omarchy/themes/0xleovision/backgrounds/* \
   ~/.config/omarchy/themes/mytheme/backgrounds/ 2>/dev/null

omarchy theme set mytheme
omarchy theme color --all | head -20    # verify what resolved
```

Then check the surfaces that matter: bar, terminal, `btop`, file manager, GTK
apps, lock screen.

Shipped themes carry `preview.png`, `unlock.png` and `preview-unlock.png` for
the picker and lock screen. Copy `unlock.png` from an existing theme if you
want lock-screen branding.

## 9. Troubleshooting

```bash
omarchy theme current                 # which slug is active?
omarchy theme dir                     # which directory is live (user vs shipped)?
cat ~/.local/state/omarchy/current/theme.name
cat ~/.local/state/omarchy/current/theme/colors.toml   # the STAGED palette
omarchy theme color --raw             # keys actually in the file
omarchy theme color --all             # fully resolved palette
omarchy theme refresh                 # re-render templates for current theme
omarchy hook theme-set "$(omarchy theme current)"   # run hooks by hand
```

| Symptom | Cause |
| --- | --- |
| Theme "does nothing" | editing the shipped copy; `omarchy theme dir` shows the other one is live |
| Terminal keeps old colours | app not reloaded — `omarchy restart terminal`, or the app is not Omarchy-themed |
| One app ignores the theme | no template exists for it; write `~/.config/omarchy/themed/<file>.tpl` |
| A colour renders wrong/black | key omitted **and** derivation produced near-black; set it explicitly |
| Colors inverted after switching | `mode` unset and luminance detection chose wrong; set `mode` |
| Template edit ignored | wrong filename (needs `.tpl`), in the shipped tree, **or the theme already ships that file** (§4) |
| `theme set` hangs | broken `.tpl` or a blocking `theme-set.d` hook |
| Lock screen looks unthemed | theme has no `unlock.png` |

## 10. Safety rules

- **Never edit `/usr/share/omarchy/themes/`.** It is package-owned and replaced
  on update. Copy to `~/.config/omarchy/themes/<slug>/` and edit that.
- **Never edit `/usr/share/omarchy/default/themed/`.** User templates in
  `~/.config/omarchy/themed/` override by filename.
- **Do not invent a `theme.json`.** The palette is `colors.toml`.
- **Keep `mode` explicit** in every theme you write.
- **Run `omarchy theme set` only when the user wants the theme applied.** It
  mutates global state, re-renders every app config, and fires hooks.
- **Templates must be pure.** No command substitution, no network calls, no
  writes outside the user's config — rendering happens inside `theme set`.
- **A theme change touches many apps at once.** Before switching, tell the user
  that terminals, editors and the bar will all restyle.
- **Verify after switching** with `omarchy theme color --all` before declaring
  success.

## Example requests

- "Make me a theme" → §8, starting from the minimal palette in §2.
- "Why is my terminal the wrong colour?" → §3 + §9 table.
- "Theme my app X" → §4, write `~/.config/omarchy/themed/<config>.tpl`.
- "Change only the accent" → set `accent` in `colors.toml`; everything derived
  from it follows.
- "Which theme file is being used?" → `omarchy theme dir`.