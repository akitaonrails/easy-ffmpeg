module EasyFfmpeg
  module CodecSupport
    # Maps container format → codecs that can be muxed without re-encoding
    CONTAINER_VIDEO_CODECS = {
      "mp4"      => %w[h264 hevc mpeg4 mpeg2video av1],
      "matroska" => %w[h264 hevc vp8 vp9 av1 mpeg4 mpeg2video theora prores mpeg1video wmv3 msmpeg4v3 ffv1 rawvideo],
      "mov"      => %w[h264 hevc prores mpeg4 mjpeg dnxhd],
      "webm"     => %w[vp8 vp9 av1],
      "avi"      => %w[h264 mpeg4 msmpeg4v3 mjpeg mpeg2video mpeg1video wmv3 ffv1 rawvideo],
      "mpegts"   => %w[h264 hevc mpeg2video],
      "ogg"      => %w[theora],
      "flv"      => %w[h264 flv1],
    }

    CONTAINER_AUDIO_CODECS = {
      "mp4"      => %w[aac mp3 ac3 eac3 flac alac opus],
      "matroska" => %w[aac mp3 ac3 eac3 dts flac opus vorbis alac pcm_s16le pcm_s24le pcm_s32le truehd pcm_f32le wavpack],
      "mov"      => %w[aac mp3 ac3 eac3 alac pcm_s16le pcm_s24le pcm_s32le flac],
      "webm"     => %w[opus vorbis],
      "avi"      => %w[mp3 ac3 pcm_s16le pcm_s24le],
      "mpegts"   => %w[aac mp3 ac3 eac3 dts],
      "ogg"      => %w[vorbis opus flac],
      "flv"      => %w[aac mp3],
    }

    CONTAINER_SUB_CODECS = {
      "mp4"      => %w[mov_text],
      "matroska" => %w[subrip ass ssa srt webvtt hdmv_pgs_subtitle dvd_subtitle],
      "mov"      => %w[mov_text],
      "webm"     => %w[webvtt],
      "avi"      => [] of String,
      "mpegts"   => %w[dvb_subtitle],
      "ogg"      => [] of String,
      "flv"      => [] of String,
    }

    # Text-based subtitle codecs that can be converted between each other
    TEXT_SUB_CODECS = %w[subrip ass ssa srt mov_text webvtt text]

    # File extension → ffmpeg container format name
    EXT_TO_FORMAT = {
      ".mp4"  => "mp4",
      ".m4v"  => "mp4",
      ".mkv"  => "matroska",
      ".mka"  => "matroska",
      ".mov"  => "mov",
      ".webm" => "webm",
      ".avi"  => "avi",
      ".ts"   => "mpegts",
      ".mts"  => "mpegts",
      ".ogg"  => "ogg",
      ".ogv"  => "ogg",
      ".flv"  => "flv",
    }

    # Default target video codec per container (when source is incompatible)
    DEFAULT_VIDEO_CODEC = {
      "mp4"      => "libx264",
      "matroska" => "libx264",
      "mov"      => "libx264",
      "webm"     => "libvpx-vp9",
      "avi"      => "libx264",
      "mpegts"   => "libx264",
      "ogg"      => "libtheora",
      "flv"      => "libx264",
    }

    # Default target audio codec per container
    DEFAULT_AUDIO_CODEC = {
      "mp4"      => "aac",
      "matroska" => "aac",
      "mov"      => "aac",
      "webm"     => "libopus",
      "avi"      => "libmp3lame",
      "mpegts"   => "aac",
      "ogg"      => "libvorbis",
      "flv"      => "aac",
    }

    # Default target subtitle codec per container
    DEFAULT_SUB_CODEC = {
      "mp4"      => "mov_text",
      "matroska" => "subrip",
      "mov"      => "mov_text",
      "webm"     => "webvtt",
    }

    # Friendly codec display names
    CODEC_DISPLAY_NAMES = {
      "h264"                => "H.264/AVC",
      "hevc"                => "H.265/HEVC",
      "vp8"                 => "VP8",
      "vp9"                 => "VP9",
      "av1"                 => "AV1",
      "mpeg4"               => "MPEG-4",
      "mpeg2video"          => "MPEG-2",
      "mpeg1video"          => "MPEG-1",
      "theora"              => "Theora",
      "prores"              => "ProRes",
      "mjpeg"               => "MJPEG",
      "aac"                 => "AAC",
      "mp3"                 => "MP3",
      "ac3"                 => "AC3/Dolby Digital",
      "eac3"                => "E-AC3/Dolby Digital+",
      "dts"                 => "DTS",
      "flac"                => "FLAC",
      "opus"                => "Opus",
      "vorbis"              => "Vorbis",
      "alac"                => "ALAC",
      "truehd"              => "TrueHD",
      "pcm_s16le"           => "PCM 16-bit",
      "pcm_s24le"           => "PCM 24-bit",
      "pcm_s32le"           => "PCM 32-bit",
      "subrip"              => "SRT",
      "ass"                 => "ASS",
      "ssa"                 => "SSA",
      "mov_text"            => "MOV_TEXT",
      "hdmv_pgs_subtitle"   => "PGS",
      "dvd_subtitle"        => "VobSub",
      "webvtt"              => "WebVTT",
      "dvb_subtitle"        => "DVB",
      "libx264"             => "H.264/AVC",
      "libx265"             => "H.265/HEVC",
      "libvpx-vp9"          => "VP9",
      "libsvtav1"           => "AV1",
      "libopus"             => "Opus",
      "libvorbis"           => "Vorbis",
      "libmp3lame"          => "MP3",
      "libtheora"           => "Theora",
    }

    def self.format_for_ext(ext : String) : String?
      EXT_TO_FORMAT[ext.downcase]?
    end

    def self.video_compatible?(codec : String, format : String) : Bool
      CONTAINER_VIDEO_CODECS[format]?.try(&.includes?(codec)) || false
    end

    def self.audio_compatible?(codec : String, format : String) : Bool
      CONTAINER_AUDIO_CODECS[format]?.try(&.includes?(codec)) || false
    end

    def self.sub_compatible?(codec : String, format : String) : Bool
      CONTAINER_SUB_CODECS[format]?.try(&.includes?(codec)) || false
    end

    def self.text_sub?(codec : String) : Bool
      TEXT_SUB_CODECS.includes?(codec)
    end

    def self.codec_display_name(codec : String) : String
      CODEC_DISPLAY_NAMES[codec]? || codec.upcase
    end

    def self.supported_output_format?(ext : String) : Bool
      EXT_TO_FORMAT.has_key?(ext.downcase)
    end
  end
end
