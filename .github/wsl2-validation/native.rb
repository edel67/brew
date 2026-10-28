# typed: true
# frozen_string_literal: true

require "bundle"
require "bundle/extensions/winget"
require "json"
require "tmpdir"
require "bundle/dumper"
require "stringio"

winget = Homebrew::Bundle::Winget
root = Pathname(ARGV.fetch(0))
fixture = root/"fixture.exe"
winget.define_singleton_method(:package_manager_executable) { fixture }
results = []
configure = lambda do |text|
  (root/"config.txt").write(text)
  (root/"calls.txt").write("")
  winget.reset!
end
check = lambda do |name, &block|
  block.call
  results << name
  puts "PASS: #{name}"
end
failure = lambda do |&block|
  begin
    block.call
  rescue ErrorDuringExecution, RuntimeError, Errno::ENOENT => e
    next e
  end
  raise "Expected inventory failure"
end
check.call("two-source inventory, Unicode and WSL UNC exports") do
  configure.call("")
  apps = winget.apps
  raise apps.inspect unless apps.map { |app| [app.name, app.source] } == [["Example café", "winget"], ["Example café", "msstore"]]
  raise "Wrong calls" unless (root/"calls.txt").read.lines.size == 4
end
check.call("successful inventory is cached") do
  winget.apps
  raise "Repeated query" unless (root/"calls.txt").read.lines.size == 4
end
check.call("exact native no-apps status skips list and caches empty") do
  configure.call("export:winget=8A150014\nexport:msstore=8A150014\n")
  raise "Expected empty" unless winget.apps.empty? && winget.apps.empty?
  raise "Unexpected list or retry" unless (root/"calls.txt").read == "export:winget\nexport:msstore\n"
end
{
  "export low-byte collision" => "export:winget=DEAD0014\n",
  "list low-byte zero failure" => "list:winget=80070000\n",
  "list no-apps status is failure" => "list:winget=8A150014\n",
  "second source failure" => "export:msstore=80070000\n",
  "malformed successful export" => "mode=malformed\n",
  "missing successful export" => "mode=missing\n",
}.each do |name, config|
  check.call(name) do
    configure.call(config)
    failure.call { winget.apps }
    (root/"config.txt").write("")
    raise "Failure poisoned cache" unless winget.apps.length == 2
  end
end
check.call("canonical empty export is BOM-free UTF-8 on WSL filesystem") do
  configure.call("export:winget=8A150014\n")
  winget.singleton_class.class_eval { public :inventory_windows_path }
  original_create = Tempfile.method(:create)
  Dir.mktmpdir("Example's café") do |directory|
    Tempfile.define_singleton_method(:create) do |basename, &block|
      original_create.call(basename, directory) do |file|
        output = winget.inventory_windows_path(file.path)
        raise "Expected WSL UNC path: #{output}" unless output.start_with?("\\\\")
        value = block.call(file)
        raise "Noncanonical bytes" unless File.binread(file.path) == '{"Sources":[]}'
        value
      end
    end
    begin
      raise "Expected empty source" unless winget.exported_apps(fixture, source: "winget").empty?
    ensure
      Tempfile.define_singleton_method(:create, original_create)
    end
  end
end
check.call("canonical empty write failure propagates") do
  configure.call("export:winget=8A150014\nmode=missing\n")
  original_create = Tempfile.method(:create)
  Dir.mktmpdir do |directory|
    Tempfile.define_singleton_method(:create) do |_basename, &block|
      block.call(Struct.new(:path).new("#{directory}/absent/empty.json"))
    end
    begin
      failure.call { winget.exported_apps(fixture, source: "winget") }
    ensure
      Tempfile.define_singleton_method(:create, original_create)
    end
  end
end
check.call("missing Windows executable propagates") do
  failure.call { winget.listed_app_names(root/"missing.exe", source: "winget") }
end
check.call("native diagnostics retain Unicode and full status on stderr") do
  configure.call("export:winget=DEAD0014\n")
  error = failure.call { winget.apps }
  raise error.to_s unless error.to_s.include?("0xDEAD0014") && error.to_s.include?("native diagnostic café")
end
original_output = winget.method(:command_output)
{
  "unsigned exact status input" => ["[uint32]2316632084", true],
  "absent status input" => ["$null", false],
  "out of range status input" => ["[long]4294967296", false],
  "string status input" => ["'0'", false],
}.each do |name, (expression, accepted)|
  check.call("instrumented #{name}, real WSL PowerShell execution") do
    configure.call("export:winget=8A150014\n")
    winget.define_singleton_method(:command_output) do |executable, args:, **options|
      if args.include?("-Command")
        args = args.map { |arg| arg.gsub("$nativeStatus = $LASTEXITCODE", "$nativeStatus = #{expression}") }
      end
      original_output.call(executable, args:, **options)
    end
    begin
      if accepted
        raise "Expected empty source" unless winget.exported_apps(fixture, source: "winget").empty?
      else
        failure.call { winget.exported_apps(fixture, source: "winget") }
      end
    ensure
      winget.define_singleton_method(:command_output, original_output)
    end
  end
end
original_which = winget.method(:which)
check.call("missing PowerShell prerequisite") do
  winget.define_singleton_method(:which) do |name, *paths|
    name == "powershell.exe" ? root/"missing-powershell.exe" : original_which.call(name, *paths)
  end
  begin
    error = failure.call { winget.apps }
    raise error.to_s unless error.to_s.include?("requires Windows PowerShell 5.1")
  ensure
    winget.define_singleton_method(:which, original_which)
  end
end
Dir.mktmpdir do |directory|
  tool = Pathname(directory)/"failed-tool"
  tool.write("#!/bin/sh\nexit 2\n")
  tool.chmod(0755)
  check.call("PowerShell launch failure through checked subprocess") do
    winget.define_singleton_method(:which) do |name, *paths|
      name == "powershell.exe" ? tool : original_which.call(name, *paths)
    end
    begin
      failure.call { winget.apps }
    ensure
      winget.define_singleton_method(:which, original_which)
    end
  end
  [nil, "exit 2", "exit 0", "printf invalid"].each do |body|
    check.call("wslpath discovery/result fault: #{body || 'missing'}") do
      tool.write("#!/bin/sh\n#{body}\n") if body
      winget.define_singleton_method(:which) do |name, *paths|
        name == "wslpath" ? (body ? tool : nil) : original_which.call(name, *paths)
      end
      begin
        failure.call { winget.inventory_windows_path("/tmp/example") }
      ensure
        winget.define_singleton_method(:which, original_which)
      end
    end
  end
end
check.call("native second-source failure preserves forced Brewfile and stdout") do
  configure.call("export:msstore=80070000\n")
  Dir.mktmpdir do |directory|
    file = Pathname(directory)/"Brewfile"
    file.write("# preserved\n")
    dump = lambda do |target|
      Homebrew::Bundle::Dumper.dump_brewfile(global: false, file: target, describe: false, force: true,
        no_restart: false, formulae: false, taps: false, casks: false, extension_types: { winget: true })
    end
    failure.call { dump.call(file.to_s) }
    raise "Existing Brewfile changed" unless file.read == "# preserved\n"
    file.delete
    failure.call { dump.call(file.to_s) }
    raise "Created Brewfile" if file.exist?
    previous_stdout = $stdout
    $stdout = StringIO.new
    begin
      failure.call { dump.call("-") }
      raise "Printed partial inventory" unless $stdout.string.empty?
    ensure
      $stdout = previous_stdout
    end
  end
end
puts JSON.pretty_generate({ cases: results, fixture: fixture.to_s, kernel: `uname -r`.strip })
