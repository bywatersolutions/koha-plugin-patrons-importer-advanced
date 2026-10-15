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

use Test::More tests => 4;
use Test::NoWarnings;
use Test::Exception;
use Test::MockModule;

use File::Slurp qw(write_file);
use File::Temp  qw(tempdir);

use Koha::Database;
use Koha::File::Transports;
use Koha::Plugin::Com::ByWaterSolutions::PatronsImporterAdvanced;

use t::lib::Mocks;
use t::lib::TestBuilder;

my $schema  = Koha::Database->new->schema;
my $builder = t::lib::TestBuilder->new;

# Storing a transport queues a connection test, which needs the message broker
my $test_transport = Test::MockModule->new('Koha::BackgroundJob::TestTransport');
$test_transport->mock( enqueue => sub { return 1 } );

sub build_local_transport {
    my ( $name, $directory ) = @_;
    return $builder->build_object(
        {
            class => 'Koha::File::Transports',
            value => {
                transport          => 'local',
                name               => $name,
                download_directory => $directory,
                upload_directory   => undef,
                password           => undef,
                key_file           => undef,
                status             => undef,
            }
        }
    );
}

# The errors as { path => message } so a whole result can be compared at once
sub messages {
    my ($result) = @_;
    return { map { $_->{path} => $_->{message} } @{ $result->{errors} } };
}

