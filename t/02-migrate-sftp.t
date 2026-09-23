#!/usr/bin/perl

# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.
#
# Koha is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Koha; if not, see <http://www.gnu.org/licenses>.

use Modern::Perl;

use FindBin qw($Bin);

BEGIN {
    unshift( @INC, "$Bin/.." );
    unshift( @INC, '/kohadevbox/koha/' );
    unshift( @INC, '/kohadevbox/koha/t/lib/' );
}

use Test::More tests => 5;
use Test::NoWarnings;
use Test::Exception;
use Test::MockModule;

use Koha::Database;
use Koha::Encryption;
use Koha::File::Transport;
use Koha::File::Transports;
use Koha::Plugin::Com::ByWaterSolutions::PatronsImporterAdvanced;

use t::lib::Mocks;

my $schema = Koha::Database->new->schema;

# Storing a transport queues a connection test, which needs the message broker
my $test_transport = Test::MockModule->new('Koha::BackgroundJob::TestTransport');
$test_transport->mock( enqueue => sub { return 1 } );

my $header = "Last Name\tFirst Name\tCard";
my $yaml   = <<"YAML";
---
# Jobs for the test
- name: A
  debug: 0
  sftp:
    host: sftp.example.org
    username: schools
    password: secret-a
    # the directory shared with job B
    directory: /home/shared
    filename: "a_students.txt" # exported nightly
  file:
    header: $header
  parameters:
    matchpoint: cardnumber
- name: B
  sftp:
    host: sftp.example.org
    username: schools
    password: secret-a
    directory: /home/shared/
    filename: b_students.txt
- name: C
  sftp: # port and password differ from A and B
    host: sftp.example.org
    port: 2222
    username: schools
    password: secret-c
    directory: /home/c
    filename: c_students.txt
- name: D
  sftp:
    host: sftp.example.org
    port: 2222
    username: schools
    password: secret-c
    directory: /home/d
    filename: d_students.txt
- name: E
  local:
    directory: /tmp
    filename: e.txt
YAML

sub store_yaml {
    my ( $plugin, $text ) = @_;
    $plugin->store_data( { configuration => Koha::Encryption->new->encrypt_hex($text) } );
}

sub stored_yaml {
    my ($plugin) = @_;
    return Koha::Encryption->new->decrypt_hex( $plugin->retrieve_data('configuration') );
}

