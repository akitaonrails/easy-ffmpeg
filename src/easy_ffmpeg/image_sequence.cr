require "json"

module EasyFfmpeg
  module ImageSequence
    IMAGE_EXTENSIONS = %w[.png .jpg .jpeg .bmp .tiff .tif .webp]

    enum InputMode
      Sequential
      Glob
    end

    struct InputPattern
      getter mode : InputMode
      getter pattern : String

      def initialize(@mode, @pattern)
      end
    end

    struct SequenceInfo
      getter directory : String
      getter files : Array(String)
      getter extension : String
      getter frame_count : Int32
      getter width : Int32
      getter height : Int32
      getter input_pattern : InputPattern
      getter total_size : Int64

      def initialize(@directory, @files, @extension, @frame_count,
                     @width, @height, @input_pattern, @total_size)
      end
    end

    def self.scan(directory : String) : SequenceInfo
      # Collect all image files
      all_images = [] of {String, String} # {filename, extension}
      Dir.each_child(directory) do |name|
        ext = File.extname(name).downcase
        if IMAGE_EXTENSIONS.includes?(ext)
          all_images << {name, ext}
        end
      end

      if all_images.size < 2
        raise "need at least 2 images, found #{all_images.size}"
      end

      # Find dominant extension
      ext_counts = Hash(String, Int32).new(0)
      all_images.each { |_, ext| ext_counts[ext] += 1 }
      dominant_ext = ext_counts.max_by { |_, count| count }[0]

      # Filter to dominant extension (include aliases)
      aliases = case dominant_ext
                when ".jpg", ".jpeg" then [".jpg", ".jpeg"]
                when ".tif", ".tiff" then [".tif", ".tiff"]
                else                      [dominant_ext]
                end
      filtered = all_images.select { |_, ext| aliases.includes?(ext) }
                           .map { |name, _| name }
                           .sort

      if filtered.size < 2
        raise "need at least 2 images with #{dominant_ext} extension, found #{filtered.size}"
      end

      # Calculate total size
      total_size = 0_i64
      filtered.each { |name| total_size += File.size(File.join(directory, name)) }

      # Detect pattern
      input_pattern = detect_pattern(directory, filtered, dominant_ext)

      # Probe first image for resolution
      first_image = File.join(directory, filtered.first)
      width, height = probe_image_resolution(first_image)

      SequenceInfo.new(
        directory: directory,
        files: filtered,
        extension: dominant_ext,
        frame_count: filtered.size,
        width: width,
        height: height,
        input_pattern: input_pattern,
        total_size: total_size,
      )
    end

    def self.detect_pattern(dir : String, files : Array(String), ext : String) : InputPattern
      # Try to find a common prefix + sequential digits pattern
      # e.g. "frame_0001.png", "frame_0002.png" or "0001.png", "0002.png"
      first = files.first
      basename = File.basename(first, File.extname(first))

      # Match trailing digits
      if match = basename.match(/^(.*?)(\d+)$/)
        prefix = match[1]
        digit_str = match[2]
        padding = digit_str.size

        # Check all files match this pattern with consecutive numbering
        all_match = files.all? do |name|
          bn = File.basename(name, File.extname(name))
          if m = bn.match(/^(.*?)(\d+)$/)
            m[1] == prefix && m[2].size == padding
          else
            false
          end
        end

        if all_match
          # Extract all numbers and check they're consecutive
          numbers = files.map do |name|
            bn = File.basename(name, File.extname(name))
            if m = bn.match(/^(.*?)(\d+)$/)
              m[2].to_i
            else
              0
            end
          end.sort

          consecutive = numbers.each_cons(2).all? { |pair| pair[1] == pair[0] + 1 }

          if consecutive
            ext_for_pattern = File.extname(files.first)
            pattern_str = File.join(dir, "#{prefix}%0#{padding}d#{ext_for_pattern}")
            return InputPattern.new(InputMode::Sequential, pattern_str)
          end
        end
      end

      # Fallback to glob
      ext_for_pattern = File.extname(files.first)
      InputPattern.new(InputMode::Glob, File.join(dir, "*#{ext_for_pattern}"))
    end

    def self.probe_image_resolution(path : String) : {Int32, Int32}
      output_buf = IO::Memory.new
      error_buf = IO::Memory.new

      status = begin
        Process.run(
          "ffprobe",
          args: ["-v", "quiet", "-print_format", "json", "-show_streams", path],
          output: output_buf,
          error: error_buf,
        )
      rescue ex : File::Error
        raise "failed to start ffprobe: #{ex.message}"
      end

      unless status.success?
        raise "ffprobe failed on #{path}: #{error_buf.to_s.strip}"
      end

      parse_resolution_probe_output(output_buf.to_s, path)
    end

    def self.build_ffmpeg_args(seq : SequenceInfo, output_path : String,
                               fps : Int32, preset : Preset,
                               target_format : String, force : Bool,
                               scale : String? = nil, aspect : String? = nil,
                               crop : Bool = false, use_gpu : Bool = false,
                               gpu_quality : GpuSupport::Quality = GpuSupport::Quality::Balanced) : Array(String)
      is_gif = target_format == "gif"
      args = ["-hide_banner", "-v", "error", "-stats_period", "0.5", "-progress", "pipe:1"]
      args << (force ? "-y" : "-n")
      args << "-framerate" << fps.to_s

      if seq.input_pattern.mode.glob?
        args << "-pattern_type" << "glob"
      end

      args << "-i" << seq.input_pattern.pattern

      # Build shared scale/aspect filter fragments
      extra_filters_pre = [] of String   # before format filter
      extra_filters_post = [] of String  # after format filter

      if s = scale
        target_h = SCALE_HEIGHTS[s]
        if seq.height > target_h
          extra_filters_pre << "scale=-2:#{target_h}"
        end
      end

      if a = aspect
        num, den = ASPECT_RATIOS[a]
        if crop
          extra_filters_post << "crop=min(iw\\,ih*#{num}/#{den}):min(ih\\,iw*#{den}/#{num})"
        else
          extra_filters_post << "pad=max(iw\\,ih*#{num}/#{den}):max(ih\\,iw*#{den}/#{num}):(ow-iw)/2:(oh-ih)/2:black"
        end
      end

      if is_gif
        # High-quality GIF with palette generation
        pre = extra_filters_pre + extra_filters_post
        if pre.any?
          prefix = pre.join(",") + ","
        else
          prefix = ""
        end
        args << "-vf" << "#{prefix}split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse"
      else
        # Video output
        config = PresetConfig.for(preset, target_format)
        cpu_encoder = config.video_codec || CodecSupport::DEFAULT_VIDEO_CODEC[target_format]? || "libx264"

        # GPU swap: codecs without NVENC equivalents (vp9, theora) silently
        # fall back to CPU.
        encoder = (use_gpu ? GpuSupport.gpu_encoder_for?(cpu_encoder) : nil) || cpu_encoder

        args << "-c:v" << encoder

        base_args = if config.force_transcode
                      config.video_args.dup
                    else
                      # Default quality args
                      case cpu_encoder
                      when "libx264"     then ["-crf", "18", "-preset", "medium"]
                      when "libx265"     then ["-crf", "20", "-preset", "medium"]
                      when "libvpx-vp9"  then ["-crf", "24", "-b:v", "0"]
                      when "libsvtav1"   then ["-crf", "23", "-preset", "6"]
                      else                    [] of String
                      end
                    end

        encoder_args = if encoder != cpu_encoder
                         base_args.empty? ? GpuSupport.default_quality_args(encoder, gpu_quality) : GpuSupport.translate_args(base_args, gpu_quality)
                       else
                         base_args
                       end
        encoder_args.each { |a| args << a }

        # Build video filter chain: scale -> format -> aspect
        filters = [] of String
        filters.concat(extra_filters_pre)

        # Pixel format for h264/h265 (and NVENC equivalents)
        if %w[libx264 libx265 h264_nvenc hevc_nvenc].includes?(encoder)
          filters << "format=yuv420p"
        end

        # Apply max_height scaling from preset (only if --scale not set)
        if scale.nil?
          if max_h = config.max_height
            if seq.height > max_h
              filters.unshift("scale=-2:#{max_h}")
            end
          end
        end

        filters.concat(extra_filters_post)

        if filters.any?
          args << "-vf" << filters.join(",")
        end

        # Faststart for mp4/mov
        if target_format == "mp4" || target_format == "mov"
          args << "-movflags" << "+faststart"
        end
      end

      args << output_path
      args
    end

    def self.run(seq : SequenceInfo, output_path : String, fps : Int32,
                 preset : Preset, target_format : String, force : Bool,
                 scale : String? = nil, aspect : String? = nil,
                 crop : Bool = false, use_gpu : Bool = false,
                 gpu_quality : GpuSupport::Quality = GpuSupport::Quality::Balanced) : Bool
      args = build_ffmpeg_args(seq, output_path, fps, preset, target_format, force,
                               scale: scale, aspect: aspect, crop: crop,
                               use_gpu: use_gpu, gpu_quality: gpu_quality)
      total_duration = seq.frame_count.to_f64 / fps
      start_time = Time.instant

      process = begin
        Process.new(
          "ffmpeg",
          args: args,
          output: Process::Redirect::Pipe,
          error: Process::Redirect::Pipe,
        )
      rescue ex : File::Error
        Display.show_error("failed to start ffmpeg: #{ex.message}")
        return false
      end

      stderr_done = Channel(String).new(1)
      spawn do
        stderr_done.send(process.error.gets_to_end)
      rescue
        stderr_done.send("")
      end

      last_speed = "0x"

      process.output.each_line do |line|
        case
        when line.starts_with?("out_time_us=")
          microseconds = line.split("=", 2)[1].to_i64?
          if microseconds && total_duration > 0
            current_seconds = microseconds / 1_000_000.0
            percentage = (current_seconds / total_duration * 100).clamp(0.0, 100.0)
            Display.show_progress(percentage, current_seconds, total_duration, last_speed)
          end
        when line.starts_with?("speed=")
          last_speed = line.split("=", 2)[1].strip
        when line == "progress=end"
          # Done
        end
      end

      status = process.wait
      stderr_output = stderr_done.receive
      Display.clear_progress

      elapsed = (Time.instant - start_time).total_seconds

      if status.success?
        Display.show_image_sequence_done(output_path, seq.total_size, elapsed)
        true
      else
        Display.show_error("ffmpeg exited with code #{status.exit_code}")
        unless stderr_output.strip.empty?
          STDERR.puts ""
          stderr_output.strip.each_line { |l| STDERR.puts "  #{l}" }
          STDERR.puts ""
        end
        false
      end
    end

    private def self.parse_resolution_probe_output(json_text : String, path : String) : {Int32, Int32}
      json = begin
        JSON.parse(json_text)
      rescue ex : JSON::ParseException
        raise "ffprobe returned invalid JSON for #{path}: #{ex.message}"
      end

      if streams = json["streams"]?.try(&.as_a?)
        streams.each do |s|
          next unless s["codec_type"]?.try(&.as_s?) == "video"

          w = s["width"]?.try(&.as_i?)
          h = s["height"]?.try(&.as_i?)
          if w && h
            return {w, h}
          end
        end
      end

      raise "could not determine resolution of #{path}"
    end
  end
end