subtest 'validate_configuration() tests' => sub {
    plan tests => 29;

    $schema->storage->txn_begin;

    my $plugin_module = Test::MockModule->new('Koha::Plugin::Com::ByWaterSolutions::PatronsImporterAdvanced');
    $plugin_module->mock( get_transformers => sub { return { dob => sub { }, phone => sub { }, pin => sub { } } } );
    t::lib::Mocks::mock_preference( 'ExtendedPatronAttributes', 1 );

    my $plugin    = Koha::Plugin::Com::ByWaterSolutions::PatronsImporterAdvanced->new( { enable_plugins => 1 } );
    my $category  = $builder->build_object( { class => 'Koha::Patron::Categories' } );
    my $library   = $builder->build_object( { class => 'Koha::Libraries' } );
    my $directory = tempdir( CLEANUP => 1 );
    my $transport = build_local_transport( 'Validator test transport', $directory );

    my $result = $plugin->validate_configuration("- name: A\n  parameters: x: y\n");
    is( scalar @{ $result->{errors} }, 1, 'A syntax error is the only error reported' );
    like(
        $result->{errors}->[0]->{message}, qr/^YAML syntax error: mapping values are not allowed in this context/,
        'The syntax error carries the libyaml problem'
    );
    is( $result->{errors}->[0]->{line}, 2,     'The syntax error points at its line' );
    is( $result->{data},                undef, 'Nothing is parsed from invalid YAML' );

    $result = $plugin->validate_configuration("name: A\n");
    is_deeply( messages($result), { '/' => 'Expected a list, got a mapping' }, 'The configuration must be a list of jobs' );

    my $good = <<"YAML";
---
- name: Good
  run_on_dow: 1,2,3,4,5
  file_transport:
    id: @{[ $transport->id ]}
    filename: students.csv
  file:
    header: "Student ID,Last Name,First Name,Grade,School,Email"
  csv_options:
    sep_char: ","
  skip_incoming:
    School:
      - "999"
  columns:
    - output: privacy
      static: 0
    - output: cardnumber
      input: Student ID
      prefix: "6279"
      padding: "0"
      length: 12
    - output: surname
      input: Last Name
    - output: categorycode
      mapping:
        source: Grade
        map:
          "09": @{[ $category->categorycode ]}
    - output: branchcode
      static: @{[ $library->branchcode ]}
    - name: Phone
      transformer: phone
    - output: patron_attributes
      static: '"GRADE:9TH"'
  delete_incoming:
    - field: surname
      value: DELETE
      comparison: equals
  parameters:
    matchpoint: cardnumber
    overwrite_cardnumber: 1
    preserve_fields:
      - email
    defaults:
      privacy: 0
  post_import_transformer: pin
  force_generate_pin: 0
YAML
    $result = $plugin->validate_configuration($good);
    is_deeply( $result->{errors}, [], 'A complete configuration has no errors' ) or diag explain $result->{errors};
    is( $result->{data}->[0]->{name}, 'Good', 'The parsed configuration is returned' );
    ok( ( grep { $_ eq 'cardnumber' } @{ $result->{valid_columns} } ), 'The import columns are returned' );

    t::lib::Mocks::mock_preference( 'ExtendedPatronAttributes', 0 );
    $result = $plugin->validate_configuration($good);
    is_deeply(
        messages($result), { '/0/columns/6/output' => "'patron_attributes' is not a column the patron import accepts" },
        'patron_attributes is only a column when ExtendedPatronAttributes is on'
    );
    t::lib::Mocks::mock_preference( 'ExtendedPatronAttributes', 1 );

    my $bad = <<"YAML";
- name: X
  csv_options:
    sep_char: ","
  file:
    header: a,b
  columns:
    - output: fone
      input: a
    - output: surname
      input: zzz
    - transformer: nope
      name: x
    - output: categorycode
      static: NOPE
    - output: surname
      static: dup
      prefix: 1
    - mapping:
        source: b
      output: branchcode
    - foo: 1
    - output: cardnumber
      input: a
      length: twelve
    - output: branchcode
      mapping:
        source: a
        map:
          '1': NOWHERE
          '2': @{[ $library->branchcode ]}
  parameters:
    matchpoint: cardnumber
    overwrite_cardnumbers: 1
    preserve_fields: [ nope, surname ]
    defaults:
      nothere: 1
  local:
    directory: /nonexistent
    filename: x.csv
  run_on_dow: 1,8
  skip_incoming:
    c: [1]
    a: 1
  delete_incoming:
    - field: nope
      value: 1
      comparison: is
  email_results:
    subject: Import done
- name: X
  columns: []
  parameters: {}
  file_transport:
    id: @{[ $transport->id + 1000 ]}
    filename: f
  post_import_transformer: gone
  skip_incoming:
    a: [1]
  skip_incoming:
    b: [2]
- just a string
- name: Z
  columns:
    - static: 1
  parameters:
    matchpoint: nope
  file_transport:
    name: Validator test transport
YAML
    $result = $plugin->validate_configuration($bad);
    my $defined = ' (defined: dob, phone, pin)';
    is_deeply(
        messages($result),
        {
            '/0/columns/0/output'               => "'fone' is not a column the patron import accepts",
            '/0/columns/1/input'                => "'zzz' is not in the configured header (header: a, b)",
            '/0/columns/2/transformer'          => "No transformer named 'nope' is defined in koha-conf.xml$defined",
            '/0/columns/3/static'               => "Patron category 'NOPE' does not exist",
            '/0/columns/4'                      => 'prefix, padding and length only apply to input columns',
            '/0/columns/4/output'               => "Output 'surname' is also set by the column on line 9, only the last one is used",
            '/0/columns/5/mapping/map'          => 'mapping needs a map of input values to output values',
            '/0/columns/6'                      => 'Column needs exactly one of static, input, mapping or transformer (found none)',
            '/0/columns/6/foo'                  => "Unknown key 'foo' in column",
            '/0/columns/7/length'               => 'length must be a whole number',
            '/0/columns/8/output'               => "Output 'branchcode' is also set by the column on line 20, only the last one is used",
            '/0/columns/8/mapping/map/1'        => "Library 'NOWHERE' does not exist",
            '/0/parameters/overwrite_cardnumbers' => "Unknown key 'overwrite_cardnumbers'",
            '/0/parameters/preserve_fields/0'   => "'nope' is not a column the patron import accepts",
            '/0/parameters/defaults/nothere'    => "'nothere' is not a column the patron import accepts",
            '/0/local/directory'                => "Directory '/nonexistent' does not exist on this server",
            '/0/run_on_dow'                     => 'run_on_dow must be weekday numbers separated by commas, Sunday is 0, for example 1,2,3,4,5',
            '/0/skip_incoming/a'                => 'Expected a list, got a number',
            '/0/skip_incoming/c'                => "'c' is not in the configured header (header: a, b)",
            '/0/delete_incoming/0/field'        => "'nope' is not a column the patron import accepts",
            '/0/delete_incoming/0/comparison'   => 'Must be one of equals, not_equals',
            '/0/email_results/to'               => "Missing required key 'to'",
            '/1/name'                           => "Another job is also named 'X' (line 1)",
            '/1/parameters/matchpoint'          => "Missing required key 'matchpoint'",
            '/1/file_transport'                 => 'No file transport found with id ' . ( $transport->id + 1000 ),
            '/1/post_import_transformer'        => "No transformer named 'gone' is defined in koha-conf.xml$defined",
            '/1/skip_incoming'                  => "Duplicate key 'skip_incoming', only the last one is used (first on line 57)",
            '/2'                                => 'Expected a mapping, got text',
            '/3/columns/0'                      => 'Column has no output',
            '/3/parameters/matchpoint'          => "matchpoint 'nope' must be cardnumber, userid or a patron attribute type code",
            '/3/file_transport/filename'        => "Missing required key 'filename'",
        },
        'Every problem is reported once, at its path'
    ) or diag explain messages($result);

    my %line = map { $_->{path} => $_->{line} } @{ $result->{errors} };
    is( $line{'/0/columns/2/transformer'}, 11, 'A column error points at the line of the key' );
    is( $line{'/1/parameters/matchpoint'}, 52, 'A missing key points at the line of its parent' );
    is( $line{'/2'},                       61, 'A job that is not a mapping points at its line' );
    is( $line{'/0/skip_incoming/c'},       42, 'A skip_incoming error points at its line' );

    my %location = map { $_->{path} => $_->{location} } @{ $result->{errors} };
    is( $location{'/0/columns/2/transformer'}, 'job 1 "X" > column 3 > transformer', 'Column errors name the job and column' );
    is( $location{'/1/parameters/matchpoint'}, 'job 2 "X" > parameters/matchpoint',  'Job errors name the job and the key' );
    is( $location{'/2'},                       'job 3',                              'A job without a name is still located' );

    my @lines = map { $_->{line} } @{ $result->{errors} };
    is_deeply( [ sort { $a <=> $b } @lines ], \@lines, 'Errors are sorted by line' );

    # Several file sources are allowed, none is not
    ( my $no_source = $good ) =~ s/  file_transport:\n.*?\n.*?\n//s;
    $result = $plugin->validate_configuration($no_source);
    is_deeply(
        messages($result), { '/0' => 'Job has no file source, add a local, file_transport or sftp block' },
        'A job needs a file source'
    );

    # A multi character separator is an error on its own, and the header is not checked with it
    ( my $backslash_t = $good ) =~ s/sep_char: ","/sep_char: '\\t'/;
    $result = $plugin->validate_configuration($backslash_t);
    is_deeply(
        messages($result),
        { '/0/csv_options/sep_char' => 'sep_char must be a single character, use double quotes ( "\t" ) for a tab' },
        'A backslash t in single quotes is caught'
    );

    # A header that cannot be parsed with the csv options is not checked against
    ( my $tab = $good ) =~ s/sep_char: ","/sep_char: "\\t"/;
    $result = $plugin->validate_configuration($tab);
    is_deeply(
        [ sort map { $_->{path} } @{ $result->{errors} } ],
        [ '/0/columns/1/input', '/0/columns/2/input', '/0/columns/3/mapping/source', '/0/skip_incoming/School' ],
        'With a tab separator the comma separated header is one field, so the input columns are not in it'
    );

    my $attribute_type = $builder->build_object( { class => 'Koha::Patron::Attribute::Types' } );
    ( my $attribute_matchpoint = $good ) =~ s/matchpoint: cardnumber/matchpoint: @{[ $attribute_type->code ]}/;
    $result = $plugin->validate_configuration($attribute_matchpoint);
    is_deeply( $result->{errors}, [], 'An attribute type code is a valid matchpoint' );
    t::lib::Mocks::mock_preference( 'ExtendedPatronAttributes', 0 );
    $result = $plugin->validate_configuration($attribute_matchpoint);
    ok(
        ( grep { $_->{path} eq '/0/parameters/matchpoint' } @{ $result->{errors} } ),
        'An attribute type code is not a valid matchpoint without ExtendedPatronAttributes'
    );
    t::lib::Mocks::mock_preference( 'ExtendedPatronAttributes', 1 );

    build_local_transport( 'Validator test transport', $directory );
    ( my $by_name = $good ) =~ s/id: \d+/name: Validator test transport/;
    $result = $plugin->validate_configuration($by_name);
    is_deeply(
        messages($result), { '/0/file_transport' => "2 file transports are named 'Validator test transport', use id instead" },
        'An ambiguous transport name is reported'
    );

    ( my $with_local = $good ) =~ s/  file:\n/  local:\n    directory: $directory\n    filename: students.csv\n  file:\n/;
    $result = $plugin->validate_configuration($with_local);
    is_deeply( $result->{errors}, [], 'A local directory that exists is accepted next to a file transport' );

    $result = $plugin->validate_configuration( $good, { transformers => { pin => sub { } } } );
    is_deeply(
        messages($result), { '/0/columns/5/transformer' => "No transformer named 'phone' is defined in koha-conf.xml (defined: pin)" },
        'Transformers passed by the caller are used instead of koha-conf.xml'
    );

    $plugin_module->mock( get_transformers => sub { die "ERROR IN dob: syntax error at (eval 1) line 1.\n" } );
    $result = $plugin->validate_configuration($good);
    is_deeply(
        messages($result),
        { '/' => 'The transformers in koha-conf.xml could not be loaded: ERROR IN dob: syntax error at (eval 1) line 1.' },
        'A transformer that does not compile is reported once and the transformer columns are left alone'
    );
    is( $result->{errors}->[0]->{line}, undef, 'A koha-conf.xml problem has no line in the YAML' );

    $plugin_module->mock( get_transformers => sub { return {} } );
    $result = $plugin->validate_configuration($good);
    is_deeply(
        messages($result),
        {
            '/0/columns/5/transformer'   => "No transformer named 'phone' is defined in koha-conf.xml",
            '/0/post_import_transformer' => "No transformer named 'pin' is defined in koha-conf.xml",
        },
        'Without any transformer the message does not list the defined ones'
    );

    $schema->storage->txn_rollback;
};

