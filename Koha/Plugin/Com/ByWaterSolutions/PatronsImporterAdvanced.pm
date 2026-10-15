package Koha::Plugin::Com::ByWaterSolutions::PatronsImporterAdvanced;

## It's good practice to use Modern::Perl
use Modern::Perl;

## Required for all plugins
use base qw(Koha::Plugins::Base);

use C4::Context;
use C4::Log qw(logaction);
use Koha::Config;
use Koha::Email;
use Koha::Encryption;
use Koha::File::Transport;
use Koha::File::Transports;
use Koha::Libraries;
use Koha::Patron::Attribute::Types;
use Koha::Patron::Categories;
use Koha::Patrons::Import;
use Koha::TemplateUtils qw(process_tt);

use Koha::Plugin::Com::ByWaterSolutions::PatronsImporterAdvanced::YamlLines
  qw(outline line_for_path duplicate_keys pointer_segment pointer_segments);

use Data::Dumper;
use Encode;
use File::Temp qw(tempdir tempfile);
use JSON::Validator;
use Net::SFTP::Foreign;
use Text::CSV;
use Text::CSV::Slurp;
use Try::Tiny;
use XML::Simple;
use XML::Simple qw( XMLin );
use YAML::XS qw(Load Dump);

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

        if ( $cgi->param('migrate') ) {
            try {
                $template->param(
                    migration           => $self->migrate_sftp_to_file_transports(),
                    migration_completed => 1,
                );
            }
            catch {
                $template->param( migration_error => "$_" );
            };
        }

        try {
            ## Grab the values we already have for our settings, if any exist
            $template->param(
                configuration => Koha::Encryption->new->decrypt_hex(
                    $self->retrieve_data('configuration')
                )
            );
        };

        if ( $cgi->param('test') ) {
            my $data = $self->get_configuration();

            my @results;
            foreach my $job (@$data) {
                next unless $job->{sftp} || $job->{file_transport};

                my $label =
                  $job->{file_transport}
                  ? "file transport for job '" . ( $job->{name} // q{} ) . "'"
                  : $job->{sftp}->{host};

                my $error;
                try {
                    if ( $job->{file_transport} ) {
                        my $transport = $self->get_file_transport($job);
                        $label = "file transport '" . $transport->name . "' ( " . $transport->host . " )";
                        $transport->disconnect;
                    }
                    else {
                        my $sftp = $self->get_sftp($job);
                    }
                }
                catch {
                    $error = $_;
                };
                push( @results, { job => $job, label => $label, error => $error } );
            }

            $template->param( results => \@results, test_completed => 1 );
        }

        $self->output_html( $template->output() );
    }
    else {
        my $configuration = scalar $cgi->param('configuration');
        my $result        = $self->validate_configuration($configuration);

        if ( @{ $result->{errors} } && !$cgi->param('save_anyway') ) {
            my $template = $self->get_template( { file => 'configure.tt' } );
            $template->param(
                configuration        => $configuration,
                validation_errors    => $result->{errors},
                valid_output_columns => $result->{valid_columns},
            );
            $self->output_html( $template->output() );
        }
        else {
            $self->save_configuration($configuration);
            $self->go_home();
        }
    }
}

=head3 save_configuration

Stores the given configuration YAML, encrypted, and logs the change with passwords redacted.

=cut

sub save_configuration {
    my ( $self, $configuration ) = @_;

    # Log previous configuration, redact sftp passwords
    my $current_configuration = eval { $self->get_configuration() };
    my $current_yaml          = _redacted_yaml($current_configuration);
    my $new_configuration     = eval {
        YAML::XS::Load( Encode::encode_utf8($configuration) );
    };
    my $new_yaml = _redacted_yaml($new_configuration);
    logaction("PatronsImporterAdvanced", "ChangeConfiguration", "", $new_yaml, "", $current_yaml);

    my $encrypted = Koha::Encryption->new->encrypt_hex($configuration);

    $self->store_data( { configuration => $encrypted } );

    C4::Log::logaction( 'SYSTEMPREFERENCE', 'MODIFY', undef,
        "PatronsImporterAdvanced: $encrypted" );
}

sub _redacted_yaml {
    my ($configuration) = @_;

    return "" unless $configuration;

    # The configuration is a list of jobs, each with its own sftp credentials
    $configuration = [$configuration] unless ref $configuration eq 'ARRAY';
    foreach my $job (@$configuration) {
        $job->{sftp}->{password} = "*****" if ref $job eq 'HASH' && $job->{sftp};
    }

    return YAML::XS::Dump($configuration);
}

