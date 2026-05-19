require "../spec_helper"
require "file_utils"

# End-to-end integration test for the --gpu flag.
#
# Runs the compiled bin/easy-ffmpeg binary against a generated test clip and
# verifies that:
#   - the wrapper passes -hwaccel cuda to ffmpeg (decode side)
#   - the wrapper picks an NVENC encoder (encode side)
#   - the resulting file is actually encoded with HEVC
#
# Skipped (pending!) when the local ffmpeg build was compiled without NVENC.
# Requires an NVIDIA GPU reachable at runtime; if NVENC is present in the
# binary but no GPU is available the test will fail loudly — that mismatch is
# itself a signal worth surfacing in CI.

private PROJECT_ROOT  = File.expand_path("../..", __DIR__)
private BIN_PATH      = File.join(PROJECT_ROOT, "bin", "easy-ffmpeg")
private CLI_SOURCE    = File.join(PROJECT_ROOT, "src", "easy_ffmpeg_cli.cr")

private def ensure_binary_built
  return if File.exists?(BIN_PATH) && File.info(BIN_PATH).modification_time >= newest_source_mtime
  FileUtils.mkdir_p(File.dirname(BIN_PATH))
  status = Process.run(
    "crystal",
    args: ["build", CLI_SOURCE, "-o", BIN_PATH],
    output: Process::Redirect::Inherit,
    error: Process::Redirect::Inherit,
  )
  raise "failed to build #{BIN_PATH}" unless status.success?
end

private def newest_source_mtime : Time
  newest = Time.unix(0)
  Dir.glob(File.join(PROJECT_ROOT, "src", "**", "*.cr")).each do |f|
    mt = File.info(f).modification_time
    newest = mt if mt > newest
  end
  newest
end

private def generate_test_clip(path : String, codec : String = "libx264")
  status = Process.run(
    "ffmpeg",
    args: [
      "-hide_banner", "-v", "error", "-y",
      "-f", "lavfi", "-i", "testsrc=duration=2:size=640x360:rate=30",
      "-c:v", codec, "-preset", "ultrafast",
      path,
    ],
    output: Process::Redirect::Close,
    error: Process::Redirect::Inherit,
  )
  raise "failed to generate test clip at #{path}" unless status.success?
end

private def generate_hdr_clip(path : String)
  status = Process.run(
    "ffmpeg",
    args: [
      "-hide_banner", "-v", "error", "-y",
      "-f", "lavfi", "-i", "testsrc=duration=1:size=640x360:rate=30",
      "-pix_fmt", "yuv420p10le",
      "-color_primaries", "bt2020",
      "-color_trc", "smpte2084",
      "-colorspace", "bt2020nc",
      "-color_range", "tv",
      "-c:v", "libx265",
      "-x265-params", "colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:hdr10=1:range=limited",
      "-preset", "ultrafast",
      path,
    ],
    output: Process::Redirect::Close,
    error: Process::Redirect::Close,
  )
  raise "failed to generate HDR test clip at #{path}" unless status.success?
end

private def generate_interlaced_clip(path : String)
  status = Process.run(
    "ffmpeg",
    args: [
      "-hide_banner", "-v", "error", "-y",
      "-f", "lavfi", "-i", "testsrc=duration=2:size=640x480:rate=30",
      "-pix_fmt", "yuv420p",
      "-vf", "tinterlace=mode=interleave_top",
      "-flags", "+ildct+ilme", "-top", "1",
      "-c:v", "libx264", "-preset", "ultrafast",
      path,
    ],
    output: Process::Redirect::Close,
    error: Process::Redirect::Close,
  )
  raise "failed to generate interlaced test clip at #{path}" unless status.success?
end

private def probe_stream_field(path : String, field : String) : String
  output = IO::Memory.new
  status = Process.run(
    "ffprobe",
    args: [
      "-v", "error", "-select_streams", "v:0",
      "-show_entries", "stream=#{field}",
      "-of", "default=noprint_wrappers=1:nokey=1",
      path,
    ],
    output: output,
    error: Process::Redirect::Inherit,
  )
  raise "ffprobe failed for #{path}" unless status.success?
  output.to_s.strip
end

