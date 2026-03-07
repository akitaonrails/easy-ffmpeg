require "option_parser"

module EasyFfmpeg
  class CLI
    def self.run
      Display.setup

      preset = Preset::Default
      custom_output : String? = nil
      dry_run = false
      force = false
      no_subs = false
      input_path : String? = nil
      target_ext : String? = nil

      OptionParser.parse do |parser|
        parser.banner = "Usage: easy-ffmpeg <input> <format> [options]"
        parser.separator ""
        parser.separator "Arguments:"
        parser.separator "  input     Input video file path"
        parser.separator "  format    Output format (mp4, mkv, mov, webm, avi, ts)"
        parser.separator ""
        parser.separator "Presets:"

        parser.on("--web", "Optimize for web embedding (H.264, AAC, faststart)") { preset = Preset::Web }
        parser.on("--mobile", "Optimize for mobile (H.264 720p, AAC stereo)") { preset = Preset::Mobile }
        parser.on("--streaming", "Optimize for streaming (H.264, 2s keyframes, faststart)") { preset = Preset::Streaming }
        parser.on("--compress", "Reduce file size (H.265, CRF 28)") { preset = Preset::Compress }

        parser.separator ""
        parser.separator "Options:"

        parser.on("-o PATH", "--output=PATH", "Custom output file path") { |p| custom_output = p }
        parser.on("--dry-run", "Print ffmpeg command without executing") { dry_run = true }
        parser.on("--force", "Overwrite output file if it exists") { force = true }
        parser.on("--no-subs", "Drop all subtitle tracks") { no_subs = true }
        parser.on("-h", "--help", "Show this help") { puts parser; exit }
        parser.on("-v", "--version", "Show version") { puts "easy-ffmpeg #{VERSION}"; exit }

        parser.unknown_args do |args|
          input_path = args[0]? if args.size >= 1
          target_ext = args[1]? if args.size >= 2
        end

        parser.invalid_option do |flag|
          Display.show_error("unknown option: #{flag}")
          STDERR.puts ""
          STDERR.puts parser
          exit 1
        end

        parser.missing_option do |flag|
          Display.show_error("#{flag} requires an argument")
          exit 1
        end
      end

      # Validate input
      unless input = input_path
        Display.show_error("missing input file. Run with -h for help.")
        exit 1
      end

      unless File.exists?(input)
        Display.show_error("file not found: #{input}")
        exit 1
      end

      unless ext = target_ext
        Display.show_error("missing output format. Example: easy-ffmpeg input.mkv mp4")
        exit 1
      end

      # Normalize extension
      ext = ".#{ext}" unless ext.starts_with?(".")
      ext = ext.downcase

      unless CodecSupport.supported_output_format?(ext)
        Display.show_error("unsupported output format: #{ext}")
        STDERR.puts "  Supported: #{CodecSupport::EXT_TO_FORMAT.keys.map(&.lstrip('.')).join(", ")}"
        exit 1
      end

      target_format = CodecSupport.format_for_ext(ext).not_nil!

      # Check ffmpeg
      unless check_command("ffmpeg")
        Display.show_error("ffmpeg not found. Please install ffmpeg.")
        exit 1
      end
      unless check_command("ffprobe")
        Display.show_error("ffprobe not found. Please install ffmpeg.")
        exit 1
      end

      # Probe input
      info = begin
        MediaInfo.probe(input)
      rescue ex
        Display.show_error("failed to analyze: #{ex.message}")
        exit 1
      end

      if info.video_streams.empty? && info.audio_streams.empty?
        Display.show_error("no media streams found in #{input}")
        exit 1
      end

      Display.show_input(info)

      # Build output path
      dest = custom_output
      unless dest
        input_dir = File.dirname(input)
        input_stem = File.basename(input, File.extname(input))

        if File.extname(input).downcase == ext
          suffix = preset.default? ? "_converted" : "_#{preset.to_s.downcase}"
          dest = File.join(input_dir, "#{input_stem}#{suffix}#{ext}")
        else
          dest = File.join(input_dir, "#{input_stem}#{ext}")
        end
      end

      if File.exists?(dest) && !force
        Display.show_error("output file already exists: #{dest}")
        STDERR.puts "  Use --force to overwrite."
        exit 1
      end

      # Build conversion plan
      plan = ConversionPlan.new(info, dest, target_format, preset)

      # Apply --no-subs: override subtitle plans to Drop
      if no_subs
        plan.stream_plans.map! do |sp|
          if sp.stream.subtitle?
            StreamPlan.new(
              stream: sp.stream,
              action: StreamAction::Drop,
              reason: "--no-subs",
              output_codec_display: "",
            )
          else
            sp
          end
        end
      end

      Display.show_plan(plan)

      if dry_run
        converter = Converter.new(plan)
        Display.show_dry_run(converter.build_args)
        exit 0
      end

      # Run conversion
      converter = Converter.new(plan)
      success = converter.run
      exit(success ? 0 : 1)
    end

    private def self.check_command(name : String) : Bool
      status = Process.run("which", args: [name], output: Process::Redirect::Close, error: Process::Redirect::Close)
      status.success?
    end
  end
end
