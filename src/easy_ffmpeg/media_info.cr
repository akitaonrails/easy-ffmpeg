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
    getter color_primaries : String?
    getter color_transfer : String?
    getter color_space : String?
    getter color_range : String?
    getter field_order : String?
    getter language : String?
    getter title : String?
    getter is_default : Bool
    getter is_attached_pic : Bool

    def initialize(
      @index, @codec_name, @codec_long_name, @codec_type,
      @width = nil, @height = nil, @frame_rate = nil,
      @bit_rate = nil, @channels = nil, @channel_layout = nil,
      @sample_rate = nil, @profile = nil, @pix_fmt = nil,
      @color_primaries = nil, @color_transfer = nil,
      @color_space = nil, @color_range = nil,
      @field_order = nil,
      @language = nil, @title = nil, @is_default = false,
      @is_attached_pic = false
    )
    end

    # True when the stream carries HDR transfer metadata that we want to
    # preserve through transcode (HDR10 / HDR10+ via PQ, or HLG).
    def hdr? : Bool
      ct = color_transfer
      return false unless ct
      ct == "smpte2084" || ct == "arib-std-b67"
    end

    # True when ffprobe reports an interlaced field order. Anything other
    # than "progressive" (or missing entirely) means we'd benefit from a
    # deinterlace filter before encoding.
    def interlaced? : Bool
      fo = field_order
      return false unless fo
      fo != "progressive" && fo != "unknown"
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

      status = begin
        Process.run(
          "ffprobe",
          args: ["-v", "quiet", "-print_format", "json", "-show_streams", "-show_format", path],
          output: output,
          error: error,
        )
      rescue ex : File::Error
        raise "failed to start ffprobe: #{ex.message}"
      end

      unless status.success?
        raise "ffprobe failed: #{error.to_s.strip}"
      end

      from_probe_json(path, output.to_s)
    end

    def self.from_probe_json(path : String, json_text : String) : MediaInfo
      json = begin
        JSON.parse(json_text)
      rescue ex : JSON::ParseException
        raise "ffprobe returned invalid JSON: #{ex.message}"
      end

      parse_probe_output(path, json)
    end

    private def self.parse_probe_output(path : String, json : JSON::Any) : MediaInfo
      video_streams = [] of StreamInfo
      audio_streams = [] of StreamInfo
      subtitle_streams = [] of StreamInfo
      other_streams = [] of StreamInfo

      if streams = json["streams"]?.try(&.as_a?)
        streams.each do |s|
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

      fmt = json["format"]?
      format = FormatInfo.new(
        filename: json_string(fmt.try(&.["filename"]?)) || path,
        format_name: json_string(fmt.try(&.["format_name"]?)) || "unknown",
        format_long_name: json_string(fmt.try(&.["format_long_name"]?)) || "Unknown",
        duration: json_float(fmt.try(&.["duration"]?)) || 0.0,
        size: json_int64(fmt.try(&.["size"]?)) || 0_i64,
        bit_rate: json_int64(fmt.try(&.["bit_rate"]?)) || 0_i64,
      )

      new(path, video_streams, audio_streams, subtitle_streams, other_streams, format)
    end

    private def self.parse_stream(s : JSON::Any) : StreamInfo
      tags = s["tags"]?
      disposition = s["disposition"]?

      StreamInfo.new(
        index: json_int(s["index"]?) || 0,
        codec_name: json_string(s["codec_name"]?) || "unknown",
        codec_long_name: json_string(s["codec_long_name"]?) || "Unknown",
        codec_type: json_string(s["codec_type"]?) || "unknown",
        width: json_int(s["width"]?),
        height: json_int(s["height"]?),
        frame_rate: parse_frame_rate(json_string(s["r_frame_rate"]?)),
        bit_rate: json_int64(s["bit_rate"]?) || parse_tag_bit_rate(s),
        channels: json_int(s["channels"]?),
        channel_layout: json_string(s["channel_layout"]?),
        sample_rate: json_int(s["sample_rate"]?),
        profile: json_string(s["profile"]?),
        pix_fmt: json_string(s["pix_fmt"]?),
        color_primaries: json_string(s["color_primaries"]?),
        color_transfer: json_string(s["color_transfer"]?),
        color_space: json_string(s["color_space"]?),
        color_range: json_string(s["color_range"]?),
        field_order: json_string(s["field_order"]?),
        language: json_string(tags.try(&.["language"]?)),
        title: json_string(tags.try(&.["title"]?)),
        is_default: (json_int(disposition.try(&.["default"]?)) == 1),
        is_attached_pic: (json_int(disposition.try(&.["attached_pic"]?)) == 1),
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
      json_int64(s["tags"]?.try(&.["BPS"]?)) ||
        json_int64(s["tags"]?.try(&.["BPS-eng"]?))
    end

    private def self.json_string(value : JSON::Any?) : String?
      return nil unless value

      case raw = value.raw
      when String
        raw
      when Int32, Int64, Float64
        raw.to_s
      else
        nil
      end
    end

    private def self.json_int(value : JSON::Any?) : Int32?
      return nil unless value

      case raw = value.raw
      when Int32
        raw
      when Int64
        return nil if raw > Int32::MAX.to_i64 || raw < Int32::MIN.to_i64
        raw.to_i
      when Float64
        raw.finite? ? raw.to_i : nil
      when String
        raw.to_i?
      else
        nil
      end
    end

    private def self.json_int64(value : JSON::Any?) : Int64?
      return nil unless value

      case raw = value.raw
      when Int32
        raw.to_i64
      when Int64
        raw
      when Float64
        raw.finite? ? raw.to_i64 : nil
      when String
        raw.to_i64?
      else
        nil
      end
    end

    private def self.json_float(value : JSON::Any?) : Float64?
      return nil unless value

      case raw = value.raw
      when Float64
        raw
      when Int32
        raw.to_f64
      when Int64
        raw.to_f64
      when String
        raw.to_f64?
      else
        nil
      end
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
      seconds = parts[0].to_f64?
      seconds && seconds >= 0 ? seconds : nil
    when 2
      # mm:ss or mm:ss.xxx
      mm = parts[0].to_i64?
      ss = parts[1].to_f64?
      return nil unless mm && ss
      return nil if mm < 0 || ss < 0 || ss >= 60
      mm * 60.0 + ss
    when 3
      # hh:mm:ss or hh:mm:ss.xxx
      hh = parts[0].to_i64?
      mm = parts[1].to_i64?
      ss = parts[2].to_f64?
      return nil unless hh && mm && ss
      return nil if hh < 0 || mm < 0 || mm >= 60 || ss < 0 || ss >= 60
      hh * 3600.0 + mm * 60.0 + ss
    else
      nil
    end
  end
end