private def with_tmpdir(&)
  path = File.join(Dir.tempdir, "easy-ffmpeg-gpu-int-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(path)
  begin
    yield path
  ensure
    FileUtils.rm_rf(path)
  end
end

private def probe_video_codec(path : String) : String
  output = IO::Memory.new
  status = Process.run(
    "ffprobe",
    args: [
      "-v", "error", "-select_streams", "v:0",
      "-show_entries", "stream=codec_name",
      "-of", "default=noprint_wrappers=1:nokey=1",
      path,
    ],
    output: output,
    error: Process::Redirect::Inherit,
  )
  raise "ffprobe failed for #{path}" unless status.success?
  output.to_s.strip
end

describe "easy-ffmpeg --gpu (integration)" do
  it "uses NVENC + -hwaccel cuda and produces an HEVC file" do
    pending! "ffmpeg has no NVENC encoders" unless EasyFfmpeg::GpuSupport.any_available?

    ensure_binary_built

    with_tmpdir do |tmp|
      input  = File.join(tmp, "source.mp4")
      output = File.join(tmp, "out.mp4")
      generate_test_clip(input)

      # --dry-run prints the exact ffmpeg command — assert hwaccel & encoder
      # are wired correctly without paying for a second encode.
      dry_out = IO::Memory.new
      dry_status = Process.run(
        BIN_PATH,
        args: [input, "mp4", "--compress", "--gpu", "--dry-run", "-o", output],
        output: dry_out,
        error: Process::Redirect::Inherit,
      )
      dry_status.success?.should be_true

      dry_text = dry_out.to_s
      dry_text.should match(/-hwaccel\s+cuda/)
      dry_text.should match(/hevc_nvenc/)

      # Real encode
      run_status = Process.run(
        BIN_PATH,
        args: [input, "mp4", "--compress", "--gpu", "--force", "-o", output],
        output: Process::Redirect::Close,
        error: Process::Redirect::Inherit,
      )
      run_status.success?.should be_true
      File.exists?(output).should be_true
      File.size(output).should be > 0

      probe_video_codec(output).should eq("hevc")
    end
  end

  it "uses h264_nvenc with the --web preset" do
    pending! "ffmpeg has no NVENC encoders" unless EasyFfmpeg::GpuSupport.any_available?

    ensure_binary_built

    with_tmpdir do |tmp|
      input  = File.join(tmp, "source.mp4")
      output = File.join(tmp, "out.mp4")
      generate_test_clip(input)

      run_status = Process.run(
        BIN_PATH,
        args: [input, "mp4", "--web", "--gpu", "--force", "-o", output],
        output: Process::Redirect::Close,
        error: Process::Redirect::Inherit,
      )
      run_status.success?.should be_true
      probe_video_codec(output).should eq("h264")
    end
  end

  it "engages a pure GPU pipeline (-hwaccel_output_format cuda) when no aspect is set" do
    pending! "ffmpeg has no NVENC encoders" unless EasyFfmpeg::GpuSupport.any_available?

    ensure_binary_built

    with_tmpdir do |tmp|
      input  = File.join(tmp, "source.mp4")
      output = File.join(tmp, "out.mp4")
      generate_test_clip(input)

      dry_out = IO::Memory.new
      dry_status = Process.run(
        BIN_PATH,
        args: [input, "mp4", "--compress", "--gpu", "--dry-run", "-o", output],
        output: dry_out,
        error: Process::Redirect::Inherit,
      )
      dry_status.success?.should be_true

      dry_text = dry_out.to_s
      dry_text.should match(/-hwaccel\s+cuda/)
      dry_text.should match(/-hwaccel_output_format\s+cuda/)
      # No CPU-side format conversion in the filter chain
      dry_text.should_not match(/format=yuv420p/)

      # Real encode keeps the pipeline on the GPU end-to-end
      run_status = Process.run(
        BIN_PATH,
        args: [input, "mp4", "--compress", "--gpu", "--force", "-o", output],
        output: Process::Redirect::Close,
        error: Process::Redirect::Inherit,
      )
      run_status.success?.should be_true
      probe_video_codec(output).should eq("hevc")
    end
  end

  it "preserves HDR (10-bit + BT.2020/PQ) when transcoding through hevc_nvenc" do
    pending! "ffmpeg has no NVENC encoders" unless EasyFfmpeg::GpuSupport.any_available?

    ensure_binary_built

    with_tmpdir do |tmp|
      input  = File.join(tmp, "hdr.mp4")
      output = File.join(tmp, "out.mp4")
      generate_hdr_clip(input)

      # Sanity check: source really is HDR
      probe_stream_field(input, "color_transfer").should eq("smpte2084")

      dry_out = IO::Memory.new
      dry_status = Process.run(
        BIN_PATH,
        args: [input, "mp4", "--compress", "--gpu", "--dry-run", "-o", output],
        output: dry_out,
        error: Process::Redirect::Inherit,
      )
      dry_status.success?.should be_true

      dry_text = dry_out.to_s
      dry_text.should match(/-color_primaries\s+bt2020/)
      dry_text.should match(/-color_trc\s+smpte2084/)
      dry_text.should match(/-colorspace\s+bt2020nc/)

      run_status = Process.run(
        BIN_PATH,
        args: [input, "mp4", "--compress", "--gpu", "--force", "-o", output],
        output: Process::Redirect::Close,
        error: Process::Redirect::Inherit,
      )
      run_status.success?.should be_true

      probe_video_codec(output).should eq("hevc")
      probe_stream_field(output, "pix_fmt").should eq("yuv420p10le")
      probe_stream_field(output, "color_transfer").should eq("smpte2084")
      probe_stream_field(output, "color_primaries").should eq("bt2020")
    end
  end

  it "auto-deinterlaces an interlaced source" do
    pending! "ffmpeg has no NVENC encoders" unless EasyFfmpeg::GpuSupport.any_available?

    ensure_binary_built

    with_tmpdir do |tmp|
      input  = File.join(tmp, "interlaced.mp4")
      output = File.join(tmp, "out.mp4")
      generate_interlaced_clip(input)

      # Sanity check: source really is interlaced
      probe_stream_field(input, "field_order").should eq("tt")

      dry_out = IO::Memory.new
      dry_status = Process.run(
        BIN_PATH,
        args: [input, "mp4", "--compress", "--gpu", "--dry-run", "-o", output],
        output: dry_out,
        error: Process::Redirect::Inherit,
      )
      dry_status.success?.should be_true

      dry_text = dry_out.to_s
      # Pure GPU pipeline rewrites yadif to yadif_cuda
      dry_text.should match(/yadif_cuda/)

      run_status = Process.run(
        BIN_PATH,
        args: [input, "mp4", "--compress", "--gpu", "--force", "-o", output],
        output: Process::Redirect::Close,
        error: Process::Redirect::Inherit,
      )
      run_status.success?.should be_true
      probe_video_codec(output).should eq("hevc")
      # The deinterlace filter should produce a progressive output
      probe_stream_field(output, "field_order").should_not eq("tt")
    end
  end

  it "uses NVENC quality-tuning args (rc-lookahead, spatial-aq, temporal-aq)" do
    pending! "ffmpeg has no NVENC encoders" unless EasyFfmpeg::GpuSupport.any_available?

    ensure_binary_built

    with_tmpdir do |tmp|
      input  = File.join(tmp, "source.mp4")
      output = File.join(tmp, "out.mp4")
      generate_test_clip(input)

      dry_out = IO::Memory.new
      dry_status = Process.run(
        BIN_PATH,
        args: [input, "mp4", "--compress", "--gpu", "--dry-run", "-o", output],
        output: dry_out,
        error: Process::Redirect::Inherit,
      )
      dry_status.success?.should be_true

      dry_text = dry_out.to_s
      dry_text.should match(/-rc-lookahead\s+20/)
      dry_text.should match(/-spatial-aq\s+1/)
      dry_text.should match(/-temporal-aq\s+1/)
      dry_text.should match(/-bf\s+3/)
      dry_text.should match(/-b_ref_mode\s+middle/)
    end
  end

  it "falls back to mixed CPU/GPU pipeline when --aspect is used" do
    pending! "ffmpeg has no NVENC encoders" unless EasyFfmpeg::GpuSupport.any_available?

    ensure_binary_built

    with_tmpdir do |tmp|
      input  = File.join(tmp, "source.mp4")
      output = File.join(tmp, "out.mp4")
      generate_test_clip(input)

      dry_out = IO::Memory.new
      dry_status = Process.run(
        BIN_PATH,
        args: [input, "mp4", "--compress", "--gpu", "--aspect", "wide",
               "--dry-run", "-o", output],
        output: dry_out,
        error: Process::Redirect::Inherit,
      )
      dry_status.success?.should be_true

      dry_text = dry_out.to_s
      dry_text.should match(/-hwaccel\s+cuda/)
      # Aspect filters force CPU memory; pure GPU pipeline must be disabled
      dry_text.should_not match(/-hwaccel_output_format\s+cuda/)
      dry_text.should match(/pad=/)

      run_status = Process.run(
        BIN_PATH,
        args: [input, "mp4", "--compress", "--gpu", "--aspect", "wide",
               "--force", "-o", output],
        output: Process::Redirect::Close,
        error: Process::Redirect::Inherit,
      )
      run_status.success?.should be_true
      probe_video_codec(output).should eq("hevc")
    end
  end

  it "--gpu-quality fast: dry-run shows preset p2 and no quality tuning" do
    pending! "ffmpeg has no NVENC encoders" unless EasyFfmpeg::GpuSupport.any_available?
    ensure_binary_built

    with_tmpdir do |tmp|
      input  = File.join(tmp, "source.mp4")
      output = File.join(tmp, "out.mp4")
      generate_test_clip(input)

      dry_out = IO::Memory.new
      dry_status = Process.run(
        BIN_PATH,
        args: [input, "mp4", "--compress", "--gpu", "--gpu-quality", "fast",
               "--dry-run", "-o", output],
        output: dry_out,
        error: Process::Redirect::Inherit,
      )
      dry_status.success?.should be_true

      dry_text = dry_out.to_s
      dry_text.should match(/-preset\s+p2/)
      dry_text.should_not match(/-rc-lookahead/)
      dry_text.should_not match(/-spatial-aq/)
    end
  end

  it "--gpu-quality smaller: dry-run shows preset p7, CQ + 5, lookahead 32" do
    pending! "ffmpeg has no NVENC encoders" unless EasyFfmpeg::GpuSupport.any_available?
    ensure_binary_built

    with_tmpdir do |tmp|
      input  = File.join(tmp, "source.mp4")
      output = File.join(tmp, "out.mp4")
      generate_test_clip(input)

      dry_out = IO::Memory.new
      dry_status = Process.run(
        BIN_PATH,
        args: [input, "mp4", "--compress", "--gpu", "--gpu-quality", "smaller",
               "--dry-run", "-o", output],
        output: dry_out,
        error: Process::Redirect::Inherit,
      )
      dry_status.success?.should be_true

      dry_text = dry_out.to_s
      dry_text.should match(/-preset\s+p7/)
      dry_text.should match(/-cq\s+33/) # compress preset = -crf 28, +5
      dry_text.should match(/-rc-lookahead\s+32/)
      dry_text.should match(/-bf\s+4/)
    end
  end

  it "--gpu-quality smaller actually produces a smaller file than balanced" do
    pending! "ffmpeg has no NVENC encoders" unless EasyFfmpeg::GpuSupport.any_available?
    ensure_binary_built

    with_tmpdir do |tmp|
      input    = File.join(tmp, "source.mp4")
      balanced = File.join(tmp, "balanced.mp4")
      smaller  = File.join(tmp, "smaller.mp4")
      # Longer clip than the other specs so the per-frame compression gap shows up.
      generate_test_clip(input)

      Process.run(BIN_PATH,
        args: [input, "mp4", "--compress", "--gpu", "--force", "-o", balanced],
        output: Process::Redirect::Close, error: Process::Redirect::Inherit,
      ).success?.should be_true

      Process.run(BIN_PATH,
        args: [input, "mp4", "--compress", "--gpu", "--gpu-quality", "smaller",
               "--force", "-o", smaller],
        output: Process::Redirect::Close, error: Process::Redirect::Inherit,
      ).success?.should be_true

      File.size(smaller).should be < File.size(balanced)
    end
  end

  it "--gpu-quality without --gpu errors out" do
    ensure_binary_built

    with_tmpdir do |tmp|
      input = File.join(tmp, "source.mp4")
      generate_test_clip(input)

      err = IO::Memory.new
      status = Process.run(
        BIN_PATH,
        args: [input, "mp4", "--gpu-quality", "smaller", "-o", File.join(tmp, "x.mp4")],
        output: Process::Redirect::Close,
        error: err,
      )
      status.success?.should be_false
      err.to_s.should match(/--gpu-quality requires --gpu/)
    end
  end

  it "--gpu-quality with invalid value errors out" do
    ensure_binary_built

    with_tmpdir do |tmp|
      input = File.join(tmp, "source.mp4")
      generate_test_clip(input)

      err = IO::Memory.new
      status = Process.run(
        BIN_PATH,
        args: [input, "mp4", "--gpu", "--gpu-quality", "bogus", "-o", File.join(tmp, "x.mp4")],
        output: Process::Redirect::Close,
        error: err,
      )
      status.success?.should be_false
      err.to_s.should match(/invalid --gpu-quality/)
    end
  end
end
