# frozen_string_literal: true

# Fixed external validator used by delivery fixtures. Arguments are literal
# output and exit code; no argument is interpreted as Ruby or a shell command.
# Real stdout, nonzero exits and reaped child status remain the production input.
output, code, reader = ARGV
abort 'missing read-only workspace handoff' if reader && !File.file?(File.join(reader, 'file.txt'))
STDOUT.puts(output)
exit Integer(code)
