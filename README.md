# aspace-importer

Convert import format files (such as EAD XML or MarcXML) to JSON batch files and
(optionally) load directly into ArchivesSpace on a recurring schedule.

This plugin allows you to drop files into a directory and have them automatically
imported into ArchivesSpace.

## Installation

Clone the plugin into your ArchivesSpace `plugins` directory:

```bash
git clone https://github.com/lyrasis/aspace-importer.git plugins/aspace-importer
```

Then enable it in `config/config.rb` and add at least one profile:

```ruby
AppConfig[:plugins] << 'aspace-importer'
```

Restart ArchivesSpace for the change to take effect.

## Configuration examples

For EAD XML (convert to json and import):

```ruby
AppConfig[:importer_profiles] = [{
  name: 'default',
  batch: {
    create_enums: true,
    enabled: true,
    repository: {
      repo_code: 'TEST'
    },
    username: 'admin'
  },
  import: {
    converter: 'EADConverter',
    type: 'ead_xml',
    directory: File.join(Dir.tmpdir, 'aspace', 'test', 'ead_xml'),
    error_file: File.join(Dir.tmpdir, 'aspace', 'test', 'ead_xml', 'importer.err')
  },
  json: {
    directory: File.join(Dir.tmpdir, 'aspace', 'test', 'json'),
    error_file: File.join(Dir.tmpdir, 'aspace', 'test', 'json', 'importer.err')
  },
  verbose: true
}]
```

For MarcXML agents and subjects (convert to json and import):

```ruby
AppConfig[:importer_profiles] = [{
  name: 'default',
  batch: {
    create_enums: true,
    enabled: true,
    repository: {
      repo_code: 'TEST'
    },
    username: 'admin'
  },
  import: {
    converter: 'MarcXMLConverter',
    type: 'marcxml_subjects_and_agents',
    directory: File.join(Dir.tmpdir, 'aspace', 'test', 'marcxml'),
    error_file: File.join(Dir.tmpdir, 'aspace', 'test', 'marcxml', 'importer.err')
  },
  json: {
    directory: File.join(Dir.tmpdir, 'aspace', 'test', 'json'),
    error_file: File.join(Dir.tmpdir, 'aspace', 'test', 'json', 'importer.err')
  },
  verbose: true
}]
```

Each profile needs a unique `name`: it identifies the profile in the logs and
determines the lock file that prevents two runs of the same profile overlapping.

## Profile reference

| Key                    | Description                                                                                                                                                 |
| ---------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `name`                 | Unique profile identifier, used in log messages and the lock file name.                                                                                     |
| `batch[:create_enums]` | Create controlled value list entries encountered during import instead of failing.                                                                          |
| `batch[:enabled]`      | When `false`, files are converted to JSON but never imported. The JSON accumulates in `json[:directory]` for you to review or load yourself.                |
| `batch[:repository]`   | A single property/value pair used to look up the target repository, e.g. `{ repo_code: 'TEST' }`. The run is skipped unless exactly one repository matches. |
| `batch[:username]`     | Username recorded as the agent for imported records.                                                                                                        |
| `import[:converter]`   | Converter class name, resolved as a constant. Use this to select your own converter subclass.                                                               |
| `import[:type]`        | Import type the converter is asked to handle, e.g. `ead_xml`. Must be a type the configured converter claims.                                               |
| `import[:directory]`   | Directory that is polled for `*.xml` files.                                                                                                                 |
| `import[:error_file]`  | Appended to when a file fails to convert.                                                                                                                   |
| `import[:options]`     | Optional hash forwarded to the converter's `set_import_options`, e.g. `{ import_events: true, import_subjects: true, import_repository: true }`.            |
| `json[:directory]`     | Where converted JSON is written and polled for import.                                                                                                      |
| `json[:error_file]`    | Appended to when a file fails to import.                                                                                                                    |
| `verbose`              | Log per-file progress. Errors and warnings are logged regardless.                                                                                           |

Files that fail are renamed with an `.err` suffix and left in place, so they are
not retried on the next run. The reason is appended to the relevant error file.

## Schedule

Use `AppConfig[:importer_schedule]` to determine how often files are checked for. Examples:

- `AppConfig[:importer_schedule] = '*/5 * * * *'` # every 5 minutes [default]
- `AppConfig[:importer_schedule] = '0 * * * *'` # every hour

The schedule is a [cron](https://crontab.guru/) formatted string.

Import tasks are allowed to run for 1 hour by default. This can be changed with `AppConfig[:importer_timeout]`.

Each profile also takes a lock file for the duration of a run. If a run is
interrupted (for example the application is killed mid-import) that lock is left
behind, so a lock older than `AppConfig[:importer_lock_timeout]` seconds (3600
by default) is treated as abandoned and cleared. Set this to at least as long
as the longest run you expect.

## Custom importers

- Add a file to `backend/model/my_converter.rb` in **your own plugin** (the file name is not important).
- Define the custom converter by subclassing an existing converter.
- Reference it in the config: `converter: "MyAwesomeConverter"`.

Naming the class explicitly means a profile always gets the converter you asked
for, rather than whichever registered converter happens to claim the import type
first. If the named converter does not handle the configured `type`, the run is
aborted with an error and no files are touched.

## License

This project is available as open source under the terms of the [MIT License](http://opensource.org/licenses/MIT).

---
