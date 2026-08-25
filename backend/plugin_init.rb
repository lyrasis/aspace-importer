# frozen_string_literal: true

require_relative 'lib/importer'

AppConfig[:importer_profiles]     = [] unless AppConfig.has_key? :importer_profiles
AppConfig[:importer_schedule]     = '*/5 * * * *' unless AppConfig.has_key? :importer_schedule
AppConfig[:importer_timeout]      = '1h' unless AppConfig.has_key? :importer_timeout
AppConfig[:importer_lock_timeout] = 3600 unless AppConfig.has_key? :importer_lock_timeout

ArchivesSpaceService.loaded_hook do
  ArchivesSpaceService.settings.scheduler.cron(
    AppConfig[:importer_schedule],
    allow_overlapping: false, # TODO: [newer versions] overlap: false
    mutex: 'aspace.importer.schedule',
    tags: 'aspace.importer.schedule',
    timeout: AppConfig[:importer_timeout]
  ) do
    Log.debug "Processing importer profiles: #{AppConfig[:importer_profiles].map { |p| p[:name] }.join(', ')}"

    AppConfig[:importer_profiles].each do |profile|
      importer = nil
      acquired = false

      begin
        importer = ArchivesSpace::Importer.new(profile)

        # this is an additional guard to prevent a duplicate importer process from running
        if importer.locked?
          if importer.stale_lock?
            Log.warn "Importer (#{importer.name}) is clearing a stale lock file"
            importer.unlock
          else
            Log.debug "Importer (#{importer.name}) is already running, skipping"
            next
          end
        end

        importer.lock
        acquired = true

        importer.convert
        importer.import
      rescue StandardError => e
        Log.warn "Importer (#{profile[:name]}) encountered an unexpected error:"
        Log.exception(e)
      ensure
        # only release a lock this run actually took
        importer.unlock if acquired
      end
    end
  end
end
