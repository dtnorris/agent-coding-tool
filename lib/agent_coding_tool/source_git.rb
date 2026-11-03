# frozen_string_literal: true

require "open3"
require_relative "source_files"

module AgentCodingTool
  # Fixed read-only Git metadata queries, with no shell, hooks, optional writes,
  # ambient Git overrides, credentials, pagers, network or unbounded pipe capture.
  class SourceGit
    Refused = RunEvidenceReader::Refused
    LIMIT = 2 * 1024 * 1024
    QUERIES = [%w[rev-parse --show-toplevel], %w[rev-parse --absolute-git-dir],
      %w[rev-parse HEAD], %w[ls-files --stage -z],
      %w[ls-files --cached --ignored --exclude-standard -z]].freeze

    # Executes one closed query in an already approved root. Returns binary stdout;
    # unknown queries, total deadline, output bounds and nonzero exits raise fixed
    # Refused. Only the owned child is killed/reaped on any incomplete observation.
    def call(root, query, deadline:)
      raise Refused, "source.git_query" unless QUERIES.include?(query)
      raise Refused, "source.deadline" unless deadline > Process.clock_gettime(Process::CLOCK_MONOTONIC)
      environment = { "PATH" => "/usr/bin:/bin", "TMPDIR" => ENV["TMPDIR"], "GIT_CONFIG_NOSYSTEM" => "1", "GIT_CONFIG_GLOBAL" => "/dev/null",
        "GIT_NO_LAZY_FETCH" => "1", "GIT_TERMINAL_PROMPT" => "0", "GIT_OPTIONAL_LOCKS" => "0", "LC_ALL" => "C" }
      argv = ["/usr/bin/git", "--no-optional-locks", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", *query]
      Open3.popen3(environment, *argv, chdir: root, unsetenv_others: true) do |input, output, error, child|
        input.close
        streams, captured = [output, error], { output => "".b, error => "".b }
        begin
          until streams.empty?
            remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            raise Refused, "source.deadline" unless remaining.positive?
            ready = IO.select(streams, nil, nil, [remaining, 0.05].min)
            next unless ready
            ready.first.each do |stream|
              bytes = stream.read_nonblock(8192, exception: false)
              next if bytes == :wait_readable
              if bytes.nil?
                streams.delete(stream)
              else
                captured[stream] << bytes
                raise Refused, "source.git_limit" if captured.values.sum(&:bytesize) > LIMIT
              end
            end
          end
          until child.join(0)
            raise Refused, "source.deadline" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
            IO.select(nil, nil, nil, 0.01)
          end
          raise Refused, "source.git" unless child.value.success?
          captured[output]
        ensure
          unless child.join(0)
            Process.kill("KILL", child.pid)
            child.join
          end
        end
      end
    rescue SystemCallError, IOError, ArgumentError
      raise Refused, "source.git", cause: nil
    end
  end
end
