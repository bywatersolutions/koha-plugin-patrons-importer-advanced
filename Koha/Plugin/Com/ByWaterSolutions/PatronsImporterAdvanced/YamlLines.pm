package Koha::Plugin::Com::ByWaterSolutions::PatronsImporterAdvanced::YamlLines;

use Modern::Perl;

use base qw(Exporter);
our @EXPORT_OK = qw(outline line_for_path duplicate_keys pointer_segment pointer_segments);

=head1 NAME

Koha::Plugin::Com::ByWaterSolutions::PatronsImporterAdvanced::YamlLines - find the line a YAML value came from

=head1 DESCRIPTION

YAML::XS only reports line numbers for syntax errors, so this walks the text by indentation to
find where a parsed value was written. It follows the block style YAML::XS::Dump writes and
people hand edit: '- ' items, 'key: value' lines, quoted keys, comments and block scalars. Flow
collections, anchors and multi-document files are not followed, the nearest parent line is
returned instead.

=head2 Functions

=head3 outline

    my $root = outline($text);

Returns the root node of the text. Every node is { line, indent, kind, key, children }, kind is 'seq' for a '- ' item and 'map' for a 'key:' line.

=cut

sub outline {
    my ($text) = @_;

    my $root  = { line => 0, indent => -1, kind => 'root', children => [] };
    my @stack = ($root);

    my $line_number = 0;
    foreach my $line ( split /\r?\n/, $text // q{} ) {
        $line_number++;
        next if $line =~ /^\s*(?:#|$)/;
        next if $line =~ /^(?:---|\.\.\.|%)/;

        my ($spaces) = $line =~ /^( *)/;
        my $indent  = length $spaces;
        my $content = substr( $line, $indent );

        # The lines of a block scalar are not structure, whatever they look like
        next if $stack[-1]->{block_scalar} && $indent > $stack[-1]->{indent};

        my $is_item = $content =~ s/^-(?:[ ]+|$)//;
        my ( $key, $value ) = _key_and_value($content);
        next unless $is_item || defined $key;

        # Close the nodes this line is not nested in. A '- ' item at the same indent as a
        # 'key:' line still belongs to that key as long as the key has no other kind of child.
        while ( @stack > 1 ) {
            my $top = $stack[-1];
            last if $top->{indent} < $indent;
            last
              if $is_item
              && $top->{indent} == $indent
              && $top->{kind} eq 'map'
              && !grep { $_->{kind} ne 'seq' } @{ $top->{children} };
            pop @stack;
        }

        if ($is_item) {
            my $item = { line => $line_number, indent => $indent, kind => 'seq', children => [] };
            push( @{ $stack[-1]->{children} }, $item );
            push( @stack, $item );

            # Whatever follows the dash is nested in the item
            $indent = length($line) - length($content);
        }

        if ( defined $key ) {
            my $node = {
                line         => $line_number,
                indent       => $indent,
                kind         => 'map',
                key          => $key,
                children     => [],
                block_scalar => ( $value =~ /^[|>]/ ? 1 : 0 ),
            };
            push( @{ $stack[-1]->{children} }, $node );
            push( @stack, $node );
        }
    }

    return $root;
}

=head3 line_for_path

    my $line = line_for_path( $text_or_outline, '/0/columns/3/output' );

Returns the 1-based line of the value at the given JSON pointer, or of the nearest parent that could be found. Returns undef when nothing matched.

=cut

sub line_for_path {
    my ( $root, $path ) = @_;
    $root = outline($root) unless ref $root;

    my $node = $root;
    foreach my $segment ( pointer_segments($path) ) {
        my $child = _child( $node, $segment );
        last unless $child;
        $node = $child;
    }

    return $node->{line} || undef;
}

=head3 duplicate_keys

    my $duplicates = duplicate_keys($text_or_outline);

Returns the keys that appear more than once in the same mapping as [ { path, key, line, first_line } ], path being the mapping's JSON pointer.

=cut

sub duplicate_keys {
    my ($root) = @_;
    $root = outline($root) unless ref $root;

    my @duplicates;
    _find_duplicates( $root, q{}, \@duplicates );

    return \@duplicates;
}

sub _find_duplicates {
    my ( $node, $path, $duplicates ) = @_;

    my %first_line;
    my $index = 0;
    foreach my $child ( @{ $node->{children} } ) {
        my $child_path;
        if ( $child->{kind} eq 'seq' ) {
            $child_path = "$path/" . $index++;
        }
        else {
            my $key = $child->{key};
            if ( exists $first_line{$key} ) {
                push(
                    @$duplicates,
                    { path => $path || '/', key => $key, line => $child->{line}, first_line => $first_line{$key} }
                );
            }
            else {
                $first_line{$key} = $child->{line};
            }
            $child_path = "$path/" . pointer_segment($key);
        }
        _find_duplicates( $child, $child_path, $duplicates );
    }
}

sub _child {
    my ( $node, $segment ) = @_;

    my @children = @{ $node->{children} };
    if ( $segment =~ /^\d+$/ ) {
        my @items = grep { $_->{kind} eq 'seq' } @children;
        return $items[$segment] if @items;
    }

    # YAML::XS keeps the last of duplicate keys, so point at that one
    my ($child) = reverse grep { $_->{kind} eq 'map' && $_->{key} eq $segment } @children;

    return $child;
}

sub _key_and_value {
    my ($content) = @_;

    my $plain = qr/[^\s"'#\[\{][^:#]*?/;
    if ( $content =~ /^(?:"((?:[^"\\]|\\.)*)"|'((?:[^']|'')*)'|($plain))\s*:(?:\s+(.*))?$/ ) {
        my $key = $1 // $2 // $3;
        $key =~ s/''/'/g if defined $2;
        return ( $key, $4 // q{} );
    }

    return;
}

sub pointer_segments {
    my ($path) = @_;

    my @segments = split( m{/}, $path // q{}, -1 );
    shift @segments;

    return map { my $segment = $_; $segment =~ s{~1}{/}g; $segment =~ s/~0/~/g; $segment } @segments;
}

sub pointer_segment {
    my ($key) = @_;

    $key =~ s/~/~0/g;
    $key =~ s{/}{~1}g;

    return $key;
}

1;
