# Advanced Patrons Importer plugin for Koha

This plugin will automatically download patron CSV files and import them into Koha.
It can support unlimited files with different configurations and allows for renaming columns, mapping data and transformations via custom subroutines.

```yaml
---
- name: EXAMPLE # Everything can have a name label, it doesn't actually do anything but can be helpful to have
  disable: 0    # Set to 1 to disable this job
  run_on_dow: 1,2,3,4,5 # Sunday (0) through Saturday (6), leave out for daily. List all day numbers separated by commas
  debug: 0      # Enable debugging for development
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
  file: # If the file you are ingesting has no header, you can inject one
    header: Last Name|First Name|Middle Name|Date of Birth|Level|Email|Phone|Address 1|Address 2|City|State|Zip|Enrollment Status
  parameters:   # These values will be passed directly to Koha::Patrons::Import::import_patrons, along with the file generated
    matchpoint: cardnumber
    preserve_extended_attributes: 1
    defaults:
      dateexpiry: 2099-01-01
      privacy: 1
    preserve_fields:
      - dateenrolled
      - password_expiration_date
      - fax
    overwrite_cardnumber: 1
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
    - name: Phone Number
      transformer: myTransformer  # Transformer will execute a custom perl subroutine defined in the koha conf file
    - output: categorycode  # Mapping allows for the transformation of one set of enumerated data to a different set of unumerated data
      mapping:
        source: studentgrade # The input file column to use as the lookup key
        map:
          "1": GRADESCHOOL
          "7": MIDDLESCHOOL
          "12": HIGHSCHOOL
          K: GRADESCHOOL
```

The transformers are stored within the `config` block of the Koha configuration file:
```xml
 <patrons_importer_advanced>
    <transformers>
        <dob>
            sub {
              my ( $input_hash, $output_hash, $stash ) = @_;
              my ( $month, $day, $year ) = split( '/', $input_hash->{"Date of Birth"} );
              $output_hash->{dateofbirth} = "$year-$month-$day";
            };
        </dob>
        <phone>
            sub {
              my ( $input_hash, $output_hash, $stash ) = @_;
              my $phone = $input_hash->{"Cell Phone"} || $input_hash->{"Phone"};
              $phone =~ s/\D//g;
              $output_hash->{phone} = $phone;
            };
        </phone>
        <pin>
            sub {
              my ( $input_hash, $output_hash, $stash ) = @_;
              require Koha::Patrons;
              my $count = Koha::Patrons->count({ cardnumber => $output_hash->{cardnumber} });
              unless ( $count ) {
               my $pin = 1000 + int(rand(8999));
               $output_hash->{password} = $pin;
               $output_hash->{patron_attributes} = "PIN:$pin";
              }
            };
        </pin>
    </transformers>
 </patrons_importer_advanced>
 ```

# Downloading

From the [release page](https://github.com/bywatersolutions/koha-plugin-patrons-importer-advanced/releases) you can download the latest release in `kpz` format.

# Installation

This plugin requires no special installation procedures.
