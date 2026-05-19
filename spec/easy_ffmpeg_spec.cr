require "./spec_helper"

private def build_media_info(video_codec : String = "h264", audio_codec : String = "aac",
                             video_width : Int32 = 1920, video_height : Int32 = 1080,
                             pix_fmt : String = "yuv420p",
                             color_primaries : String? = nil,
                             color_transfer : String? = nil,
                             color_space : String? = nil,
                             color_range : String? = nil,
                             field_order : String? = nil,
                             audio_channels : Int32 = 2,
                             other_streams : Array(EasyFfmpeg::StreamInfo) = [] of EasyFfmpeg::StreamInfo)
  video_stream = EasyFfmpeg::StreamInfo.new(
    index: 0,
    codec_name: video_codec,
    codec_long_name: video_codec.upcase,
    codec_type: "video",
    width: video_width,
    height: video_height,
    frame_rate: 23.976,
    pix_fmt: pix_fmt,
    color_primaries: color_primaries,
    color_transfer: color_transfer,
    color_space: color_space,
    color_range: color_range,
    field_order: field_order,
  )

  audio_stream = EasyFfmpeg::StreamInfo.new(
    index: 1,
    codec_name: audio_codec,
    codec_long_name: audio_codec.upcase,
    codec_type: "audio",
    channels: audio_channels,
  )

  format = EasyFfmpeg::FormatInfo.new(
    filename: "input.mkv",
    format_name: "matroska",
    format_long_name: "Matroska",
    duration: 180.0,
    size: 1_000_000_i64,
    bit_rate: 640_000_i64,
  )

  EasyFfmpeg::MediaInfo.new(
    "input.mkv",
    [video_stream],
    [audio_stream],
    [] of EasyFfmpeg::StreamInfo,
    other_streams,
    format,
  )
end

