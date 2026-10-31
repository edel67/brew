from pathlib import Path
import json, re, subprocess, sys

brew, mode, directory = sys.argv[1:]
evidence = Path(directory)
evidence.mkdir(parents=True, exist_ok=True)
source = Path('Library/Homebrew/bundle/extensions/winget.rb')
original = source.read_text()
spec = 'bundle/winget_native' if mode == 'native' else 'bundle/winget'
tests = Path('Library/Homebrew/test/' + spec + '_spec.rb').read_text().splitlines()
results = []

def run(name, description=None, failures=0, examples=None):
    target = spec
    if description:
        lines = [n for n, line in enumerate(tests, 1) if description in line]
        assert len(lines) == 1, (description, lines)
        target += ':' + str(lines[0])
    command = [brew, 'tests', '--only=' + target, '--no-parallel']
    process = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    (evidence/(name + '.log')).write_text(process.stdout)
    plain = re.sub(r'\x1b\[[0-9;]*m', '', process.stdout)
    counts = re.findall(r'(\d+) examples?, (\d+) failures?(?:, (\d+) pending)?', plain)
    assert counts, (name, process.returncode, plain[-3000:])
    count, failed, pending = [int(x or 0) for x in counts[-1]]
    assert count > 0 and failed == failures and pending == 0, (name, count, failed, pending, plain[-3000:])
    assert (process.returncode == 0) == (failures == 0), (name, process.returncode)
    if examples is not None:
        assert count == examples, (name, count)
    results.append({'name': name, 'target': target, 'examples': count, 'failures': failed, 'pending': pending})
    print(name, count, 'examples;', failed, 'expected failures', flush=True)

if mode == 'native':
    mutations = [
        ('status-width', '$nativeCode = [long]$nativeStatus -band 4294967295L', '$nativeCode = [long]$nativeStatus -band 255', 'rejects native failure 0x', 2),
        ('status-collision', 'if ($nativeCode -eq #{NO_APPLICATIONS_FOUND}) {', 'if (($nativeCode -band 255) -eq (#{NO_APPLICATIONS_FOUND} -band 255)) {', 'rejects native failure 0x', 1),
        ('empty-status-scope', 'if ($nativeCode -eq 0) { exit 0 }', 'if ($nativeCode -eq 0 -or $nativeCode -eq #{NO_APPLICATIONS_FOUND}) { exit 0 }', 'rejects the no-applications status for list', 1),
        ('literal-quotes', r"value.gsub(/['\u2018-\u201B]/) { |quote| quote * 2 }", 'value.gsub("\'", "\'\'")', 'preserves literal arguments through native export and list', 4),
        ('empty-encoding', '(New-Object System.Text.UTF8Encoding($false))', '(New-Object System.Text.UTF8Encoding($true))', 'writes the canonical empty export as BOM-free UTF-8', 5),
        ('empty-write-error', "trap { [Console]::Error.WriteLine($_); exit 1 }", 'trap { exit 0 }', 'propagates failure to write the canonical empty export', 1),
    ]
else:
    assert mode == 'portable'
    mutations = [
        ('missing-export', 'parse_export(File.read(file.path), source:)', 'File.exist?(file.path) ? parse_export(File.read(file.path), source:) : []', 'retries after a successful command produces a', 1),
        ('malformed-export', 'raise "Invalid WinGet export: expected JSON"', '[]', 'retries after a successful command produces a', 1),
        ('missing-powershell', 'raise "WinGet inventory requires Windows PowerShell 5.1 (powershell.exe)" unless powershell.executable?', '', 'rejects an unavailable PowerShell executable', 1),
        ('failed-conversion', 'command_output(wslpath, args: ["-w", path]).chomp', 'Utils.popen_read_text(wslpath, "-w", path).chomp', 'rejects unsuccessful or nonabsolute conversion:', 1),
        ('nonabsolute-conversion', 'raise "Invalid Windows path from wslpath" unless absolute_windows_path?(converted)', '', 'rejects unsuccessful or nonabsolute conversion:', 1),
    ]

run('baseline', examples=16 if mode == 'native' else None)
try:
    for name, before, after, description, failures in mutations:
        assert original.count(before) == 1, (name, original.count(before))
        source.write_text(original.replace(before, after))
        try:
            run(name + '-red', description, failures)
        finally:
            source.write_text(original)
        run(name + '-green', description)
finally:
    source.write_text(original)
assert source.read_text() == original
(evidence/'results.json').write_text(json.dumps(results, indent=2) + '\n')
