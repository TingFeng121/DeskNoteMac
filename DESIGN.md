---
name: DeskNote（桌面便签）
description: 文件优先的 macOS 桌面便签与待办工作台——磁盘上的 .md 是唯一真相，界面只是看它的一扇窗。
colors:
  panel-light: "#F7F7F5"
  panel-dark: "#1C1F24"
  rail-teal: "#5C9E8C"
  rail-sand: "#B8996B"
  rail-plum: "#9E7394"
  rail-indigo: "#6B87B8"
  rail-clay: "#B3736B"
  rail-steel: "#7A8FA3"
  warn-ink-light: "#9E6108"
  warn-ink-dark: "#E0913D"
  alert-ink-light: "#B83D2E"
  alert-ink-dark: "#D96B5C"
  sync-ink-light: "#3D7869"
  sync-ink-dark: "#5C9E8C"
  meta-ink-light: "#61615E"
  meta-ink-dark: "#9EA1A3"
typography:
  display:
    fontFamily: "-apple-system, 'SF Pro Text', 'PingFang SC', sans-serif"
    fontSize: "16px"
    fontWeight: 700
    lineHeight: 1.35
  headline:
    fontFamily: "-apple-system, 'SF Pro Text', 'PingFang SC', sans-serif"
    fontSize: "14px"
    fontWeight: 700
    lineHeight: 1.3
  title:
    fontFamily: "-apple-system, 'SF Pro Text', 'PingFang SC', sans-serif"
    fontSize: "13px"
    fontWeight: 400
    lineHeight: 1.45
  body:
    fontFamily: "-apple-system, 'SF Pro Text', 'PingFang SC', sans-serif"
    fontSize: "12px"
    fontWeight: 500
    lineHeight: 1.4
  label:
    fontFamily: "-apple-system, 'SF Pro Text', 'PingFang SC', sans-serif"
    fontSize: "10px"
    fontWeight: 400
    lineHeight: 1.4
  caption:
    fontFamily: "-apple-system, 'SF Pro Text', 'PingFang SC', sans-serif"
    fontSize: "9px"
    fontWeight: 400
    lineHeight: 1.4
  mono-data:
    fontFamily: "'SF Mono', ui-monospace, monospace"
    fontSize: "8px"
    fontWeight: 400
rounded:
  glyph: "1.5px"
  fill-sm: "5px"
  focus: "6px"
  control: "7px"
  field: "8px"
  chip: "9px"
  block: "10px"
  window: "14px"
spacing:
  tight: "4px"
  group: "6px"
  row: "8px"
  pad: "10px"
  gutter: "12px"
components:
  rail-chip-selected:
    backgroundColor: "{colors.rail-teal}"
    textColor: "#FFFFFF"
    rounded: "{rounded.chip}"
    size: "54x34"
  rail-chip-idle:
    backgroundColor: "rgba(92, 158, 140, 0.22)"
    textColor: "#000000"
    rounded: "{rounded.chip}"
    size: "54x34"
  rail-chip-hover:
    backgroundColor: "rgba(92, 158, 140, 0.36)"
    rounded: "{rounded.chip}"
    size: "54x34"
  filter-chip-selected:
    backgroundColor: "AccentColor"
    textColor: "#FFFFFF"
    rounded: "{rounded.control}"
    height: "22px"
    padding: "0 9px"
  filter-chip-idle:
    backgroundColor: "rgba(0, 0, 0, 0.055)"
    textColor: "{colors.meta-ink-light}"
    rounded: "{rounded.control}"
    height: "22px"
    padding: "0 9px"
  button-primary:
    backgroundColor: "AccentColor"
    textColor: "#FFFFFF"
    rounded: "{rounded.control}"
    height: "22px"
    padding: "0 10px"
  button-primary-pressed:
    backgroundColor: "rgba(0, 122, 255, 0.72)"
    textColor: "#FFFFFF"
    rounded: "{rounded.control}"
    height: "22px"
---

