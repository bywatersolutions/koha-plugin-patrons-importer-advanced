package Koha::Plugin::Com::ByWaterSolutions::PatronsImporterAdvanced;

## It's good practice to use Modern::Perl
use Modern::Perl;

## Required for all plugins
use base qw(Koha::Plugins::Base);

use C4::Context;
use Koha::Encryption;
use Koha::Patrons::Import;

use Data::Dumper;
use File::Temp qw(tempdir tempfile);
use Net::SFTP::Foreign;
use Text::CSV::Slurp;
use Try::Tiny;

## Here we set our plugin version
our $VERSION         = "{VERSION}";
our $MINIMUM_VERSION = "{MINIMUM_VERSION}";

our $metadata = {
    name            => 'Advanced Patrons Importer',
    author          => 'Kyle M Hall',
    date_authored   => '2024-06-12',
    date_updated    => "1900-01-01",
    minimum_version => $MINIMUM_VERSION,
    maximum_version => undef,
    version         => $VERSION,
    description     =>
'Automate importing patron CSV files with column mapping and transformations',
};

=head3 new

=cut

sub new {
    my ( $class, $args ) = @_;

    ## We need to add our metadata here so our base class can access it
    $args->{'metadata'} = $metadata;
    $args->{'metadata'}->{'class'} = $class;

    ## Here, we call the 'new' method for our base class
    ## This runs some additional magic and checking
    ## and returns our actual $self
    my $self = $class->SUPER::new($args);

    return $self;
}

=head3 configure

=cut

sub configure {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    unless ( $cgi->param('save') ) {
        my $template = $self->get_template( { file => 'configure.tt' } );

        if ( $cgi->param('sync') ) {
            $self->cronjob_nightly( { send_sync_report => 1 } );
            $template->param( sync_report_ran => 1, );
        }

        ## Grab the values we already have for our settings, if any exist
        my $configuration = $self->retrieve_data('configuration') || q{};
        $configuration => Koha::Encryption->new->decrypt_hex($configuration)
          if $configuration;
        $template->param( configuration => $configuration );

        if ( $cgi->param('test') ) {
            my $data = $self->get_configuration();

            my @results;
            foreach my $job (@$data) {
                if ( $job->{sftp} ) {
                    my $error;
                    try {
                        my $sftp = $self->get_sftp($job);
                    }
                    catch {
                        $error = $_;
                    };
                    push( @results, { job => $job, error => $error } );
                }
            }

            $template->param( results => \@results, test_completed => 1 );
        }

        $self->output_html( $template->output() );
    }
    else {
        $self->store_data(
            {
                configuration => Koha::Encryption->new->encrypt_hex(
                    $cgi->param('configuration')
                ),
            }
        );
        $self->go_home();
    }
}

sub get_sftp {
    my ( $self, $job ) = @_;
    my $sftp_host     = $job->{sftp}->{host};
    my $sftp_username = $job->{sftp}->{username};
    my $sftp_password = $job->{sftp}->{password};
    my $sftp_dir      = $job->{sftp}->{directory};

    my $sftp = Net::SFTP::Foreign->new(
        host     => $sftp_host,
        user     => $sftp_username,
        port     => 22,
        password => $sftp_password,
        timeout  => 5, # seconds
    );
    $sftp->die_on_error( "Patrons Importer - "
          . "SFTP ERROR: Unable to establish SFTP connection for "
          . Data::Dumper::Dumper( $job->{sftp} ) );

    $sftp->setcwd($sftp_dir)
      or die "Patrons Importer - SFTP ERROR: unable to change cwd: "
      . $sftp->error
      . " - for "
      . Data::Dumper::Dumper( $job->{sftp} );

    return $sftp;
}

=head3 get_configuration

=cut

sub get_configuration {
    my ($self) = @_;

    my $configuration = Koha::Encryption->new->decrypt_hex(
        $self->retrieve_data('configuration') );

    my $data = eval { YAML::XS::Load( Encode::encode_utf8($configuration) ); };
    if ($@) {
        die "CRITICAL ERROR: Unable to parse yaml `$configuration` : $@";
    }

    return $data;
}

=head3 cronjob_nightly

=cut

