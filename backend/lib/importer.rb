# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'

module ArchivesSpace
  class Importer
    # Raised when the configured :converter does not claim the configured :type.
    class ConverterMismatch < StandardError; end

    DEFAULT_LOCK_TIMEOUT = 3600

    attr_reader :config, :name

    def initialize(config)
      @config = config
      @name   = @config[:name]

      @batch_enabled       = @config[:batch][:enabled]
      @batch_username      = @config[:batch][:username]
      @create_enums        = @config[:batch][:create_enums]

      @repository_id       = nil # retrieve this via repo prop -> value lookup
      @repository_property = @config[:batch][:repository].keys.first
      @repository_value    = @config[:batch][:repository].values.first

      @converter           = @config[:import][:converter]
      @type                = @config[:import][:type]
      @import_directory    = @config[:import][:directory]
      @import_error_file   = @config[:import][:error_file]
      @import_options      = @config[:import][:options] || {}

      @json_directory      = @config[:json][:directory]
      @json_error_file     = @config[:json][:error_file]

      @verbose             = @config[:verbose]
      @lock_file           = File.join(Dir.tmpdir, "aspace.importer.#{@name}.lock")
      @lock_timeout        = lock_timeout
      setup
      converter_class # resolve now so a bad :converter fails before any files move
    end

    def convert
      files = incoming_xml

      if files.empty?
        Log.debug("[#{name}]: skipping conversion (no files in #{@import_directory})")
        return
      end

      unless valid_repository?
        Log.warn("[#{name}]: skipping conversion (no repository matches #{@repository_property}=#{@repository_value})")
        return
      end

      total = files.count
      Log.info "[#{name}]: converting #{total} files in (#{@import_directory}) at #{Time.now}" if @verbose

      files.each do |file|
        fn = File.basename(file, '.*')
        begin
          Log.info "[#{name}]: Converting #{fn}" if @verbose
          with_context { convert_file(file, fn) }

          FileUtils.remove_file file
        rescue ConverterMismatch => e
          Log.error("[#{name}]: #{e.message}; aborting conversion (check :converter and :type)")
          return
        rescue StandardError => e
          handle_error(@import_error_file, e, file)
        end
      end

      Log.info "[#{name}]: finished conversion of #{total} files at #{Time.now}" if @verbose
    end

    def import
      files = incoming_json

      if files.empty?
        Log.debug("[#{name}]: skipping import (no files in #{@json_directory})")
        return
      end

      unless batch_enabled?
        Log.debug("[#{name}]: skipping import (batch is disabled)")
        return
      end

      unless valid_repository?
        Log.warn("[#{name}]: skipping import (no repository matches #{@repository_property}=#{@repository_value})")
        return
      end

      total = files.count
      Log.info "[#{name}]: importing #{total} files in (#{@json_directory}) at #{Time.now}" if @verbose

      files.each do |file|
        fn = File.basename(file, '.*')
        begin
          stream file
          FileUtils.remove_file file
          Log.info "[#{name}]: imported #{fn}" if @verbose
        rescue StandardError => e
          handle_error(@json_error_file, e, file)
        end
      end

      Log.info "[#{name}]: finished importing #{total} files at #{Time.now}" if @verbose
    end

    def any_json?
      incoming_json.count.positive?
    end

    def any_xml?
      incoming_xml.count.positive?
    end

    def batch_enabled?
      @batch_enabled
    end

    def lock
      FileUtils.touch @lock_file
    end

    def locked?
      File.exist? @lock_file
    end

    def stale_lock?
      return false unless locked?

      (Time.now - File.mtime(@lock_file)) > @lock_timeout
    end

    def stream(file)
      with_context do
        File.open(file, 'r') do |fh|
          batch = StreamingImport.new(fh, ArchivesSpace::Importer::Ticker.new, false)
          batch.process
        end
      end
    end

    def valid_repository?
      repository = Repository.where(@repository_property => @repository_value)
      count = repository.count

      Log.warn "[#{name}]: #{count} repositories match #{@repository_property}=#{@repository_value}" if count > 1

      @repository_id = count == 1 ? repository.first.id : nil
      Log.info "[#{name}]: using repo_id #{@repository_id}" if @repository_id && @verbose
      !@repository_id.nil?
    end

    def unlock
      FileUtils.rm_f @lock_file
    end

    def with_context(&block)
      DB.open(DB.supports_mvcc?, retry_on_optimistic_locking_fail: true) do
        RequestContext.open(
          create_enums: @create_enums,
          current_username: @batch_username,
          repo_id: @repository_id, &block
        )
      end
    end

    private

    def converter_class
      @converter_class ||= Object.const_get(@converter)
    end

    # Seconds, unlike :importer_timeout which is a duration string.
    def lock_timeout
      value = AppConfig[:importer_lock_timeout]
      seconds = value.is_a?(Numeric) ? value.to_i : Integer(value.to_s, exception: false).to_i
      return seconds if seconds.positive?

      Log.warn("[#{name}]: invalid :importer_lock_timeout #{value.inspect}, using #{DEFAULT_LOCK_TIMEOUT}s")
      DEFAULT_LOCK_TIMEOUT
    end

    def convert_file(file, basename)
      c = converter_class.instance_for(@type, file)
      raise ConverterMismatch, "#{@converter} does not handle import type '#{@type}'" if c.nil?

      c.set_import_options(@import_options) if @import_options.any? && c.respond_to?(:set_import_options)

      begin
        c.run

        target = File.join(@json_directory, "#{basename}.json")
        raise "#{basename}.json already exists and is awaiting import" if File.exist?(target)

        FileUtils.cp(c.get_output_path, target)
      ensure
        c.remove_files
      end
    end

    def handle_error(error_file, error, file)
      File.open(error_file, 'a') do |f|
        f.puts "#{File.basename(file)}: #{error.message}\n#{Array(error.backtrace).join("\n")}"
      end
      FileUtils.mv(file, "#{file}.err")
    end

    def incoming_json
      Dir.glob("#{@json_directory}/*.json")
    end

    def incoming_xml
      Dir.glob("#{@import_directory}/*.xml")
    end

    def setup
      [
        @import_directory,
        @json_directory
      ].each { |d| FileUtils.mkdir_p d }

      [
        @import_error_file,
        @json_error_file
      ].each do |f|
        FileUtils.mkdir_p File.dirname(f)
        FileUtils.touch f
      end
    end

    class Ticker
      def initialize(out = Log)
        @out = out
      end

      def tick; end

      def status_update(status_code, status)
        @out.info("#{status[:id]}. #{status_code.upcase}: #{status[:label]}")
      end

      def log(s)
        @out.info(s)
      end

      def tick_estimate=(n); end
    end
  end
end