# Design System: DeskNote（桌面便签）

## Overview

**Creative North Star: "The File Workbench（文件工作台）"**

DeskNote is a native macOS utility whose whole identity is "a window onto files." The interface is a quiet instrument panel: a warm near-white (light) or cool near-black (dark) panel, a 72pt rail of low-saturation color-block chips on the left, and hairline-ruled content columns. Nothing shouts. Color is spent only where a real state exists — sync, external change, conflict — and every other square millimeter stays tonal gray.

The system is hand-built, not stock chrome. Controls are plain SwiftUI buttons with explicit hit shapes, drawn to survive an environment where the app often has no key window (offscreen capture, desktop-pinned windows, menu-bar panels). That constraint shaped the whole vocabulary: accent-filled buttons instead of `.borderedProminent`, self-drawn focus rings instead of the system ring, a hidden-Button layer carrying ⌘F / ⌘1–4 / ⌘W because SwiftUI had no native carrier for them.

Density is the discipline. A 13pt base font (user-adjustable) delivered through the `\.noteFontSize` environment key, a 29pt table row, 22pt chips, 9–10pt metadata that still clears legibility because it uses measured inks instead of system secondary. The 库 (library) page added in this build extends, and does not replace, this incumbent identity: same panels, same rail, same derived type, same hairlines.

**Key Characteristics:**
- Two panels, one system: `panelLight` #F7F7F5 / `panelDark` #1C1F24, chosen by user theme, never by page.
- 72pt icon rail of 54×34 radius-9 color-block chips; the rail is navigation and identity at once.
- Every text size is an offset from the user's base font size; no literal point sizes.
- Status color does real work: teal = synced, amber = external change, red = conflict; quiet states stay quiet.
- Hairline structure (dividers at 0.4 opacity, 1px row rules) carries the layout; exactly one drawn shadow exists.

## Colors

The palette is two large neutral panels, one categorical rail ramp, four appearance-adaptive working inks, and the user's macOS accent for selection and primary actions.

