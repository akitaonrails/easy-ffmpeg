module EasyFfmpeg
  module GpuSupport
    # Coarse-grained quality mode for NVENC encodes. Selected with the
    # CLI's --gpu-quality flag.
    #
    #   Fast      - prioritize encode speed; smaller per-block analysis,
    #               no rc-lookahead, no AQ. Bigger / lower-quality file
    #               than balanced, but ~2-3x faster.
    #   Balanced  - default. Same -cq value as the CPU -crf, NVENC preset
    #               p5, full quality tuning (lookahead + AQ + B-pyramid).
    #               Bigger file than libx265 at the same numeric value
    #               but slightly higher quality.
    #   Smaller   - prioritize file size; preset p7 (slowest, best
    #               quality-per-bit), -cq bumped +5, lookahead 32, bf 4.
    #               File size comparable to libx265, still 3-4x faster
    #               than CPU encode.
    enum Quality
      Fast
      Balanced
      Smaller
    end

    # CPU encoder → NVENC equivalent. Encoders not listed (libvpx-vp9, libtheora,
    # libsvtav1 on older GPUs, etc.) have no NVENC equivalent and fall back to CPU.
    NVENC_ENCODER_MAP = {
      "libx264"   => "h264_nvenc",
      "libx265"   => "hevc_nvenc",
      "libsvtav1" => "av1_nvenc",
    }

    # libx264/libx265 -preset → NVENC -preset. NVENC presets are p1 (fastest) to
    # p7 (slowest, best quality). p4 maps to ffmpeg's "medium" baseline.
    NVENC_PRESET_MAP = {
      "ultrafast" => "p1",
      "superfast" => "p1",
      "veryfast"  => "p2",
      "faster"    => "p3",
      "fast"      => "p4",
      "medium"    => "p5",
      "slow"      => "p6",
      "slower"    => "p6",
      "veryslow"  => "p7",
      "placebo"   => "p7",
    }

    # Per-quality preset override. We force the NVENC preset based on the
    # selected Quality mode, ignoring whatever the CPU -preset translated to.
    # This is intentional — the CPU preset reflects libx265's speed/quality
    # trade-off, but NVENC's preset scale is different and the user picked
    # the quality mode explicitly.
    PRESET_FOR_QUALITY = {
      Quality::Fast     => "p2",
      Quality::Balanced => "p5",
      Quality::Smaller  => "p7",
    }

    # Per-quality CQ offset. NVENC is more conservative than libx265 at the
    # same numeric value, so bumping +5 in Smaller mode closes the file-size
    # gap with libx265 -crf.
    CQ_OFFSET_FOR_QUALITY = {
      Quality::Fast     => 0,
      Quality::Balanced => 0,
      Quality::Smaller  => 5,
    }

    # Per-quality extra args appended after rate control. Fast strips
    # everything heavy; Balanced is the original tuning; Smaller boosts
    # lookahead and B-frames for tighter compression.
    #
    # Requires NVIDIA Turing (RTX 20-series) or newer for full effect; older
    # GPUs silently ignore the bits they don't support.
    def self.quality_tuning_for(quality : Quality) : Array(String)
      case quality
      when Quality::Fast
        [] of String
      when Quality::Balanced
        ["-rc-lookahead", "20",
         "-spatial-aq", "1",
         "-temporal-aq", "1",
         "-bf", "3",
         "-b_ref_mode", "middle"]
      when Quality::Smaller
        ["-rc-lookahead", "32",
         "-spatial-aq", "1",
         "-temporal-aq", "1",
         "-bf", "4",
         "-b_ref_mode", "middle"]
      else
        [] of String
      end
    end

    @@available_encoders : Set(String)? = nil

    # Available NVENC encoders compiled into the local ffmpeg binary.
    # Cached after first call.
    def self.available_encoders : Set(String)
      @@available_encoders ||= probe_encoders
    end

    # True when at least one NVENC encoder is present in the local ffmpeg.
    def self.any_available? : Bool
      NVENC_ENCODER_MAP.values.any? { |e| available_encoders.includes?(e) }
    end

    # Returns the GPU encoder for the given CPU encoder, or nil when no
    # equivalent exists or the local ffmpeg lacks it.
    def self.gpu_encoder_for?(cpu_encoder : String) : String?
      gpu = NVENC_ENCODER_MAP[cpu_encoder]?
      return nil unless gpu
      available_encoders.includes?(gpu) ? gpu : nil
    end

    # Translate CPU encoder args (-crf/-preset/etc.) to NVENC equivalents.
    # -crf N         → -cq (N + CQ_OFFSET_FOR_QUALITY[quality]) -b:v 0
    # -preset *      → -preset PRESET_FOR_QUALITY[quality]
    # -level *       → dropped (NVENC strictly enforces level vs output
    #                  dimensions; let it auto-select to avoid crashes).
    # Other args (-profile:v, -g, -keyint_min) pass through unchanged.
    def self.translate_args(cpu_args : Array(String),
                            quality : Quality = Quality::Balanced) : Array(String)
      out = [] of String
      i = 0
      while i < cpu_args.size
        case cpu_args[i]
        when "-crf"
          if val = cpu_args[i + 1]?
            cq = val.to_i? || 28
            out << "-cq" << (cq + CQ_OFFSET_FOR_QUALITY[quality]).to_s << "-b:v" << "0"
            i += 2
          else
            out << cpu_args[i]
            i += 1
          end
        when "-preset"
          if cpu_args[i + 1]?
            out << "-preset" << PRESET_FOR_QUALITY[quality]
            i += 2
          else
            out << cpu_args[i]
            i += 1
          end
        when "-level"
          i += cpu_args[i + 1]? ? 2 : 1
        else
          out << cpu_args[i]
          i += 1
        end
      end

      # Rate control + base tuning. NVENC defaults to CBR; for our CRF-like
      # workflow we want VBR with a quality target.
      out.unshift("-rc", "vbr", "-tune", "hq") unless out.includes?("-rc")
      quality_tuning_for(quality).each { |a| out << a }
      out
    end

    # Quality args for transcodes that don't go through a preset (e.g. the
    # default "incompatible source" path that just picks libx264 with no CRF
    # set). Mirrors ConversionPlan#default_quality_args.
    def self.default_quality_args(gpu_encoder : String,
                                  quality : Quality = Quality::Balanced) : Array(String)
      base_cq = case gpu_encoder
                when "h264_nvenc" then 19
                when "hevc_nvenc" then 21
                when "av1_nvenc"  then 23
                else                   nil
                end
      return [] of String unless base_cq

      cq = base_cq + CQ_OFFSET_FOR_QUALITY[quality]
      preset = PRESET_FOR_QUALITY[quality]
      base = ["-rc", "vbr", "-cq", cq.to_s, "-b:v", "0", "-preset", preset, "-tune", "hq"]
      base + quality_tuning_for(quality)
    end

    # Reset the cache (used in specs).
    def self.reset_cache!
      @@available_encoders = nil
    end

    # Inject a stub set of encoders (used in specs to avoid shelling out).
    def self.stub_encoders!(encoders : Enumerable(String))
      @@available_encoders = encoders.to_set
    end

    private def self.probe_encoders : Set(String)
      output_buf = IO::Memory.new
      status = begin
        Process.run(
          "ffmpeg",
          args: ["-hide_banner", "-encoders"],
          output: output_buf,
          error: Process::Redirect::Close,
        )
      rescue File::Error
        return Set(String).new
      end

      return Set(String).new unless status.success?

      encoders = Set(String).new
      output_buf.to_s.each_line do |line|
        # ffmpeg -encoders format: " V..... h264_nvenc           NVIDIA NVENC H.264 ..."
        next unless line.size > 8 && line[0] == ' '
        # Skip header lines (start with "------" or section titles)
        next if line.lstrip.starts_with?("---") || line.lstrip.starts_with?("Encoders:")
        parts = line.strip.split(/\s+/, 3)
        next if parts.size < 2
        flags = parts[0]
        # Only video encoders ("V" in first position)
        next unless flags.size >= 1 && flags[0] == 'V'
        encoders << parts[1]
      end
      encoders
    end
  end
end
