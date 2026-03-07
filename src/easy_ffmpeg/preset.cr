module EasyFfmpeg
  enum Preset
    Default
    Web
    Mobile
    Streaming
    Compress
  end

  struct PresetConfig
    getter video_codec : String?
    getter video_args : Array(String)
    getter audio_codec : String?
    getter audio_args : Array(String)
    getter max_height : Int32?
    getter downmix_stereo : Bool
    getter drop_subs : Bool
    getter faststart : Bool
    getter force_transcode : Bool

    def initialize(
      @video_codec = nil,
      @video_args = [] of String,
      @audio_codec = nil,
      @audio_args = [] of String,
      @max_height = nil,
      @downmix_stereo = false,
      @drop_subs = false,
      @faststart = false,
      @force_transcode = false
    )
    end

    def self.for(preset : Preset, format : String) : PresetConfig
      case preset
      when .default?
        default_config(format)
      when .web?
        web_config(format)
      when .mobile?
        mobile_config(format)
      when .streaming?
        streaming_config(format)
      when .compress?
        compress_config(format)
      else
        default_config(format)
      end
    end

    def self.default_config(format : String) : PresetConfig
      new(faststart: format == "mp4" || format == "mov")
    end

    def self.web_config(format : String) : PresetConfig
      video_codec = format == "webm" ? "libvpx-vp9" : "libx264"
      audio_codec = format == "webm" ? "libopus" : "aac"

      video_args = if video_codec == "libx264"
                     ["-crf", "23", "-preset", "medium", "-profile:v", "high", "-level", "4.1"]
                   else
                     ["-crf", "32", "-b:v", "0"]
                   end

      audio_args = if audio_codec == "aac"
                     ["-b:a", "128k"]
                   else
                     ["-b:a", "128k"]
                   end

      new(
        video_codec: video_codec,
        video_args: video_args,
        audio_codec: audio_codec,
        audio_args: audio_args,
        downmix_stereo: true,
        drop_subs: true,
        faststart: format == "mp4" || format == "mov",
        force_transcode: true,
      )
    end

    def self.mobile_config(format : String) : PresetConfig
      video_codec = format == "webm" ? "libvpx-vp9" : "libx264"
      audio_codec = format == "webm" ? "libopus" : "aac"

      video_args = if video_codec == "libx264"
                     ["-crf", "26", "-preset", "medium", "-profile:v", "main", "-level", "3.1"]
                   else
                     ["-crf", "36", "-b:v", "0"]
                   end

      audio_args = if audio_codec == "aac"
                     ["-b:a", "96k"]
                   else
                     ["-b:a", "64k"]
                   end

      new(
        video_codec: video_codec,
        video_args: video_args,
        audio_codec: audio_codec,
        audio_args: audio_args,
        max_height: 720,
        downmix_stereo: true,
        drop_subs: true,
        faststart: format == "mp4" || format == "mov",
        force_transcode: true,
      )
    end

    def self.streaming_config(format : String) : PresetConfig
      video_codec = format == "webm" ? "libvpx-vp9" : "libx264"
      audio_codec = format == "webm" ? "libopus" : "aac"

      video_args = if video_codec == "libx264"
                     ["-crf", "22", "-preset", "medium", "-profile:v", "high", "-level", "4.1",
                      "-g", "48", "-keyint_min", "48"]
                   else
                     ["-crf", "32", "-b:v", "0", "-g", "48", "-keyint_min", "48"]
                   end

      audio_args = if audio_codec == "aac"
                     ["-b:a", "192k"]
                   else
                     ["-b:a", "128k"]
                   end

      new(
        video_codec: video_codec,
        video_args: video_args,
        audio_codec: audio_codec,
        audio_args: audio_args,
        downmix_stereo: false,
        drop_subs: false,
        faststart: format == "mp4" || format == "mov",
        force_transcode: true,
      )
    end

    def self.compress_config(format : String) : PresetConfig
      video_codec = if format == "webm"
                      "libvpx-vp9"
                    elsif format == "mp4" || format == "matroska" || format == "mov" || format == "mpegts"
                      "libx265"
                    else
                      "libx264"
                    end

      audio_codec = format == "webm" ? "libopus" : "aac"

      video_args = case video_codec
                   when "libx265"
                     ["-crf", "28", "-preset", "medium"]
                   when "libvpx-vp9"
                     ["-crf", "38", "-b:v", "0"]
                   else
                     ["-crf", "28", "-preset", "medium"]
                   end

      audio_args = if audio_codec == "aac"
                     ["-b:a", "128k"]
                   else
                     ["-b:a", "96k"]
                   end

      new(
        video_codec: video_codec,
        video_args: video_args,
        audio_codec: audio_codec,
        audio_args: audio_args,
        downmix_stereo: false,
        drop_subs: false,
        faststart: format == "mp4" || format == "mov",
        force_transcode: true,
      )
    end
  end
end
