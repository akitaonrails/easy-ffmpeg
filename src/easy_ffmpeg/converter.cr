module EasyFfmpeg
  class Converter
    getter plan : ConversionPlan

    def initialize(@plan)
    end

    def build_args : Array(String)
      args = ["-hide_banner", "-v", "error", "-stats_period", "0.5", "-progress", "pipe:1"]
      args << (plan.overwrite_output ? "-y" : "-n")

      # Trim: -ss before -i for fast seeking
      if ss = plan.start_time
        args << "-ss" << format_ffmpeg_time(ss)
      end

      # Hardware-accelerated decode. Two tiers:
      #
      #   pure_gpu_pipeline?  → `-hwaccel cuda -hwaccel_output_format cuda`
      #     Decoded surfaces stay on the GPU. Filters are CUDA-aware
      #     (scale_cuda, no format conversion). NVENC reads directly from
      #     CUDA memory. Best throughput.
      #
      #   uses_nvenc_transcode? (only) → `-hwaccel cuda`
      #     Decode runs on the GPU but frames are downloaded to system memory
      #     so the CPU filter chain (crop / pad) can run. NVENC re-uploads
      #     them at the encode step. Still faster than software decode.
      if plan.pure_gpu_pipeline?
        args << "-hwaccel" << "cuda" << "-hwaccel_output_format" << "cuda"
      elsif uses_nvenc_transcode?
        args << "-hwaccel" << "cuda"
      end

      args << "-i" << plan.input.path

      # Trim: -to / -t after -i (relative to start)
      if et = plan.end_time
        if ss = plan.start_time
          # -to is relative to -ss when -ss is before -i, use -t instead
          args << "-t" << format_ffmpeg_time(et - ss)
        else
          args << "-to" << format_ffmpeg_time(et)
        end
      elsif dur = plan.duration
        args << "-t" << format_ffmpeg_time(dur)
      end

      # Map non-dropped streams
      mapped = plan.mapped_streams
      mapped.each do |sp|
        args << "-map" << "0:#{sp.stream.index}"
      end

      # Codec args per stream type
      video_idx = 0
      audio_idx = 0
      sub_idx = 0

      mapped.each do |sp|
        if sp.stream.video?
          if sp.action.copy?
            args << "-c:v:#{video_idx}" << "copy"
          else
            args << "-c:v:#{video_idx}" << sp.encoder.not_nil!
            sp.encoder_args.each { |a| args << a }
          end
          video_idx += 1
        elsif sp.stream.audio?
          if sp.action.copy?
            args << "-c:a:#{audio_idx}" << "copy"
          else
            args << "-c:a:#{audio_idx}" << sp.encoder.not_nil!
            # Per-audio-stream args: need to qualify bitrate/channel args
            sp.encoder_args.each { |a| args << a }
          end
          audio_idx += 1
        elsif sp.stream.subtitle?
          if sp.action.copy?
            args << "-c:s:#{sub_idx}" << "copy"
          else
            args << "-c:s:#{sub_idx}" << sp.encoder.not_nil!
          end
          sub_idx += 1
        end
      end

      # Video filters
      if plan.video_filters.any?
        args << "-vf" << plan.video_filters.join(",")
      end

      # Global args
      plan.global_args.each { |a| args << a }

      args << plan.output_path
      args
    end

    # True when --gpu was requested AND at least one video stream is being
    # transcoded by an NVENC encoder. Guards against enabling hwaccel for
    # remux-only jobs or CPU-fallback transcodes (e.g. webm -> libvpx-vp9 with
    # --gpu), where -hwaccel cuda would be wasted or actively harmful.
    private def uses_nvenc_transcode? : Bool
      return false unless plan.use_gpu
      plan.video_plans.any? do |sp|
        sp.action.transcode? && (sp.encoder.try(&.ends_with?("_nvenc")) || false)
      end
    end

    private def format_ffmpeg_time(seconds : Float64) : String
      h = (seconds / 3600).to_i
      m = ((seconds % 3600) / 60).to_i
      s = seconds % 60
      "%02d:%02d:%06.3f" % {h, m, s}
    end

    def run : Bool
      args = build_args
      total_duration = plan.effective_duration
      start_time = Time.instant
      stderr_done = Channel(String).new(1)
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

      # Read stderr in a fiber to avoid pipe deadlock.
      spawn do
        stderr_done.send(process.error.gets_to_end)
      rescue
        stderr_done.send("")
      end

      if plan.is_remux_only
        Display.show_remux_progress
      end

      # Parse progress from stdout
      process.output.each_line do |line|
        case
        when line.starts_with?("out_time_us=")
          microseconds = line.split("=", 2)[1].to_i64?
          if microseconds && total_duration > 0
            current_seconds = microseconds / 1_000_000.0
            percentage = (current_seconds / total_duration * 100).clamp(0.0, 100.0)
            unless plan.is_remux_only
              Display.show_progress(percentage, current_seconds, total_duration, @last_speed || "0x")
            end
          end
        when line.starts_with?("speed=")
          @last_speed = line.split("=", 2)[1].strip
        when line == "progress=end"
          # Done
        end
      end

      status = process.wait
      stderr_output = stderr_done.receive
      Display.clear_progress

      elapsed = (Time.instant - start_time).total_seconds

      if status.success?
        Display.show_done(plan.output_path, plan.input.format.size, elapsed)
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

    @last_speed : String?
  end
end
