require "./spec_helper"

# A program reading a real Windows console, through a pseudoconsole this
# spec plays the terminal for. What it checks is what the unit specs cannot:
# that raw mode, the console reader and the resize records work against the
# console Windows Terminal and WezTerm host programs in.
{% skip_file unless flag?(:win32) %}

require "file_utils"
require "./support/conpty"

private module Target
  # Built once, the first time it is wanted. The compile takes a while.
  def self.path : Path
    @@path ||= build
  end

  @@path : Path? = nil

  private def self.build : Path
    root = Path[__DIR__].parent
    directory = Path[File.tempname "termbuf-input-conpty", nil]
    Dir.mkdir_p directory
    at_exit { FileUtils.rm_rf directory.to_s }

    built = directory / "conpty_target.exe"
    said = IO::Memory.new
    status = Process.run "crystal", ["build", "--no-debug", "-o", built.to_s, "spec/support/conpty_target.cr"],
      output: said, error: said, chdir: root.to_s
    raise "building the conpty target failed:\n#{said}" unless status.success?

    built
  end
end

# A console running the target, and the log it writes.
private class Session
  getter console : PseudoConsole
  getter log : Path

  def initialize(columns = 80, rows = 24)
    @log = Target.path.parent / "log-#{Random.rand UInt32}.txt"
    @console = PseudoConsole.new Target.path.to_s, [@log.to_s], columns, rows
  end

  def lines : Array(String)
    File.exists?(@log) ? File.read_lines(@log) : [] of String
  end

  # Waits up to *timeout* for a log line equal to *line*.
  def wait_for(line : String, timeout : Time::Span = 10.seconds) : Bool
    deadline = Time.instant + timeout
    until Time.instant >= deadline
      return true if lines.includes? line
      sleep 20.milliseconds
    end
    false
  end

  def close : Nil
    @console.close
  end
end

private def with_session(columns = 80, rows = 24, &)
  session = Session.new columns, rows
  begin
    raise "the target never got ready: #{session.lines}" unless session.wait_for("ready")
    yield session
  ensure
    session.close
  end
end

Spectator.describe "a program in a Windows pseudoconsole" do
  it "has a console, and raw mode" do
    with_session do |session|
      expect(session.lines.first).to eq "console true, raw true"
    end
  end

  it "reads a letter" do
    with_session do |session|
      session.console.type "a"
      expect(session.wait_for("key a")).to be_true
    end
  end

  it "reads an arrow key as the escape sequence a terminal sends" do
    with_session do |session|
      session.console.type "\e[A"
      expect(session.wait_for("key Up")).to be_true
    end
  end

  it "reads a character outside the basic plane" do
    with_session do |session|
      session.console.type "😀"
      expect(session.wait_for("key 😀")).to be_true
    end
  end

  it "reads Ctrl+C as a key, since raw mode turns the interrupt off" do
    with_session do |session|
      session.console.type "\u0003"
      expect(session.wait_for("key Ctrl+C")).to be_true
    end
  end

  it "reports a resize with the new size" do
    with_session(80, 24) do |session|
      session.console.resize 100, 30
      expect(session.wait_for("resize 100x30")).to be_true
    end
  end

  it "reads a bracketed paste" do
    with_session do |session|
      session.console.type "\e[200~pasted text\e[201~"
      expect(session.wait_for(%(paste "pasted text"))).to be_true
    end
  end

  it "ends, putting the console back, on q" do
    with_session do |session|
      session.console.type "q"
      expect(session.console.wait(10.seconds)).to eq 0
      expect(session.lines.last).to eq "done"
    end
  end
end
