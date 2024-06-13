# Advanced Patrons Importer plugin for Koha

This plugin will automatically download patron CSV files and import them into Koha.
It can support unlimited files with different configurations and allows for renaming columns, mapping data and transformations via custom subroutines.

```yaml
---
- name: ERU
  run_on_dow: 0 # Sunday (0) through Saturday (6), leave out for daily
  debug:        # Enable debugging for development
  verbose: 3    # Gives more verbose output from the Koha patron import process
  sftp:
    host: sftp.library.org
    username: admin
    password: secret
    directory: /my/dir
    filename: myfile.txt
  local:        # If a local file is set, sftp settings will be ignored
    directory: /kohadevbox/koha
    filename: ERU_student_data.txt
  parameters:   # These values will be passed directly to Koha::Patrons::Import::import_patrons, along with the file generated
    matchpoint: cardnumber
    defaults:
      dateexpiry: 2099-01-01
      privacy: 1
    preserve_fields:
      - dateenrolled
      - password_expiration_date
      - fax
    overwrite_cardnumber: 0
    overwrite_passwords: 0
    update_dateexpiry: 1
    update_dateexpiry_from_today: 1
    update_dateexpiry_from_existing: 0
    send_welcome: 0
    dry_run: 0
  csv_options:  # These values will be passed to Text::CSV
    sep_char: "\t"
  columns:      # These are the output file column definitions
    - output: branchcode # Static output will just put the "static" value in the column
      static: ERU
    - output: surname    # Input will read the input column from the input file and place that value in the specified output column
      input: "Last Name" # essentially just renaming the column
      prefix: 1234       # Prepend the input column value with this value
      postfix: 1234      # Append this value to the input column value
    - subroutine: |-     # Subroutine will execute a custom perl function that takes the parameters for the input hash, output hash, and a general stash hash
        sub {
          my ( $input_hash, $output_hash, $stash ) = @_;
          $output_hash->{TEST} = "This is a test";
        };
    - output: categorycode  # Mapping allows for the transformation of one set of enumerated data to a different set of unumerated data
      mapping:
        source: studentgrade # The input file column to use as the lookup key
        map:
          "1": GRADESCHOOL
          "7": MIDDLESCHOOL
          "12": HIGHSCHOOL
          K: GRADESCHOOL
```

# Downloading

From the [release page](https://github.com/bywatersolutions/koha-plugin-patrons-importer/releases) you can download the latest release in `kpz` format.

# Installation

This plugin requires no special installation procedures.
