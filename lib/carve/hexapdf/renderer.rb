# frozen_string_literal: true

module Carve
  module Hexapdf
    # Walks a Carve AST (as produced by +Carve.parse+) and draws it onto a
    # HexaPDF::Composer, producing a laid-out PDF document.
    #
    # The mapping is structural: Carve block nodes become HexaPDF boxes (text,
    # list, table, container, image) and Carve inline nodes become the
    # multi-part styled "runs" that HexaPDF::Composer#formatted_text consumes.
    # Bold/italic map to font variants, inline code to Courier, links to a
    # colored run with a URI overlay.
    #
    # The renderer never raises on an unknown or unsupported node: it degrades
    # to the node's text/children so a document always renders. Constructs with
    # no meaningful PDF form (raw HTML, comments) are dropped.
    class Renderer
      # Point sizes for headings h1..h6.
      HEADING_SIZE = { 1 => 22, 2 => 18, 3 => 15, 4 => 13, 5 => 12, 6 => 11 }.freeze

      # Bottom margin (pt) placed under common block types.
      BLOCK_GAP = 8

      def initialize(composer, base_font: "Times", code_font: "Courier",
                     link_color: "hp-blue")
        @c = composer
        @layout = composer.document.layout
        @base = base_font
        @code_font = code_font
        @link_color = link_color
      end

      # Render a whole document node (the value returned by +Carve.parse+).
      def render_document(doc)
        Array(doc[:children]).each { |node| block(node, @c) }
        @c
      end

      # ---- block dispatch ------------------------------------------------

      # Draw a single block +node+ onto +target+ (the composer or a nested box
      # builder yielded by +list+/+container+ - both expose the same box
      # factory methods).
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
          # Unknown block: degrade to its inline children or nested blocks.
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
        emit_paragraph(node[:children], target)
      end

      def emit_paragraph(children, target, **style)
        runs = inline_runs(children)
        return if runs.empty?

        target.formatted_text(runs, **{ margin: [0, 0, BLOCK_GAP] }.merge(style))
      end

      def code_block(node, target)
        content = node[:content].to_s
        content = content.chomp
        target.text(content, font: @code_font, font_size: 9, margin: [2, 0, BLOCK_GAP],
                    box_style: { background_color: "f2f2f2", padding: 6 })
      end

      def list(node, target)
        items = Array(node[:items])
        ordered = node[:ordered]
        task = items.any? { |it| !it[:checked].nil? }
        # Standard PDF fonts lack a checkbox glyph, so task lists suppress the
        # list marker (empty-marker Proc) and prefix an ASCII checkbox instead.
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

      # Render a list item's block children into +cell+. When +prefix+ is set
      # (task-list checkbox), it is prepended to the item's first paragraph.
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
        # An item that was only a checkbox with non-paragraph content still
        # needs the marker shown.
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
        src = node[:src].to_s
        if File.file?(src)
          target.image(src, margin: [2, 0, BLOCK_GAP])
        else
          alt = node[:alt].to_s
          alt = "[image: #{src}]" if alt.empty?
          target.formatted_text([{ text: alt, font: [@base, { variant: :italic }] }],
                                margin: [0, 0, BLOCK_GAP])
        end
      end

      def thematic_break(target)
        target.box(:base, height: 2,
                   style: { margin: [BLOCK_GAP, 0, BLOCK_GAP], background_color: "cccccc" })
      end

      def table(node, target)
        rows = Array(node[:rows])
        return if rows.empty?

        has_header = rows.first && Array(rows.first[:cells]).any? { |c| c[:header] }
        cells = rows.map do |row|
          Array(row[:cells]).map do |c|
            runs = inline_runs(c[:children], bold: c[:header])
            runs = [{ text: "" }] if runs.empty?
            @layout.formatted_text_box(runs, font_size: 10, padding: 4)
          end
        end

        header = has_header ? ->(_table) { [cells.first] } : nil
        body = has_header ? cells[1..] : cells
        body = [[@layout.text_box("")]] if body.nil? || body.empty?
        target.table(body, header: header, margin: [2, 0, BLOCK_GAP])
        if node[:caption] && !node[:caption].empty?
          target.formatted_text(inline_runs(node[:caption], italic: true),
                                font_size: 9, margin: [0, 0, BLOCK_GAP])
        end
      end

      # ---- inline flattening ---------------------------------------------

      # Flatten a list of Carve inline nodes into an array of HexaPDF
      # formatted-text run hashes. +ctx+ carries accumulated styling
      # (:bold, :italic, :code, :link) down the inline tree.
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
        when "math"       then out << run(node[:content].to_s, ctx.merge(code: true))
        when "link"
          lctx = ctx.merge(link: node[:href].to_s)
          if node[:children] && !node[:children].empty?
            node[:children].each { |c| emit_inline(c, lctx, out) }
          else
            out << run(node[:href].to_s, lctx)
          end
        when "autolink" then out << run(node[:href].to_s, ctx.merge(link: node[:href].to_s))
        when "image"
          alt = node[:alt].to_s
          out << run(alt.empty? ? "[image]" : alt, ctx.merge(italic: true))
        when "emoji"   then out << run(":#{node[:name]}:", ctx)
        when "mention" then out << run("@#{node[:user]}", ctx)
        when "tag"     then out << run("##{node[:name]}", ctx)
        when "footnote"
          out << run("[#{node[:number]}]", ctx) if node[:number]
        when "citation_group" then out << run(node[:raw].to_s, ctx)
        when "abbreviation"   then out << run(node[:abbr].to_s, ctx)
        when "cross_ref"      then out << run(node[:target].to_s, ctx)
        when "caption_number" then (out << run(node[:number].to_s, ctx) if node[:number])
        when "critic_insert", "critic_delete" then emit_children(node, ctx, out)
        when "critic_substitute" then out << run(node[:new_text].to_s, ctx)
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
        else ctx # underline/strike/super/sub/highlight: keep text, no font change
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
        if ctx[:link] && !ctx[:link].empty?
          item[:link] = ctx[:link]
          item[:fill_color] = @link_color
        end
        item
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