subtest 'migrate_sftp_to_file_transports() tests' => sub {
    plan tests => 33;

    $schema->storage->txn_begin;
    t::lib::Mocks::mock_userenv();

    my $plugin = Koha::Plugin::Com::ByWaterSolutions::PatronsImporterAdvanced->new( { enable_plugins => 1 } );
    store_yaml( $plugin, $yaml );

    my $count_before = Koha::File::Transports->count;
    my $report       = $plugin->migrate_sftp_to_file_transports();
    is( Koha::File::Transports->count, $count_before + 2, 'One file transport created per distinct connection' );
    is( scalar @$report,               2,                 'Report has one entry per transport' );

    my $t1 = $report->[0]->{transport};
    is( $t1->name,                'schools@sftp.example.org', 'Transport named after the username and host' );
    is( $t1->transport,           'sftp',                     'Transport is sftp' );
    is( $t1->host,                'sftp.example.org',         'Host set' );
    is( $t1->port,                22,                         'Default port set' );
    is( $t1->user_name,           'schools',                  'Username set' );
    is( $t1->auth_mode,           'password',                 'Password authentication' );
    is( $t1->plain_text_password, 'secret-a',                 'Password stored encrypted and decrypts' );
    is( $t1->download_directory,  '/home/shared/',            'Shared directory moved to the transport' );
    is( $report->[0]->{created},  1,                          'Transport reported as created' );
    is_deeply(
        $report->[0]->{jobs},
        [ { name => 'A', directory_kept => 0 }, { name => 'B', directory_kept => 0 } ],
        'Jobs A and B use the first transport and dropped their directory'
    );

    my $t2 = $report->[1]->{transport};
    is( $t2->name,                'schools@sftp.example.org:2222', 'Non-default port is part of the name' );
    is( $t2->port,                2222,                            'Port set' );
    is( $t2->plain_text_password, 'secret-c',                      'Second password stored' );
    is( $t2->download_directory,  undef,                           'No shared directory on the second transport' );
    is_deeply(
        $report->[1]->{jobs},
        [ { name => 'C', directory_kept => 1 }, { name => 'D', directory_kept => 1 } ],
        'Jobs C and D use the second transport and keep their directories'
    );

    my $new_yaml = stored_yaml($plugin);
    unlike( $new_yaml, qr/sftp:/,   'No sftp blocks left' );
    unlike( $new_yaml, qr/secret-/, 'No passwords left' );
    like( $new_yaml, qr/^# Jobs for the test$/m,                       'Top level comment kept' );
    like( $new_yaml, qr/^    # the directory shared with job B$/m,      'Comment inside a block kept' );
    like( $new_yaml, qr/^    filename: "a_students.txt" # exported nightly$/m, 'Quoted filename and its comment kept byte for byte' );
    like( $new_yaml, qr/^    header: \Q$header\E$/m,                   'Tab separated header untouched' );
    like( $new_yaml, qr/^  file_transport: # port and password differ from A and B$/m, 'Comment on the sftp line kept' );
    my ( $id1, $id2 ) = ( $t1->id, $t2->id );
    is( scalar( () = $new_yaml =~ /^    id: $id1$/mg ), 2, 'Two jobs point at the first transport' );
    is( scalar( () = $new_yaml =~ /^    id: $id2$/mg ), 2, 'Two jobs point at the second transport' );

    my $jobs = $plugin->get_configuration();
    is_deeply( $jobs->[0]->{file_transport}, { id => $id1, filename => 'a_students.txt' }, 'Job A rewritten' );
    is_deeply( $jobs->[1]->{file_transport}, { id => $id1, filename => 'b_students.txt' }, 'Job B rewritten' );
    is_deeply(
        $jobs->[2]->{file_transport},
        { id => $id2, directory => '/home/c', filename => 'c_students.txt' },
        'Job C rewritten and keeps its directory'
    );
    is_deeply(
        $jobs->[4], { name => 'E', local => { directory => '/tmp', filename => 'e.txt' } },
        'Local job untouched'
    );

    is_deeply( $plugin->migrate_sftp_to_file_transports(), [], 'Nothing left to migrate on a second run' );

    # Restoring the old configuration and migrating again reuses the transports
    store_yaml( $plugin, $yaml );
    $report = $plugin->migrate_sftp_to_file_transports();
    is( Koha::File::Transports->count, $count_before + 2, 'No new transports when the connections already exist' );
    is_deeply( [ map { $_->{created} } @$report ], [ 0, 0 ], 'Transports reported as reused' );

    $schema->storage->txn_rollback;
};

subtest 'CRLF configuration' => sub {
    plan tests => 3;

    $schema->storage->txn_begin;
    t::lib::Mocks::mock_userenv();

    my $plugin = Koha::Plugin::Com::ByWaterSolutions::PatronsImporterAdvanced->new( { enable_plugins => 1 } );
    my $crlf   = $yaml =~ s/\n/\r\n/gr;
    store_yaml( $plugin, $crlf );

    my $report = $plugin->migrate_sftp_to_file_transports();
    is( scalar @$report, 2, 'CRLF configuration migrated' );

    my $new_yaml = stored_yaml($plugin);
    my @lines    = grep { length } split( /\n/, $new_yaml );
    is( scalar( grep { !/\r$/ } @lines ), 0, 'Every line still ends with CRLF' );
    like( $new_yaml, qr/^    id: \d+\r$/m, 'New lines use CRLF too' );

    $schema->storage->txn_rollback;
};

subtest 'existing transport is reused' => sub {
    plan tests => 6;

    $schema->storage->txn_begin;
    t::lib::Mocks::mock_userenv();

    my $plugin = Koha::Plugin::Com::ByWaterSolutions::PatronsImporterAdvanced->new( { enable_plugins => 1 } );
    store_yaml( $plugin, $yaml );

    my $existing = Koha::File::Transport->new(
        {
            name               => 'Existing schools transport',
            host               => 'sftp.example.org',
            port               => 22,
            transport          => 'sftp',
            user_name          => 'schools',
            password           => 'secret-a',
            auth_mode          => 'password',
            download_directory => '/somewhere/else',
        }
    )->store;

    my $count_before = Koha::File::Transports->count;
    my $report       = $plugin->migrate_sftp_to_file_transports();
    is( Koha::File::Transports->count, $count_before + 1, 'Only the second connection needed a new transport' );
    is( $report->[0]->{transport}->id, $existing->id,     'Existing transport reused' );
    is( $report->[0]->{created},       0,                 'Reported as reused' );
    is(
        $existing->discard_changes->download_directory, '/somewhere/else/',
        'Existing transport left as it was'
    );
    is_deeply(
        $report->[0]->{jobs},
        [ { name => 'A', directory_kept => 1 }, { name => 'B', directory_kept => 1 } ],
        'Jobs keep their directory when the transport uses a different one'
    );
    like( stored_yaml($plugin), qr/^    directory: \/home\/shared$/m, 'Directory line kept' );

    $schema->storage->txn_rollback;
};

subtest 'abort cases' => sub {
    plan tests => 12;

    $schema->storage->txn_begin;
    t::lib::Mocks::mock_userenv();

    my $plugin = Koha::Plugin::Com::ByWaterSolutions::PatronsImporterAdvanced->new( { enable_plugins => 1 } );

    my $flow_style = <<'YAML';
- name: A
  sftp: { host: sftp.example.org, username: schools, password: secret-a, directory: /home/a, filename: a.txt }
YAML
    my $both = <<'YAML';
- name: A
  file_transport:
    id: 1
  sftp:
    host: sftp.example.org
    username: schools
    password: secret-a
    directory: /home/a
    filename: a.txt
YAML
    my $no_filename = <<'YAML';
- name: A
  sftp:
    host: sftp.example.org
    username: schools
    password: secret-a
    directory: /home/a
YAML
    my $alias = <<'YAML';
- name: A
  sftp: &creds
    host: sftp.example.org
    username: schools
    password: secret-a
    directory: /home/a
    filename: a.txt
- name: B
  sftp: *creds
YAML

    my @cases = (
        [ $flow_style,  qr/could not match the sftp block for job 'A'/,     'flow style block' ],
        [ $both,        qr/has both sftp and file_transport settings/,      'sftp and file_transport in one job' ],
        [ $no_filename, qr/job 'A' has no sftp filename/,                   'missing filename' ],
        [ $alias,       qr/could not match the sftp block for job 'A'/,     'anchors and aliases' ],
    );
    foreach my $case (@cases) {
        my ( $text, $error, $description ) = @$case;
        store_yaml( $plugin, $text );
        my $count_before = Koha::File::Transports->count;
        throws_ok { $plugin->migrate_sftp_to_file_transports() } $error, "Migration dies for $description";
        is( Koha::File::Transports->count, $count_before, "No transport created for $description" );
        is( stored_yaml($plugin),          $text,         "Configuration unchanged for $description" );
    }

    $schema->storage->txn_rollback;
};
