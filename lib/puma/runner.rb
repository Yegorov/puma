# frozen_string_literal: true

require 'puma/server'
require 'puma/const'
require 'fcntl'

module Puma
  # Generic class that is used by `Puma::Cluster` and `Puma::Single` to
  # serve requests. This class spawns a new instance of `Puma::Server` via
  # a call to `start_server`.
  class Runner
    def initialize(cli, events)
      @launcher = cli
      @events = events
      @options = cli.options
      @app = nil
      @control = nil
      @started_at = Time.now
    end

    def development?
      @options[:environment] == "development"
    end

    def test?
      @options[:environment] == "test"
    end

    def log(str)
      @events.log str
    end

    # @version 5.0.0
    def stop_control
      @control.stop(true) if @control
    end

    def error(str)
      @events.error str
    end

    def debug(str)
      @events.log "- #{str}" if @options[:debug]
    end

    def start_control
      str = @options[:control_url]
      return unless str

      require 'puma/app/status'

      if token = @options[:control_auth_token]
        token = nil if token.empty? || token == 'none'
      end

      app = Puma::App::Status.new @launcher, token

      control = Puma::Server.new app, @launcher.events,
        { min_threads: 0, max_threads: 1, queue_requests: false }

      control.binder.parse [str], self, 'Starting control server'

      control.run thread_name: 'control'
      @control = control
    end

    # @version 5.0.0
    def close_control_listeners
      @control.binder.close_listeners if @control
    end

    # @!attribute [r] ruby_engine
    def ruby_engine
      if !defined?(RUBY_ENGINE) || RUBY_ENGINE == "ruby"
        "ruby #{RUBY_VERSION}-p#{RUBY_PATCHLEVEL}"
      else
        if defined?(RUBY_ENGINE_VERSION)
          "#{RUBY_ENGINE} #{RUBY_ENGINE_VERSION} - ruby #{RUBY_VERSION}"
        else
          "#{RUBY_ENGINE} #{RUBY_VERSION}"
        end
      end
    end

    def output_header(mode)
      min_t = @options[:min_threads]
      max_t = @options[:max_threads]

      log "Puma starting in #{mode} mode..."
      log "* Puma version: #{Puma::Const::PUMA_VERSION} (#{ruby_engine}) (\"#{Puma::Const::CODE_NAME}\")"
      log "*  Min threads: #{min_t}"
      log "*  Max threads: #{max_t}"
      log "*  Environment: #{ENV['RACK_ENV']}"

      if mode == "cluster"
        log "*   Master PID: #{Process.pid}"
      else
        log "*          PID: #{Process.pid}"
      end
    end

    def should_reopen?(fd)
      append_flags = File::WRONLY | File::APPEND

      if fd.closed?
        return false
      end

      is_append = (fd.fcntl(Fcntl::F_GETFL) & append_flags) == append_flags
      if fd.stat.file? && fd.sync && is_append
        return true
      end
      return false
    rescue IOError, Errno::EBADF
      false
    end

    def reopen_log(fd)
      orig_stat = begin
        fd.stat
      rescue IOError, Errno::EBADF => e
        STDOUT.puts "#{e.class.name} #{e.message} #{e.backtrace.join("\n")}"
        return
      end

      # We only need files which were moved on disk
      begin
        new_stat = File.stat(fd.path)
        if orig_stat.dev == new_stat.dev && orig_stat.ino == new_stat.ino
          return
        end
      rescue Errno::ENOENT => e
        STDOUT.puts "#{e.class.name} #{e.message} #{e.backtrace.join("\n")}"
      end

      STDOUT.puts "=== puma rotating log file #{fd.path} at #{Time.now} ==="

      begin
        fd.reopen(fd.path, "a")
      rescue IOError, Errno::EBADF => e
        STDOUT.puts "#{e.class.name} #{e.message} #{e.backtrace.join("\n")}"
        return
      end

      # this is required to create the new file right away
      fd.sync = true
      fd.flush

      new_stat = fd.stat

      if orig_stat.uid != new_stat.uid || orig_stat.gid != new_stat.gid
        fd.chown(orig_stat.uid, orig_stat.gid)
      end
    end

    def reopen_logs?
      @options[:reopen_logs]
    end

    def reopen_logs
      fds = []

      ObjectSpace.each_object(File) do |fd|
        if should_reopen?(fd)
          fds << fd
        end
      end

      fds.each { |fd| reopen_log(fd) }
    end

    def redirected_io?
      @options[:redirect_stdout] || @options[:redirect_stderr]
    end

    def redirect_io
      stdout = @options[:redirect_stdout]
      stderr = @options[:redirect_stderr]
      append = @options[:redirect_append]

      if stdout
        unless Dir.exist?(File.dirname(stdout))
          raise "Cannot redirect STDOUT to #{stdout}"
        end

        STDOUT.reopen stdout, (append ? "a" : "w")
        STDOUT.puts "=== puma redirects stdout: #{Time.now} ==="
        STDOUT.flush unless STDOUT.sync
      end

      if stderr
        unless Dir.exist?(File.dirname(stderr))
          raise "Cannot redirect STDERR to #{stderr}"
        end

        STDERR.reopen stderr, (append ? "a" : "w")
        STDERR.puts "=== puma redirects stderr: #{Time.now} ==="
        STDERR.flush unless STDERR.sync
      end

      if @options[:mutate_stdout_and_stderr_to_sync_on_write]
        STDOUT.sync = true
        STDERR.sync = true
      end
    end

    def load_and_bind
      unless @launcher.config.app_configured?
        error "No application configured, nothing to run"
        exit 1
      end

      begin
        @app = @launcher.config.app
      rescue Exception => e
        log "! Unable to load application: #{e.class}: #{e.message}"
        raise e
      end

      @launcher.binder.parse @options[:binds], self
    end

    # @!attribute [r] app
    def app
      @app ||= @launcher.config.app
    end

    def start_server
      server = Puma::Server.new app, @launcher.events, @options
      server.inherit_binder @launcher.binder
      server
    end
  end
end
