#!/usr/bin/env ruby
# Reviewed private external-service fixture; validates credential delivery and
# retains real adapter streams, readiness sockets, EOF and child wait status.
require ENV.fetch("ACT_TEST_TUNNEL_SUPPORT")
require "json"
require "socket"
require "open3"
require "shellwords"
exit 41 unless ENV["CONTROL_PLANE_API_KEY"] == "ACT29_SYNTHETIC_CREDENTIAL_7fQ9"
exit 42 if ENV.key?("OPENAI_TUNNEL_KEY") || ENV.key?("OTHER_SECRET")
config = JSON.parse(File.binread(ARGV.fetch(2)))
capacity = config.dig("admin_ui", "log_buffer_events")
exit 45 unless capacity.is_a?(Integer) && capacity.positive?
command = Shellwords.split(config.fetch("mcp").fetch("commands").first.fetch("command"))
exit 43 unless command.take(2) == ["/usr/bin/env", "-i"]
exit 44 if command.any? { |argument| argument.include?(ENV.fetch("CONTROL_PLANE_API_KEY")) }
# Keep the owned client alive through TERM unwinding until its adapter is reaped.
# The production owner still enforces its existing finite cleanup deadline.
begin
  input, output, waiter = TunnelProcesses.adapter(config_path: ARGV.fetch(2), command: command)
  wire = UNIXServer.new("wire")
  health = TCPServer.new("127.0.0.1", 0)
  Thread.new do
    loop do
      connection = health.accept
      connection.gets
      connection.write("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
      connection.close
    end
  end
  File.write(config.fetch("health").fetch("url_file"), "http://127.0.0.1:#{health.addr[1]}\n", perm: 0o600)
  connection = wire.accept
  while (frame = connection.gets)
    input.write(frame)
    input.flush
    response = output.gets
    break unless response
    connection.write(response)
  end
ensure
  input.close if input && !input.closed?
  if waiter
    status = waiter.value
    File.write("fixture-adapter-reaped.json", JSON.generate(
      "pid" => waiter.pid, "exit_code" => status.exitstatus, "signal" => status.termsig), perm: 0o600)
  end
end
