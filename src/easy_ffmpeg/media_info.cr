require "json"

module EasyFfmpeg
  struct StreamInfo
    getter index : Int32
    getter codec_name : String
    getter codec_long_name : String
    getter codec_type : String
    getter width : Int32?
    getter height : Int32?
    getter frame_rate : Float64?
    getter bit_rate : Int64?
    getter channels : Int32?
    getter channel_layout : String?
    getter sample_rate : Int32?
    getter profile : String?
    getter pix_fmt : String?
    getter language : String?
    getter title : String?
    getter is_default : Bool
    getter is_attached_pic : Bool

    def initialize(
      @index, @codec_name, @codec_long_name, @codec_type,
      @width = nil, @height = nil, @frame_rate = nil,
      @bit_rate = nil, @channels = nil, @channel_layout = nil,
      @sample_rate = nil, @profile = nil, @pix_fmt = nil,
      @language = nil, @title = nil, @is_default = false,
      @is_attached_pic = false
    )
    end

    def video? : Bool
      codec_type == "video" && !is_attached_pic
    end

    def audio? : Bool
      codec_type == "audio"
    end

    def subtitle? : Bool
      codec_type == "subtitle"
    end

    def channel_description : String
      case channels
      when 1 then "Mono"
      when 2 then "Stereo"
      when 6 then "5.1"
      when 8 then "7.1"
      else
        channels ? "#{channels}ch" : "?"
      end
    end

    def language_display : String
      lang = language
      return "" unless lang && lang != "und"
      lang.size == 3 ? LANGUAGE_NAMES[lang]? || lang.capitalize : lang.capitalize
    end

    def frame_rate_display : String
      fps = frame_rate
      return "?" unless fps && fps > 0
      if (fps - fps.round).abs < 0.01
        "#{fps.round.to_i}fps"
      else
        "#{"%.3f" % fps}fps"
      end
    end

    def resolution_display : String
      w = width
      h = height
      return "?" unless w && h
      "#{w}x#{h}"
    end

    def bit_rate_display : String
      br = bit_rate
      return "" unless br && br > 0
      if br >= 1_000_000
        "#{"%.1f" % (br / 1_000_000.0)}Mbps"
      else
        "#{br // 1000}kbps"
      end
    end
  end

  struct FormatInfo
    getter filename : String
    getter format_name : String
    getter format_long_name : String
    getter duration : Float64
    getter size : Int64
    getter bit_rate : Int64

    def initialize(@filename, @format_name, @format_long_name, @duration, @size, @bit_rate)
    end

    def duration_display : String
      EasyFfmpeg.format_duration(duration)
    end

    def size_display : String
      EasyFfmpeg.format_file_size(size)
    end
  end

  class MediaInfo
    getter video_streams : Array(StreamInfo)
    getter audio_streams : Array(StreamInfo)
    getter subtitle_streams : Array(StreamInfo)
    getter other_streams : Array(StreamInfo)
    getter format : FormatInfo
    getter path : String

    def initialize(@path, @video_streams, @audio_streams, @subtitle_streams, @other_streams, @format)
    end

    def self.probe(path : String) : MediaInfo
      output = IO::Memory.new
      error = IO::Memory.new

      status = Process.run(
        "ffprobe",
        args: ["-v", "quiet", "-print_format", "json", "-show_streams", "-show_format", path],
        output: output,
        error: error,
      )

      unless status.success?
        raise "ffprobe failed: #{error.to_s.strip}"
      end

      json = JSON.parse(output.to_s)
      parse_probe_output(path, json)
    end

    private def self.parse_probe_output(path : String, json : JSON::Any) : MediaInfo
      video_streams = [] of StreamInfo
      audio_streams = [] of StreamInfo
      subtitle_streams = [] of StreamInfo
      other_streams = [] of StreamInfo

      if streams = json["streams"]?
        streams.as_a.each do |s|
          info = parse_stream(s)
          case info.codec_type
          when "video"
            if info.is_attached_pic
              other_streams << info
            else
              video_streams << info
            end
          when "audio"
            audio_streams << info
          when "subtitle"
            subtitle_streams << info
          else
            other_streams << info
          end
        end
      end

      fmt = json["format"]
      format = FormatInfo.new(
        filename: fmt["filename"]?.try(&.as_s) || path,
        format_name: fmt["format_name"]?.try(&.as_s) || "unknown",
        format_long_name: fmt["format_long_name"]?.try(&.as_s) || "Unknown",
        duration: fmt["duration"]?.try(&.as_s.to_f64) || 0.0,
        size: fmt["size"]?.try(&.as_s.to_i64) || 0_i64,
        bit_rate: fmt["bit_rate"]?.try(&.as_s.to_i64) || 0_i64,
      )

      new(path, video_streams, audio_streams, subtitle_streams, other_streams, format)
    end

    private def self.parse_stream(s : JSON::Any) : StreamInfo
      tags = s["tags"]?
      disposition = s["disposition"]?

      StreamInfo.new(
        index: s["index"].as_i,
        codec_name: s["codec_name"]?.try(&.as_s) || "unknown",
        codec_long_name: s["codec_long_name"]?.try(&.as_s) || "Unknown",
        codec_type: s["codec_type"]?.try(&.as_s) || "unknown",
        width: s["width"]?.try(&.as_i),
        height: s["height"]?.try(&.as_i),
        frame_rate: parse_frame_rate(s["r_frame_rate"]?.try(&.as_s)),
        bit_rate: s["bit_rate"]?.try(&.as_s.to_i64?) || parse_tag_bit_rate(s),
        channels: s["channels"]?.try(&.as_i),
        channel_layout: s["channel_layout"]?.try(&.as_s),
        sample_rate: s["sample_rate"]?.try(&.as_s.to_i?),
        profile: s["profile"]?.try(&.as_s),
        pix_fmt: s["pix_fmt"]?.try(&.as_s),
        language: tags.try(&.["language"]?.try(&.as_s)),
        title: tags.try(&.["title"]?.try(&.as_s)),
        is_default: (disposition.try { |d| d["default"]?.try(&.as_i) == 1 }) || false,
        is_attached_pic: (disposition.try { |d| d["attached_pic"]?.try(&.as_i) == 1 }) || false,
      )
    end

    private def self.parse_frame_rate(rate : String?) : Float64?
      return nil unless rate
      parts = rate.split("/")
      if parts.size == 2
        num = parts[0].to_f64?
        den = parts[1].to_f64?
        if num && den && den > 0
          return num / den
        end
      end
      rate.to_f64?
    end

    private def self.parse_tag_bit_rate(s : JSON::Any) : Int64?
      s["tags"]?.try(&.["BPS"]?.try(&.as_s.to_i64?)) ||
        s["tags"]?.try(&.["BPS-eng"]?.try(&.as_s.to_i64?))
    end
  end

  # Shared helpers

  LANGUAGE_NAMES = {
    "eng" => "English", "spa" => "Spanish", "fre" => "French", "fra" => "French",
    "deu" => "German", "ger" => "German", "ita" => "Italian", "por" => "Portuguese",
    "rus" => "Russian", "jpn" => "Japanese", "kor" => "Korean", "chi" => "Chinese",
    "zho" => "Chinese", "ara" => "Arabic", "hin" => "Hindi", "tur" => "Turkish",
    "pol" => "Polish", "nld" => "Dutch", "dut" => "Dutch", "swe" => "Swedish",
    "nor" => "Norwegian", "dan" => "Danish", "fin" => "Finnish", "cze" => "Czech",
    "ces" => "Czech", "hun" => "Hungarian", "rum" => "Romanian", "ron" => "Romanian",
    "bul" => "Bulgarian", "hrv" => "Croatian", "slv" => "Slovenian", "srp" => "Serbian",
    "ukr" => "Ukrainian", "vie" => "Vietnamese", "tha" => "Thai", "ind" => "Indonesian",
    "may" => "Malay", "msa" => "Malay", "heb" => "Hebrew", "gre" => "Greek",
    "ell" => "Greek", "cat" => "Catalan", "und" => "Undefined",
  }

  def self.format_duration(seconds : Float64) : String
    return "0s" if seconds <= 0
    total = seconds.to_i
    h = total // 3600
    m = (total % 3600) // 60
    s = total % 60
    if h > 0
      "%dh%02dm%02ds" % {h, m, s}
    elsif m > 0
      "%dm%02ds" % {m, s}
    else
      "%ds" % s
    end
  end

  def self.format_file_size(bytes : Int64) : String
    if bytes >= 1_073_741_824 # 1 GB
      "%.1f GB" % (bytes / 1_073_741_824.0)
    elsif bytes >= 1_048_576 # 1 MB
      "%.1f MB" % (bytes / 1_048_576.0)
    elsif bytes >= 1024
      "%.1f KB" % (bytes / 1024.0)
    else
      "#{bytes} B"
    end
  end

  def self.format_duration_timestamp(seconds : Float64) : String
    return "0:00:00" if seconds <= 0
    total = seconds.to_i
    h = total // 3600
    m = (total % 3600) // 60
    s = total % 60
    "%d:%02d:%02d" % {h, m, s}
  end

  # Parses user-provided time strings into seconds.
  # Supported formats:
  #   90        → 90.0 (plain seconds)
  #   1:31      → 91.0 (mm:ss)
  #   1:31.500  → 91.5 (mm:ss.ms)
  #   1:02:30   → 3750.0 (hh:mm:ss)
  #   1:02:30.5 → 3750.5 (hh:mm:ss.ms)
  def self.parse_time(input : String) : Float64?
    input = input.strip
    return nil if input.empty?

    parts = input.split(":")
    case parts.size
    when 1
      # Plain seconds: "90" or "90.5"
      parts[0].to_f64?
    when 2
      # mm:ss or mm:ss.xxx
      mm = parts[0].to_i64?
      ss = parts[1].to_f64?
      return nil unless mm && ss
      mm * 60.0 + ss
    when 3
      # hh:mm:ss or hh:mm:ss.xxx
      hh = parts[0].to_i64?
      mm = parts[1].to_i64?
      ss = parts[2].to_f64?
      return nil unless hh && mm && ss
      hh * 3600.0 + mm * 60.0 + ss
    else
      nil
    end
  end
end
