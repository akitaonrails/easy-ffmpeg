require "./spec_helper"

private def build_media_info(video_codec : String = "h264", audio_codec : String = "aac",
                             video_width : Int32 = 1920, video_height : Int32 = 1080,
                             pix_fmt : String = "yuv420p",
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