subtest 'get_transformers() tests' => sub {
    plan tests => 5;

    my $plugin    = Koha::Plugin::Com::ByWaterSolutions::PatronsImporterAdvanced->new( { enable_plugins => 1 } );
    my $directory = tempdir( CLEANUP => 1 );

    write_file( "$directory/koha-conf.xml", <<'XML' );
<yazgfs>
  <config>
    <patrons_importer_advanced>
      <transformers>
        <upper><![CDATA[
          sub {
            my ( $input, $output ) = @_;
            $output->{surname} = uc $input->{"Last Name"};
          };
        ]]></upper>
        <noop>sub { return 1 }</noop>
      </transformers>
    </patrons_importer_advanced>
  </config>
</yazgfs>
XML
    local $ENV{KOHA_CONF} = "$directory/koha-conf.xml";
    my $transformers = $plugin->get_transformers();
    is_deeply( [ sort keys %$transformers ], [qw(noop upper)], 'Every transformer in koha-conf.xml is loaded' );
    isa_ok( $transformers->{upper}, 'CODE', 'A CDATA transformer' );
    my $output = {};
    $transformers->{upper}->( { 'Last Name' => 'hall' }, $output );
    is( $output->{surname}, 'HALL', 'The loaded transformer runs' );

    write_file( "$directory/koha-conf.xml", "<yazgfs><config></config></yazgfs>\n" );
    is_deeply( $plugin->get_transformers(), {}, 'No transformers block gives an empty hash' );

    write_file(
        "$directory/koha-conf.xml",
        "<yazgfs><config><patrons_importer_advanced><transformers><broken>sub { </broken></transformers></patrons_importer_advanced></config></yazgfs>\n"
    );
    throws_ok { $plugin->get_transformers() } qr/^ERROR IN broken: /, 'A transformer that does not compile dies with its name';
};

