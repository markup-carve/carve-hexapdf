# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.0] - 2026-07-11

### Added

- Added hierarchical `styles:` support through `Carve::Hexapdf::StyleMap` for
  restyling headings, code, links, highlights, admonitions, tables, images, math
  fallbacks, and other renderer surfaces.
- Kept `base_font:`, `code_font:`, `link_color:`, and `highlight_color:` as
  convenience keyword sugar under the new style map.

### Fixed

- `base_font:` (and a `base` font style) now applies to all regular text;
  previously it only affected bold/italic runs while plain text kept the
  composer default font.

## [0.1.0] - 2026-07-06

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
- Graceful degradation: unknown nodes fall back to text/children, remote image
  URLs show alt text, raw HTML and comments are dropped; the renderer never
  raises.

[Unreleased]: https://github.com/markup-carve/carve-hexapdf/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/markup-carve/carve-hexapdf/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/markup-carve/carve-hexapdf/releases/tag/v0.1.0
