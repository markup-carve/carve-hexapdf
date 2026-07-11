# frozen_string_literal: true

require "hexapdf"
require "carve"

require_relative "hexapdf/version"
require_relative "hexapdf/style_map"
require_relative "hexapdf/renderer"

module Carve
  # Render Carve markup to PDF using the pure-Ruby HexaPDF layout engine.
  #
  #   pdf_bytes = Carve::Hexapdf.render("# Hello *world*")
  #   Carve::Hexapdf.render_file("# Report", "out.pdf")
  #
  # The Carve source is parsed with +Carve.parse+ (from the carve-lang gem) and
  # the resulting AST is walked by {Renderer}, which drives a
  # HexaPDF::Composer. Bold/italic map to font variants, inline code to a
  # monospace font, links to colored runs with URI overlays; block nodes map to
  # HexaPDF text/list/table/container/image boxes.
  #
  # NOTE ON LICENSING: HexaPDF is dual-licensed AGPL-3.0 / commercial. Software
  # that is distributed or offered over a network while depending on HexaPDF
  # must comply with the AGPL or hold a HexaPDF commercial license. This gem
  # (MIT) only bridges to it; your use of HexaPDF is governed by HexaPDF's own
  # terms.
  module Hexapdf
    class << self
      # Render Carve +source+ to a PDF and return the document as a binary
      # String.
      #
      # Options:
      #   page_size::   HexaPDF page size (default +:A4+).
      #   margin::      page margin in points (default 45).
      #   base_font::   proportional font family (default "Times").
      #   code_font::   monospace font family (default "Courier").
      #   link_color::  fill color for links (default "hp-blue").
      #   styles::      hierarchical style map for PDF output.
      #   renderers::   Hash of callables that turn math / diagram source into
      #                 raster image bytes, so those constructs render as images
      #                 instead of degrading to source. Keys:
      #                 +:math+ -> callable(tex, display_bool) -> String|nil;
      #                 +:mermaid+ / +:graphviz+ / +:chart+ -> callable(source)
      #                 -> String|nil (PNG/JPG bytes).
      def render(source, **opts)
        render_ast(::Carve.parse(source), **opts)
      end

      # Render an already-parsed Carve AST Hash (see +Carve.parse+) to PDF
      # bytes. Useful when the AST is inspected or transformed before render.
      def render_ast(ast, page_size: :A4, margin: 45, base_font: nil,
                     code_font: nil, link_color: nil,
                     highlight_color: nil, styles: nil, renderers: nil)
        composer = ::HexaPDF::Composer.new(page_size: page_size, margin: margin)
        Renderer.new(composer, base_font: base_font, code_font: code_font,
                     link_color: link_color, highlight_color: highlight_color,
                     styles: styles, renderers: renderers).render_document(ast)
        composer.write_to_string
      end

      # Render Carve +source+ and write the PDF to +path+. Returns +path+.
      def render_file(source, path, **opts)
        File.binwrite(path, render(source, **opts))
        path
      end
    end
  end
end
