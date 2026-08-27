# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

## [0.1.1] - 2026-08-27

### Changed

- The development pin moves to released `carve-lang` 0.1.2, so the suite covers
  the current embedded engine and output surface. The supported consumer range
  remains `>= 0.1.1, < 0.2.0`: 0.1.1 still satisfies this renderer's API and
  security requirements. On the engine's own 0.x scheme `0.1` is the major and the third digit
  the minor, so the previous open range admitted, by the engine's own rules, a
  release declared breaking - and this gem reads an AST whose node vocabulary
  was already renamed once inside 0.1
  ([#26](https://github.com/markup-carve/carve-hexapdf/issues/26)).

## [0.1.0] - 2026-08-19

### Added

- Initial release: `Carve::Hexapdf.render`, `.render_ast`, and `.render_file`
  to render Carve markup to PDF via the pure-Ruby HexaPDF engine.
- AST walker mapping Carve blocks to HexaPDF text/list/table/container/image
  boxes and Carve inline nodes to styled text runs.
- All inline emphasis renders with its decoration: strong/italic/bold-italic
  (font variants), underline, strikethrough, superscript, subscript, and
  highlight; critic insert/delete map to underline/strikethrough; footnote
  references render as superscript.
- Tables with header rows and full **row / column span** resolution (`^` / `<`
  markers map to HexaPDF `row_span` / `col_span`).
- Math and diagram fences render as embedded raster images via optional
  `renderers:` callables (`:math`, `:mermaid`, `:graphviz`, `:chart`), degrading
  to monospace source when no renderer is supplied.
- Images (block and inline) embedded from local file paths or `data:` URIs.
- Footnotes (inline `^[..]` and referenced `[^id]`) render as superscript
  `[n]` markers with their bodies collected into a numbered endnote section.
- Task-list checkboxes are drawn in the list marker column, so item text and
  nested lists align like any other list.
- Renderer callables may return `{ bytes:, width:, height: }` to control the
  drawn size, so high-DPI rasters embed crisply.
- Hierarchical `styles:` support through `Carve::Hexapdf::StyleMap` for
  restyling headings, code, links, highlights, admonitions, tables, images,
  math fallbacks, and other renderer surfaces; the `base_font:`, `code_font:`,
  `link_color:`, and `highlight_color:` keyword options are convenience sugar
  under the style map.
- Graceful degradation: unknown nodes fall back to text/children, remote image
  URLs show alt text, raw HTML and comments are dropped; the renderer never
  raises.

[Unreleased]: https://github.com/markup-carve/carve-hexapdf/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/markup-carve/carve-hexapdf/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/markup-carve/carve-hexapdf/releases/tag/v0.1.0

- **Composite figures render as one grouped float.** A bare `::: figure`
  container is one numbered figure of ordered panels (Carve PART 9 section 4c,
  AST node `figure_group`). Its panels, the content preserved between them and
  the group caption are laid out as a single box a page break may not enter,
  and each panel keeps its own caption the same way, so the caption that numbers
  the figure cannot land on the page after it. A group too tall for a page
  splits rather than failing the render, panels still in source order. A
  `.columns-N` hint is honored when the page can give every column
  `figure.group.min_column_width` points and is otherwise ignored in favor of a
  stack - every panel is drawn either way. Two new style keys, `figure.group`
  and `figure.group.caption`. The parser this gem consumes does not produce the
  node yet; `render_ast` accepts one from any engine that does.

### Fixed

- **The `carve-lang` floor moves to `>= 0.1.1`.** At `>= 0.1` a consumer could
  resolve carve-lang 0.1.0, which predates the Carve 0.1.3 security release and
  renders a list-valued URL attribute unsanitized - so this gem's own suite
  could be green while every install of it carried a vulnerable engine. 0.1.1 is
  the rebuild onto carve-rs 0.1.3.

- **A table's caption no longer loses the whole document.** `table.caption`
  sits under `table` in the style chain, so it inherited `cell_padding` - a
  property this renderer reads itself and HexaPDF has never heard of - and
  splatting it into the caption's text box raised `NoMethodError`. Every
  captioned table was affected; no fixture had captioned one.

- **A resolved no-break space renders instead of killing the render.** The
  engines publish U+E000 in a text value to stand for a no-break space the parser
  resolved - from an escaped space (`a\ b`) or a line block's preserved
  indentation - and PART 12 says a consumer maps it to its target's no-break
  space and must not emit it. It was drawn as-is, and the default Type1 font has
  no glyph for a private-use codepoint, so an ordinary escaped space raised
  `HexaPDF::MissingGlyphError` and produced no document at all. It now maps to
  U+00A0 in text, inline code, code blocks and image alt text.

- **Four more inline nodes reach the page instead of vanishing.** `symbol`,
  `literal_inline`, `caption_number` and `inline_extension` each carry their
  content in `name`, `content` or `n` rather than in `children`, and the inline
  fallback emits children only - so they contributed nothing at all: no error, no
  placeholder, just missing text. A captioned figure rendered its caption without
  its number. The `emoji` arm had also gone dead when that type was renamed to
  `symbol` upstream; both names are accepted now. What each prints follows the
  reference engine's plain-text target. `heading_ref` and `substitution` are still
  dropped and are pinned as known gaps, since each needs a decision rather than an
  arm.

- **Bold, italic, underline, strike, superscript and subscript reach the page
  again.** Each emphasis sort is its own node type now, not one `emphasis` node
  carrying a `kind` (carve-rb#32). The renderer matched only `emphasis`, so all
  seven fell through to the default branch: the text still rendered, in the
  regular face with no decoration, and the PDF stayed valid - which is why the
  smoke test kept passing. `/*both*/` is a single `strong` carrying
  `boldItalic`, so the italic is read off the flag rather than inferred from
  nesting.

- **Footnote endnote numbers are back, and the body appears once.** Definitions
  used to arrive as a `footnote_defs` map on the root; PART 12 fixes the root at
  three fields, so they moved into the tree as `footnote` block nodes carrying a
  `label` (carve-rb#19, #21), and the inline became `footnote_ref` /
  `inline_footnote` rather than `footnote`. Reading the old root field found
  nothing, every reference failed to resolve, and the `[1]` markers silently
  vanished while the bodies still rendered. A definition is now relocated to the
  endnote section wherever it sits, including inside a container.

  Both old spellings are still accepted, so an AST stored by an earlier version
  renders the same.

- **An escaped character no longer vanishes from the page.** `escaped_text` is
  its own inline node (carve#350), and it carries no children - so without an
  arm of its own it fell through to the branch that emits children and rendered
  nothing at all. `a\-b` came out as `ab`. The same silent-drop shape as the
  smart-punctuation node before it (carve#355).

  Dormant until the engine behind `Carve.parse` emits the node; handled here
  first so the bump lands into a renderer that already copes.
