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
      #                 raster images, so those constructs render as images
      #                 instead of degrading to source. Keys:
      #                 +:math+ -> callable(tex, display_bool);
      #                 +:mermaid+ / +:graphviz+ / +:chart+ -> callable(source).
      #                 Return PNG/JPG bytes as a String, or a Hash with
      #                 +:bytes+ and optional +:width+/+:height+ (points) to
      #                 control the drawn size; anything else degrades the
      #                 construct to its monospace source.
      def render(source, include_root: nil, source_path: nil, extensions: nil,
                 profile: nil, on_includes: nil, **opts)
        ast = parse_source(source, include_root: include_root, source_path: source_path,
                           extensions: extensions, profile: profile,
                           on_includes: on_includes)
        render_ast(ast, **opts)
      end

      # Render the Carve document at +path+, with its <tt>{{ path }}</tt>
      # includes expanded, and return the PDF bytes.
      #
      #   Carve::Hexapdf.render_from_file("report/index.crv")
      #
      # NOT to be confused with {render_file}, which takes Carve SOURCE and
      # writes the PDF out. This one READS the Carve and hands the bytes back.
      #
      # Containment defaults to the input file's own directory, so a sibling or
      # a file below it resolves and nothing above it does. +include_root:+
      # widens or moves that root, and reaches the engine as the caller wrote
      # it: the engine refuses a relative root, which is what keeps containment
      # off whatever directory the process happens to run in.
      def render_from_file(path, include_root: nil, **opts)
        absolute = File.expand_path(path)
        root = include_root || File.dirname(absolute)
        render(File.read(absolute), include_root: root, source_path: absolute, **opts)
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
      #
      # +source+ is a String with no identity of its own, so a directive stays
      # literal unless the caller names both +include_root:+ and +source_path:+.
      def render_file(source, path, **opts)
        File.binwrite(path, render(source, **opts))
        path
      end

      private

      # The AST to draw: expanded when the caller named a root and a document.
      #
      # A String reaching this with neither is parsed as it stands, so a
      # directive in it is text. That is the only thing a caller with no file
      # can be given: a relative include has nothing to resolve against.
      def parse_source(source, include_root:, source_path:, extensions:, profile:,
                       on_includes:)
        if include_root.nil? || source_path.nil?
          unless extensions.nil? && profile.nil?
            raise ArgumentError,
                  "extensions: and profile: reach the engine on the include path only; " \
                  "pass include_root: and source_path:, or drop them"
          end

          return ::Carve.parse(source)
        end

        result = ::Carve.parse_with_includes(source, root: include_root,
                                                     source_path: source_path,
                                                     extensions: extensions,
                                                     profile: profile)
        report_includes(result, on_includes)
        result[:value]
      end

      # Hand the caller everything expansion found, or say what degraded.
      #
      # With +on_includes:+ the caller owns reporting and gets the dependency
      # identities with it. Without it the sanitized warnings go to stderr,
      # because a document that silently lost half its content is the failure
      # this exists to prevent.
      def report_includes(result, on_includes)
        if on_includes
          on_includes.call(warnings: Array(result[:warnings]),
                           dependencies: Array(result[:dependencies]),
                           suppressed_warnings: result[:suppressedWarnings].to_i)
          return
        end

        Array(result[:warnings]).each do |warning|
          where = warning[:file] ? "#{warning[:file]}: " : ""
          $stderr.puts "carve-hexapdf: #{where}#{warning[:rule]}: #{warning[:message]}"
        end
        suppressed = result[:suppressedWarnings].to_i
        return unless suppressed.positive?

        $stderr.puts "carve-hexapdf: #{suppressed} further include warnings suppressed"
      end
    end
  end
end