sub cronjob_nightly {
    my ( $self, $p ) = @_;

    my $data = $self->get_configuration();

    my $Import = Koha::Patrons::Import->new();

    # Load transformation subroutines from kaho-conf.xml
    my $koha_conf_data = C4::Context->config("patrons_importer_advanced");
    my $transformers   = $koha_conf_data->{transformers};
    if ($transformers) {
        foreach my $sub_name ( keys %$transformers ) {
            my $code   = $transformers->{$sub_name};
            my $subref = eval $code;
            $transformers->{$sub_name} = $subref;
        }
    }

    foreach my $job (@$data) {
        next if $job->{disable};

        my $debug   = $job->{debug}   || 0;
        my $verbose = $job->{verbose} || 0;

        say "Working on job: $job->{name}" if $debug;

        my $run_on_dow = $job->{run_on_dow};
        if ( defined $run_on_dow ) {
            my $current_dow = (localtime)[6];
            my $is_day_to_run = index($run_on_dow, $current_dow) != -1;
            if ( $is_day_to_run ) {
                say "Running import, $current_dow is listed in $run_on_dow" if $debug >= 1;
            }
            else {
                say "Skipping import, $current_dow is listed in $run_on_dow" if $debug >= 1;
                next;
            }
        }

        my $directory;
        my $filename;

        if ( $job->{local} ) {
            $directory = $job->{local}->{directory};
            $filename  = $job->{local}->{filename};
            $debug && say "Loading local file from $directory/$filename";
        }
        elsif ( $job->{sftp} ) {
            $directory = tempdir();
            $filename  = $job->{sftp}->{filename};

            my $sftp_dir = $job->{sftp}->{directory};

            my $sftp = $self->get_sftp($job);

            $debug
              && say qq{Downloading '$sftp_dir/$filename' }
              . qq{via SFTP to '$directory/$filename'};

            $sftp->get( "$sftp_dir/$filename", "$directory/$filename" )
              or die "Patrons Importer - SFTP ERROR: get failed: "
              . $sftp->error;
        }

        my $filepath = "$directory/$filename";

        # Write a header if needed
        if ( my $header = $job->{file}->{header} ) {
            my ( $new_tmp_fh, $new_tmp_filename ) = tempfile();

            open my $new, '>:encoding(UTF-8)', $new_tmp_filename
              or die "$new_tmp_filename: $!";
            open my $old, '<:encoding(UTF-8)', $filepath or die "$filepath: $!";

            print {$new} "$header\n";
            print {$new} $_ while <$old>;
            close $new;

            $filepath = $new_tmp_filename;
        }

        my $options = $job->{csv_options} || {};
        my $inputs    = Text::CSV::Slurp->load( file => $filepath, %$options );

        my @output_data;
        foreach my $input (@$inputs) {
            $debug && say "WORKING ON " . Data::Dumper::Dumper($input);
            my $output = {};
            my $stash  = {};

            my $columns = $job->{columns};
            foreach my $column (@$columns) {
                my $output_column = $column->{output};
                say "NO OUPUT SPECIFIED FOR " . Data::Dumper::Dumper($column)
                  unless $output;

                if ( defined $column->{static} ) {
                    my $static_value = $column->{static};
                    $output->{$output_column} = $static_value;
                }
                elsif ( defined $column->{input} ) {
                    my $input_column = $column->{input};
                    my $value        = $input->{$input_column} // q{};
                    my $prefix       = $column->{prefix}       // q{};
                    my $postfix      = $column->{postfix}      // q{};
                    $value = $prefix . $value . $postfix;
                    $output->{$output_column} = $value;
                }
                elsif ( defined $column->{mapping} ) {
                    my $mapping = $column->{mapping};
                    my $source  = $mapping->{source};
                    my $map     = $mapping->{map};

                    my $input_value = $column->{$source};
                    my $value       = $map->{$input_value};
                    $output->{$output_column} = $value;
                }
                elsif ( defined $column->{transformer} ) {
                    my $sub_name = $column->{transformer};
                    my $sub      = $transformers->{$sub_name};
                    die "NO TRANSFORMER NAMED $sub_name DEFINED" unless $sub;
                    &$sub( $input, $output, $stash, $job );
                }
            }

            $debug && say "OUTPUT: " . Data::Dumper::Dumper($output);

            push( @output_data, $output );
        }

        my ( $tmp_fh, $tmp_filename ) = tempfile();
        my $csv = Text::CSV::Slurp->create( input => \@output_data );
        print $tmp_fh $csv;
        close $tmp_fh;

        # Reopen file handle for reading
        my $handle;
        open( $handle, "<:encoding(UTF-8)", $tmp_filename ) or die $!;

        my $params = $job->{parameters};
        my $return = $Import->import_patrons(
            {
                file => $handle,
                %$params,
            }
        );

        my $feedback    = $return->{feedback};
        my $errors      = $return->{errors};
        my $imported    = $return->{imported};
        my $overwritten = $return->{overwritten};
        my $alreadyindb = $return->{already_in_db};
        my $invalid     = $return->{invalid};
        my $total       = $imported + $alreadyindb + $invalid + $overwritten;

        if ($verbose) {
            say q{};
            say "Import complete:";
            say "Imported:    $imported";
            say "Overwritten: $overwritten";
            say "Skipped:     $alreadyindb";
            say "Invalid:     $invalid";
            say "Total:       $total";
            say q{};
        }

        if ( $verbose > 1 ) {
            say "Errors:";
            say Data::Dumper::Dumper($errors);
        }

        if ( $verbose > 2 ) {
            say "Feedback:";
            say Data::Dumper::Dumper($feedback);
        }

    }
}

=head3 install

This is the 'install' method. Any database tables or other setup that should
be done when the plugin if first installed should be executed in this method.
The installation method should always return true if the installation succeeded
or false if it failed.

=cut

sub install() {
    my ( $self, $args ) = @_;

    return 1;
}

=head3 upgrade

This is the 'upgrade' method. It will be triggered when a newer version of a
plugin is installed over an existing older version of a plugin

=cut

sub upgrade {
    my ( $self, $args ) = @_;

    return 1;
}

=head3 uninstall

This method will be run just before the plugin files are deleted
when a plugin is uninstalled. It is good practice to clean up
after ourselves!

=cut

sub uninstall() {
    my ( $self, $args ) = @_;

    return 1;
}

1;