describe EasyFfmpeg do
  describe ".parse_time" do
    it "parses supported time formats" do
      EasyFfmpeg.parse_time("90").should eq(90.0)
      EasyFfmpeg.parse_time("1:31").should eq(91.0)
      EasyFfmpeg.parse_time("1:31.500").should eq(91.5)
      EasyFfmpeg.parse_time("1:02:30").should eq(3750.0)
      EasyFfmpeg.parse_time("1:02:30.5").should eq(3750.5)
    end

    it "rejects negative and out-of-range colon formats" do
      EasyFfmpeg.parse_time("-1").should be_nil
      EasyFfmpeg.parse_time("1:60").should be_nil
      EasyFfmpeg.parse_time("1:02:60").should be_nil
      EasyFfmpeg.parse_time("1:99:00").should be_nil
    end
  end

  describe EasyFfmpeg::MediaInfo do
    it "parses ffprobe json without crashing on missing format fields" do
      json = <<-JSON
      {
        "streams": [
          {
            "index": 0,
            "codec_name": "h264",
            "codec_type": "video",
            "width": 1920,
            "height": 1080,
            "r_frame_rate": "24000/1001",
            "disposition": {"attached_pic": 0}
          },
          {
            "index": 1,
            "codec_name": "aac",
            "codec_type": "audio",
            "channels": 2,
            "bit_rate": "N/A",
            "tags": {"language": "eng", "BPS": "192000"}
          }
        ]
      }
      JSON

      info = EasyFfmpeg::MediaInfo.from_probe_json("movie.mkv", json)

      info.format.filename.should eq("movie.mkv")
      info.format.duration.should eq(0.0)
      info.video_streams.first.frame_rate.should_not be_nil
      info.video_streams.first.frame_rate.not_nil!.should be_close(23.976, 0.001)
      info.audio_streams.first.bit_rate.should eq(192_000_i64)
      info.audio_streams.first.language.should eq("eng")
    end

    it "raises a clear error for invalid probe json" do
      expect_raises(Exception, /invalid JSON/) do
        EasyFfmpeg::MediaInfo.from_probe_json("movie.mkv", "{")
      end
    end
  end

  describe EasyFfmpeg::ConversionPlan do
    it "does not overwrite outputs unless force was requested" do
      info = build_media_info
      plan = EasyFfmpeg::ConversionPlan.new(info, "out.mp4", "mp4", EasyFfmpeg::Preset::Default)

      EasyFfmpeg::Converter.new(plan).build_args.should contain("-n")
      EasyFfmpeg::Converter.new(plan).build_args.should_not contain("-y")
    end

    it "uses overwrite mode when force was requested" do
      info = build_media_info
      plan = EasyFfmpeg::ConversionPlan.new(
        info,
        "out.mp4",
        "mp4",
        EasyFfmpeg::Preset::Default,
        overwrite_output: true,
      )

      EasyFfmpeg::Converter.new(plan).build_args.should contain("-y")
      EasyFfmpeg::Converter.new(plan).build_args.should_not contain("-n")
    end

    it "drops unsupported auxiliary streams instead of trying to mux them blindly" do
      data_stream = EasyFfmpeg::StreamInfo.new(
        index: 2,
        codec_name: "bin_data",
        codec_long_name: "Binary Data",
        codec_type: "data",
      )
      info = build_media_info(other_streams: [data_stream])

      plan = EasyFfmpeg::ConversionPlan.new(info, "out.mp4", "mp4", EasyFfmpeg::Preset::Default)
      auxiliary_plan = plan.stream_plans.find { |sp| sp.stream.codec_type == "data" }

      auxiliary_plan.should_not be_nil
      auxiliary_plan.not_nil!.action.drop?.should be_true
      auxiliary_plan.not_nil!.reason.should eq("unsupported auxiliary stream")
    end

    it "keeps supported attached cover art" do
      cover_art = EasyFfmpeg::StreamInfo.new(
        index: 2,
        codec_name: "mjpeg",
        codec_long_name: "MJPEG",
        codec_type: "video",
        is_attached_pic: true,
      )
      info = build_media_info(other_streams: [cover_art])

      plan = EasyFfmpeg::ConversionPlan.new(info, "out.mp4", "mp4", EasyFfmpeg::Preset::Default)
      art_plan = plan.stream_plans.find(&.stream.is_attached_pic)

      art_plan.should_not be_nil
      art_plan.not_nil!.action.copy?.should be_true
    end

    it "adds scale filter to ensure even dimensions for libx264 when width is odd" do
      info = build_media_info(video_codec: "vp8", video_width: 1057, video_height: 518)

      plan = EasyFfmpeg::ConversionPlan.new(info, "out.mp4", "mp4", EasyFfmpeg::Preset::Default)

      plan.video_plans.first.action.transcode?.should be_true
      plan.video_filters.should contain("scale=trunc(iw/2)*2:trunc(ih/2)*2")
    end

    it "does not add even-dimension scale filter when dimensions are already even" do
      info = build_media_info(video_codec: "vp8", video_width: 1920, video_height: 1080)

      plan = EasyFfmpeg::ConversionPlan.new(info, "out.mp4", "mp4", EasyFfmpeg::Preset::Default)

      plan.video_filters.any? { |f| f.includes?("trunc") }.should be_false
    end

    it "does not add even-dimension scale filter when a scale filter is already present" do
      info = build_media_info(video_codec: "vp8", video_width: 1057, video_height: 2160)

      plan = EasyFfmpeg::ConversionPlan.new(
        info, "out.mp4", "mp4", EasyFfmpeg::Preset::Default, scale: "hd",
      )

      plan.video_filters.should contain("scale=-2:720")
      plan.video_filters.any? { |f| f.includes?("trunc") }.should be_false
    end

    it "adds transcode filters when scaling, aspect, or pixel format normalization is needed" do
      info = build_media_info(video_codec: "vp9", video_height: 2160, pix_fmt: "yuv444p")

      plan = EasyFfmpeg::ConversionPlan.new(
        info,
        "out.mp4",
        "mp4",
        EasyFfmpeg::Preset::Default,
        scale: "hd",
        aspect: "wide",
      )

      plan.video_plans.first.action.transcode?.should be_true
      plan.video_filters.should contain("scale=-2:720")
      plan.video_filters.should contain("format=yuv420p")
      plan.video_filters.any?(&.starts_with?("pad=")).should be_true
    end
  end

  describe EasyFfmpeg::GpuSupport do
    it "maps cpu encoders to nvenc equivalents only when available" do
      EasyFfmpeg::GpuSupport.stub_encoders!(["h264_nvenc", "hevc_nvenc"])

      EasyFfmpeg::GpuSupport.gpu_encoder_for?("libx264").should eq("h264_nvenc")
      EasyFfmpeg::GpuSupport.gpu_encoder_for?("libx265").should eq("hevc_nvenc")
      EasyFfmpeg::GpuSupport.gpu_encoder_for?("libsvtav1").should be_nil
      EasyFfmpeg::GpuSupport.gpu_encoder_for?("libvpx-vp9").should be_nil
    ensure
      EasyFfmpeg::GpuSupport.reset_cache!
    end

    it "translates -crf and -preset to nvenc args" do
      cpu = ["-crf", "23", "-preset", "medium", "-profile:v", "high"]
      gpu = EasyFfmpeg::GpuSupport.translate_args(cpu)

      gpu.should contain("-cq")
      gpu[gpu.index!("-cq") + 1].should eq("23")
      gpu.should contain("-b:v")
      gpu[gpu.index!("-preset") + 1].should eq("p5")
      gpu.should contain("-profile:v")
      gpu.should contain("-rc")
      gpu[gpu.index!("-rc") + 1].should eq("vbr")
    end

    it "drops -level when translating to NVENC" do
      cpu = ["-crf", "26", "-preset", "medium", "-profile:v", "main", "-level", "3.1"]
      gpu = EasyFfmpeg::GpuSupport.translate_args(cpu)

      gpu.should_not contain("-level")
      gpu.should_not contain("3.1")
      gpu.should contain("-profile:v")
      gpu[gpu.index!("-profile:v") + 1].should eq("main")
    end
  end

  describe "ConversionPlan with --mobile --gpu" do
    it "does not emit -level on the NVENC encoder args" do
      EasyFfmpeg::GpuSupport.stub_encoders!(["h264_nvenc", "hevc_nvenc"])
      info = build_media_info(video_codec: "h264", video_width: 1920, video_height: 816)

      plan = EasyFfmpeg::ConversionPlan.new(
        info, "out.mp4", "mp4", EasyFfmpeg::Preset::Mobile, use_gpu: true,
      )
      args = plan.video_plans.first.encoder_args

      plan.video_plans.first.encoder.should eq("h264_nvenc")
      args.should_not contain("-level")
    ensure
      EasyFfmpeg::GpuSupport.reset_cache!
    end

    it "still emits -level on the CPU --mobile path" do
      EasyFfmpeg::GpuSupport.stub_encoders!(["h264_nvenc", "hevc_nvenc"])
      info = build_media_info(video_codec: "h264", video_width: 1920, video_height: 816)

      plan = EasyFfmpeg::ConversionPlan.new(
        info, "out.mp4", "mp4", EasyFfmpeg::Preset::Mobile,
      )
      args = plan.video_plans.first.encoder_args

      plan.video_plans.first.encoder.should eq("libx264")
      args.should contain("-level")
      args[args.index!("-level") + 1].should eq("3.1")
    ensure
      EasyFfmpeg::GpuSupport.reset_cache!
    end
  end

  describe "ConversionPlan with --gpu" do
    it "swaps libx264 for h264_nvenc when nvenc is available" do
      EasyFfmpeg::GpuSupport.stub_encoders!(["h264_nvenc", "hevc_nvenc"])
      info = build_media_info(video_codec: "vp9") # forces transcode for mp4

      plan = EasyFfmpeg::ConversionPlan.new(
        info, "out.mp4", "mp4", EasyFfmpeg::Preset::Web, use_gpu: true,
      )

      plan.video_plans.first.encoder.should eq("h264_nvenc")
      args = plan.video_plans.first.encoder_args
      args.should contain("-cq")
      args.should_not contain("-crf")
    end

    it "swaps libx265 for hevc_nvenc on the compress preset" do
      EasyFfmpeg::GpuSupport.stub_encoders!(["h264_nvenc", "hevc_nvenc"])
      info = build_media_info(video_codec: "vp9")

      plan = EasyFfmpeg::ConversionPlan.new(
        info, "out.mp4", "mp4", EasyFfmpeg::Preset::Compress, use_gpu: true,
      )

      plan.video_plans.first.encoder.should eq("hevc_nvenc")
    end

    it "falls back to cpu encoder when no nvenc equivalent exists" do
      EasyFfmpeg::GpuSupport.stub_encoders!(["h264_nvenc", "hevc_nvenc"])
      info = build_media_info(video_codec: "h264") # vp9 webm target → libvpx-vp9 has no nvenc

      plan = EasyFfmpeg::ConversionPlan.new(
        info, "out.webm", "webm", EasyFfmpeg::Preset::Web, use_gpu: true,
      )

      plan.video_plans.first.encoder.should eq("libvpx-vp9")
    end

    it "leaves the encoder unchanged when use_gpu is false" do
      EasyFfmpeg::GpuSupport.stub_encoders!(["h264_nvenc", "hevc_nvenc"])
      info = build_media_info(video_codec: "vp9")

      plan = EasyFfmpeg::ConversionPlan.new(
        info, "out.mp4", "mp4", EasyFfmpeg::Preset::Web,
      )

      plan.video_plans.first.encoder.should eq("libx264")
    ensure
      EasyFfmpeg::GpuSupport.reset_cache!
    end

    it "still applies even-dimension scaling for nvenc h264/h265" do
      EasyFfmpeg::GpuSupport.stub_encoders!(["h264_nvenc", "hevc_nvenc"])
      info = build_media_info(video_codec: "vp9", video_width: 1057, video_height: 519)

      plan = EasyFfmpeg::ConversionPlan.new(
        info, "out.mp4", "mp4", EasyFfmpeg::Preset::Default, use_gpu: true,
      )

      # In pure-GPU mode the filter is rewritten to scale_cuda. Either form
      # is acceptable here — what matters is that the even-dimension fix is
      # applied.
      plan.video_filters.any? { |f|
        f.includes?("trunc(iw/2)*2:trunc(ih/2)*2")
      }.should be_true
    ensure
      EasyFfmpeg::GpuSupport.reset_cache!
    end
  end

  describe "Converter with --gpu" do
    it "adds -hwaccel cuda before -i when encoding through NVENC" do
      EasyFfmpeg::GpuSupport.stub_encoders!(["h264_nvenc", "hevc_nvenc"])
      info = build_media_info(video_codec: "vp9") # forces transcode for mp4

      plan = EasyFfmpeg::ConversionPlan.new(
        info, "out.mp4", "mp4", EasyFfmpeg::Preset::Web, use_gpu: true,
      )
      args = EasyFfmpeg::Converter.new(plan).build_args

      hwaccel_idx = args.index("-hwaccel")
      hwaccel_idx.should_not be_nil
      args[hwaccel_idx.not_nil! + 1].should eq("cuda")
      # -hwaccel must come before the input
      args.index("-hwaccel").not_nil!.should be < args.index("-i").not_nil!
    ensure
      EasyFfmpeg::GpuSupport.reset_cache!
    end

    it "omits -hwaccel cuda when --gpu falls back to a CPU encoder" do
      EasyFfmpeg::GpuSupport.stub_encoders!(["h264_nvenc", "hevc_nvenc"])
      # webm target → libvpx-vp9, which has no NVENC equivalent → CPU encode
      info = build_media_info(video_codec: "h264")

      plan = EasyFfmpeg::ConversionPlan.new(
        info, "out.webm", "webm", EasyFfmpeg::Preset::Web, use_gpu: true,
      )
      args = EasyFfmpeg::Converter.new(plan).build_args

      args.should_not contain("-hwaccel")
    ensure
      EasyFfmpeg::GpuSupport.reset_cache!
    end

    it "omits -hwaccel cuda when use_gpu is false" do
      EasyFfmpeg::GpuSupport.stub_encoders!(["h264_nvenc", "hevc_nvenc"])
      info = build_media_info(video_codec: "vp9")

      plan = EasyFfmpeg::ConversionPlan.new(
        info, "out.mp4", "mp4", EasyFfmpeg::Preset::Web,
      )
      args = EasyFfmpeg::Converter.new(plan).build_args

      args.should_not contain("-hwaccel")
    ensure
      EasyFfmpeg::GpuSupport.reset_cache!
    end

    it "omits -hwaccel cuda for remux-only jobs (no transcode)" do
      EasyFfmpeg::GpuSupport.stub_encoders!(["h264_nvenc", "hevc_nvenc"])
      info = build_media_info(video_codec: "h264") # h264 in mp4 → copy

      plan = EasyFfmpeg::ConversionPlan.new(
        info, "out.mp4", "mp4", EasyFfmpeg::Preset::Default, use_gpu: true,
      )
      args = EasyFfmpeg::Converter.new(plan).build_args

      args.should_not contain("-hwaccel")
    ensure
      EasyFfmpeg::GpuSupport.reset_cache!
    end

    it "adds -hwaccel_output_format cuda for a pure GPU pipeline" do
      EasyFfmpeg::GpuSupport.stub_encoders!(["h264_nvenc", "hevc_nvenc"])
      info = build_media_info(video_codec: "vp9")

      plan = EasyFfmpeg::ConversionPlan.new(
        info, "out.mp4", "mp4", EasyFfmpeg::Preset::Compress, use_gpu: true,
      )
      args = EasyFfmpeg::Converter.new(plan).build_args

      plan.pure_gpu_pipeline?.should be_true
      idx = args.index("-hwaccel_output_format")
      idx.should_not be_nil
      args[idx.not_nil! + 1].should eq("cuda")
    ensure
      EasyFfmpeg::GpuSupport.reset_cache!
    end

    it "drops -hwaccel_output_format cuda when an aspect filter is requested" do
      EasyFfmpeg::GpuSupport.stub_encoders!(["h264_nvenc", "hevc_nvenc"])
      info = build_media_info(video_codec: "vp9")

      plan = EasyFfmpeg::ConversionPlan.new(
        info, "out.mp4", "mp4", EasyFfmpeg::Preset::Compress,
        use_gpu: true, aspect: "wide",
      )
      args = EasyFfmpeg::Converter.new(plan).build_args

      plan.pure_gpu_pipeline?.should be_false
      args.should contain("-hwaccel")
      args.should_not contain("-hwaccel_output_format")
    ensure
      EasyFfmpeg::GpuSupport.reset_cache!
    end
  end

  describe "ConversionPlan pure GPU filter rewriting" do
    it "rewrites scale to scale_cuda when pure GPU" do
      EasyFfmpeg::GpuSupport.stub_encoders!(["h264_nvenc", "hevc_nvenc"])
      info = build_media_info(video_codec: "vp9", video_width: 1920, video_height: 1080)

      plan = EasyFfmpeg::ConversionPlan.new(
        info, "out.mp4", "mp4", EasyFfmpeg::Preset::Compress,
        use_gpu: true, scale: "hd",
      )

      plan.pure_gpu_pipeline?.should be_true
      plan.video_filters.should contain("scale_cuda=-2:720")
      plan.video_filters.none? { |f| f.starts_with?("scale=") }.should be_true
    ensure
      EasyFfmpeg::GpuSupport.reset_cache!
    end

    it "rewrites even-dimension scale to scale_cuda for odd-dim sources" do
      EasyFfmpeg::GpuSupport.stub_encoders!(["h264_nvenc", "hevc_nvenc"])
      info = build_media_info(video_codec: "vp9", video_width: 1057, video_height: 519)

      plan = EasyFfmpeg::ConversionPlan.new(
        info, "out.mp4", "mp4", EasyFfmpeg::Preset::Default, use_gpu: true,
      )

      plan.pure_gpu_pipeline?.should be_true
      plan.video_filters.should contain("scale_cuda=trunc(iw/2)*2:trunc(ih/2)*2")
    ensure
      EasyFfmpeg::GpuSupport.reset_cache!
    end

    it "drops format=yuv420p when pure GPU (NVENC handles pix_fmt)" do
      EasyFfmpeg::GpuSupport.stub_encoders!(["h264_nvenc", "hevc_nvenc"])
      info = build_media_info(
        video_codec: "vp9", video_width: 1920, video_height: 1080,
        pix_fmt: "yuv444p", # forces format=yuv420p filter on H.264/H.265
      )

      plan = EasyFfmpeg::ConversionPlan.new(
        info, "out.mp4", "mp4", EasyFfmpeg::Preset::Compress, use_gpu: true,
      )

      plan.pure_gpu_pipeline?.should be_true
      plan.video_filters.should_not contain("format=yuv420p")
    ensure
      EasyFfmpeg::GpuSupport.reset_cache!
    end

    it "keeps CPU filters and disables pure GPU when --aspect is used" do
      EasyFfmpeg::GpuSupport.stub_encoders!(["h264_nvenc", "hevc_nvenc"])
      info = build_media_info(video_codec: "vp9")

      plan = EasyFfmpeg::ConversionPlan.new(
        info, "out.mp4", "mp4", EasyFfmpeg::Preset::Compress,
        use_gpu: true, aspect: "wide",
      )

      plan.pure_gpu_pipeline?.should be_false
      plan.video_filters.any? { |f| f.starts_with?("pad=") }.should be_true
      plan.video_filters.none? { |f| f.starts_with?("scale_cuda=") }.should be_true
    ensure
      EasyFfmpeg::GpuSupport.reset_cache!
    end

    it "does not enable pure GPU when --gpu is off" do
      EasyFfmpeg::GpuSupport.stub_encoders!(["h264_nvenc", "hevc_nvenc"])
      info = build_media_info(video_codec: "vp9")

      plan = EasyFfmpeg::ConversionPlan.new(
        info, "out.mp4", "mp4", EasyFfmpeg::Preset::Compress,
      )

      plan.pure_gpu_pipeline?.should be_false
      plan.video_filters.none? { |f| f.starts_with?("scale_cuda=") }.should be_true
    ensure
      EasyFfmpeg::GpuSupport.reset_cache!
    end
  end

  describe EasyFfmpeg::StreamInfo do
    it "detects HDR via PQ (smpte2084) transfer characteristic" do
      s = EasyFfmpeg::StreamInfo.new(
        index: 0, codec_name: "hevc", codec_long_name: "HEVC", codec_type: "video",
        color_transfer: "smpte2084",
      )
      s.hdr?.should be_true
    end

    it "detects HDR via HLG (arib-std-b67) transfer characteristic" do
      s = EasyFfmpeg::StreamInfo.new(
        index: 0, codec_name: "hevc", codec_long_name: "HEVC", codec_type: "video",
        color_transfer: "arib-std-b67",
      )
      s.hdr?.should be_true
    end

    it "treats missing or SDR transfer as non-HDR" do
      sdr = EasyFfmpeg::StreamInfo.new(
        index: 0, codec_name: "h264", codec_long_name: "H264", codec_type: "video",
        color_transfer: "bt709",
      )
      missing = EasyFfmpeg::StreamInfo.new(
        index: 0, codec_name: "h264", codec_long_name: "H264", codec_type: "video",
      )
      sdr.hdr?.should be_false
      missing.hdr?.should be_false
    end

    it "detects interlaced field orders" do
      %w[tt bb tb bt].each do |order|
        s = EasyFfmpeg::StreamInfo.new(
          index: 0, codec_name: "h264", codec_long_name: "H264", codec_type: "video",
          field_order: order,
        )
        s.interlaced?.should be_true
      end
    end

    it "treats progressive / unknown / missing field order as non-interlaced" do
      ["progressive", "unknown", nil].each do |order|
        s = EasyFfmpeg::StreamInfo.new(
          index: 0, codec_name: "h264", codec_long_name: "H264", codec_type: "video",
          field_order: order,
        )
        s.interlaced?.should be_false
      end
    end
  end

  describe "GpuSupport quality tuning" do
    it "appends rc-lookahead / spatial-aq / temporal-aq / bf / b_ref_mode in translate_args" do
      result = EasyFfmpeg::GpuSupport.translate_args(["-crf", "20", "-preset", "medium"])
      result.should contain("-rc-lookahead")
      result[result.index!("-rc-lookahead") + 1].should eq("20")
      result.should contain("-spatial-aq")
      result.should contain("-temporal-aq")
      result.should contain("-bf")
      result[result.index!("-bf") + 1].should eq("3")
      result.should contain("-b_ref_mode")
    end

    it "includes the same tuning in default_quality_args for each NVENC encoder" do
      %w[h264_nvenc hevc_nvenc av1_nvenc].each do |enc|
        args = EasyFfmpeg::GpuSupport.default_quality_args(enc)
        args.should contain("-rc-lookahead")
        args.should contain("-spatial-aq")
        args.should contain("-temporal-aq")
      end
    end
  end

  describe "GpuSupport quality modes" do
    it "Fast mode: preset p2, no rc-lookahead/spatial-aq/temporal-aq" do
      result = EasyFfmpeg::GpuSupport.translate_args(
        ["-crf", "28", "-preset", "medium"],
        EasyFfmpeg::GpuSupport::Quality::Fast,
      )
      result[result.index!("-preset") + 1].should eq("p2")
      result[result.index!("-cq") + 1].should eq("28") # no offset on Fast
      result.should_not contain("-rc-lookahead")
      result.should_not contain("-spatial-aq")
      result.should_not contain("-temporal-aq")
      result.should_not contain("-bf")
    end

    it "Balanced mode (default): preset p5, full tuning, no CQ offset" do
      result = EasyFfmpeg::GpuSupport.translate_args(["-crf", "28", "-preset", "medium"])
      result[result.index!("-preset") + 1].should eq("p5")
      result[result.index!("-cq") + 1].should eq("28")
      result[result.index!("-rc-lookahead") + 1].should eq("20")
      result[result.index!("-bf") + 1].should eq("3")
    end

    it "Smaller mode: preset p7, CQ + 5, lookahead 32, bf 4" do
      result = EasyFfmpeg::GpuSupport.translate_args(
        ["-crf", "28", "-preset", "medium"],
        EasyFfmpeg::GpuSupport::Quality::Smaller,
      )
      result[result.index!("-preset") + 1].should eq("p7")
      result[result.index!("-cq") + 1].should eq("33") # 28 + 5
      result[result.index!("-rc-lookahead") + 1].should eq("32")
      result[result.index!("-bf") + 1].should eq("4")
    end

    it "default_quality_args respects the quality mode" do
      fast     = EasyFfmpeg::GpuSupport.default_quality_args("hevc_nvenc", EasyFfmpeg::GpuSupport::Quality::Fast)
      balanced = EasyFfmpeg::GpuSupport.default_quality_args("hevc_nvenc", EasyFfmpeg::GpuSupport::Quality::Balanced)
      smaller  = EasyFfmpeg::GpuSupport.default_quality_args("hevc_nvenc", EasyFfmpeg::GpuSupport::Quality::Smaller)

      fast[fast.index!("-preset") + 1].should eq("p2")
      fast[fast.index!("-cq") + 1].should eq("21")
      fast.should_not contain("-rc-lookahead")

      balanced[balanced.index!("-preset") + 1].should eq("p5")
      balanced[balanced.index!("-cq") + 1].should eq("21")

      smaller[smaller.index!("-preset") + 1].should eq("p7")
      smaller[smaller.index!("-cq") + 1].should eq("26") # 21 + 5
      smaller[smaller.index!("-rc-lookahead") + 1].should eq("32")
    end

    it "Smaller mode CQ offset applies regardless of input CRF value" do
      [10, 18, 23, 28, 35].each do |crf|
        result = EasyFfmpeg::GpuSupport.translate_args(
          ["-crf", crf.to_s, "-preset", "medium"],
          EasyFfmpeg::GpuSupport::Quality::Smaller,
        )
        result[result.index!("-cq") + 1].should eq((crf + 5).to_s)
      end
    end
  end

  describe "ConversionPlan with --gpu-quality" do
    it "passes Smaller mode through to encoder args" do
      EasyFfmpeg::GpuSupport.stub_encoders!(["h264_nvenc", "hevc_nvenc"])
      info = build_media_info(video_codec: "vp9")

      plan = EasyFfmpeg::ConversionPlan.new(
        info, "out.mp4", "mp4", EasyFfmpeg::Preset::Compress,
        use_gpu: true, gpu_quality: EasyFfmpeg::GpuSupport::Quality::Smaller,
      )
      args = plan.video_plans.first.encoder_args

      args[args.index!("-preset") + 1].should eq("p7")
      args[args.index!("-cq") + 1].should eq("33") # compress preset is -crf 28
      args[args.index!("-rc-lookahead") + 1].should eq("32")
    ensure
      EasyFfmpeg::GpuSupport.reset_cache!
    end

    it "Fast mode produces smaller arg set (no quality tuning)" do
      EasyFfmpeg::GpuSupport.stub_encoders!(["h264_nvenc", "hevc_nvenc"])
      info = build_media_info(video_codec: "vp9")

      plan = EasyFfmpeg::ConversionPlan.new(
        info, "out.mp4", "mp4", EasyFfmpeg::Preset::Compress,
        use_gpu: true, gpu_quality: EasyFfmpeg::GpuSupport::Quality::Fast,
      )
      args = plan.video_plans.first.encoder_args

      args[args.index!("-preset") + 1].should eq("p2")
      args.should_not contain("-rc-lookahead")
      args.should_not contain("-spatial-aq")
    ensure
      EasyFfmpeg::GpuSupport.reset_cache!
    end

    it "defaults to Balanced when gpu_quality is not specified" do
      EasyFfmpeg::GpuSupport.stub_encoders!(["h264_nvenc", "hevc_nvenc"])
      info = build_media_info(video_codec: "vp9")

      plan = EasyFfmpeg::ConversionPlan.new(
        info, "out.mp4", "mp4", EasyFfmpeg::Preset::Compress, use_gpu: true,
      )

      plan.gpu_quality.should eq(EasyFfmpeg::GpuSupport::Quality::Balanced)
    ensure
      EasyFfmpeg::GpuSupport.reset_cache!
    end
  end

  describe "ConversionPlan HDR preservation" do
    it "preserves HDR for hevc_nvenc: propagates color metadata" do
      EasyFfmpeg::GpuSupport.stub_encoders!(["h264_nvenc", "hevc_nvenc"])
      info = build_media_info(
        video_codec: "hevc", pix_fmt: "yuv420p10le",
        color_primaries: "bt2020", color_transfer: "smpte2084",
        color_space: "bt2020nc", color_range: "tv",
      )

      plan = EasyFfmpeg::ConversionPlan.new(
        info, "out.mp4", "mp4", EasyFfmpeg::Preset::Compress, use_gpu: true,
      )
      args = plan.video_plans.first.encoder_args

      # No explicit -pix_fmt: NVENC inherits 10-bit from the input surface.
      # Setting it would conflict with CUDA hwaccel surfaces.
      args.should_not contain("-pix_fmt")
      args.should contain("-color_primaries")
      args[args.index!("-color_primaries") + 1].should eq("bt2020")
      args.should contain("-color_trc")
      args[args.index!("-color_trc") + 1].should eq("smpte2084")
      args.should contain("-colorspace")
      args[args.index!("-colorspace") + 1].should eq("bt2020nc")
    ensure
      EasyFfmpeg::GpuSupport.reset_cache!
    end

    it "does not preserve HDR for h264_nvenc (no robust HDR support)" do
      EasyFfmpeg::GpuSupport.stub_encoders!(["h264_nvenc", "hevc_nvenc"])
      info = build_media_info(
        video_codec: "hevc", pix_fmt: "yuv420p10le",
        color_transfer: "smpte2084",
      )

      plan = EasyFfmpeg::ConversionPlan.new(
        info, "out.mp4", "mp4", EasyFfmpeg::Preset::Web, use_gpu: true,
      )
      args = plan.video_plans.first.encoder_args

      plan.video_plans.first.encoder.should eq("h264_nvenc")
      args.should_not contain("-color_primaries")
    ensure
      EasyFfmpeg::GpuSupport.reset_cache!
    end

    it "supplies default color metadata when source fields are missing" do
      EasyFfmpeg::GpuSupport.stub_encoders!(["h264_nvenc", "hevc_nvenc"])
      info = build_media_info(
        video_codec: "hevc", pix_fmt: "yuv420p10le",
        color_transfer: "smpte2084", # HDR transfer present, other fields missing
      )

      plan = EasyFfmpeg::ConversionPlan.new(
        info, "out.mp4", "mp4", EasyFfmpeg::Preset::Compress, use_gpu: true,
      )
      args = plan.video_plans.first.encoder_args

      args[args.index!("-color_primaries") + 1].should eq("bt2020")
      args[args.index!("-colorspace") + 1].should eq("bt2020nc")
    ensure
      EasyFfmpeg::GpuSupport.reset_cache!
    end

    it "does not add format=yuv420p when preserving HDR (would discard 10-bit)" do
      EasyFfmpeg::GpuSupport.stub_encoders!(["h264_nvenc", "hevc_nvenc"])
      info = build_media_info(
        video_codec: "hevc", pix_fmt: "yuv444p10le", # not in the skip list
        color_transfer: "smpte2084",
      )

      plan = EasyFfmpeg::ConversionPlan.new(
        info, "out.mp4", "mp4", EasyFfmpeg::Preset::Compress, use_gpu: true,
      )

      plan.video_filters.should_not contain("format=yuv420p")
    ensure
      EasyFfmpeg::GpuSupport.reset_cache!
    end
  end

  describe "ConversionPlan auto-deinterlace" do
    it "inserts yadif first in the filter chain on CPU path" do
      info = build_media_info(video_codec: "vp9", field_order: "tt")

      plan = EasyFfmpeg::ConversionPlan.new(
        info, "out.mp4", "mp4", EasyFfmpeg::Preset::Compress,
      )

      plan.video_filters.first.starts_with?("yadif=").should be_true
    end

    it "rewrites yadif to yadif_cuda on pure GPU path" do
      EasyFfmpeg::GpuSupport.stub_encoders!(["h264_nvenc", "hevc_nvenc"])
      info = build_media_info(video_codec: "vp9", field_order: "tt")

      plan = EasyFfmpeg::ConversionPlan.new(
        info, "out.mp4", "mp4", EasyFfmpeg::Preset::Compress, use_gpu: true,
      )

      plan.pure_gpu_pipeline?.should be_true
      plan.video_filters.first.starts_with?("yadif_cuda=").should be_true
    ensure
      EasyFfmpeg::GpuSupport.reset_cache!
    end

    it "does not add yadif for progressive sources" do
      info = build_media_info(video_codec: "vp9", field_order: "progressive")

      plan = EasyFfmpeg::ConversionPlan.new(
        info, "out.mp4", "mp4", EasyFfmpeg::Preset::Compress,
      )

      plan.video_filters.none? { |f| f.starts_with?("yadif") }.should be_true
    end

    it "places yadif before scale and aspect filters" do
      info = build_media_info(video_codec: "vp9", field_order: "tt", video_height: 1080)

      plan = EasyFfmpeg::ConversionPlan.new(
        info, "out.mp4", "mp4", EasyFfmpeg::Preset::Mobile,
        aspect: "wide",
      )

      yadif_idx = plan.video_filters.index { |f| f.starts_with?("yadif") }
      scale_idx = plan.video_filters.index { |f| f.starts_with?("scale") }
      aspect_idx = plan.video_filters.index { |f| f.starts_with?("pad=") || f.starts_with?("crop=") }

      yadif_idx.should_not be_nil
      scale_idx.should_not be_nil
      aspect_idx.should_not be_nil
      yadif_idx.not_nil!.should be < scale_idx.not_nil!
      yadif_idx.not_nil!.should be < aspect_idx.not_nil!
    end
  end

  describe EasyFfmpeg::ImageSequence do
    it "honors the force flag when building ffmpeg args" do
      seq = EasyFfmpeg::ImageSequence::SequenceInfo.new(
        directory: "frames",
        files: ["frame_0001.png", "frame_0002.png"],
        extension: ".png",
        frame_count: 2,
        width: 1920,
        height: 1080,
        input_pattern: EasyFfmpeg::ImageSequence::InputPattern.new(
          EasyFfmpeg::ImageSequence::InputMode::Sequential,
          "frames/frame_%04d.png",
        ),
        total_size: 1024_i64,
      )

      normal_args = EasyFfmpeg::ImageSequence.build_ffmpeg_args(
        seq,
        "out.mp4",
        24,
        EasyFfmpeg::Preset::Default,
        "mp4",
        false,
      )
      forced_args = EasyFfmpeg::ImageSequence.build_ffmpeg_args(
        seq,
        "out.mp4",
        24,
        EasyFfmpeg::Preset::Default,
        "mp4",
        true,
      )

      normal_args.should contain("-n")
      forced_args.should contain("-y")
    end

    it "builds palette-based gif filters" do
      seq = EasyFfmpeg::ImageSequence::SequenceInfo.new(
        directory: "frames",
        files: ["a.png", "b.png"],
        extension: ".png",
        frame_count: 2,
        width: 800,
        height: 600,
        input_pattern: EasyFfmpeg::ImageSequence::InputPattern.new(
          EasyFfmpeg::ImageSequence::InputMode::Glob,
          "frames/*.png",
        ),
        total_size: 1024_i64,
      )

      args = EasyFfmpeg::ImageSequence.build_ffmpeg_args(
        seq,
        "out.gif",
        12,
        EasyFfmpeg::Preset::Default,
        "gif",
        false,
        aspect: "square",
      )

      args.should contain("-pattern_type")
      args.should contain("glob")
      args.join(" ").should contain("palettegen")
      args.join(" ").should contain("paletteuse")
    end
  end
end
