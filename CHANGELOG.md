# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-07-06

### Added

- Initial release: `Carve::Hexapdf.render`, `.render_ast`, and `.render_file`
  to render Carve markup to PDF via the pure-Ruby HexaPDF engine.
- AST walker mapping Carve blocks to HexaPDF text/list/table/container/image
  boxes and Carve inline nodes to styled text runs (bold/italic font variants,
  monospace code, colored links).
- Graceful degradation for math, diagrams, table cell spans, and raw HTML.

[Unreleased]: https://github.com/markup-carve/carve-hexapdf/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/markup-carve/carve-hexapdf/releases/tag/v0.1.0