### Primary
- **Rail Teal** (#5C9E8C, `SidebarView.palette[0]`): the identity accent of the rail. The 库 chip is this teal; the other five rail tints (Sand #B8996B, Plum #9E7394, Indigo #6B87B8, Clay #B3736B, Steel #7A8FA3) are categorical fills for user categories, assigned by index, never by meaning.
- **System Control Accent** (`Color.accentColor`, user-tinted — renders blue in the shipped captures): selection and primary action fill. Selected table row is accent at 0.16; selected filter chip and `LibraryPrimaryStyle` buttons are accent solid with white text; active sort column and links are accent text. It is deliberately not a fixed hex: the app follows the user's macOS accent setting.

### Working inks (appearance-adaptive, `Helpers.swift themedInk(light:dark:)`)
- **Warn Amber Ink** (light #9E6108 / dark #E0913D): "one side changed, waiting on you" — external-change state, scan-failure banner, header "N 处需要处理" count.
- **Alert Red Ink** (light #B83D2E / dark #D96B5C): both sides changed — conflict.
- **Sync Teal Ink** (light #3D7869 / dark #5C9E8C): synced state. Slightly deepened from rail teal because rail teal on #F7F7F5 measures only ~2.9:1.
- **Meta Gray Ink** (light #61615E / dark #9EA1A3): the token for small neutral metadata — column headers, timestamps, folder paths, word counts. The finish reviewer's pixel sampling of the shipped rasters measured it at 5.5–5.9:1 light / 6.0–6.4:1 dark.

### Neutral
- **Panel Light** (#F7F7F5) / **Panel Dark** (#1C1F24): window backgrounds, and the only opaque fill allowed under overlays that cover scrolling content (the preview drawer).
- **Tonal fills**: depth-less surface steps built from `Color.primary.opacity()` — 0.02 (drawer footer), 0.025 (table header), 0.045 (row hover), 0.05 (rail background), 0.055 (filter chip idle, row hairline), 0.10 (drawer edge rule). Plus material steps `.quaternary.opacity(0.3–0.5)` for search field and project blocks.

### Named Rules
**The Status Color Does Real Work Rule.** teal = synced, amber = external change, red = conflict, and nothing else. A status ink appears only where a state the user can act on exists; the clean state is drawn in quiet sync teal, and the drawer's "已同步" line deliberately uses secondary gray so it does not compete for the eye.

**The Measured-Ink Rule.** Small text (9–12pt) on the panels never uses system `.secondary` (~4.0:1 on panelLight) or `.tertiary` (~2:1). Neutral small text uses Meta Gray Ink; colored small text uses the themed inks above, which exist precisely because raw system orange/red measured ~2.5:1 on #F7F7F5.

## Typography

**Display Font:** the platform system stack (SF Pro Text, PingFang SC for Chinese) — the app is a native tool and speaks in the OS voice at every size; there is no separate display face.
**Body Font:** same system stack.
**Label/Mono Font:** SF Mono, used only for data — file paths, filenames — never as styling; all counts, dates and word tallies use `monospacedDigit()` on the system face.

**Character:** utilitarian and tabular. Numbers align because they are read as measurements of a real file store, not as prose.

### Hierarchy
All sizes below are the shipped defaults at the user's base size of 13pt, delivered via `@Environment(\.noteFontSize)`. The real rule is the offset, not the px.

- **Display** (bold, base+3 = 16px): the library setup heading 「库还没建起来」. Rendered note bodies promote `#` headings to base+5 (18px) within the preview column only.
- **Headline** (bold, base+1 = 14px): the window header title (库 / 便签), category names.
- **Title** (regular, base = 13px): todo item text, note editor body.
- **Body** (medium, base−1 = 12px): library row names, drawer title, search field, note list titles.
- **Label** (regular, base−3 = 10px): folder paths in rows, error banner text, rail chip titles (base−3, semibold when selected).
- **Caption** (regular, base−4 = 9px): column headers, filter chip counts, timestamps, drawer footer.
- **Mono-data** (base−5 = 8px, SF Mono): the drawer's filename; rail chip counts use tabular digits at this offset.

### Named Rules
**The Derived-Size Rule.** Every text size in the app is written as `fontSize ± n` against the `noteFontSize` environment value (default 13, user-adjustable in Settings); the whole interface rescales with one setting. A literal `.font(.system(size: 12))` anywhere is a bug by definition. (Fixed sizes exist only for non-text glyphs: empty-state icons, the 6pt project dot.)

**The Tabular Rule.** Any number that lives in a column or a count — dates, word counts, chip counts — gets `monospacedDigit()`; paths and filenames get the mono face. Columns must not wiggle as data changes.

## Layout

The main window is 760×540 default, min 520×360 (`NoteLayout.mainSize/mainMinSize`, enforced on both `contentMinSize` and frame `minSize`). Structure, left to right:

- **Rail**: fixed 72pt wide, 9pt padding, 7pt vertical rhythm, chips 54×34. Four pinned chips (全部 / 完成 / 便签 / 库) then category chips at 41pt pitch in a scroll column.
- **Header**: lives in one row with the traffic lights — `.padding(.leading, 70)` into the 28pt titlebar safe area (lights measured at window x 6…62), `.ignoresSafeArea(.all, edges: .top)`. The library header reads 「库 · N 个文件 · N 处需要处理」 with the actionable count in warn ink.
- **Search bar** row, then the section content, separated by 0.4-opacity hairlines.

The 库 page (this build) inside the content column:

- **Filter row**: 38pt tall, 12pt horizontal padding, 6pt chip gaps; scan timestamp and icon buttons hug the right edge.
- **Table**: header 24pt on a 0.025 fill; rows exactly 29pt; columns 名称 (flex) | 所在目录 92 | 更新 58 | 状态 44 | 字数 36, 8pt gaps, 12pt side padding.
- **Preview drawer**: 296pt fixed width, pinned top-trailing over the table. **The adaptive-column rule:** when the drawer is open (`drawerOpen`), the table drops the two columns the drawer already explains (所在目录, 字数) and pads its trailing edge by 296pt — at 760 window width the table has ~391pt left, and five columns would grind the name column to ellipses. The wide captures (drawer collapsed) show all five columns.
- Other surfaces keep the same rails: notes list column 216pt; desktop panel 300×360 (min 200×186); pinned sticky note 300×260 (min height 140, collapsed bar 36).

Spacing rhythm: 12pt content gutters, 8pt in-row gaps, 6pt chip groups, 4pt minimum separations; vertical density is set by row heights (29/34/38/24), not by padding.

## Elevation & Depth

This is a flat, tonal system. Surfaces separate by fill opacity steps and hairlines, not by shadow. Windows carry the native macOS window shadow (the main window stays at alpha 1; desktop widgets and standalone sticky notes use the user-set alpha, default 0.92, with 14pt content corners); inside the window there is exactly one drawn shadow in the entire codebase, and it is earned: the preview drawer floats over a scrolling table and is the only element that visually overlaps live content.

### Shadow Vocabulary
- **Drawer veil** (`shadow(color: black.opacity(0.10), radius: 14, x: -6, y: 0)` + a 1px leading rule at `primary.opacity(0.10)`): the only in-content shadow. Directional (offset toward the content it covers), soft, and paired with an opaque panel background — material blur is explicitly not allowed here because the table must not read through.

### Named Rules
**The Overlay Earns Its Shadow Rule.** A drawn shadow is reserved for a surface that covers scrolling content, and such a surface must also be opaque (panel colors, never a material) and hairline-edged. Everything else states depth with tonal fills at the exact steps listed in Colors.

## Shapes

Corner language is small and tight: controls sit at 7–9pt (rail chips 9, filter chips and primary buttons 7, search field 8, self-drawn focus ring 6), content blocks at 10, the window at 14. The signature geometry is micro: status capsules and kind marks are 3pt and 7×9pt rectangles at radius 1.5 — the system's smallest radii belong to the shapes that carry data, not to containers.

Borders are hairlines, declared once per edge: selected rail chips take a 1.5pt `primary.opacity(0.35)` stroke; table rows end in a 1px `primary.opacity(0.055)` rule; section breaks use `Divider().opacity(0.4)`. Drop targets stroke a 1.5pt accent border on a radius-5 fill. No element carries both a border and a shadow.

The recurring silhouette of the 库 page is the **two-track status glyph** (see Components) — two stacked capsules, always 3pt tall, whose relative lengths and colors decode an entire sync state at a glance.

## Components

### Rail chip（边条芯片 — signature navigation）
- **Shape:** gently rounded (radius 9), fixed 54×34.
- **States:** selected = solid tint fill, white text, 1.5pt dark stroke; idle = tint at 0.22; hover = tint at 0.36 (code-evidenced via `onHover`; the offscreen capture pipeline has no pointer, so no raster shows it). Title at base−3 (semibold when selected) over a tabular count at base−5.
- **Behavior:** tap gestures, not Buttons, because category chips are drag sources and buttons would eat the mouseDown. The 库 chip is rail teal with the folder SF Symbol and carries ⌘4 in the hidden shortcut layer.

### Filter chip（库页过滤芯片）
- **Style:** 22pt tall, radius 7, 9pt horizontal padding; label base−3 + tabular count base−4.
- **States:** selected = accent solid, white, semibold; idle = `primary.opacity(0.055)` with Meta Gray Ink text. The selected treatment is the same accent-fill language as the rail's selected chip.
- **Behavior:** the active filter persists to UserDefaults; the 冲突 chip's help text escalates to 「N 处需要处理」 when its count is non-zero.

### Primary button（`LibraryPrimaryStyle` — hand-drawn）
- **Shape:** radius 7, 22pt tall, 10pt horizontal padding, white label at base−2 medium.
- **Colors:** accent solid fill; pressed state drops the fill to 0.72 opacity. No system control style is involved.
- **Why hand-drawn:** `.borderedProminent` degenerates to a white-on-white pill in an offscreen window with no key window; the accent-filled block is also the same language as the selected rail chip.

### Library row（文件表行）
- **Geometry:** exactly 29pt tall, 12pt side padding, 8pt column gaps, 1px bottom hairline.
- **States:** selected = accent 0.16 background + accent text on the name; hover = `primary.opacity(0.045)` (code-evidenced, same raster caveat as rail hover); row name truncates middle at one line.
- **Keyboard:** the scroll area is `.focusable()` with ↑/↓ moving selection and self-scroll to center; the focus ring is self-drawn — 2pt accent at 0.55, radius 6 — because the system ring is invisible on panelDark (code-evidenced; no capture shows it, per the no-key-window pipeline).

### Two-track status glyph（双轨状态条 — signature）
Two stacked 3pt capsules at radius 1.5 in a 44pt column. Top track = the disk's copy, bottom = DeskNote's. The hot (actionable) track is always the longer one (36pt vs 14pt); the quiet track stays sync teal at 24pt. Four distinct silhouettes: clean = two equal teal; changed = long amber top; pending = long amber bottom; conflict = two long red. The meaning is additionally spelled out in words by `LibraryRow.State.words` in the drawer, tooltips and help lines — the glyph is an index, never a cipher.

### Preview drawer（预览抽屉）
296pt wide, opaque panel background, 1px leading hairline + the veil shadow. Header 34pt (name + close), state line in words (colored only when actionable), filename in mono + word count, rendered Markdown body, backlinks list (accent links, max 4 shown), footer 34pt on a 0.02 fill with the 「在 Typora/Obsidian 打开」 primary button — the page's only edit path, and it hands off to the external editor.

### Error banner（扫描报错条）
Warn ink at 0.10 background under the filter row: triangle glyph in warn ink, message at base−3 in primary, a 「重新扫描」 recovery button in warn ink. It clears itself on the next successful scan — a partial table never pretends to be complete.

### Icon button & shortcut layer
Icon-only controls are plain buttons on an explicit 20×18/20×20 `contentShape` block (thin SF Symbol glyphs must not define the hit area), secondary foreground, always with `.help`. ⌘F / ⌘1–4 / ⌘W ride on invisible real Buttons in a zero-size layer — the only carrier SwiftUI had.

## Do's and Don'ts

### Do:
- **Do** derive every text size from `noteFontSize` as `fontSize ± n`; the base is 13 and user-adjustable, and the whole tree must follow it.
- **Do** use Meta Gray Ink for small neutral metadata and the themed status inks for colored small text; they exist because system secondary/tertiary fail at 9–10pt on panelLight.
- **Do** keep the hairline discipline: `Divider().opacity(0.4)` between sections, 1px `primary.opacity(0.055)` between table rows, and declare elevation once — border or shadow, never both.
- **Do** draw controls yourself (plain button + `contentShape` + `.help`) whenever a system style depends on key-window state; `.borderedProminent`, system focus rings, and material backgrounds all lie in the offscreen/desktop-layer context.
- **Do** spell out in words whatever a glyph or color encodes (`State.words`, `.help`), so no signal is a private code.
- **Do** give overlays that cover scrolling content an opaque panel background plus the veil shadow, and drop the columns the overlay already explains.
- **Do** keep both themes first-class: every surface token has a light and a dark value, and adaptive inks resolve through `themedInk(light:dark:)` at draw time.

### Don't:
- **Don't** write literal point sizes for text; a hard-coded size silently opts out of the user's font setting and is the one type bug this system treats as a defect on sight.
- **Don't** use `.secondary` or `.tertiary` for small (≤10pt) text on the panels; use `Color.metaInk`.
- **Don't** paint status color on anything that is decoration — teal/amber/red are reserved for sync/changed/conflict and the header's actionable count.
- **Don't** use a material (`.regularMaterial` etc.) or a translucent fill where content scrolls beneath it; the drawer's background is opaque panel color by rule.
- **Don't** rename or re-tint files' identity in the UI layer: the 库 page reports the disk's account (counts are file counts, states are computed from real three-way comparison), never a cached story.
- **Don't** let a rail chip become a `Button` if it needs drag/drop; the tap-gesture idiom in the rail is load-bearing.

## Library workspace extension (2026-10-31)

The library now extends the established Operate/Read surface into a native Markdown workspace. The rail, adaptive panel colors, derived font sizes, and hairline separators remain the visual authority. A folder-first file tree (210pt, 164pt in compact windows) replaces the file table and preview drawer. Files open into a document area with 阅读 / 编辑 / 分屏 controls, a quiet save status footer, and collapsible frontmatter in reading mode. Wide split mode places source and reading side by side; compact split mode stacks them. Each region scrolls independently. The tree can be hidden for a focused document view.

Creation and rename use small native naming sheets. File actions live beside the vault name and in contextual menus; Finder and external editors remain available. The source editor shows raw Markdown with tonal syntax coloring and native text selection/undo. Metadata and conflict messages use the existing meta/warn inks. Automatic saving retains frontmatter verbatim and writes an independent conflict copy when the disk baseline changes. Prior table/drawer descriptions above document the previous library surface; this section describes the current implementation.

## Rich reading and search (2026-11-01)

Reading mode can hand the document to one local web view for Markdown features the native renderer doesn't draw: Mermaid diagrams, KaTeX math, callouts, footnotes, sanitized inline HTML. This is a surface, not a second visual world — `MarkdownRenderer/renderer.css` opens with the same tonal steps the Colors section lists (`--code-bg` at `primary.opacity(0.045)`, `--hairline` at 0.10 light / 0.14 dark, `--quote-bar` for blockquotes) and takes four values injected from the host at runtime (`panel`, `ink`, `meta`, `accent`, resolved through `desknotePanelLight/Dark`, `.labelColor`, `.desknoteMetaInk`, `controlAccentColor`) plus `--note-size` derived from `noteFontSize`, so the page is the same panel, the same ink, the same user-chosen size as the rest of the app, in both appearances. Body font stack is `-apple-system … PingFang SC`, code is `ui-monospace / SF Mono`, radii stay 3–6pt and read as tighter than the 7–9pt window scale because they belong to inline blocks, not surfaces. No cards, no shadow, no colour that isn't already a token.

Routing is the restraint that keeps it native: the web view is created on demand and reused across document switches, and it appears **only** in 阅读. 编辑 and 分屏 keep the native `NSTextView`, so typing never round-trips through a browser. The byte scan in `LibraryRichReader.isNeeded` routes on what the native renderer genuinely can't draw — `~~~` fences, mermaid fences, `$$` and inline math, raw HTML blocks, footnotes, callout markers — and nothing else: a plain ``` fenced block (native draws it monospace, no tokenizer), a table, a task list, `[[双链]]` and embedded images stay native. The verdict is memoised per (path, revision), so a sidebar collapse or a rescroll doesn't re-scan the file. If the bundled renderer is missing, the reader falls back to the native view instead of showing a blank page.

Search stays honest about its own depth. The tree's near-text filter reads the first 32 KB of each file, so when a query is present one quiet meta-ink row appears under the search field: an accent-coloured 搜正文深处 action, a mini spinner with 正在读正文深处… while it runs, then 正文深处另有 N 份 with a 清除. The decision to read the disk is handed to the person searching, not taken by every keystroke. Matches beyond the near-text window carry a `正文深处：…` line in the row's hover help.

Performance work is invisible by design and changes nothing above: no spinner for a cached document (the previous rendered version stays on screen while a new one parses), no full-page flash on reparse, and the footer counts come from values maintained as you type rather than a recount of the whole file.