sub get_sftp {
    my ( $self, $job ) = @_;
    my $sftp_host     = $job->{sftp}->{host};
    my $sftp_username = $job->{sftp}->{username};
    my $sftp_password = $job->{sftp}->{password};
    my $sftp_dir      = defined $job->{sftp}->{directory} ? process_tt( $job->{sftp}->{directory} ) : undef;
    my $sftp_port     = $job->{sftp}->{port};

    my $sftp = Net::SFTP::Foreign->new(
        host     => $sftp_host,
        user     => $sftp_username,
        port     => $sftp_port || 22,
        password => $sftp_password,
        timeout  => 5,                  # seconds
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

=head3 find_file_transport

    my $transport = $plugin->find_file_transport($job);

Returns the Koha::File::Transport referenced by a job's 'file_transport' block without connecting to it. Dies if the block has no filename, or names no transport or more than one.

=cut

sub find_file_transport {
    my ( $self, $job ) = @_;
    my $conf = $job->{file_transport};

    die "Patrons Importer - FILE TRANSPORT ERROR: file_transport requires a filename"
      unless ref $conf eq 'HASH' && defined $conf->{filename} && length $conf->{filename};

    my $transport;
    if ( $conf->{id} ) {
        $transport = Koha::File::Transports->find( $conf->{id} );
        die "Patrons Importer - FILE TRANSPORT ERROR: No file transport found with id $conf->{id}"
          unless $transport;
    }
    elsif ( $conf->{name} ) {
        my $transports = Koha::File::Transports->search( { name => $conf->{name} } );
        my $count      = $transports->count;
        die "Patrons Importer - FILE TRANSPORT ERROR: No file transport found named '$conf->{name}'"
          unless $count;
        die "Patrons Importer - FILE TRANSPORT ERROR: $count file transports are named '$conf->{name}', use id instead"
          if $count > 1;
        $transport = $transports->next;
    }
    else {
        die "Patrons Importer - FILE TRANSPORT ERROR: file_transport requires an id or a name";
    }

    return $transport;
}

=head3 get_file_transport

Returns the Koha::File::Transport referenced by a job's 'file_transport' block,
connected and positioned in the job's directory. Dies if the transport can't be
found or connected to, or if the directory can't be changed to.

=cut

sub get_file_transport {
    my ( $self, $job ) = @_;
    my $conf = $job->{file_transport};

    my $transport = $self->find_file_transport($job);

    _file_transport_op( $transport, 'connect', sub { $transport->connect } );

    # The job's directory overrides the transport's download directory
    my $directory =
      ( defined $conf->{directory} && length $conf->{directory} )
      ? process_tt( $conf->{directory} )
      : $transport->download_directory;

    if ($directory) {
        _file_transport_op( $transport, "change directory to '$directory'",
            sub { $transport->change_directory($directory) } );
    }

    return $transport;
}

# Koha 25.11's SFTP transport dies ( missing JSON import ) instead of returning false when
# an operation fails, but it records the real error on the object first. So run every
# transport operation in a try block and build the message from the object's error messages.
sub _file_transport_op {
    my ( $transport, $description, $code ) = @_;

    my $exception;
    my $ok = try { $code->() } catch { $exception = $_; 0 };
    return 1 if $ok;

    my $label = sprintf( "'%s' ( #%s, %s://%s )",
        $transport->name, $transport->id, $transport->transport, $transport->host );
    my $reason = _file_transport_errors($transport);
    $reason .= " ( exception: $exception )" if $exception;

    die "Patrons Importer - FILE TRANSPORT ERROR: $description failed for file transport $label: $reason";
}

sub _file_transport_errors {
    my ($transport) = @_;

    my @errors = map {
        my $payload = $_->payload || {};
        $_->message . ': ' . ( $payload->{error} // 'unknown error' );
    } grep { $_->type eq 'error' } @{ $transport->object_messages };

    return join( '; ', @errors ) || 'unknown error';
}

=head3 migrate_sftp_to_file_transports

    my $report = $plugin->migrate_sftp_to_file_transports();

Replaces the 'sftp' block of every job with a 'file_transport' block, creating one Koha file
transport per distinct host, port, username and password. Only the sftp blocks of the stored
YAML are rewritten, the rest of the text is left as is. Saves the configuration and returns the
transports with the jobs that now use them. Dies without saving if the YAML text can't be
matched to the parsed configuration.

=cut

sub migrate_sftp_to_file_transports {
    my ($self) = @_;

    my $yaml = Koha::Encryption->new->decrypt_hex( $self->retrieve_data('configuration') );
    my $jobs = $self->get_configuration();
    die "Patrons Importer - MIGRATION ERROR: the configuration is not a list of jobs"
      unless ref $jobs eq 'ARRAY';

    # The configuration textarea saves CRLF line endings, keep whatever the configuration uses
    my $eol   = $yaml =~ /\r\n/ ? "\r\n" : "\n";
    my @lines = map { s/\r$//r } split( /\n/, $yaml, -1 );

    my $items = _top_level_items( \@lines, scalar @$jobs );

    # Pair each job's sftp settings with its block of text, and make sure the two agree
    # before anything is created or changed
    my @sftp_jobs;
    for my $i ( 0 .. $#$jobs ) {
        my $job   = $jobs->[$i];
        my $name  = ref $job eq 'HASH' && defined $job->{name} ? $job->{name} : "#" . ( $i + 1 );
        my $sftp  = ref $job eq 'HASH' ? $job->{sftp} : undef;
        my $block = _find_sftp_block( \@lines, $items->[$i], $name );
        my $mismatch =
          "Patrons Importer - MIGRATION ERROR: could not match the sftp block for job '$name' "
          . "to the parsed configuration, migrate it by hand";

        if ( ref $sftp ne 'HASH' ) {
            die $mismatch if $block;
            next;
        }
        die $mismatch unless $block && _deep_eq( _parse_sftp_block( $block, $name ), $sftp );

        die "Patrons Importer - MIGRATION ERROR: job '$name' has both sftp and file_transport settings, "
          . "migrate it by hand"
          if exists $job->{file_transport};
        foreach my $key (qw(host username password filename)) {
            die "Patrons Importer - MIGRATION ERROR: job '$name' has no sftp $key"
              unless defined $sftp->{$key} && length $sftp->{$key};
        }
        die "Patrons Importer - MIGRATION ERROR: job '$name' has a non-numeric sftp port"
          if defined $sftp->{port} && $sftp->{port} !~ /^\d+$/;

        push( @sftp_jobs, { index => $i, name => $name, sftp => $sftp, block => $block } );
    }

    # Group the jobs by connection, in the order the connections first appear
    my ( @groups, %group_for );
    foreach my $sftp_job (@sftp_jobs) {
        my $sftp = $sftp_job->{sftp};
        my $key  = join( "\0", $sftp->{host}, $sftp->{port} // 22, $sftp->{username}, $sftp->{password} );
        unless ( $group_for{$key} ) {
            $group_for{$key} = { sftp => $sftp, jobs => [] };
            push( @groups, $group_for{$key} );
        }
        push( @{ $group_for{$key}->{jobs} }, $sftp_job );
    }

    # A directory shared by every job of a group moves to the transport, unless it holds
    # template toolkit markup, which Koha wouldn't render
    foreach my $group (@groups) {
        my @directories      = map { _normalize_dir( $_->{sftp}->{directory} ) } @{ $group->{jobs} };
        my $common_directory = $directories[0];
        $common_directory = undef
          if !defined $common_directory
          || !length $common_directory
          || index( $common_directory, '[%' ) != -1
          || grep { !defined $_ || $_ ne $common_directory } @directories;

        my ( $transport, $created ) = _find_or_create_transport( $group->{sftp}, $common_directory );
        $group->{transport} = $transport;
        $group->{created}   = $created;
    }

    # Rewrite the blocks, from the last one to the first so the earlier line numbers stay valid
    my ( @report, %expected );
    foreach my $group (@groups) {
        my $transport           = $group->{transport};
        my $transport_directory = _normalize_dir( $transport->download_directory );
        my @report_jobs;

        foreach my $sftp_job ( @{ $group->{jobs} } ) {
            my $sftp      = $sftp_job->{sftp};
            my $directory = $sftp->{directory};
            my $has_directory     = defined $directory && length $directory;
            my $directory_dropped = $has_directory
              && defined $transport_directory
              && _normalize_dir($directory) eq $transport_directory;

            $sftp_job->{transport_id}      = $transport->id;
            $sftp_job->{directory_dropped} = $directory_dropped;

            my %expected_block = %$sftp;
            delete @expected_block{qw(host username password port)};
            delete $expected_block{directory} if $directory_dropped;
            $expected_block{id} = $transport->id;
            $expected{ $sftp_job->{index} } = \%expected_block;

            push( @report_jobs, { name => $sftp_job->{name}, directory_kept => $has_directory && !$directory_dropped ? 1 : 0 } );
        }

        push( @report, { transport => $transport, created => $group->{created}, jobs => \@report_jobs } );
    }

    foreach my $sftp_job ( sort { $b->{block}->{start} <=> $a->{block}->{start} } @sftp_jobs ) {
        my $block = $sftp_job->{block};
        my @new_lines = (
            ( ' ' x $block->{indent} ) . 'file_transport:' . ( $block->{trailing_comment} ? " $block->{trailing_comment}" : q{} ),
            ( ' ' x $block->{child_indent} ) . "id: $sftp_job->{transport_id}",
        );
        foreach my $entry ( @{ $block->{entries} } ) {
            my $key = $entry->{key} // q{};
            next if $key eq 'host' || $key eq 'username' || $key eq 'password' || $key eq 'port';
            next if $key eq 'directory' && $sftp_job->{directory_dropped};
            push( @new_lines, @{ $entry->{lines} } );
        }
        splice( @lines, $block->{start}, $block->{end} - $block->{start} + 1, @new_lines );
    }
    my $new_yaml = join( $eol, @lines );

    # Make sure the rewritten text parses to the same jobs, with only the sftp blocks changed
    my $new_jobs = eval { YAML::XS::Load( Encode::encode_utf8($new_yaml) ) };
    die "Patrons Importer - MIGRATION ERROR: the rewritten configuration is not valid YAML, nothing was saved: $@"
      unless ref $new_jobs eq 'ARRAY';
    die "Patrons Importer - MIGRATION ERROR: the rewritten configuration has a different number of jobs, nothing was saved"
      unless @$new_jobs == @$jobs;
    for my $i ( 0 .. $#$jobs ) {
        my %old = ref $jobs->[$i] eq 'HASH'     ? %{ $jobs->[$i] }     : ();
        my %new = ref $new_jobs->[$i] eq 'HASH' ? %{ $new_jobs->[$i] } : ();
        my $ok = $expected{$i} ? !exists $new{sftp} && _deep_eq( $new{file_transport}, $expected{$i} ) : 1;
        delete @old{qw(sftp file_transport)};
        delete @new{qw(sftp file_transport)};
        die "Patrons Importer - MIGRATION ERROR: the rewritten configuration differs from the original for job "
          . ( $i + 1 )
          . " in more than its sftp block, nothing was saved"
          unless $ok && _deep_eq( \%old, \%new );
    }

    $self->save_configuration($new_yaml) if @sftp_jobs;

    return \@report;
}

# Returns the line range and key indentation of each top level list item, so a job's sftp
# block can be matched to the job by position rather than by searching the whole text
sub _top_level_items {
    my ( $lines, $count ) = @_;

    my ( @items, $indent );
    for my $i ( 0 .. $#$lines ) {
        next unless $lines->[$i] =~ /^([ ]*)-(?:([ ]+)\S|$)/;
        my $dash_indent = length $1;
        my $spaces      = length( $2 // ' ' );
        $indent //= $dash_indent;
        next unless $dash_indent == $indent;

        $items[-1]->{last} = $i - 1 if @items;
        push( @items, { first => $i, last => $#$lines, key_indent => $dash_indent + 1 + $spaces } );
    }

    die "Patrons Importer - MIGRATION ERROR: found "
      . scalar(@items)
      . " jobs in the configuration text but $count in the parsed configuration, migrate it by hand"
      unless @items == $count;

    return \@items;
}

# Returns a job's sftp block split into entries ( a key line plus its continuation lines ),
# so a whole value can be dropped or kept even when it spans several lines
sub _find_sftp_block {
    my ( $lines, $item, $name ) = @_;

    my $key_indent = $item->{key_indent};
    my @matches    = grep { $lines->[$_] =~ /^[ ]{$key_indent}sftp:[ ]*(?:#.*)?$/ } $item->{first} .. $item->{last};
    return unless @matches;
    die "Patrons Importer - MIGRATION ERROR: job '$name' has more than one sftp block, migrate it by hand"
      if @matches > 1;

    my $start = $matches[0];
    my ($trailing_comment) = $lines->[$start] =~ /sftp:[ ]*(#.*)$/;

    # The block runs until the next non-blank line that isn't indented deeper than the key
    my $end = $start;
    for my $i ( $start + 1 .. $item->{last} ) {
        next unless $lines->[$i] =~ /\S/;
        last unless $lines->[$i] =~ /^[ ]{$key_indent}[ ]+\S/;
        $end = $i;
    }
    return unless $end > $start;

    my ($child_indent) = map { /^([ ]*)\S/ ? length $1 : () } @{$lines}[ $start + 1 .. $end ];
    my $mismatch = "Patrons Importer - MIGRATION ERROR: could not match the sftp block for job '$name' "
      . "to the parsed configuration, migrate it by hand";

    my @entries;
    for my $i ( $start + 1 .. $end ) {
        my $line = $lines->[$i];
        if ( $line =~ /^[ ]{$child_indent}(\S)/ ) {
            if ( $1 eq '#' ) {
                push( @entries, { key => undef, lines => [$line] } );
            }
            else {
                my ( $double, $single, $bare ) = $line =~ /^[ ]*(?:"([^"]*)"|'([^']*)'|([^\s#'"][^:]*?))[ ]*:(?:[ ]|$)/;
                my $key = $double // $single // $bare;
                die $mismatch unless defined $key;
                push( @entries, { key => $key, lines => [$line] } );
            }
        }
        else {
            die $mismatch unless @entries;
            push( @{ $entries[-1]->{lines} }, $line );
        }
    }

    return {
        start            => $start,
        end              => $end,
        indent           => $key_indent,
        child_indent     => $child_indent,
        trailing_comment => $trailing_comment,
        entries          => \@entries,
    };
}

# Parses an sftp block on its own, so it can be compared to the job's parsed settings
sub _parse_sftp_block {
    my ( $block, $name ) = @_;

    my @lines = ( 'sftp:', map { @{ $_->{lines} } } @{ $block->{entries} } );
    my $text  = join( "\n", map { my $l = $_; $l =~ s/^[ ]{$block->{indent}}//; $l } @lines );

    my $data = try { YAML::XS::Load( Encode::encode_utf8($text) ) } catch { undef };
    die "Patrons Importer - MIGRATION ERROR: could not match the sftp block for job '$name' "
      . "to the parsed configuration, migrate it by hand"
      unless ref $data eq 'HASH' && ref $data->{sftp} eq 'HASH';

    return $data->{sftp};
}

sub _deep_eq {
    my ( $x, $y ) = @_;

    return 0 if ( ref $x ) ne ( ref $y );
    if ( ref $x eq 'HASH' ) {
        return 0 unless keys %$x == keys %$y;
        return 0 if grep { !exists $y->{$_} || !_deep_eq( $x->{$_}, $y->{$_} ) } keys %$x;
        return 1;
    }
    if ( ref $x eq 'ARRAY' ) {
        return 0 unless @$x == @$y;
        return 0 if grep { !_deep_eq( $x->[$_], $y->[$_] ) } 0 .. $#$x;
        return 1;
    }
    return 1 if !defined $x && !defined $y;
    return 0 if !defined $x || !defined $y;
    return "$x" eq "$y" ? 1 : 0;
}

# Koha adds a trailing slash to a transport's download directory when it is stored
sub _normalize_dir {
    my ($dir) = @_;

    return unless defined $dir;
    $dir =~ s{(.)/+$}{$1};
    return $dir;
}

sub _transport_name {
    my ($sftp) = @_;

    my $port = $sftp->{port} // 22;
    my $base = substr( "$sftp->{username}\@$sftp->{host}" . ( $port == 22 ? q{} : ":$port" ), 0, 75 );
    my $name = $base;
    my $n    = 1;
    $name = $base . ' (' . ++$n . ')' while Koha::File::Transports->search( { name => $name } )->count;

    return $name;
}

# Reuses an existing transport for the same connection, so running the migration again
# doesn't create duplicates. Never changes a transport it didn't create.
sub _find_or_create_transport {
    my ( $sftp, $common_directory ) = @_;

    my $port       = $sftp->{port} // 22;
    my $transports = Koha::File::Transports->search(
        {
            transport => 'sftp',
            auth_mode => 'password',
            host      => $sftp->{host},
            port      => $port,
            user_name => $sftp->{username},
        },
        { order_by => 'file_transport_id' }
    );
    while ( my $transport = $transports->next ) {
        my $password = try { $transport->plain_text_password } catch { undef };
        return ( $transport, 0 ) if defined $password && $password eq $sftp->{password};
    }

    my $transport = Koha::File::Transport->new(
        {
            name               => _transport_name($sftp),
            host               => $sftp->{host},
            port               => $port,
            transport          => 'sftp',
            user_name          => $sftp->{username},
            password           => $sftp->{password},
            auth_mode          => 'password',
            download_directory => $common_directory,
        }
    )->store;

    return ( $transport, 1 );
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

=head3 get_transformers

    my $transformers = $plugin->get_transformers();

Returns the transformer subroutines defined in koha-conf.xml, keyed by name. Dies if one of them doesn't compile.

=cut

sub get_transformers {
    my ($self) = @_;

    # Load transformation subroutines from kaho-conf.xml. KeyAttr is empty so XML::Simple
    # doesn't fold the rest of the file on name attributes and warn about the duplicates
    my $conf_file = Koha::Config->guess_koha_conf;
    my $xml       = XMLin(
        $conf_file,
        ForceArray    => 0,
        KeyAttr       => [],
        SuppressEmpty => undef,
    );

    my $koha_conf_data = $xml->{config}->{patrons_importer_advanced};
    my $transformers   = $koha_conf_data->{transformers} || {};
    foreach my $sub_name ( keys %$transformers ) {
        my $code   = $transformers->{$sub_name};
        my $subref = eval $code;
        die "ERROR IN $sub_name: $@" if $@;
        $transformers->{$sub_name} = $subref;
    }

    return $transformers;
}

=head3 validate_configuration

    my $result = $plugin->validate_configuration( $yaml, { transformers => $transformers } );

Checks a configuration YAML text without saving it. Returns { errors => [ { path, line, location, message } ], data => $parsed, valid_columns => [...] }, errors sorted by line.

=cut

sub validate_configuration {
    my ( $self, $yaml, $options ) = @_;
    $options //= {};

    my $data = eval { YAML::XS::Load( Encode::encode_utf8( $yaml // q{} ) ) };
    if ($@) {
        my $error = "$@";
        my ($problem) = $error =~ /The problem:\s*(.*?)\s*was found at/s;
        my ($line)    = $error =~ /line: (\d+)/;
        $problem //= $error =~ s/^YAML::XS::Load Error:\s*//r =~ s/\s+at \S+ line \d+\.?\s*$//r;
        return {
            errors => [ { path => '/', line => $line, location => undef, message => "YAML syntax error: $problem" } ],
            data   => undef,
        };
    }

    my $outline = outline($yaml);
    my @errors;

    foreach my $duplicate ( @{ duplicate_keys($outline) } ) {
        my $parent = $duplicate->{path} eq '/' ? q{} : $duplicate->{path};
        push(
            @errors,
            {
                path    => "$parent/" . pointer_segment( $duplicate->{key} ),
                message => "Duplicate key '$duplicate->{key}', only the last one is used (first on line $duplicate->{first_line})",
            }
        );
    }

    my $validator = JSON::Validator->new->schema( YAML::XS::Load( $self->mbf_read('configuration_schema.yaml') ) );
    push( @errors, _schema_errors( $validator->validate($data) ) );

    my $extended     = C4::Context->preference('ExtendedPatronAttributes');
    my %valid_column = map { $_ => 1 } Koha::Patrons::Import->new->set_column_keys($extended);

    # Without the transformers nothing can be checked against them, so report the load
    # failure once instead of flagging every transformer column
    my $transformers = $options->{transformers};
    unless ($transformers) {
        $transformers = eval { $self->get_transformers() };
        if ($@) {
            my $error = "$@" =~ s/\s+$//r;
            push( @errors, { path => '/', message => "The transformers in koha-conf.xml could not be loaded: $error" } );
            $transformers = undef;
        }
    }

    my $check_transformer = sub {
        my ( $name, $path ) = @_;
        return unless $transformers;
        return if defined $name && !ref $name && $transformers->{$name};
        my $defined = %$transformers ? " (defined: " . join( ', ', sort keys %$transformers ) . ")" : q{};
        push( @errors, { path => $path, message => "No transformer named '" . ( $name // q{} ) . "' is defined in koha-conf.xml$defined" } );
    };

    my $check_code = sub {
        my ( $output, $value, $path ) = @_;
        $value //= q{};
        if ( $output eq 'categorycode' && !Koha::Patron::Categories->find($value) ) {
            push( @errors, { path => $path, message => "Patron category '$value' does not exist" } );
        }
        elsif ( $output eq 'branchcode' && !Koha::Libraries->find($value) ) {
            push( @errors, { path => $path, message => "Library '$value' does not exist" } );
        }
    };

    my %known_column_key = map { $_ => 1 } qw(output static input prefix padding length mapping transformer name);
    my %job_line;

    my @jobs = ref $data eq 'ARRAY' ? @$data : ();
    foreach my $i ( 0 .. $#jobs ) {
        my $job = $jobs[$i];
        next unless ref $job eq 'HASH';
        my $p = "/$i";

        my $name = $job->{name};
        if ( defined $name && !ref $name ) {
            if ( exists $job_line{$name} ) {
                push( @errors, { path => "$p/name", message => "Another job is also named '$name' (line $job_line{$name})" } );
            }
            else {
                $job_line{$name} = line_for_path( $outline, "$p/name" ) // '?';
            }
        }

        push( @errors, { path => $p, message => "Job has no file source, add a local, file_transport or sftp block" } )
          unless grep { ref $job->{$_} eq 'HASH' } qw(local file_transport sftp);

        if ( defined $job->{run_on_dow} && $job->{run_on_dow} !~ /^\s*[0-6](\s*,\s*[0-6])*\s*$/ ) {
            push(
                @errors,
                {
                    path    => "$p/run_on_dow",
                    message => "run_on_dow must be weekday numbers separated by commas, Sunday is 0, for example 1,2,3,4,5",
                }
            );
        }

        $check_transformer->( $job->{post_import_transformer}, "$p/post_import_transformer" )
          if exists $job->{post_import_transformer};

        # A missing filename is already reported by the schema
        if ( ref $job->{file_transport} eq 'HASH' && defined $job->{file_transport}->{filename} ) {
            try { $self->find_file_transport($job) }
            catch {
                my $message = "$_" =~ s/^Patrons Importer - FILE TRANSPORT ERROR: //r =~ s/\s+at \S+ line \d+\.?\s*$//r;
                push( @errors, { path => "$p/file_transport", message => $message } );
            };
        }

        if ( ref $job->{local} eq 'HASH' && defined $job->{local}->{directory} && !-d $job->{local}->{directory} ) {
            push(
                @errors,
                { path => "$p/local/directory", message => "Directory '$job->{local}->{directory}' does not exist on this server" }
            );
        }

        # The same csv options parse the configured header and the file, so a bad option
        # also means the header can't be checked
        my $csv_options = ref $job->{csv_options} eq 'HASH' ? $job->{csv_options} : {};
        my $csv = eval { Text::CSV->new( { binary => 1, %$csv_options } ) };
        unless ($csv) {
            my $reason = $@ ? "$@" =~ s/\s+at \S+ line \d+\.?\s*$//r : scalar Text::CSV->error_diag;
            push( @errors, { path => "$p/csv_options", message => "csv_options are not valid: $reason" } );
        }

        # Text::CSV accepts a multi character sep_char, which splits nothing. The usual
        # mistake is '\t' in single quotes, which is a backslash and a t rather than a tab.
        my $sep_char = $csv_options->{sep_char};
        if ( defined $sep_char && !ref $sep_char && length $sep_char != 1 ) {
            my $hint = $sep_char eq '\t' ? ', use double quotes ( "\t" ) for a tab' : q{};
            push( @errors, { path => "$p/csv_options/sep_char", message => "sep_char must be a single character$hint" } );
            $csv = undef;
        }

        my %in_header;
        my $header = ref $job->{file} eq 'HASH' ? $job->{file}->{header} : undef;
        if ( $csv && defined $header && length $header && !ref $header && $csv->parse($header) ) {
            %in_header = map { $_ => 1 } $csv->fields;
        }
        my $not_in_header = sub {
            my ($field) = @_;
            return "'$field' is not in the configured header (header: " . join( ', ', sort keys %in_header ) . ")";
        };

        if ( %in_header && ref $job->{skip_incoming} eq 'HASH' ) {
            foreach my $field ( sort keys %{ $job->{skip_incoming} } ) {
                push( @errors, { path => "$p/skip_incoming/" . pointer_segment($field), message => $not_in_header->($field) } )
                  unless $in_header{$field};
            }
        }

        my $parameters = ref $job->{parameters} eq 'HASH' ? $job->{parameters} : {};
        my $matchpoint = $parameters->{matchpoint};
        if ( defined $matchpoint && !ref $matchpoint ) {
            my $known =
                 $matchpoint eq 'cardnumber'
              || $matchpoint eq 'userid'
              || ( $extended && Koha::Patron::Attribute::Types->find($matchpoint) );
            push(
                @errors,
                {
                    path    => "$p/parameters/matchpoint",
                    message => "matchpoint '$matchpoint' must be cardnumber, userid or a patron attribute type code",
                }
            ) unless $known;
        }
        if ( ref $parameters->{preserve_fields} eq 'ARRAY' ) {
            my @fields = @{ $parameters->{preserve_fields} };
            foreach my $k ( 0 .. $#fields ) {
                my $field = $fields[$k] // q{};
                push( @errors, { path => "$p/parameters/preserve_fields/$k", message => _not_a_column($field) } )
                  unless $valid_column{$field};
            }
        }
        if ( ref $parameters->{defaults} eq 'HASH' ) {
            foreach my $field ( sort keys %{ $parameters->{defaults} } ) {
                push( @errors, { path => "$p/parameters/defaults/" . pointer_segment($field), message => _not_a_column($field) } )
                  unless $valid_column{$field};
            }
        }

        if ( ref $job->{delete_incoming} eq 'ARRAY' ) {
            my @criteria = @{ $job->{delete_incoming} };
            foreach my $k ( 0 .. $#criteria ) {
                my $criterion = $criteria[$k];
                next unless ref $criterion eq 'HASH' && defined $criterion->{field} && !ref $criterion->{field};
                push( @errors, { path => "$p/delete_incoming/$k/field", message => _not_a_column( $criterion->{field} ) } )
                  unless $valid_column{ $criterion->{field} };
            }
        }

        my @columns = ref $job->{columns} eq 'ARRAY' ? @{ $job->{columns} } : ();
        my %output_line;
        foreach my $k ( 0 .. $#columns ) {
            my $column = $columns[$k];
            my $cp     = "$p/columns/$k";
            unless ( ref $column eq 'HASH' ) {
                push(
                    @errors,
                    { path => $cp, message => "Column must be a mapping with output and one of static, input, mapping or transformer" }
                );
                next;
            }

            # The import loop tries static, input, mapping then transformer, so the first one
            # present is the one that runs
            my @kinds = grep { exists $column->{$_} } qw(static input mapping transformer);
            my $kind  = $kinds[0];
            if ( @kinds != 1 ) {
                my $found = @kinds ? "found: " . join( ', ', @kinds ) : "found none";
                push( @errors, { path => $cp, message => "Column needs exactly one of static, input, mapping or transformer ($found)" } );
            }

            foreach my $key ( sort keys %$column ) {
                push( @errors, { path => "$cp/" . pointer_segment($key), message => "Unknown key '$key' in column" } )
                  unless $known_column_key{$key};
            }

            my $output = $column->{output};
            if ( $kind && $kind ne 'transformer' ) {
                if ( !defined $output || ref $output || !length $output ) {
                    push( @errors, { path => $cp, message => "Column has no output" } );
                    $output = undef;
                }
                else {
                    push( @errors, { path => "$cp/output", message => _not_a_column($output) } ) unless $valid_column{$output};
                    if ( exists $output_line{$output} ) {
                        push(
                            @errors,
                            {
                                path    => "$cp/output",
                                message => "Output '$output' is also set by the column on line $output_line{$output}, only the last one is used",
                            }
                        );
                    }
                    else {
                        $output_line{$output} = line_for_path( $outline, "$cp/output" ) // '?';
                    }
                }
            }

            if ( $kind && $kind ne 'input' && grep { exists $column->{$_} } qw(prefix padding length) ) {
                push( @errors, { path => $cp, message => "prefix, padding and length only apply to input columns" } );
            }
            if ( defined $column->{length} && $column->{length} !~ /^\d+$/ ) {
                push( @errors, { path => "$cp/length", message => "length must be a whole number" } );
            }

            if ( $kind && $kind eq 'input' && %in_header && !$in_header{ $column->{input} // q{} } ) {
                push( @errors, { path => "$cp/input", message => $not_in_header->( $column->{input} // q{} ) } );
            }
            elsif ( $kind && $kind eq 'static' && defined $output ) {
                $check_code->( $output, $column->{static}, "$cp/static" );
            }
            elsif ( $kind && $kind eq 'mapping' ) {
                my $mapping = $column->{mapping};
                if ( ref $mapping ne 'HASH' ) {
                    push( @errors, { path => "$cp/mapping", message => "mapping needs a source column and a map of input values to output values" } );
                }
                else {
                    my $source = $mapping->{source};
                    if ( !defined $source || ref $source || !length $source ) {
                        push( @errors, { path => "$cp/mapping", message => "mapping needs a source column" } );
                    }
                    elsif ( %in_header && !$in_header{$source} ) {
                        push( @errors, { path => "$cp/mapping/source", message => $not_in_header->($source) } );
                    }

                    my $map = $mapping->{map};
                    if ( ref $map ne 'HASH' || grep { ref } values %$map ) {
                        push( @errors, { path => "$cp/mapping/map", message => "mapping needs a map of input values to output values" } );
                    }
                    elsif ( defined $output ) {
                        $check_code->( $output, $map->{$_}, "$cp/mapping/map/" . pointer_segment($_) ) for sort keys %$map;
                    }
                }
            }
            elsif ( $kind && $kind eq 'transformer' ) {
                $check_transformer->( $column->{transformer}, "$cp/transformer" );
            }
        }
    }

    foreach my $error (@errors) {
        $error->{line} //= line_for_path( $outline, $error->{path} );
        $error->{location} = _describe_path( $data, $error->{path} );
    }
    @errors = sort { ( $a->{line} // ~0 ) <=> ( $b->{line} // ~0 ) || $a->{path} cmp $b->{path} } @errors;

    return { errors => \@errors, data => $data, valid_columns => [ sort keys %valid_column ] };
}

sub _not_a_column {
    my ($field) = @_;

    return "'$field' is not a column the patron import accepts";
}

# Turns JSON::Validator's errors into the same { path, message } shape as the other checks,
# with wording a librarian can act on
sub _schema_errors {
    my (@validator_errors) = @_;

    my %type_name = ( object => 'a mapping', array => 'a list', string => 'text', integer => 'a number', number => 'a number', null => 'nothing', boolean => 'true or false' );

    my @errors;
    foreach my $error (@validator_errors) {
        my $path    = $error->path;
        my $message = $error->message;

        if ( $message =~ /^Properties not allowed: (.*)\.$/ ) {
            push( @errors, { path => "$path/" . pointer_segment($_), message => "Unknown key '$_'" } ) for split( /, /, $1 );
        }
        elsif ( $message =~ /^Missing property\.$/ ) {
            my ($key) = ( pointer_segments($path) )[-1];
            push( @errors, { path => $path, message => "Missing required key '$key'" } );
        }
        elsif ( $message =~ /^Not in enum list: (.*)\.$/ ) {
            push( @errors, { path => $path, message => "Must be one of $1" } );
        }
        elsif ( $message =~ /^Expected (\S+) - got (\S+)\.$/ ) {
            my ( $expected, $got ) = ( $1, $2 );
            $expected = join( ' or ', map { $type_name{$_} // $_ } split( /\//, $expected ) );
            push( @errors, { path => $path, message => "Expected $expected, got " . ( $type_name{$got} // $got ) } );
        }
        else {
            push( @errors, { path => $path, message => $message =~ s/\.$//r } );
        }
    }

    return @errors;
}

# "job 12 "PUSD" > column 14 > transformer" reads better than "/11/columns/13/transformer"
sub _describe_path {
    my ( $data, $path ) = @_;

    my @segments = pointer_segments($path);
    return unless @segments && $segments[0] =~ /^\d+$/ && ref $data eq 'ARRAY';

    my $index = shift @segments;
    my $job   = $data->[$index];
    my $name  = ref $job eq 'HASH' && defined $job->{name} && !ref $job->{name} ? qq{ "$job->{name}"} : q{};

    my @parts = ( 'job ' . ( $index + 1 ) . $name );
    if ( @segments >= 2 && $segments[0] eq 'columns' && $segments[1] =~ /^\d+$/ ) {
        push( @parts, 'column ' . ( $segments[1] + 1 ) );
        splice( @segments, 0, 2 );
    }
    push( @parts, join( '/', @segments ) ) if @segments;

    return join( ' > ', @parts );
}

=head3 cronjob_nightly

=cut

sub cronjob_nightly {
    my ( $self, $p ) = @_;

    my $data = $self->get_configuration();

    my $Import = Koha::Patrons::Import->new();

    my $transformers = $self->get_transformers();

    # Problems the configuration page would have refused, or that were saved anyway
    my $yaml   = Koha::Encryption->new->decrypt_hex( $self->retrieve_data('configuration') );
    my $result = $self->validate_configuration( $yaml, { transformers => $transformers } );
    foreach my $error ( @{ $result->{errors} } ) {
        my @where = ( ( defined $error->{line} ? "line $error->{line}" : () ), ( $error->{location} // () ) );
        say "CONFIGURATION PROBLEM: " . ( @where ? join( ', ', @where ) . ': ' : q{} ) . $error->{message};
    }

    foreach my $job (@$data) {
        try {
            next if $job->{disable};

            my $debug   = $job->{debug}   || 0;
            my $verbose = $job->{verbose} || 0;

            say "Working on job: $job->{name}" if $debug;

            my $run_on_dow = $job->{run_on_dow};
            if ( defined $run_on_dow ) {
                my $current_dow   = (localtime)[6];
                my $is_day_to_run = index( $run_on_dow, $current_dow ) != -1;
                if ($is_day_to_run) {
                    say "Running import, $current_dow is listed in $run_on_dow"
                      if $debug >= 1;
                }
                else {
                    say "Skipping import, $current_dow is listed in $run_on_dow"
                      if $debug >= 1;
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
            elsif ( $job->{file_transport} ) {
                $directory = tempdir( CLEANUP => 1 );

                my $transport = $self->get_file_transport($job);
                $filename = process_tt( $job->{file_transport}->{filename} );

                $debug
                  && say qq{Downloading '$filename' via file transport '}
                  . $transport->name
                  . qq{' to '$directory/$filename'};

                _file_transport_op( $transport, "download of '$filename'",
                    sub { $transport->download_file( $filename, "$directory/$filename" ) } );

                $transport->disconnect;
            }
            elsif ( $job->{sftp} ) {
                $directory = tempdir( CLEANUP => 1 );
                $filename  = process_tt( $job->{sftp}->{filename} // q{} );

                my $sftp_dir = defined $job->{sftp}->{directory} ? process_tt( $job->{sftp}->{directory} ) : undef;

                my $sftp = $self->get_sftp($job);

                $debug
                  && say qq{Downloading '$sftp_dir/$filename' }
                  . qq{via SFTP to '$directory/$filename'};

                $sftp->get( "$sftp_dir/$filename", "$directory/$filename" )
                  or die
"Patrons Importer - SFTP ERROR: get failed for $sftp_dir/$filename :"
                  . $sftp->error;
            }

            my $filepath = process_tt("$directory/$filename");

            # Write a header if needed
            if ( my $header = $job->{file}->{header} ) {
                my ( $new_tmp_fh, $new_tmp_filename ) = tempfile();
                binmode( $new_tmp_fh, ":utf8" );

                open my $new, '>:encoding(UTF-8)', $new_tmp_filename
                  or die "$new_tmp_filename: $!";
                open my $old, '<:encoding(UTF-8)', $filepath
                  or die "$filepath: $!";

                print {$new} "$header\n";
                print {$new} $_ while <$old>;
                close $new;

                $filepath = $new_tmp_filename;
            }

            my $options = $job->{csv_options} || {};
            my $inputs = Text::CSV::Slurp->load( file => $filepath, %$options );

            my @output_data;
            foreach my $input (@$inputs) {
                $debug && say "WORKING ON " . Data::Dumper::Dumper($input);

                if ( $input->{disabled} ) {
                    say "DISABLED, SKIPPING...";
                    next;
                }

                my $skip = 0;
                foreach my $input_column ( keys %{ $job->{skip_incoming} } ) {
                    my $values = $job->{skip_incoming}->{$input_column};
                    foreach my $value (@$values) {
                        if ( defined $input->{$input_column}
                            && $input->{$input_column} eq $value )
                        {
                            $debug
                              && say
"SKIPPING: Row has column '$input_column' value of $value, skipping!";
                            $skip = 1;
                            last;
                        }
                    }
                }
                next if $skip;

                my $output = {};
                my $stash  = {};

                my $columns = $job->{columns};
                foreach my $column (@$columns) {
                    my $output_column = $column->{output};
                    say "NO OUPUT SPECIFIED FOR "
                      . Data::Dumper::Dumper($column)
                      unless $output;

                    if ( defined $column->{static} ) {
                        my $static_value = $column->{static};
                        $output->{$output_column} = $static_value;
                    }
                    elsif ( defined $column->{input} ) {
                        my $input_column = $column->{input};
                        my $value        = $input->{$input_column} // q{};
                        my $prefix       = $column->{prefix}       // q{};
                        my $padding      = $column->{padding}      // q{};
                        my $length       = $column->{length}       // 0;

                        my $padding_length =
                          $length - length($prefix) - length($value);
                        $padding_length = 0 if $padding_length < 0;
                        $padding        = $padding x $padding_length;

                        $value = $prefix . $padding . $value;
                        $output->{$output_column} = $value;
                    }
                    elsif ( defined $column->{mapping} ) {
                        my $mapping = $column->{mapping};
                        my $source  = $mapping->{source};
                        my $map     = $mapping->{map};

                        my $input_value = $input->{$source};
                        my $value       = $map->{$input_value};
                        $output->{$output_column} = $value;
                    }
                    elsif ( defined $column->{transformer} ) {
                        my $sub_name = $column->{transformer};
                        my $sub      = $transformers->{$sub_name};
                        die "NO TRANSFORMER NAMED $sub_name DEFINED"
                          unless $sub;

                        try {
                            &$sub( $input, $output, $stash, $job );
                        }
                        catch {
                            warn
"Call to transformer $sub_name failed with errors: $_";
                        };
                    }
                }

                $debug && say "OUTPUT: " . Data::Dumper::Dumper($output);

                if ( $job->{delete_incoming} ) {
                    my $criteria = $job->{delete_incoming};

                    my $delete = 0;

                    foreach my $c (@$criteria) {
                        my $field      = $c->{field};
                        my $value      = $c->{value};
                        my $comparison = $c->{comparison};

                        next
                          unless defined($field)
                          && defined($value)
                          && defined($comparison);

                        if ( $comparison eq 'equals' ) {
                            $delete = 1
                              if defined( $output->{$field} )
                              && $output->{$field} eq $value;
                        }
                        elsif ( $comparison eq 'not_equals' ) {
                            $delete = 1
                              if defined( $output->{$field} )
                              && $output->{$field} ne $value;
                        }

                        say "DELETING $output->{cardnumber} BECAUSE "
                          . Data::Dumper::Dumper($c)
                          if $delete && $verbose;

                        if ($delete) {
                            delete_if_found( $output, $job );
                        }
                        else {
                            push( @output_data, $output );
                        }
                    }

                    delete_if_found( $output, $job ) if $delete;
                }
                else {
                    push( @output_data, $output );
                }
            }

            my ( $tmp_fh, $tmp_filename ) = tempfile();
            binmode( $tmp_fh, ":utf8" );
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
            my $total = $imported + $alreadyindb + $invalid + $overwritten;

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

            if ( my $email_conf = $job->{email_results} ) {

                $email_conf->{text_body} = qq{
Import complete for $job->{name}:
Imported:    $imported
Overwritten: $overwritten
Skipped:     $alreadyindb
Invalid:     $invalid
Total:       $total
                };

                my $email = Koha::Email->create($email_conf);

                try {
                    $email->send_or_die();
                }
                catch {
                    warn "ERROR: Failed to send email for job $job->{name}: $_";
                }
            }

            if ( $verbose > 1 ) {
                say "Errors:";
                say Data::Dumper::Dumper($errors);
            }

            if ( $verbose > 2 ) {
                say "Feedback:";
                say Data::Dumper::Dumper($feedback);
            }

            if ( $job->{post_import_transformer} ) {
                my $sub_name = $job->{post_import_transformer};
                my $sub      = $transformers->{$sub_name};
                die "NO TRANSFORMER NAMED $sub_name DEFINED"
                  unless $sub;

                try {
                    &$sub( \@output_data, $job );
                }
                catch {
                    warn "Call to transformer $sub_name failed with errors: $_";
                };
            }

        }
        catch {
            say "JOB $job->{name} FAILED WITH THE ERROR: $_";
        };
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

sub uninstall {
    my ( $self, $args ) = @_;

    return 1;
}

sub delete_if_found {
    my ( $job, $output ) = @_;

    my $debug   = $job->{debug}   || 0;
    my $verbose = $job->{verbose} || 0;

    my $matchpoint = $job->{parameters}->{matchpoint};
    my $value      = $output->{$matchpoint};

    return unless $matchpoint && $value;

    my $patron =
      Koha::Patrons->find( { $matchpoint => $output->{$matchpoint} } );

    if ($patron) {
        say "MATCHING PATRON TO DELETE FOUND FOR "
          . "$matchpoint => $output->{$matchpoint}"
          if $verbose;
        $patron->move_to_deleted();
        $patron->delete();
    }
    else {
        say "NO MATCHING PATRON TO DELETE FOUND FOR "
          . "$matchpoint => $output->{$matchpoint}"
          if $verbose > 1;
    }
}

1;
