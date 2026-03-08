require "colorize"

module EasyFfmpeg
  module Display
    LABEL_WIDTH = 10

    def self.setup
      Colorize.on_tty_only!
    end

    # ── Input analysis ──

    def self.show_input(info : MediaInfo)
      puts ""
      label("Input", "#{File.basename(info.path)} (#{info.format.size_display}, #{info.format.duration_display})")

      info.video_streams.each_with_index do |s, i|
        prefix = i == 0 ? "Video" : ""
        parts = [
          CodecSupport.codec_display_name(s.codec_name),
          s.resolution_display,
          s.frame_rate_display,
        ]
        parts << s.bit_rate_display unless s.bit_rate_display.empty?
        parts << s.profile.to_s unless s.profile.nil? || s.profile.try(&.empty?)
        label(prefix, parts.join(" @ ").gsub(" @ @ ", " @ "))
      end

      info.audio_streams.each_with_index do |s, i|
        prefix = i == 0 ? "Audio" : ""
        parts = ["##{i + 1}"]
        parts << CodecSupport.codec_display_name(s.codec_name)
        parts << s.channel_description
        parts << s.bit_rate_display unless s.bit_rate_display.empty?
        lang = s.language_display
        parts << "(#{lang})" unless lang.empty?
        label(prefix, parts.join(" "))
      end

      info.subtitle_streams.each_with_index do |s, i|
        prefix = i == 0 ? "Subs" : ""
        parts = ["##{i + 1}"]
        parts << CodecSupport.codec_display_name(s.codec_name)
        lang = s.language_display
        parts << "(#{lang})" unless lang.empty?
        label(prefix, parts.join(" "))
      end
    end

    # ── Conversion plan ──

    def self.show_plan(plan : ConversionPlan)
      puts ""
      preset_label = plan.preset.default? ? "" : " (--#{plan.preset.to_s.downcase})"
      label("Output", "#{File.basename(plan.output_path)}#{preset_label}")

      video_idx = 0
      plan.video_plans.each do |p|
        prefix = video_idx == 0 ? "Video" : ""
        show_stream_plan(prefix, p)
        video_idx += 1
      end

      audio_idx = 0
      plan.audio_plans.each do |p|
        prefix = audio_idx == 0 ? "Audio" : ""
        show_stream_plan(prefix, p, audio_idx + 1)
        audio_idx += 1
      end

      sub_idx = 0
      plan.sub_plans.each do |p|
        prefix = sub_idx == 0 ? "Subs" : ""
        show_stream_plan(prefix, p, sub_idx + 1)
        sub_idx += 1
      end

      if s = plan.scale
        height = SCALE_HEIGHTS[s]
        label("Scale", "#{s} (#{height}p)")
      end

      if a = plan.aspect
        num, den = ASPECT_RATIOS[a]
        mode = plan.crop ? "crop" : "pad"
        label("Aspect", "#{a} (#{num}:#{den}, #{mode})")
      end

      if plan.video_filters.any?
        label("Filters", plan.video_filters.join(", "))
      end

      if plan.start_time || plan.end_time || plan.duration
        trim_parts = [] of String
        if ss = plan.start_time
          trim_parts << "from #{EasyFfmpeg.format_duration_timestamp(ss)}"
        end
        if et = plan.end_time
          trim_parts << "to #{EasyFfmpeg.format_duration_timestamp(et)}"
        end
        if dur = plan.duration
          trim_parts << "duration #{EasyFfmpeg.format_duration(dur)}"
        end
        effective = plan.effective_duration
        trim_parts << "(#{EasyFfmpeg.format_duration(effective)})"
        label("Trim", trim_parts.join(" "))
      end

      puts ""
    end

    private def self.show_stream_plan(prefix : String, plan : StreamPlan, track_num : Int32? = nil)
      src_name = CodecSupport.codec_display_name(plan.stream.codec_name)

      case plan.action
      when .copy?
        track = track_num ? "##{track_num} " : ""
        text = "#{track}#{src_name} -> #{plan.output_codec_display}  #{"copy".colorize(:green)}"
        label(prefix, text)
      when .transcode?
        track = track_num ? "##{track_num} " : ""
        args_display = plan.encoder_args.join(" ")
        text = "#{track}#{src_name} -> #{plan.output_codec_display}  #{"transcode".colorize(:yellow)}"
        text += "  #{args_display.colorize(:dark_gray)}" unless args_display.empty?
        label(prefix, text)
      when .drop?
        track = track_num ? "##{track_num} " : ""
        text = "#{track}#{src_name} -> #{"dropped".colorize(:red)}  #{plan.reason.colorize(:dark_gray)}"
        label(prefix, text)
      end
    end

    # ── Dry run ──

    def self.show_dry_run(args : Array(String))
      puts ""
      puts " #{"Command".colorize(:cyan)}"
      escaped = args.map { |a| a.includes?(" ") || a.includes?("(") ? %("#{a}") : a }
      puts "  ffmpeg #{escaped.join(" ")}"
      puts ""
    end

    # ── Progress ──

    def self.show_progress(percentage : Float64, current_time : Float64, total_time : Float64, speed : String)
      bar_width = 30
      filled = (percentage / 100.0 * bar_width).clamp(0, bar_width).to_i
      empty = bar_width - filled
      bar = "\u2588" * filled + "\u2591" * empty

      current = EasyFfmpeg.format_duration_timestamp(current_time)
      total = EasyFfmpeg.format_duration_timestamp(total_time)

      pct_str = "%3d%%" % percentage.clamp(0, 100).to_i
      eta = if percentage > 0 && percentage < 100
              remaining = total_time - current_time
              speed_val = speed.rstrip('x').to_f64?
              if speed_val && speed_val > 0
                eta_seconds = remaining / speed_val
                "ETA #{EasyFfmpeg.format_duration(eta_seconds)}"
              else
                ""
              end
            else
              ""
            end

      line = " [#{bar}] #{pct_str}  #{current} / #{total}  #{speed}  #{eta}"
      print "\r#{line}\e[K"
      STDOUT.flush
    end

    def self.show_remux_progress
      print "\r #{"Remuxing...".colorize(:cyan)} (stream copy, this should be fast)\e[K"
      STDOUT.flush
    end

    def self.clear_progress
      print "\r\e[K"
      STDOUT.flush
    end

    # ── Final summary ──

    def self.show_done(output_path : String, input_size : Int64, elapsed_seconds : Float64)
      output_size = File.size(output_path)
      ratio = if input_size > 0
                pct = ((1.0 - output_size.to_f64 / input_size.to_f64) * 100).to_i
                if pct > 0
                  "#{pct}% smaller"
                elsif pct < 0
                  "#{pct.abs}% larger"
                else
                  "same size"
                end
              else
                ""
              end

      size_info = EasyFfmpeg.format_file_size(output_size)
      size_info += ", #{ratio}" unless ratio.empty?

      puts ""
      label("Done", "#{File.basename(output_path)} (#{ size_info })".colorize(:green).to_s)
      label("", "Completed in #{EasyFfmpeg.format_duration(elapsed_seconds)}")
      label("", File.expand_path(output_path))
      puts ""
    end

    # ── Image sequence ──

    def self.show_image_sequence_info(seq : ImageSequence::SequenceInfo, output_path : String,
                                      fps : Int32, preset : Preset, target_format : String,
                                      scale : String? = nil, aspect : String? = nil,
                                      crop : Bool = false)
      puts ""
      label("Input", "#{File.basename(seq.directory.rstrip("/"))}/ (#{seq.frame_count} frames, #{EasyFfmpeg.format_file_size(seq.total_size)})")
      label("Images", "#{seq.extension.lstrip('.')} #{seq.width}x#{seq.height}")
      pattern_label = seq.input_pattern.mode.sequential? ? "sequential" : "glob"
      label("Pattern", "#{File.basename(seq.input_pattern.pattern)} (#{pattern_label})")

      expected_duration = seq.frame_count.to_f64 / fps
      label("Output", File.basename(output_path))

      is_gif = target_format == "gif"
      if is_gif
        label("Encode", "GIF (palette-optimized)")
      else
        config = PresetConfig.for(preset, target_format)
        encoder = config.video_codec || CodecSupport::DEFAULT_VIDEO_CODEC[target_format]? || "libx264"
        preset_label = preset.default? ? "" : " (--#{preset.to_s.downcase})"
        label("Encode", "#{CodecSupport.codec_display_name(encoder)}#{preset_label}")
      end

      if s = scale
        height = SCALE_HEIGHTS[s]
        label("Scale", "#{s} (#{height}p)")
      end

      if a = aspect
        num, den = ASPECT_RATIOS[a]
        mode = crop ? "crop" : "pad"
        label("Aspect", "#{a} (#{num}:#{den}, #{mode})")
      end

      label("FPS", "#{fps}fps -> #{EasyFfmpeg.format_duration(expected_duration)}")
      puts ""
    end

    def self.show_image_sequence_done(output_path : String, input_total_size : Int64, elapsed_seconds : Float64)
      output_size = File.size(output_path)
      size_info = EasyFfmpeg.format_file_size(output_size)

      puts ""
      label("Done", "#{File.basename(output_path)} (#{size_info})".colorize(:green).to_s)
      label("", "Completed in #{EasyFfmpeg.format_duration(elapsed_seconds)}")
      label("", File.expand_path(output_path))
      puts ""
    end

    def self.show_error(message : String)
      STDERR.puts " #{"Error".colorize(:red)}  #{message}"
    end

    # ── Helpers ──

    private def self.label(name : String, value)
      if name.empty?
        puts " #{" " * LABEL_WIDTH}#{value}"
      else
        puts " #{name.ljust(LABEL_WIDTH).colorize(:cyan)}#{value}"
      end
    end
  end
end