subtest 'find_file_transport() tests' => sub {
    plan tests => 8;

    $schema->storage->txn_begin;

    my $plugin    = Koha::Plugin::Com::ByWaterSolutions::PatronsImporterAdvanced->new( { enable_plugins => 1 } );
    my $transport = build_local_transport( 'Find test transport', tempdir( CLEANUP => 1 ) );

    throws_ok { $plugin->find_file_transport( {} ) } qr/requires a filename/, 'Dies without a file_transport block';
    throws_ok { $plugin->find_file_transport( { file_transport => { id => $transport->id } } ) }
    qr/requires a filename/, 'Dies without a filename';
    throws_ok { $plugin->find_file_transport( { file_transport => { filename => 'patrons.csv' } } ) }
    qr/requires an id or a name/, 'Dies without an id or a name';
    throws_ok {
        $plugin->find_file_transport( { file_transport => { id => $transport->id + 1000, filename => 'patrons.csv' } } )
    }
    qr/No file transport found with id/, 'Dies for an unknown id';
    throws_ok {
        $plugin->find_file_transport( { file_transport => { name => 'No such transport', filename => 'patrons.csv' } } )
    }
    qr/No file transport found named/, 'Dies for an unknown name';

    my $found = $plugin->find_file_transport( { file_transport => { id => $transport->id, filename => 'patrons.csv' } } );
    is( $found->id, $transport->id, 'Found by id' );
    $found = $plugin->find_file_transport( { file_transport => { name => $transport->name, filename => 'patrons.csv' } } );
    is( $found->id, $transport->id, 'Found by name' );

    build_local_transport( $transport->name, tempdir( CLEANUP => 1 ) );
    throws_ok {
        $plugin->find_file_transport( { file_transport => { name => $transport->name, filename => 'patrons.csv' } } )
    }
    qr/2 file transports are named/, 'Dies for an ambiguous name';

    $schema->storage->txn_rollback;
};
