module EasyFfmpeg
  SCALE_HEIGHTS  = {"2k" => 1440, "fullhd" => 1080, "hd" => 720, "retro" => 480, "icon" => 240}
  ASPECT_RATIOS  = {"wide" => {16, 9}, "4:3" => {4, 3}, "8:7" => {8, 7}, "square" => {1, 1}, "tiktok" => {9, 16}}

  enum StreamAction
    Copy
    Transcode
    Drop
  end

  struct StreamPlan
    getter stream : StreamInfo
    getter action : StreamAction
    getter encoder : String?
    getter encoder_args : Array(String)
    getter reason : String
    getter output_codec_display : String

    def initialize(@stream, @action, @encoder = nil, @encoder_args = [] of String,
                   @reason = "", @output_codec_display = "")
    end
  end

  class ConversionPlan
    getter input : MediaInfo
    getter output_path : String
    getter target_format : String
    getter preset : Preset
    getter stream_plans : Array(StreamPlan)
    getter global_args : Array(String)
    getter video_filters : Array(String)
    getter is_remux_only : Bool
    getter start_time : Float64?
    getter end_time : Float64?
    getter duration : Float64?
    getter scale : String?
    getter aspect : String?
    getter crop : Bool

    def initialize(@input, @output_path, @target_format, @preset,
                   @start_time = nil, @end_time = nil, @duration = nil,
                   @scale = nil, @aspect = nil, @crop = false)
      @stream_plans = [] of StreamPlan
      @global_args = [] of String
      @video_filters = [] of String
      @is_remux_only = false
      build
    end

    # Effective duration of output (accounting for trim)
    def effective_duration : Float64
      total = input.format.duration
      ss = start_time || 0.0
      if d = duration
        d
      elsif et = end_time
        et - ss
      else
        total - ss
      end
    end

    def mapped_streams : Array(StreamPlan)
      stream_plans.reject(&.action.drop?)
    end

    def video_plans : Array(StreamPlan)
      stream_plans.select { |p| p.stream.video? }
    end

    def audio_plans : Array(StreamPlan)
      stream_plans.select { |p| p.stream.audio? }
    end

    def sub_plans : Array(StreamPlan)
      stream_plans.select { |p| p.stream.subtitle? }
    end

    private def build
      config = PresetConfig.for(preset, target_format)

      plan_video_streams(config)
      plan_audio_streams(config)
      plan_subtitle_streams(config)
      plan_other_streams

      if config.faststart
        @global_args << "-movflags" << "+faststart"
      end

      @is_remux_only = stream_plans.all? { |p| p.action.copy? || p.action.drop? }
    end

    private def plan_video_streams(config : PresetConfig)
      needs_filters = !scale.nil? || !aspect.nil?
      input.video_streams.each do |stream|
        if config.force_transcode || needs_filters
          plan_video_transcode(stream, config)
        elsif CodecSupport.video_compatible?(stream.codec_name, target_format)
          @stream_plans << StreamPlan.new(
            stream: stream,
            action: StreamAction::Copy,
            encoder: "copy",
            reason: "compatible",
            output_codec_display: CodecSupport.codec_display_name(stream.codec_name),
          )
        else
          plan_video_transcode(stream, config)
        end
      end
    end

    private def plan_video_transcode(stream : StreamInfo, config : PresetConfig)
      encoder = config.video_codec || CodecSupport::DEFAULT_VIDEO_CODEC[target_format]? || "libx264"
      args = if config.force_transcode
               config.video_args.dup
             else
               default_quality_args(encoder)
             end

      # 1. Scale filter (--scale overrides preset max_height)
      if s = scale
        target_h = SCALE_HEIGHTS[s]
        if h = stream.height
          if h > target_h
            @video_filters << "scale=-2:#{target_h}"
          end
        end
      elsif max_h = config.max_height
        if h = stream.height
          if h > max_h
            @video_filters << "scale=-2:#{max_h}"
          end
        end
      end

      # 2. Pixel format for h264/h265
      if encoder == "libx264" || encoder == "libx265"
        pix = stream.pix_fmt
        if pix && !%w[yuv420p yuv420p10le].includes?(pix)
          @video_filters << "format=yuv420p"
        end
      end

      # 3. Aspect ratio filter
      if a = aspect
        num, den = ASPECT_RATIOS[a]
        if crop
          @video_filters << "crop=min(iw\\,ih*#{num}/#{den}):min(ih\\,iw*#{den}/#{num})"
        else
          @video_filters << "pad=max(iw\\,ih*#{num}/#{den}):max(ih\\,iw*#{den}/#{num}):(ow-iw)/2:(oh-ih)/2:black"
        end
      end

      reason = if !scale.nil? || !aspect.nil?
                 parts = [] of String
                 parts << "--scale #{scale}" if scale
                 parts << "--aspect #{aspect}" if aspect
                 parts.join(" ")
               elsif config.force_transcode
                 preset.to_s.downcase
               else
                 "incompatible"
               end

      @stream_plans << StreamPlan.new(
        stream: stream,
        action: StreamAction::Transcode,
        encoder: encoder,
        encoder_args: args,
        reason: reason,
        output_codec_display: CodecSupport.codec_display_name(encoder),
      )
    end

    private def plan_audio_streams(config : PresetConfig)
      input.audio_streams.each do |stream|
        if config.force_transcode
          plan_audio_transcode(stream, config)
        elsif CodecSupport.audio_compatible?(stream.codec_name, target_format)
          @stream_plans << StreamPlan.new(
            stream: stream,
            action: StreamAction::Copy,
            encoder: "copy",
            reason: "compatible",
            output_codec_display: CodecSupport.codec_display_name(stream.codec_name),
          )
        else
          plan_audio_transcode(stream, config)
        end
      end
    end

    private def plan_audio_transcode(stream : StreamInfo, config : PresetConfig)
      encoder = config.audio_codec || CodecSupport::DEFAULT_AUDIO_CODEC[target_format]? || "aac"
      args = config.force_transcode ? config.audio_args.dup : default_audio_args(encoder)

      if config.downmix_stereo
        channels = stream.channels
        if channels && channels > 2
          args << "-ac" << "2"
        end
      end

      reason = config.force_transcode ? preset.to_s.downcase : "incompatible"

      @stream_plans << StreamPlan.new(
        stream: stream,
        action: StreamAction::Transcode,
        encoder: encoder,
        encoder_args: args,
        reason: reason,
        output_codec_display: CodecSupport.codec_display_name(encoder),
      )
    end

    private def plan_subtitle_streams(config : PresetConfig)
      if config.drop_subs
        input.subtitle_streams.each do |stream|
          @stream_plans << StreamPlan.new(
            stream: stream,
            action: StreamAction::Drop,
            reason: "#{preset.to_s.downcase} preset",
            output_codec_display: "",
          )
        end
        return
      end

      target_sub = CodecSupport::DEFAULT_SUB_CODEC[target_format]?

      input.subtitle_streams.each do |stream|
        if CodecSupport.sub_compatible?(stream.codec_name, target_format)
          @stream_plans << StreamPlan.new(
            stream: stream,
            action: StreamAction::Copy,
            encoder: "copy",
            reason: "compatible",
            output_codec_display: CodecSupport.codec_display_name(stream.codec_name),
          )
        elsif target_sub && CodecSupport.text_sub?(stream.codec_name)
          @stream_plans << StreamPlan.new(
            stream: stream,
            action: StreamAction::Transcode,
            encoder: target_sub,
            reason: "convert",
            output_codec_display: CodecSupport.codec_display_name(target_sub),
          )
        else
          reason = CodecSupport::CONTAINER_SUB_CODECS[target_format]?.try(&.empty?) ? "unsupported container" : "bitmap subtitle"
          @stream_plans << StreamPlan.new(
            stream: stream,
            action: StreamAction::Drop,
            reason: reason,
            output_codec_display: "",
          )
        end
      end
    end

    private def plan_other_streams
      input.other_streams.each do |stream|
        @stream_plans << StreamPlan.new(
          stream: stream,
          action: StreamAction::Copy,
          encoder: "copy",
          reason: "passthrough",
          output_codec_display: CodecSupport.codec_display_name(stream.codec_name),
        )
      end
    end

    private def default_quality_args(encoder : String) : Array(String)
      case encoder
      when "libx264"  then ["-crf", "18", "-preset", "medium"]
      when "libx265"  then ["-crf", "20", "-preset", "medium"]
      when "libvpx-vp9" then ["-crf", "24", "-b:v", "0"]
      when "libsvtav1" then ["-crf", "23", "-preset", "6"]
      else                  [] of String
      end
    end

    private def default_audio_args(encoder : String) : Array(String)
      case encoder
      when "aac"        then ["-b:a", "320k"]
      when "libmp3lame" then ["-b:a", "320k"]
      when "libopus"    then ["-b:a", "256k"]
      when "libvorbis"  then ["-b:a", "256k"]
      when "flac"       then [] of String
      else                   [] of String
      end
    end
  end
end
