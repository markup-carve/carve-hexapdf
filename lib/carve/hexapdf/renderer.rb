# frozen_string_literal: true

require "stringio"
require "base64"

require_relative "style_map"

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
      def initialize(composer, base_font: nil, code_font: nil,
                     link_color: nil, highlight_color: nil, styles: nil, renderers: nil)
        @c = composer
        @layout = composer.document.layout
        @styles = StyleMap.new(style_sugar(base_font: base_font, code_font: code_font,
                                           link_color: link_color,
                                           highlight_color: highlight_color,
                                           styles: styles))
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

      def style_sugar(base_font:, code_font:, link_color:, highlight_color:, styles:)
        sugar = {}
        sugar["base"] = { font: base_font } unless base_font.nil?
        sugar["code"] = { font: code_font } unless code_font.nil?
        sugar["link"] = { fill_color: link_color } unless link_color.nil?
        sugar["highlight"] = { background_color: highlight_color } unless highlight_color.nil?
        return sugar if styles.nil?
        unless styles.respond_to?(:each_pair)
          raise ArgumentError, "styles must be a Hash-like object"
        end

        styles.each_pair.with_object(sugar) do |(key, value), out|
          key = key.to_s
          out[key] = (out[key] || {}).merge(value)
        end
      end

      # The default base font ("Times") matches HexaPDF's own default, so it is
      # stripped from block styles to keep default output identical to what the
      # composer would produce anyway; a USER-set font at any chain level
      # (including base) must survive into the block style.
      #
      # :box is a pseudo-property consumed only by sites that draw a surrounding
      # box (code blocks, quotes, admonitions, ...); everywhere else it would
      # crash HexaPDF's style handling, so it is stripped unless requested.
      def style_for(key, inherited_font: false, with_box: false)
        style = @styles.resolve(key).dup
        style.delete(:font) unless inherited_font || @styles.user_set_in_chain?(key, :font)
        style.delete(:box) unless with_box
        style
      end

      def heading(node, target)
        style = style_for("heading.#{node[:level]}")
        runs = inline_runs(node[:children], bold: true, font_family: style[:font])
        return if runs.empty?

        target.formatted_text(runs, **style)
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
        merged = style_for("paragraph").merge(style)
        runs = inline_runs(children, font_family: merged[:font])
        return if runs.empty?

        target.formatted_text(runs, **merged)
      end

      def code_block(node, target)
        lang = node[:lang].to_s.downcase
        if (key = DIAGRAM_LANGS[lang]) && (bytes = call_renderer(key, node[:content].to_s))
          return image_bytes(bytes, target)
        end

        content = node[:content].to_s.chomp
        style = style_for("code.block", inherited_font: true, with_box: true)
        box = style.delete(:box)
        target.text(content, **style, box_style: box)
      end

      def list(node, target)
        # The list box is structural: item text styling flows through the
        # paragraph chain, and Composer#list rejects text keywords (:font,
        # :font_size, ...) that the chain inherits from base - whitelist.
        style = style_for("list").slice(:item_spacing, :content_indentation)
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
        style[:content_indentation] = 4 if task && !@styles.user_set?("list", :content_indentation)

        target.list(**style, marker_type: marker, start_number: start) do |list_box|
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
        para_style = style_for("paragraph").merge(margin: [0, 0, 2])
        first_para_done = false
        children.each do |ch|
          if prefix && !first_para_done && ch[:type] == "paragraph"
            runs = [{ text: prefix }] + inline_runs(ch[:children], font_family: para_style[:font])
            cell.formatted_text(runs, **para_style)
            first_para_done = true
          else
            block(ch, cell)
          end
        end
        cell.formatted_text([{ text: prefix }], **para_style.except(:margin)) if prefix && !first_para_done
      end

      def block_quote(node, target)
        target.container(style: style_for("quote", with_box: true)[:box]) do |cont|
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
        kind = node[:kind].to_s
        key = kind.empty? || kind.include?(".") ? "admonition" : "admonition.#{kind}"
        style = style_for(key, with_box: true)
        target.container(style: style[:box]) do |cont|
          title = node[:title] && !node[:title].empty? ? node[:title] : [{ type: "text", value: node[:kind].to_s.capitalize }]
          cont.formatted_text(inline_runs(title, bold: true, font_family: style[:font]),
                              margin: style[:title_margin])
          Array(node[:children]).each { |ch| block(ch, cont) }
        end
      end

      def definition_list(node, target)
        style = style_for("definition_list", with_box: true)
        target.container(style: style[:box]) do |cont|
          Array(node[:items]).each do |item|
            Array(item[:terms]).each do |term|
              cont.formatted_text(inline_runs(term, bold: true), margin: [2, 0, 1])
            end
            Array(item[:definitions]).each do |defn|
              cont.container(style: { padding: [0, 0, 0, style[:definition_indent]] }) do |dcont|
                Array(defn).each { |ch| block(ch, dcont) }
              end
            end
          end
        end
      end

      def figure(node, target)
        block(node[:target], target) if node[:target]
        if node[:caption] && !node[:caption].empty?
          style = style_for("figure.caption")
          target.formatted_text(inline_runs(node[:caption], italic: true, font_family: style[:font]),
                                **style)
        end
      end

      def image_block(node, target)
        io = resolve_image(node[:src].to_s)
        if io
          target.image(io, **style_for("image"))
        else
          alt = node[:alt].to_s
          alt = "[image: #{node[:src]}]" if alt.empty?
          target.formatted_text([{ text: alt, font: [base_font, { variant: :italic }] }],
                                margin: [0, 0, BLOCK_GAP])
        end
      end

      def display_math(node, target)
        if (bytes = call_renderer(:math, node[:content].to_s, true))
          return image_bytes(bytes, target, align: :center)
        end

        style = style_for("math", with_box: true)
        box = style.delete(:box)
        style[:font] ||= code_font
        target.text(node[:content].to_s, **style, text_align: :center, box_style: box)
      end

      def thematic_break(target)
        style = style_for("thematic_break")
        height = style.delete(:height)
        target.box(:base, height: height, style: style)
      end

      # Draw raster image bytes as a block image.
      def image_bytes(bytes, target, align: nil)
        style = style_for("image")
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
        table_style = style_for("table")
        header_style = style_for("table.header")

        cell_boxes = resolved.map do |row|
          row.map do |o|
            cell_style = o[:header] ? table_style.merge(header_style) : table_style
            runs = inline_runs(o[:cell][:children], bold: o[:header],
                               font_family: cell_style[:font])
            runs = [{ text: "" }] if runs.empty?
            # :margin belongs to the table box, :cell_padding is our pseudo-prop.
            box_opts = cell_style.except(:margin, :cell_padding, :box)
            box_opts[:padding] = cell_style[:cell_padding]
            box = @layout.formatted_text_box(runs, **box_opts)
            hash = { content: box }
            hash[:col_span] = o[:col_span] if o[:col_span] > 1
            hash[:row_span] = o[:row_span] if o[:row_span] > 1
            hash
          end
        end

        header = header_count.positive? ? ->(_t) { [cell_boxes.first] } : nil
        body = header_count.positive? ? cell_boxes[1..] : cell_boxes
        body = [[{ content: @layout.text_box("") }]] if body.nil? || body.empty?

        target.table(body, header: header, margin: table_style[:margin])
        if node[:caption] && !node[:caption].empty?
          style = style_for("table.caption")
          target.formatted_text(inline_runs(node[:caption], italic: true, font_family: style[:font]),
                                **style)
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
          # :box is a block-level pseudo-property (e.g. inherited from a user
          # "code" entry meant for code.block); HexaPDF would read a run :box
          # as an inline box spec and crash.
          item.merge!(@styles.resolve("code.inline").except(:box))
        elsif ctx[:bold] || ctx[:italic]
          variant = if ctx[:bold] && ctx[:italic]
                      :bold_italic
                    elsif ctx[:bold]
                      :bold
                    else
                      :italic
                    end
          item[:font] = [ctx[:font_family] || base_font, { variant: variant }]
        end
        item[:underline] = true if ctx[:underline]
        item[:strikeout] = true if ctx[:strike]
        item[:superscript] = true if ctx[:super]
        item[:subscript] = true if ctx[:sub]
        item.merge!(run_style("highlight")) if ctx[:highlight]
        if ctx[:link] && !ctx[:link].empty?
          item[:link] = ctx[:link]
          item.merge!(run_style("link"))
        end
        item
      end

      # Link/highlight styles are decoration overlays on a run that may already
      # carry a variant or code font; the font they inherit from +base+ must not
      # clobber it (only a font set explicitly on the key itself wins), and a
      # block-level :box pseudo-property must never reach a run.
      def run_style(key)
        style = @styles.resolve(key).except(:box)
        return style if @styles.user_set?(key, :font)

        style.except(:font)
      end

      def base_font
        @styles.resolve("base")[:font]
      end

      def code_font
        @styles.resolve("code.inline")[:font]
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
