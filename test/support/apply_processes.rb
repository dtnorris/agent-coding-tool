# frozen_string_literal: true

require_relative 'child_processes'
# Exact external validator adapter for the public PTY apply journey. It leaves
# product parsing, confirmations, pipe drains, interrupts and statuses intact.
module ApplyProcesses
  VALIDATORS = %w[
    42f711ee67132d81613018c8b94d3d9d95d7f1608ad8bc1cf6ff58f24bc4041e
    33db947daed7b739ff7c50b7327ed1c1d22a85f470a2a09d7f217f0ded118941
    950096dab7c603df54f31433586580935f1ba57395adcd5313648c5802d49c0c
    2199ab8e884ea39dc5303135e3d17815225e16ddd597216500604ff1ee3cda4a
    58fe4f882b6c6247cb180c420ca81d2ebbb12dcb59a99ac30b975c5e02a7f457
    aae726fab1f164dc8993fd109b1f3de43af58bb3becbbf04d2cf62c7573ca116
    01ce007e2106aa5e9ebde9716c2a76a09db8623351dbd4503ea308b7d2767fbf
  ].freeze

  # Runs only an exact reviewed file/argv envelope. Validator children retain
  # guard and coverage but receive no ACT/model bootstrap. Unknown scripts refuse.
  def call(argv, cwd: nil, env: {}, input: '', timeout: nil, **options)
    ruby_validation = argv == [RbConfig.ruby, '-Ilib:test', '--', 'verify.rb']
    rake_validation = argv == %w[bundle exec rake actd:validate_yaml test:all]
    missing_bundle = argv == %w[bundle exec rake test] && ENV['PATH']&.split(File::PATH_SEPARATOR)&.length == 1 &&
      File.basename(ENV['PATH']) == 'only-git' && !File.exist?(File.join(ENV['PATH'], 'bundle'))
    return super unless ruby_validation || rake_validation || missing_bundle
    source = ruby_validation ? File.join(cwd, 'verify.rb') : File.join(ChildProcesses::FIXTURES, 'apply_rake.rb')
    digest = Digest::SHA256.file(source).hexdigest
    if ruby_validation
      NoGitExecution.refuse!('unreviewed apply validator') unless VALIDATORS.include?(digest)
    elsif rake_validation
      NoGitExecution.refuse!('changed apply Rakefile') unless Digest::SHA256.file(File.join(cwd, 'Rakefile')).hexdigest == '7f6189cf275d371d348a75544341f3590a2ae63e7cd8b501714b013cca6808bc'
      NoGitExecution.refuse!('changed apply rake entry') unless digest == '5e6ffa21390410b05853c16c25647e85b2fb1f66a2f8ceda139564a5416e8c15'
    end
    NoGitExecution.refuse!('apply validator envelope') unless input == '' && options == { pgroup: true }
    preloads = {}
    if defined?(Bundler)
      bundler = File.realpath($LOADED_FEATURES.find { |path| path.end_with?('/bundler/setup.rb') })
      preloads[bundler] = Digest::SHA256.file(bundler).hexdigest
    end
    preloads[NoGitExecution::COVERAGE] = Digest::SHA256.file(NoGitExecution::COVERAGE).hexdigest if ENV['ACT_COVERAGE_CONTEXT']
    changed_environment = true
    previous = ENV['RUBYOPT']
    ENV['RUBYOPT'] = Shellwords.join(["-r#{NoGitExecution::GUARD}", *preloads.keys.map { |path| "-r#{path}" }])
    environment = env.merge('ACT_TEST_MEMORY_ENDPOINT' => nil, 'ACT_TEST_CODING_SKILL' => nil,
      'RUBYLIB' => [File.join(cwd, 'lib'), File.join(cwd, 'test'), ENV['RUBYLIB']].compact.join(File::PATH_SEPARATOR))
    permit = if missing_bundle
               NoGitExecution::MissingExecutablePermit.new(directory: ENV.fetch('PATH'), preloads: preloads, options: { chdir: cwd, pgroup: true })
             else
               NoGitExecution::Permit.new(script: source, sha256: digest, preloads: preloads,
                 arguments: rake_validation ? argv.drop(3) : [], environment: environment, options: { chdir: cwd, pgroup: true })
             end
    NoGitExecution.with_permit(permit) do
      super(permit.argv, cwd: cwd, env: permit.environment, input: input, timeout: timeout, **options)
    end
  ensure
    ENV['RUBYOPT'] = previous if changed_environment
  end
end
AgentCodingTool::NativeCommandTransport.prepend(ApplyProcesses)
