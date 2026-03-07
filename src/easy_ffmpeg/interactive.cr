require "colorize"

module EasyFfmpeg
  module Interactive
    # ── Terminal size ──

    lib LibC
      struct Winsize
        ws_row : UInt16
        ws_col : UInt16
        ws_xpixel : UInt16
        ws_ypixel : UInt16
      end

      {% if flag?(:darwin) %}
        TIOCGWINSZ = 0x40087468_u64
      {% else %}
        TIOCGWINSZ = 0x5413_u64
      {% end %}

      fun ioctl(fd : Int32, request : UInt64, ...) : Int32
    end

    def self.terminal_cols : Int32
      ws = LibC::Winsize.new
      if LibC.ioctl(1, LibC::TIOCGWINSZ, pointerof(ws)) == 0 && ws.ws_col > 0
        ws.ws_col.to_i
      else
        80
      end
    end

    # ── Key reading ──

    enum Key
      Char
      Enter
      Backspace
      Up
      Down
      Left
      Right
      CtrlC
      CtrlW
      Escape
      Tab
    end

    struct KeyEvent
      getter key : Key
      getter char : Char

      def initialize(@key, @char = '\0')
      end
    end

    def self.read_key(io : IO) : KeyEvent
      byte = io.read_byte
      return KeyEvent.new(Key::CtrlC) unless byte

      case byte
      when 3_u8    then KeyEvent.new(Key::CtrlC)
      when 9_u8    then KeyEvent.new(Key::Tab)
      when 13_u8   then KeyEvent.new(Key::Enter)
      when 23_u8   then KeyEvent.new(Key::CtrlW)
      when 127_u8  then KeyEvent.new(Key::Backspace)
      when 8_u8    then KeyEvent.new(Key::Backspace)
      when 27_u8
        # Escape sequence
        b2 = io.read_byte
        return KeyEvent.new(Key::Escape) unless b2
        if b2 == 91_u8 # '['
          b3 = io.read_byte
          return KeyEvent.new(Key::Escape) unless b3
          case b3
          when 65_u8 then KeyEvent.new(Key::Up)
          when 66_u8 then KeyEvent.new(Key::Down)
          when 67_u8 then KeyEvent.new(Key::Right)
          when 68_u8 then KeyEvent.new(Key::Left)
          else            KeyEvent.new(Key::Escape)
          end
        else
          KeyEvent.new(Key::Escape)
        end
      else
        ch = byte.chr
        if ch.printable? || ch == ' '
          KeyEvent.new(Key::Char, ch)
        else
          KeyEvent.new(Key::Escape)
        end
      end
    end

    # ── ANSI helpers ──

    def self.clear_lines(n : Int32)
      n.times do
        print "\e[A\e[2K"
      end
      print "\r"
      STDOUT.flush
    end

    def self.hide_cursor
      print "\e[?25l"
      STDOUT.flush
    end

    def self.show_cursor
      print "\e[?25h"
      STDOUT.flush
    end

    def self.reset_colors
      print "\e[0m"
      STDOUT.flush
    end

    def self.beep
      print "\a"
      STDOUT.flush
    end

    # ── Fuzzy matching ──

    module FuzzyMatch
      SEPARATOR_CHARS = {'.', '-', '_', '/', ' '}

      def self.score(query : String, candidate : String) : Int32?
        return 0 if query.empty?
        q = query.downcase
        c = candidate.downcase

        qi = 0
        ci = 0
        total = 0
        last_match = -2

        while qi < q.size && ci < c.size
          if q[qi] == c[ci]
            total += 1
            # Consecutive match bonus
            total += 5 if ci == last_match + 1
            # Start of string bonus
            total += 10 if ci == 0
            # After separator bonus
            total += 8 if ci > 0 && SEPARATOR_CHARS.includes?(candidate[ci - 1])
            # Case exact match bonus
            total += 2 if query[qi] == candidate[ci]
            last_match = ci
            qi += 1
          end
          ci += 1
        end

        qi == q.size ? total : nil
      end

      def self.match_indices(query : String, candidate : String) : Array(Int32)
        indices = [] of Int32
        return indices if query.empty?
        q = query.downcase
        c = candidate.downcase
        qi = 0
        c.each_char_with_index do |ch, ci|
          if qi < q.size && q[qi] == ch
            indices << ci
            qi += 1
          end
        end
        indices
      end

      def self.highlight(query : String, candidate : String) : String
        indices = match_indices(query, candidate)
        return candidate if indices.empty?
        result = String::Builder.new
        candidate.each_char_with_index do |ch, i|
          if indices.includes?(i)
            result << "\e[1;33m" << ch << "\e[0m"
          else
            result << ch
          end
        end
        result.to_s
      end
    end

    # ── Main entry point ──

    def self.run
      at_exit { show_cursor; reset_colors }
      Signal::INT.trap { show_cursor; reset_colors; exit 130 }

      Display.setup

      puts ""
      puts " #{"easy-ffmpeg".colorize(:cyan)} interactive mode"
      puts ""

      # Check dependencies
      unless CLI.check_command("ffmpeg") && CLI.check_command("ffprobe")
        Display.show_error("ffmpeg/ffprobe not found. Please install ffmpeg.")
        exit 1
      end

      # Step 1: Pick input file
      input_path = step_file_picker
      return unless input_path

      # Probe input
      info = begin
        MediaInfo.probe(input_path)
      rescue ex
        Display.show_error("failed to analyze: #{ex.message}")
        exit 1
      end

      if info.video_streams.empty? && info.audio_streams.empty?
        Display.show_error("no media streams found in #{input_path}")
        exit 1
      end

      Display.show_input(info)
      puts ""

      # Step 2: Output name
      output_path = step_output_name(input_path)
      return unless output_path

      # Step 3: Preset
      preset = step_preset
      return unless preset

      # Step 4: Start time
      start_time = step_time("Start time", "00:00:00.000")
      return unless start_time

      # Step 5: End time
      total_dur = info.format.duration
      default_end = format_timestamp_full(total_dur)
      end_time = step_time("End time", default_end)
      return unless end_time

      # Determine trim values
      actual_start : Float64? = nil
      actual_end : Float64? = nil

      parsed_start = EasyFfmpeg.parse_time(start_time).not_nil!
      parsed_end = EasyFfmpeg.parse_time(end_time).not_nil!

      if parsed_start > 0.01 || (total_dur - parsed_end).abs > 0.5
        actual_start = parsed_start if parsed_start > 0.01
        actual_end = parsed_end if (total_dur - parsed_end).abs > 0.5
      end

      # Check output exists
      if File.exists?(output_path)
        unless step_confirm_overwrite(output_path)
          puts " Cancelled."
          return
        end
      end

      # Determine target format
      ext = File.extname(output_path).downcase
      target_format = CodecSupport.format_for_ext(ext).not_nil!

      # Build plan
      plan = ConversionPlan.new(info, output_path, target_format, preset,
        start_time: actual_start, end_time: actual_end)

      Display.show_plan(plan)

      # Step 6: Confirm
      unless step_confirm_run
        puts " Cancelled."
        return
      end

      # Run conversion
      converter = Converter.new(plan)
      success = converter.run
      exit(success ? 0 : 1)
    end

    # ── Step 1: File picker with fuzzy search ──

    private def self.step_file_picker : String?
      extensions = CodecSupport::EXT_TO_FORMAT.keys
      files = Dir.glob("*").select do |f|
        File.file?(f) && extensions.includes?(File.extname(f).downcase)
      end.sort

      if files.empty?
        Display.show_error("no media files found in current directory")
        STDERR.puts "  Supported: #{extensions.map { |e| e.lstrip('.') }.join(", ")}"
        exit 1
      end

      query = ""
      selected = 0
      scroll_offset = 0
      max_visible = 10

      draw_file_picker(files, query, selected, scroll_offset, max_visible)
      lines_drawn = rendered_line_count(files, query, max_visible)

      result = nil
      loop do
        event = STDIN.raw { |io| STDIN.noecho { read_key(io) } }

        case event.key
        when .ctrl_c?, .escape?
          clear_lines(lines_drawn)
          return nil
        when .enter?
          filtered = filter_files(files, query)
          unless filtered.empty?
            result = filtered[selected]
          end
          break
        when .backspace?
          unless query.empty?
            query = query[0...-1]
            selected = 0
            scroll_offset = 0
          end
        when .ctrl_w?
          query = ""
          selected = 0
          scroll_offset = 0
        when .up?
          filtered = filter_files(files, query)
          unless filtered.empty?
            selected = (selected - 1) % filtered.size
          end
        when .down?
          filtered = filter_files(files, query)
          unless filtered.empty?
            selected = (selected + 1) % filtered.size
          end
        when .char?
          query += event.char
          selected = 0
          scroll_offset = 0
        end

        # Adjust scroll
        filtered = filter_files(files, query)
        unless filtered.empty?
          selected = selected.clamp(0, filtered.size - 1)
          if selected < scroll_offset
            scroll_offset = selected
          elsif selected >= scroll_offset + max_visible
            scroll_offset = selected - max_visible + 1
          end
        end

        clear_lines(lines_drawn)
        draw_file_picker(files, query, selected, scroll_offset, max_visible)
        lines_drawn = rendered_line_count(files, query, max_visible)
      end

      clear_lines(lines_drawn)
      if result
        puts " #{"Input".ljust(10).colorize(:cyan)}#{result}"
      end
      result
    end

    private def self.filter_files(files : Array(String), query : String) : Array(String)
      return files if query.empty?
      scored = files.compact_map do |f|
        s = FuzzyMatch.score(query, f)
        s ? {f, s} : nil
      end
      scored.sort_by! { |pair| -pair[1] }
      scored.map { |pair| pair[0] }
    end

    private def self.draw_file_picker(files : Array(String), query : String, selected : Int32, scroll_offset : Int32, max_visible : Int32)
      filtered = filter_files(files, query)
      print " #{"Select input file".colorize(:cyan)} "
      puts "(#{filtered.size}/#{files.size} files, arrows to navigate, type to filter)"

      puts " \e[1m> #{query}\e[0m\e[K"

      if filtered.empty?
        puts "   #{"no matches".colorize(:dark_gray)}"
      else
        visible = filtered[scroll_offset, max_visible]
        visible.each_with_index do |f, i|
          actual_idx = scroll_offset + i
          prefix = actual_idx == selected ? " \e[7m" : "  "
          suffix = actual_idx == selected ? "\e[0m" : ""
          display = query.empty? ? f : FuzzyMatch.highlight(query, f)
          puts "#{prefix} #{display} #{suffix}"
        end

        if filtered.size > max_visible
          remaining = filtered.size - scroll_offset - max_visible
          if remaining > 0
            puts "   #{"...#{remaining} more".colorize(:dark_gray)}"
          end
        end
      end
      STDOUT.flush
    end

    private def self.rendered_line_count(files : Array(String), query : String, max_visible : Int32) : Int32
      filtered = filter_files(files, query)
      lines = 2 # header + query line
      if filtered.empty?
        lines += 1
      else
        lines += Math.min(filtered.size, max_visible)
        remaining = filtered.size - max_visible
        lines += 1 if remaining > 0
      end
      lines
    end

    # ── Step 2: Output name editor ──

    private def self.step_output_name(input_path : String) : String?
      stem = File.basename(input_path, File.extname(input_path))
      ext = File.extname(input_path)
      text = "#{stem}#{ext}"
      cursor = stem.size # position before the dot

      draw_output_editor(text, cursor, nil)

      result = nil
      loop do
        event = STDIN.raw { |io| STDIN.noecho { read_key(io) } }

        case event.key
        when .ctrl_c?, .escape?
          clear_lines(2)
          return nil
        when .enter?
          out_ext = File.extname(text).downcase
          if out_ext.empty? || !CodecSupport.supported_output_format?(out_ext)
            supported = CodecSupport::EXT_TO_FORMAT.keys.map { |e| e.lstrip('.') }.join(", ")
            clear_lines(2)
            draw_output_editor(text, cursor, "unsupported format. Supported: #{supported}")
            beep
            next
          end
          result = text
          break
        when .backspace?
          if cursor > 0
            text = text[0...cursor - 1] + text[cursor..]
            cursor -= 1
          end
        when .ctrl_w?
          # Clear word before cursor
          if cursor > 0
            new_cursor = cursor - 1
            while new_cursor > 0 && text[new_cursor - 1] != ' ' && text[new_cursor - 1] != '.'
              new_cursor -= 1
            end
            text = text[0...new_cursor] + text[cursor..]
            cursor = new_cursor
          end
        when .left?
          cursor = Math.max(0, cursor - 1)
        when .right?
          cursor = Math.min(text.size, cursor + 1)
        when .char?
          text = text[0...cursor] + event.char + text[cursor..]
          cursor += 1
        end

        clear_lines(2)
        draw_output_editor(text, cursor, nil)
      end

      clear_lines(2)
      if result
        puts " #{"Output".ljust(10).colorize(:cyan)}#{result}"
      end
      result
    end

    private def self.draw_output_editor(text : String, cursor : Int32, error : String?)
      print " #{"Output name".colorize(:cyan)} "
      if error
        puts "(#{"#{error}".colorize(:red)})"
      else
        puts "(type to edit, Enter to confirm)"
      end

      # Show text with cursor
      before = text[0...cursor]
      cursor_char = cursor < text.size ? text[cursor].to_s : " "
      after = cursor < text.size - 1 ? text[cursor + 1..] : ""
      # Use reverse video for cursor position
      puts "  #{before}\e[7m#{cursor_char}\e[0m#{after}"
      STDOUT.flush
    end

    # ── Step 3: Preset selection ──

    PRESET_OPTIONS = [
      {Preset::Default, "Default", "Copy streams when compatible, transcode only if needed"},
      {Preset::Web, "Web", "H.264 + AAC, optimized for web embedding"},
      {Preset::Mobile, "Mobile", "H.264 720p + AAC stereo, optimized for phones"},
      {Preset::Streaming, "Streaming", "H.265 high-quality, consumer-friendly (Netflix/YouTube-like)"},
      {Preset::Compress, "Compress", "H.265 CRF 28, reduce file size"},
    ]

    private def self.step_preset : Preset?
      selected = 0
      draw_preset_menu(selected)
      lines = PRESET_OPTIONS.size + 1

      loop do
        event = STDIN.raw { |io| STDIN.noecho { read_key(io) } }

        case event.key
        when .ctrl_c?, .escape?
          clear_lines(lines)
          return nil
        when .enter?
          break
        when .up?
          selected = (selected - 1) % PRESET_OPTIONS.size
        when .down?
          selected = (selected + 1) % PRESET_OPTIONS.size
        end

        clear_lines(lines)
        draw_preset_menu(selected)
      end

      clear_lines(lines)
      choice = PRESET_OPTIONS[selected]
      puts " #{"Preset".ljust(10).colorize(:cyan)}#{choice[1]}"
      choice[0]
    end

    private def self.draw_preset_menu(selected : Int32)
      puts " #{"Preset".colorize(:cyan)}     (arrows to select, Enter to confirm)"
      PRESET_OPTIONS.each_with_index do |opt, i|
        name = opt[1]
        desc = opt[2]
        if i == selected
          puts " \e[7m  #{name.ljust(12)} #{desc} \e[0m"
        else
          puts "   #{name.ljust(12).colorize(:white)} #{desc.colorize(:dark_gray)}"
        end
      end
      STDOUT.flush
    end

    # ── Step 4 & 5: Time input ──

    private def self.step_time(label : String, default : String) : String?
      text = default
      cursor = text.size

      draw_time_input(label, text, cursor, nil)

      loop do
        event = STDIN.raw { |io| STDIN.noecho { read_key(io) } }

        case event.key
        when .ctrl_c?, .escape?
          clear_lines(2)
          return nil
        when .enter?
          parsed = EasyFfmpeg.parse_time(text)
          if parsed
            break
          else
            clear_lines(2)
            draw_time_input(label, text, cursor, "invalid time format (e.g. 1:30, 0:01:30.000)")
            beep
            next
          end
        when .backspace?
          if cursor > 0
            text = text[0...cursor - 1] + text[cursor..]
            cursor -= 1
          end
        when .ctrl_w?
          text = ""
          cursor = 0
        when .left?
          cursor = Math.max(0, cursor - 1)
        when .right?
          cursor = Math.min(text.size, cursor + 1)
        when .char?
          ch = event.char
          if ch.ascii_number? || ch == ':' || ch == '.'
            text = text[0...cursor] + ch + text[cursor..]
            cursor += 1
          else
            beep
          end
        end

        clear_lines(2)
        draw_time_input(label, text, cursor, nil)
      end

      clear_lines(2)
      puts " #{label.ljust(10).colorize(:cyan)}#{text}"
      text
    end

    private def self.draw_time_input(label : String, text : String, cursor : Int32, error : String?)
      print " #{label.colorize(:cyan)} "
      if error
        puts "(#{"#{error}".colorize(:red)})"
      else
        puts "(Enter to accept, digits/:/. only)"
      end

      before = text[0...cursor]
      cursor_char = cursor < text.size ? text[cursor].to_s : " "
      after = cursor < text.size - 1 ? text[cursor + 1..] : ""
      puts "  #{before}\e[7m#{cursor_char}\e[0m#{after}"
      STDOUT.flush
    end

    # ── Step 6: Confirmations ──

    private def self.step_confirm_overwrite(path : String) : Bool
      print " Output file already exists. #{"Overwrite?".colorize(:yellow)} [y/N] "
      STDOUT.flush

      loop do
        event = STDIN.raw { |io| STDIN.noecho { read_key(io) } }
        case event.key
        when .ctrl_c?, .escape?
          puts ""
          return false
        when .enter?
          puts "n"
          return false
        when .char?
          case event.char
          when 'y', 'Y'
            puts "y"
            return true
          when 'n', 'N'
            puts "n"
            return false
          end
        end
      end
    end

    private def self.step_confirm_run : Bool
      print " #{"Start conversion?".colorize(:cyan)} [Y/n] "
      STDOUT.flush

      loop do
        event = STDIN.raw { |io| STDIN.noecho { read_key(io) } }
        case event.key
        when .ctrl_c?, .escape?
          puts ""
          return false
        when .enter?
          puts "y"
          return true
        when .char?
          case event.char
          when 'y', 'Y'
            puts "y"
            return true
          when 'n', 'N'
            puts "n"
            return false
          end
        end
      end
    end

    # ── Helpers ──

    private def self.format_timestamp_full(seconds : Float64) : String
      return "00:00:00.000" if seconds <= 0
      total_ms = (seconds * 1000).to_i64
      h = total_ms // 3_600_000
      m = (total_ms % 3_600_000) // 60_000
      s = (total_ms % 60_000) // 1000
      ms = total_ms % 1000
      "%02d:%02d:%02d.%03d" % {h, m, s, ms}
    end
  end
end
