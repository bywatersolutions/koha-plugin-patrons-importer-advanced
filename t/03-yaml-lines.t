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
}

use Test::More tests => 4;
use Test::NoWarnings;

use Koha::Plugin::Com::ByWaterSolutions::PatronsImporterAdvanced::YamlLines
  qw(outline line_for_path duplicate_keys);

my $yaml = <<'YAML';
---
# Jobs for the test
- name: A
  file:
    header: |
      first_name,last_name
      dup: 1
      dup: 2
  columns:
    - output: privacy
      static: 0
    - mapping:
        map:
          '0': K
          "01": 1ST
          Graduation Year: GRAD
        source: Grade Level
      output: categorycode
    - name: DOB  # a label
      transformer: dob
  skip_incoming:
    school_id: ['973', '102']
  parameters:
    matchpoint: cardnumber
- name: B
  columns:
  - output: surname
    input: Last Name
  - input: x
    output: firstname
  skip_incoming:
    a: [1]
  skip_incoming:
    b: [2]
YAML

subtest 'outline() tests' => sub {
    plan tests => 7;

    my $root = outline($yaml);
    is( scalar @{ $root->{children} }, 2, 'two top level items' );

    my $job_a = $root->{children}->[0];
    is( $job_a->{kind}, 'seq', 'top level items are sequence items' );
    is( $job_a->{line}, 3,     'first job starts on line 3' );
    is_deeply(
        [ map { $_->{key} } @{ $job_a->{children} } ],
        [qw(name file columns skip_incoming parameters)],
        'the inline key after the dash and the keys below it are children of the item'
    );

    my ($header) = grep { $_->{key} eq 'header' } @{ $job_a->{children}->[1]->{children} };
    is( scalar @{ $header->{children} }, 0, 'the lines of a block scalar are not treated as keys' );

    my ($columns_b) = grep { $_->{key} eq 'columns' } @{ $root->{children}->[1]->{children} };
    is( scalar @{ $columns_b->{children} }, 2, 'items at the same indent as their key belong to the key' );

    is( scalar @{ outline(q{})->{children} }, 0, 'empty text gives an empty outline' );
};

subtest 'line_for_path() tests' => sub {
    plan tests => 20;

    my %expected = (
        '/0'                                      => 3,
        '/0/name'                                 => 3,
        '/0/file/header'                          => 5,
        '/0/file/header/dup'                      => 5,
        '/0/columns'                              => 9,
        '/0/columns/0'                            => 10,
        '/0/columns/0/static'                     => 11,
        '/0/columns/1/mapping/map/0'              => 14,
        '/0/columns/1/mapping/map/01'             => 15,
        '/0/columns/1/mapping/map/Graduation Year' => 16,
        '/0/columns/1/output'                     => 18,
        '/0/columns/2/transformer'                => 20,
        '/0/skip_incoming/school_id/1'            => 22,
        '/0/parameters/matchpoint'                => 24,
        '/0/parameters/nothere'                   => 23,
        '/1/columns/0/input'                      => 28,
        '/1/columns/1/output'                     => 30,
        '/1/skip_incoming'                        => 33,
    );
    foreach my $path ( sort keys %expected ) {
        is( line_for_path( $yaml, $path ), $expected{$path}, "$path is on line $expected{$path}" );
    }

    is( line_for_path( $yaml, '/5' ), undef, 'a missing top level item has no line' );

    ( my $crlf = $yaml ) =~ s/\n/\r\n/g;
    is( line_for_path( $crlf, '/1/columns/1/output' ), 30, 'CRLF text gives the same lines' );
};

subtest 'duplicate_keys() tests' => sub {
    plan tests => 2;

    is_deeply(
        duplicate_keys($yaml),
        [ { path => '/1', key => 'skip_incoming', line => 33, first_line => 31 } ],
        'the repeated key is reported with both lines, block scalar lines are ignored'
    );

    is_deeply( duplicate_keys( outline("a: 1\nb:\n  c: 2\n") ), [], 'no duplicates when every key is unique' );
};
