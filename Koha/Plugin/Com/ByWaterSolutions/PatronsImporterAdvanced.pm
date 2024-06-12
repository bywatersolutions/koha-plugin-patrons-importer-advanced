package Koha::Plugin::Com::ByWaterSolutions::PatronsImporterAdvanced;

## It's good practice to use Modern::Perl
use Modern::Perl;

## Required for all plugins
use base qw(Koha::Plugins::Base);

use Koha::Encryption;

use File::Temp qw(tempdir);
use Net::SFTP::Foreign;
use Try::Tiny;

## Here we set our plugin version
our $VERSION         = "{VERSION}";
our $MINIMUM_VERSION = "{MINIMUM_VERSION}";

our $metadata = {
    name            => 'Patrons Importer',
    author          => 'Kyle M Hall',
    date_authored   => '2022-12-02',
    date_updated    => "1900-01-01",
    minimum_version => $MINIMUM_VERSION,
    maximum_version => undef,
    version         => $VERSION,
    description     => 'Automate importing patron CSV files from SFTP',
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
        $template->param(
            configuration => $self->retrieve_data('configuration'), );

        if ( $cgi->param('test') ) {
            try {
                my $sftp = $self->get_sftp();
            }
            catch {
                $template->param( test_error => $_ );
            };

            $template->param( test_completed => 1 );
        }

        $self->output_html( $template->output() );
    }
    else {
        $self->store_data(
            {
                configuration => $cgi->param('configuration'),
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
        password => $sftp_password
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

=head3 cronjob_nightly

=cut

sub cronjob_nightly {
    my ( $self, $p ) = @_;

    my $configuration = $self->retrieve_data('configuration');
    my $data = eval { YAML::XS::Load( Encode::encode_utf8($configuration) ); };
    if ($@) {
        warn "Unable to parse yaml `$configuration` : $@";
        return;
    }

    foreach my $job (@$data) {
        my $debug = $job->{debug} || 0;

        my $run_on_dow = $job->{run_on_dow};
        if ($run_on_dow) {
            if ( (localtime)[6] == $run_on_dow ) {
                say "Run on Day of Week $run_on_dow"
                  . " matches current day of week "
                  . (localtime)[6]
                  if $debug >= 1;
            }
            else {
                say "Run on Day of Week $run_on_dow"
                  . " does not match current day of week "
                  . (localtime)[6]
                  if $debug >= 1;
                return;
            }
        }

        my $sftp_filename = $job->{filename};

        my $sftp = $self->get_sftp($job);

        my $tempdir = tempdir();

        warn qq{DOWNLOADING '$sftp_dir/$sftp_filename' }
          . qq{TO '$tempdir/$sftp_filename'};

        $sftp->get( "$sftp_dir/$sftp_filename", "$tempdir/$sftp_filename" )
          or die "Patrons Importer - SFTP ERROR: get failed: " . $sftp->error;

        ## FIXME - THIS IS WHERE THE MAGIC GOES

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

    $self->store_data(
        {
            run_on_dow => "0",
        }
    );

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
