# frozen_string_literal: true

require "stringio"
require "base64"

module Carve
  module Hexapdf
    # Walks a Carve AST (as produced by +Carve.parse+) and draws it onto a
    # HexaPDF::Composer, producing a laid-out PDF document.
    #
    # Block nodes become HexaPDF boxes (text, list, table, container, image);
    # inline nodes become the multi-part styled "runs" that
    # HexaPDF::Composer#formatted_text consumes. Emphasis maps to font variants
    # and text decorations, inline code to a monospace font, links to a colored
    # run with a URI overlay.
    #
    # Math and diagram fences are rendered through optional +renderers:+
    # callables (which return image bytes); without a matching renderer they
    # degrade to their monospace source. The renderer never raises on an
    # unknown or unsupported node - it degrades to text/children so a document
    # always renders.
    class Renderer
      HEADING_SIZE = { 1 => 22, 2 => 18, 3 => 15, 4 => 13, 5 => 12, 6 => 11 }.freeze
      BLOCK_GAP = 8

      # Code-fence languages that map to a diagram renderer key.
      DIAGRAM_LANGS = {
        "mermaid" => :mermaid,
        "dot" => :graphviz,
        "graphviz" => :graphviz,
        "chart" => :chart,
        "vega" => :chart,
      }.freeze

      # @param renderers [Hash] optional callables that turn a construct's
      #   source into raster image bytes (PNG/JPG). Keys:
      #   +:math+ -> callable(tex_string, display_bool) -> String|nil;
      #   +:mermaid+/+:graphviz+/+:chart+ -> callable(source_string) -> String|nil.
      #   A nil / non-String return, or a missing key, degrades the construct to
      #   its source.
      def initialize(composer, base_font: "Times", code_font: "Courier",
                     link_color: "hp-blue", highlight_color: "fff3a3", renderers: nil)
        @c = composer
        @layout = composer.document.layout
        @base = base_font
        @code_font = code_font
        @link_color = link_color
        @highlight_color = highlight_color
        @renderers = renderers || {}
      end

      def render_document(doc)
        Array(doc[:children]).each { |node| block(node, @c) }
        @c
      end

      # ---- block dispatch ------------------------------------------------

      def block(node, target)
        case node[:type]
        when "heading"          then heading(node, target)
        when "paragraph"        then paragraph(node, target)
        when "code_block"       then code_block(node, target)
        when "list"             then list(node, target)
        when "block_quote"      then block_quote(node, target)
        when "table"            then table(node, target)
        when "thematic_break"   then thematic_break(target)
        when "div"              then container_of(node[:children], target)
        when "admonition"       then admonition(node, target)
        when "definition_list"  then definition_list(node, target)
        when "figure"           then figure(node, target)
        when "block_image", "image" then image_block(node, target)
        when "block_extension"  then container_of(node[:children], target)
        when "raw_block", "comment", "abbreviation_def"
          # No meaningful PDF form - drop.
        else
          if inline_children?(node[:children])
            emit_paragraph(node[:children], target)
          elsif node[:children]
            Array(node[:children]).each { |ch| block(ch, target) }
          end
        end
      end

      private

      def heading(node, target)
        size = HEADING_SIZE[node[:level]] || 11
        runs = inline_runs(node[:children], bold: true)
        return if runs.empty?

        target.formatted_text(runs, font_size: size, margin: [BLOCK_GAP + 2, 0, BLOCK_GAP - 2])
      end

      def paragraph(node, target)
        # A paragraph that is only a display-math node becomes a centered image.
        children = Array(node[:children])
        if children.size == 1 && children.first[:type] == "math" && children.first[:display]
          return display_math(children.first, target)
        end

        emit_paragraph(children, target)
      end

      def emit_paragraph(children, target, **style)
        runs = inline_runs(children)
        return if runs.empty?

        target.formatted_text(runs, **{ margin: [0, 0, BLOCK_GAP] }.merge(style))
      end

      def code_block(node, target)
        lang = node[:lang].to_s.downcase
        if (key = DIAGRAM_LANGS[lang]) && (bytes = call_renderer(key, node[:content].to_s))
          return image_bytes(bytes, target)
        end

        content = node[:content].to_s.chomp
        target.text(content, font: @code_font, font_size: 9, margin: [2, 0, BLOCK_GAP],
                    box_style: { background_color: "f2f2f2", padding: 6 })
      end

      def list(node, target)
        items = Array(node[:items])
        ordered = node[:ordered]
        task = items.any? { |it| !it[:checked].nil? }
        marker = if task
                   ->(doc, _list, _index) { doc.layout.text_box("") }
                 elsif ordered
                   :decimal
                 else
                   :disc
                 end
        start = node[:start] || 1

        target.list(marker_type: marker, start_number: start, item_spacing: 3,
                    content_indentation: task ? 4 : 18) do |list_box|
          items.each do |item|
            list_box.container do |cell|
              prefix = task ? (item[:checked] ? "[x] " : "[ ] ") : nil
              render_item(item, cell, prefix)
            end
          end
        end
      end

      def render_item(item, cell, prefix)
        children = Array(item[:children])
        first_para_done = false
        children.each do |ch|
          if prefix && !first_para_done && ch[:type] == "paragraph"
            runs = [{ text: prefix }] + inline_runs(ch[:children])
            cell.formatted_text(runs, margin: [0, 0, 2])
            first_para_done = true
          else
            block(ch, cell)
          end
        end
        cell.formatted_text([{ text: prefix }]) if prefix && !first_para_done
      end

      def block_quote(node, target)
        target.container(style: { margin: [2, 0, BLOCK_GAP], padding: [4, 10],
                                  background_color: "f7f7f7" }) do |cont|
          Array(node[:children]).each { |ch| block(ch, cont) }
          if node[:attribution]
            emit_paragraph(node[:attribution], cont, margin: [2, 0, 0])
          end
        end
      end

      def container_of(children, target)
        target.container(style: { margin: [0, 0, BLOCK_GAP] }) do |cont|
          Array(children).each { |ch| block(ch, cont) }
        end
      end

      def admonition(node, target)
        target.container(style: { margin: [2, 0, BLOCK_GAP], padding: [6, 10],
                                  background_color: "eef3fb" }) do |cont|
          title = node[:title] && !node[:title].empty? ? node[:title] : [{ type: "text", value: node[:kind].to_s.capitalize }]
          cont.formatted_text(inline_runs(title, bold: true), margin: [0, 0, 4])
          Array(node[:children]).each { |ch| block(ch, cont) }
        end
      end

      def definition_list(node, target)
        target.container(style: { margin: [0, 0, BLOCK_GAP] }) do |cont|
          Array(node[:items]).each do |item|
            Array(item[:terms]).each do |term|
              cont.formatted_text(inline_runs(term, bold: true), margin: [2, 0, 1])
            end
            Array(item[:definitions]).each do |defn|
              cont.container(style: { padding: [0, 0, 0, 16] }) do |dcont|
                Array(defn).each { |ch| block(ch, dcont) }
              end
            end
          end
        end
      end

      def figure(node, target)
        block(node[:target], target) if node[:target]
        if node[:caption] && !node[:caption].empty?
          target.formatted_text(inline_runs(node[:caption], italic: true),
                                text_align: :center, font_size: 9, margin: [2, 0, BLOCK_GAP])
        end
      end

      def image_block(node, target)
        io = resolve_image(node[:src].to_s)
        if io
          target.image(io, margin: [2, 0, BLOCK_GAP])
        else
          alt = node[:alt].to_s
          alt = "[image: #{node[:src]}]" if alt.empty?
          target.formatted_text([{ text: alt, font: [@base, { variant: :italic }] }],
                                margin: [0, 0, BLOCK_GAP])
        end
      end

      def display_math(node, target)
        if (bytes = call_renderer(:math, node[:content].to_s, true))
          return image_bytes(bytes, target, align: :center)
        end

        target.text(node[:content].to_s, font: @code_font, font_size: 11, text_align: :center,
                    margin: [4, 0, BLOCK_GAP], box_style: { padding: 4 })
      end

      def thematic_break(target)
        target.box(:base, height: 2,
                   style: { margin: [BLOCK_GAP, 0, BLOCK_GAP], background_color: "cccccc" })
      end

      # Draw raster image bytes as a block image.
      def image_bytes(bytes, target, align: nil)
        style = { margin: [2, 0, BLOCK_GAP] }
        style[:align] = align if align
        target.image(StringIO.new(bytes), style: style)
      rescue StandardError
        # A malformed image must not abort the whole document.
        nil
      end

      # ---- tables (with row/col spans) -----------------------------------

      def table(node, target)
        resolved = resolve_spans(Array(node[:rows]))
        return if resolved.empty?

        header_count = resolved.first.any? { |o| o[:header] } ? 1 : 0

        cell_boxes = resolved.map do |row|
          row.map do |o|
            runs = inline_runs(o[:cell][:children], bold: o[:header])
            runs = [{ text: "" }] if runs.empty?
            box = @layout.formatted_text_box(runs, font_size: 10, padding: 4)
            hash = { content: box }
            hash[:col_span] = o[:col_span] if o[:col_span] > 1
            hash[:row_span] = o[:row_span] if o[:row_span] > 1
            hash
          end
        end

        header = header_count.positive? ? ->(_t) { [cell_boxes.first] } : nil
        body = header_count.positive? ? cell_boxes[1..] : cell_boxes
        body = [[{ content: @layout.text_box("") }]] if body.nil? || body.empty?

        target.table(body, header: header, margin: [2, 0, BLOCK_GAP])
        if node[:caption] && !node[:caption].empty?
          target.formatted_text(inline_runs(node[:caption], italic: true),
                                font_size: 9, margin: [0, 0, BLOCK_GAP])
        end
      end

      # Resolve Carve's explicit span markers (a `<` cell = merge left, a `^`
      # cell = merge up) into per-cell col_span / row_span counts, returning
      # rows of originator hashes {cell:, header:, col_span:, row_span:} with
      # marker cells dropped. Every covered grid position is explicit in Carve,
      # so a cell's column index equals its position in the row.
      def resolve_spans(rows)
        col_owner = {} # column index => originator hash currently owning it
        out = []
        rows.each do |row|
          emitted = []
          last = nil
          bumped = {} # originators already row-extended in THIS row (by object id)
          Array(row[:cells]).each_with_index do |cell, col|
            case cell[:span]
            when "colspan"
              owner = last || col_owner[col - 1]
              owner[:col_span] += 1 if owner
              col_owner[col] = owner if owner
            when "rowspan"
              owner = col_owner[col]
              # A multi-column cell has one `^` per covered column on the next
              # row; count the downward extension only once per originator.
              if owner && !bumped[owner.object_id]
                owner[:row_span] += 1
                bumped[owner.object_id] = true
              end
              # col_owner[col] stays pointing at the same originator so a
              # further `^` in the next row chains onto it.
            else
              o = { cell: cell, header: cell[:header], col_span: 1, row_span: 1 }
              emitted << o
              last = o
              col_owner[col] = o
            end
          end
          out << emitted
        end
        out
      end

      # ---- inline flattening ---------------------------------------------

      def inline_runs(nodes, **ctx)
        out = []
        Array(nodes).each { |n| emit_inline(n, ctx, out) }
        out
      end

      def emit_inline(node, ctx, out)
        case node[:type]
        when "text"       then out << run(node[:value].to_s, ctx)
        when "soft_break" then out << run(" ", ctx)
        when "hard_break" then out << { text: "\n" }
        when "emphasis"   then emit_children(node, emphasis_ctx(ctx, node[:kind]), out)
        when "span"       then emit_children(node, ctx, out)
        when "code"       then out << run(node[:value].to_s, ctx.merge(code: true))
        when "math"       then inline_math(node, ctx, out)
        when "link"
          lctx = ctx.merge(link: node[:href].to_s)
          if node[:children] && !node[:children].empty?
            node[:children].each { |c| emit_inline(c, lctx, out) }
          else
            out << run(node[:href].to_s, lctx)
          end
        when "autolink" then out << run(node[:href].to_s, ctx.merge(link: node[:href].to_s))
        when "image"    then inline_image(node, ctx, out)
        when "emoji"    then out << run(":#{node[:name]}:", ctx)
        when "mention"  then out << run("@#{node[:user]}", ctx)
        when "tag"      then out << run("##{node[:name]}", ctx)
        when "footnote"
          out << run("[#{node[:number]}]", ctx.merge(super: true)) if node[:number]
        when "citation_group" then out << run(node[:raw].to_s, ctx)
        when "abbreviation"   then out << run(node[:abbr].to_s, ctx)
        when "cross_ref"      then out << run(node[:target].to_s, ctx)
        when "caption_number" then (out << run(node[:number].to_s, ctx) if node[:number])
        when "critic_insert"  then emit_children(node, ctx.merge(underline: true), out)
        when "critic_delete"  then emit_children(node, ctx.merge(strike: true), out)
        when "critic_substitute" then out << run(node[:new_text].to_s, ctx.merge(underline: true))
        when "raw_inline", "critic_comment"
          # No safe PDF form - drop.
        else
          emit_children(node, ctx, out) if node[:children]
        end
      end

      def emit_children(node, ctx, out)
        Array(node[:children]).each { |c| emit_inline(c, ctx, out) }
      end

      def emphasis_ctx(ctx, kind)
        case kind
        when "strong"      then ctx.merge(bold: true)
        when "italic"      then ctx.merge(italic: true)
        when "bold-italic" then ctx.merge(bold: true, italic: true)
        when "underline"   then ctx.merge(underline: true)
        when "strike"      then ctx.merge(strike: true)
        when "super"       then ctx.merge(super: true)
        when "sub"         then ctx.merge(sub: true)
        when "highlight"   then ctx.merge(highlight: true)
        else ctx
        end
      end

      # Build one formatted-text run hash for +text+ under styling +ctx+.
      def run(text, ctx)
        item = { text: text }
        if ctx[:code]
          item[:font] = @code_font
        elsif ctx[:bold] || ctx[:italic]
          variant = if ctx[:bold] && ctx[:italic]
                      :bold_italic
                    elsif ctx[:bold]
                      :bold
                    else
                      :italic
                    end
          item[:font] = [@base, { variant: variant }]
        end
        item[:underline] = true if ctx[:underline]
        item[:strikeout] = true if ctx[:strike]
        item[:superscript] = true if ctx[:super]
        item[:subscript] = true if ctx[:sub]
        item[:background_color] = @highlight_color if ctx[:highlight]
        if ctx[:link] && !ctx[:link].empty?
          item[:link] = ctx[:link]
          item[:fill_color] = @link_color
        end
        item
      end

      def inline_math(node, ctx, out)
        if (bytes = call_renderer(:math, node[:content].to_s, !!node[:display]))
          out << { box: [:image, StringIO.new(bytes)], height: 11, valign: :baseline }
        else
          out << run(node[:content].to_s, ctx.merge(code: true))
        end
      rescue StandardError
        out << run(node[:content].to_s, ctx.merge(code: true))
      end

      def inline_image(node, ctx, out)
        io = resolve_image(node[:src].to_s)
        if io
          out << { box: [:image, io], height: 12, valign: :baseline }
        else
          alt = node[:alt].to_s
          out << run(alt.empty? ? "[image]" : alt, ctx.merge(italic: true))
        end
      rescue StandardError
        out << run(node[:alt].to_s.empty? ? "[image]" : node[:alt].to_s, ctx.merge(italic: true))
      end

      # Resolve an image source to something HexaPDF can load: a local file
      # path, or a decoded +data:+ URI (as a StringIO). Returns nil for remote
      # URLs or unreadable sources (no network fetching).
      def resolve_image(src)
        return nil if src.empty?

        if src.start_with?("data:")
          meta, data = src.split(",", 2)
          return nil unless data

          bytes = meta.include?(";base64") ? Base64.decode64(data) : data
          return StringIO.new(bytes)
        end
        return src if File.file?(src)

        nil
      end

      # Invoke a renderer callable; return its String image bytes or nil.
      def call_renderer(key, *args)
        callable = @renderers[key] || @renderers[key.to_s]
        return nil unless callable

        result = callable.call(*args)
        result.is_a?(String) ? result : nil
      rescue StandardError
        nil
      end

      def inline_children?(children)
        Array(children).any? { |c| INLINE_TYPES.include?(c[:type]) }
      end

      INLINE_TYPES = %w[
        text emphasis code link image span math raw_inline emoji autolink
        cross_ref caption_number mention tag citation_group inline_extension
        abbreviation footnote soft_break hard_break critic_insert critic_delete
        critic_substitute critic_comment
      ].freeze
    end
  end
end
