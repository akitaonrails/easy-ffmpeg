require "option_parser"

module EasyFfmpeg
  class CLI
    def self.run
      if ARGV.empty? && STDIN.tty?
        Interactive.run
        return
      end

      Display.setup

      preset = Preset::Default
      custom_output : String? = nil
      dry_run = false
      force = false
      no_subs = false
      start_time : Float64? = nil
      end_time : Float64? = nil
      duration : Float64? = nil
      fps_override : Int32? = nil
      scale : String? = nil
      aspect : String? = nil
      crop = false
      input_path : String? = nil
      target_ext : String? = nil

      OptionParser.parse do |parser|
        parser.banner = "Usage: easy-ffmpeg <input> <format> [options]"
        parser.separator ""
        parser.separator "Arguments:"
        parser.separator "  input       Input video file or image directory"
        parser.separator "  format      Output format (mp4, mkv, mov, webm, avi, ts, gif)"
        parser.separator ""
        parser.separator "Presets:"

        parser.on("--web", "Optimize for web embedding (H.264, AAC, faststart)") { preset = Preset::Web }
        parser.on("--mobile", "Optimize for mobile (H.264 720p, AAC stereo)") { preset = Preset::Mobile }
        parser.on("--streaming", "Consumer-friendly quality (H.265, Netflix/YouTube-like)") { preset = Preset::Streaming }
        parser.on("--compress", "Reduce file size (H.265, CRF 28)") { preset = Preset::Compress }

        parser.separator ""
        parser.separator "Trimming:"

        parser.on("--start TIME", "Start time (cuts from beginning)") do |t|
          start_time = parse_time_or_exit(t, "--start")
        end
        parser.on("--end TIME", "End time (cuts from end)") do |t|
          end_time = parse_time_or_exit(t, "--end")
        end
        parser.on("--duration SECS", "Max duration from start point") do |t|
          duration = parse_time_or_exit(t, "--duration")
        end

        parser.separator ""
        parser.separator "Options:"

        parser.on("--fps N", "Frame rate for image sequences (default: 24 video, 10 GIF)") do |n|
          val = n.to_i?
          unless val && val >= 1 && val <= 120
            Display.show_error("--fps must be between 1 and 120")
            exit 1
          end
          fps_override = val
        end
        parser.on("--scale NAME", "Scale resolution (2k, fullhd, hd, retro, icon)") do |s|
          unless SCALE_HEIGHTS.has_key?(s)
            Display.show_error("unknown scale '#{s}'. Valid options: #{SCALE_HEIGHTS.keys.join(", ")}")
            exit 1
          end
          scale = s
        end
        parser.on("--aspect RATIO", "Aspect ratio (wide, 4:3, 8:7, square, tiktok)") do |a|
          unless ASPECT_RATIOS.has_key?(a)
            Display.show_error("unknown aspect ratio '#{a}'. Valid options: #{ASPECT_RATIOS.keys.join(", ")}")
            exit 1
          end
          aspect = a
        end
        parser.on("--crop", "Crop to aspect ratio instead of padding") { crop = true }
        parser.on("-o PATH", "--output=PATH", "Custom output file path") { |p| custom_output = p }
        parser.on("--dry-run", "Print ffmpeg command without executing") { dry_run = true }
        parser.on("--force", "Overwrite output file if it exists") { force = true }
        parser.on("--no-subs", "Drop all subtitle tracks") { no_subs = true }
        parser.on("-h", "--help", "Show help and examples") { show_help(parser); exit }
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

      # Validate --crop requires --aspect
      if crop && aspect.nil?
        Display.show_error("--crop requires --aspect")
        exit 1
      end

      # Validate input
      unless input = input_path
        Display.show_error("missing input file. Run with -h for help.")
        exit 1
      end

      # Image sequence mode: input is a directory
      if Dir.exists?(input)
        unless ext = target_ext
          Display.show_error("missing output format. Example: easy-ffmpeg /path/to/frames/ mp4")
          exit 1
        end
        ext = ".#{ext}" unless ext.starts_with?(".")
        ext = ext.downcase

        if start_time || end_time || duration
          Display.show_error("--start/--end/--duration are not supported for image sequences")
          exit 1
        end

        run_image_sequence(input, ext, fps_override, preset, custom_output, dry_run, force,
                           scale, aspect, crop)
        return
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

      # Validate trim options
      if end_time && duration
        Display.show_error("cannot use both --end and --duration. Pick one.")
        exit 1
      end

      if (st = start_time) && (et = end_time) && et <= st
        Display.show_error("--end (#{et}) must be after --start (#{st})")
        exit 1
      end

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

      # Validate trim against actual duration
      total = info.format.duration
      if total > 0
        if (st = start_time) && st >= total
          Display.show_error("--start #{st}s is beyond the end of the file (#{EasyFfmpeg.format_duration(total)})")
          exit 1
        end
        if (et = end_time) && et > total
          Display.show_error("--end #{et}s is beyond the end of the file (#{EasyFfmpeg.format_duration(total)})")
          exit 1
        end
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
      plan = ConversionPlan.new(info, dest, target_format, preset,
        start_time: start_time, end_time: end_time, duration: duration,
        scale: scale, aspect: aspect, crop: crop)

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

    private def self.run_image_sequence(input : String, ext : String, fps_override : Int32?,
                                        preset : Preset, custom_output : String?,
                                        dry_run : Bool, force : Bool,
                                        scale : String?, aspect : String?, crop : Bool)
      is_gif = ext == ".gif"

      unless is_gif || CodecSupport.supported_output_format?(ext)
        Display.show_error("unsupported output format: #{ext}")
        supported = CodecSupport::EXT_TO_FORMAT.keys.map(&.lstrip('.')).join(", ")
        STDERR.puts "  Supported: #{supported}, gif"
        exit 1
      end

      if is_gif && !preset.default?
        Display.show_error("presets do not apply to GIF output")
        exit 1
      end

      fps = fps_override || (is_gif ? 10 : 24)

      target_format = is_gif ? "gif" : CodecSupport.format_for_ext(ext).not_nil!

      # Check ffmpeg/ffprobe
      unless check_command("ffmpeg")
        Display.show_error("ffmpeg not found. Please install ffmpeg.")
        exit 1
      end
      unless check_command("ffprobe")
        Display.show_error("ffprobe not found. Please install ffmpeg.")
        exit 1
      end

      seq = begin
        ImageSequence.scan(input)
      rescue ex
        Display.show_error("failed to scan directory: #{ex.message}")
        exit 1
      end

      # Build output path
      dest = custom_output
      unless dest
        dir_name = File.basename(input.rstrip("/"))
        dir_parent = File.dirname(input.rstrip("/"))
        dest = File.join(dir_parent, "#{dir_name}#{ext}")
      end

      if File.exists?(dest) && !force
        Display.show_error("output file already exists: #{dest}")
        STDERR.puts "  Use --force to overwrite."
        exit 1
      end

      Display.show_image_sequence_info(seq, dest, fps, preset, target_format,
                                       scale: scale, aspect: aspect, crop: crop)

      if dry_run
        args = ImageSequence.build_ffmpeg_args(seq, dest, fps, preset, target_format, force,
                                               scale: scale, aspect: aspect, crop: crop)
        Display.show_dry_run(args)
        exit 0
      end

      success = ImageSequence.run(seq, dest, fps, preset, target_format, force,
                                   scale: scale, aspect: aspect, crop: crop)
      exit(success ? 0 : 1)
    end

    private def self.parse_time_or_exit(value : String, flag : String) : Float64
      result = EasyFfmpeg.parse_time(value)
      unless result
        Display.show_error("invalid time for #{flag}: '#{value}'")
        STDERR.puts "  Accepted formats: 90, 1:31, 1:31.500, 1:02:30, 1:02:30.500"
        exit 1
      end
      result
    end

    private def self.show_help(parser : OptionParser)
      puts parser
      puts ""
      puts "Time formats:"
      puts "  90          Seconds"
      puts "  1:31        Minutes:Seconds"
      puts "  1:31.500    Minutes:Seconds.Milliseconds"
      puts "  1:02:30     Hours:Minutes:Seconds"
      puts "  1:02:30.5   Hours:Minutes:Seconds.Milliseconds"
      puts ""
      puts "Examples:"
      puts "  # Remux MKV to MP4 (no re-encoding, fast)"
      puts "  easy-ffmpeg movie.mkv mp4"
      puts ""
      puts "  # Convert for web embedding"
      puts "  easy-ffmpeg movie.mkv mp4 --web"
      puts ""
      puts "  # Compress a large Blu-ray rip"
      puts "  easy-ffmpeg bluray.mkv mp4 --compress"
      puts ""
      puts "  # Extract a 90-second clip starting at 1:30"
      puts "  easy-ffmpeg movie.mkv mp4 --start 1:30 --duration 90"
      puts ""
      puts "  # Trim from 10 minutes to 15 minutes"
      puts "  easy-ffmpeg movie.mkv mp4 --start 10:00 --end 15:00"
      puts ""
      puts "  # Mobile-friendly clip with custom output path"
      puts "  easy-ffmpeg movie.mkv mp4 --mobile --start 0:30 --end 2:00 -o clip.mp4"
      puts ""
      puts "  # Scale to 720p"
      puts "  easy-ffmpeg movie.mkv mp4 --scale hd"
      puts ""
      puts "  # Pad to 16:9 aspect ratio (black bars)"
      puts "  easy-ffmpeg movie.mkv mp4 --aspect wide"
      puts ""
      puts "  # Crop to square"
      puts "  easy-ffmpeg movie.mkv mp4 --aspect square --crop"
      puts ""
      puts "  # Preview the ffmpeg command without running it"
      puts "  easy-ffmpeg movie.mkv mp4 --web --dry-run"
      puts ""
      puts "  # Convert image sequence to video"
      puts "  easy-ffmpeg /path/to/frames/ mp4"
      puts ""
      puts "  # Create animated GIF from images at 15fps"
      puts "  easy-ffmpeg /path/to/frames/ gif --fps 15"
    end

    def self.check_command(name : String) : Bool
      status = Process.run("which", args: [name], output: Process::Redirect::Close, error: Process::Redirect::Close)
      status.success?
    end
  end
end
