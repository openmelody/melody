# Movable Type (r) Open Source (C) 2001-2011 Six Apart, Ltd.
# This program is distributed under the terms of the
# GNU General Public License, version 2.
#
# $Id$

package AtomPub::Atom;
use strict;

package AtomPub::Atom::Content;
use base qw( XML::Atom::Content );

__PACKAGE__->mk_attr_accessors(qw( src ));


package AtomPub::Atom::Entry;
use base qw( XML::Atom::Entry );

use MT::I18N qw( encode_text );
use XML::Atom qw( LIBXML );


sub _create_issued {
    my ( $ts, $blog ) = @_;
    my @co_list = unpack 'A4A2A2A2A2A2', $ts;
    my $co = sprintf "%04d-%02d-%02dT%02d:%02d:%02d", @co_list;
    my $epoch = Time::Local::timegm(
                                     $co_list[5],     $co_list[4],
                                     $co_list[3],     $co_list[2],
                                     $co_list[1] - 1, $co_list[0]
    );
    my $so = $blog->server_offset;
    $so += 1 if ( localtime $epoch )[8];
    $so = sprintf( "%s%02d:%02d",
                   $so < 0 ? '-' : '+',
                   abs( int $so ),
                   abs( $so - int $so ) * 60 );
    $co .= $so;
}

sub new_with_entry {
    my $class = shift;
    my ( $entry, %param ) = @_;
    my $rfc_compat = $param{Version} && $param{Version} eq '1';

    my $atom = $class->new(%param);
    $atom->title( encode_text( $entry->title, undef, 'utf-8' ) );
    $atom->summary( encode_text( $entry->excerpt, undef, 'utf-8' ) );

    # Build our own XML::Atom::Content so we always get 'html' back instead
    # of XML::Atom's guess of HTML or XHTML.
    my $content = XML::Atom::Content->new();

    # TODO: apply entry's text filters! otherwise this doesn't work for e.g. Markdown entries
    my $html = $entry->text;
    my $text
      = LIBXML
      ? XML::LibXML::Text->new($html)
      : XML::XPath::Node::Text->new($html);
    $content->elem->appendChild($text);
    if ($rfc_compat) {
        $content->type('html');
    }
    else {
        $content->type('text/html');
        $content->mode('escaped');
    }
    $atom->content($content);

    my $mt_author = MT::Author->load( $entry->author_id ) or return undef;
    my $atom_author = new XML::Atom::Person(%param);
    $atom_author->name( encode_text( $mt_author->nickname, undef, 'utf-8' ) );
    $atom_author->email( $mt_author->email ) if $mt_author->email;
    my $author_url_field = $rfc_compat ? 'uri' : 'url';
    $atom_author->$author_url_field( $mt_author->url ) if $mt_author->url;
    $atom->author($atom_author);

    for my $cat ( @{ $entry->categories } ) {
        my $atom_cat = XML::Atom::Category->new(%param);
        $atom_cat->term( $cat->label );
        $atom->add_category($atom_cat);
    }

    my $blog = MT::Blog->load( $entry->blog_id ) or return undef;
    my $co = _create_issued( $entry->authored_on, $blog );
    $atom->issued($co);
    my $upd = $entry->modified_on;
    if ($upd) {
        $atom->updated( _create_issued( $upd, $blog ) );
    }
    else {
        $atom->updated($co);
    }
    $atom->add_link( {
                       rel  => 'alternate',
                       type => 'text/html',
                       href => $entry->permalink
                     }
    );
    my ($host) = $blog->site_url =~ m!^https?://([^/:]+)(:\d+)?/!;

    unless ( $entry->atom_id ) {

        # atom_id is not there - probably because
        # the entry is in HOLD state
        $entry->atom_id( $entry->make_atom_id() );

        # call update directly because MT::Entry::save
        # is overkill for the purpose.
        $entry->update if $entry->atom_id();
    }

    $atom->id( $entry->atom_id );

    #$atom->draft('true') if $entry->status != MT::Entry::RELEASE();

    $atom;
} ## end sub new_with_entry

sub new_with_asset {
    my $class = shift;
    my ( $asset, %param ) = @_;
    my $blog = MT::Blog->load( $asset->blog_id ) or return undef;

    my $atom = $class->new(%param);
    $atom->title( $asset->label );
    $atom->summary( $asset->description );
    $atom->issued( _create_issued( $asset->created_on, $blog ) );

    my $content = AtomPub::Atom::Content->new;
    $content->type( $asset->mime_type );
    $content->src( $asset->url() );
    $atom->set( $atom->ns, 'content', $content );

    my ($host) = $blog->site_url =~ m!^https?://([^/:]+)(:\d+)?/!;
    $atom->id( 'tag:' . $host . ':asset-' . $asset->id );

    return $atom;
} ## end sub new_with_asset

sub new_with_comment {
    my $class = shift;
    my ( $comment, %param ) = @_;
    my $rfc_compat = $param{Version} && $param{Version} eq '1';

    my $entry = $comment->entry;
    return unless $entry;
    my $blog = $comment->blog;
    return unless $blog;

    my $atom = $class->new(%param);
    $atom->title( encode_text( $entry->title, undef, 'utf-8' ) );
    $atom->content( encode_text( $comment->text, undef, 'utf-8' ) );

    # Old Atom API gets application/xhtml+xml for compatibility -- but why
    # do we say it's that when all we're guaranteed is it's an opaque blob
    # of text? So use 'html' for new RFC compatible output.
    # XML::Atom::Content intelligently determines content-type for rfc compat.
    unless ($rfc_compat) {
        $atom->content->type('application/xhtml+xml');
    }

    my $atom_author = new XML::Atom::Person(%param);
    $atom_author->name( encode_text( $comment->author, undef, 'utf-8' ) );
    $atom_author->email( $comment->email ) if $comment->email;
    my $author_url_field = $rfc_compat ? 'uri' : 'url';
    $atom_author->$author_url_field( $comment->url ) if $comment->url;
    $atom->author($atom_author);

    my $co = _create_issued( $comment->created_on, $blog );
    $atom->issued($co);
    my $upd = $comment->modified_on;
    if ($upd) {
        $atom->updated( _create_issued( $upd, $blog ) );
    }
    else {
        $atom->updated($co);
    }
    $atom->add_link( {
                     rel  => 'alternate',
                     type => 'text/html',
                     href => $entry->archive_url . '#comment-' . $comment->id
                   }
    );
    my ($host) = $blog->site_url =~ m!^https?://([^/:]+)(:\d+)?/!;

    $atom->id( $entry->atom_id . '/' . $comment->id );
    $atom;
} ## end sub new_with_comment

1;
__END__

=head1 NAME

AtomPub::Atom

=head1 AUTHOR & COPYRIGHT

Please see AtomPub's C<LICENSE> file.

=cut
