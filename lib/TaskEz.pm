package TaskEz;

use Modern::Perl;
use Moose;
use namespace::autoclean;
use Method::Signatures;
use Devel::Confess;
use YAML::Tiny;
use DBI;
use File::Path 'make_path';
use File::Basename;
use DateTime;
use SQL::Abstract::Complete;

use Data::Printer alias => 'pdump';

=head1 NAME

TaskEz - The great new TaskEz!

=cut

our $VERSION = '0.01';

=head1 VERSION

Version 0.01

=cut

=head1 SYNOPSIS

Quick summary of what the module does.

Perhaps a little code snippet.

    use TaskEz;

    my $foo = TaskEz->new();
    ...

=head1 EXPORT

A list of functions that can be exported.  You can delete this section
if you don't export anything, such as for a purely object-oriented module.

=head1 SUBROUTINES/METHODS

=head2 function1

=cut

#sub function1 {
#}

=head2 function2

=cut

#sub function2 {
#}

use constant DEFAULT_PRIORITY => 10;

###############################################################

has conf_file => (
    is      => 'ro',
    isa     => 'Str',
    default => "$ENV{HOME}/.eztaskrc"
);

has sql_ez => (
    is      => 'rw',
    lazy    => 1,
    builder => '_build_sql_ez',
);

###############################################################

has _default_db_path => (
    is      => 'ro',
    isa     => 'Str',
    default => "$ENV{HOME}/.eztask.d/tasks"
);

has _conf_cache => (
    is  => 'rw',
    isa => 'HashRef',
);

###############################################################

method get_conf {

    if ( !$self->_conf_cache ) {

        if ( !-e $self->conf_file ) {
            $self->init;
        }

        eval {
            my $yaml = YAML::Tiny->read( $self->conf_file );
            my $conf = $yaml->[0];
            $self->_conf_cache($conf);
        };
        confess $@ if $@;
    }

    return $self->_conf_cache;
}

method get_db_path {

    my $conf = $self->get_conf;

    if ( !$conf->{db}{path} ) {
        return $self->_default_db_path;
    }

    return $conf->{db}{path};
}

method init () {

    if ( !-e $self->conf_file ) {

        my %conf = ( db => { path => $self->_default_db_path } );

        eval {
            my $yaml = YAML::Tiny->new( \%conf );
            $yaml->write( $self->conf_file );
        };
        confess $@ if $@;

        say "created " . $self->conf_file;
    }

    $self->init_db;
}

method done (:$id!) {

    my $done_epoch = time;

    my $sql = qq{
        update tasks
        set 
            state = 'done',
            done_epoch = ?,
            done_flag = 1,
            hold_flag = 0,
            hold_until_epoch = null,
            pri = null
        where 
            rowid = ?
    };

    my $dbh = $self->get_dbh;
    $dbh->do( $sql, undef, $done_epoch, $id );
}

method hold (Num :$id!,
             Num :$days) {

    if ( $self->_is_done( id => $id ) ) {
        $self->my_error("can't put on hold because it is marked as done");
    }

    my %values = (
        state     => 'hold',
        hold_flag => 1,
    );

    if ( defined $days ) {

        my $dt = DateTime->now;
        $dt->add( days => $days );
        $values{hold_until_epoch} = $dt->epoch;
    }
    else {
        $values{hold_until_epoch} = undef;
    }

    my %where = ( rowid => $id );

    my $sql = SQL::Abstract::Complete->new;
    my ( $stmt, @bind ) = $sql->update( 'tasks', \%values, \%where );

    my $dbh = $self->get_dbh;
    $dbh->do( $stmt, undef, @bind );
}

method start (:$id!) {

    my %values = ( state => 'wip' );
    my %where  = ( rowid => $id );

    my $sql = SQL::Abstract::Complete->new;
    my ( $stmt, @bind ) = $sql->update( 'tasks', \%values, \%where );

    my $dbh = $self->get_dbh;
    $dbh->do( $stmt, undef, @bind );
}

method get_row_by_id (Num    :$id!,
                     Object :$dbh) {

    $dbh = $self->get_dbh if !$dbh;

    my $sql = qq{
        select rowid, * from tasks where rowid = $id
    };

    return $dbh->selectrow_hashref($sql);
}

method list (Str        :$state, 
             Str|Undef  :$not_state,
             Num        :$hold_flag,
             ArrayRef   :$order_by = []) {

    my %where;
    $where{state} = $state if $state;
    $where{state} = { '!=', $not_state } if $not_state;
    $where{hold_flag} = $hold_flag if defined $hold_flag;

    my $sql  = SQL::Abstract::Complete->new;
    my @cols = (
        'rowid',
        'pri',
        'title',
        'state',
        "datetime(insert_epoch,     
            'unixepoch', 'localtime') as insert_date",
        "datetime(done_epoch,       
            'unixepoch', 'localtime') as done_date",
        'done_flag',
        "datetime(hold_until_epoch, 
            'unixepoch', 'localtime') as hold_until_date",
        'hold_flag'
    );
    my ( $stmt, @bind ) =
      $sql->select( 'tasks', [@cols], \%where, { order_by => $order_by } );

    my $dbh = $self->get_dbh;
    my $sth = $dbh->prepare($stmt);
    $sth->execute(@bind);

    my @rows;

    while ( my $row = $sth->fetchrow_hashref ) {
        push @rows, $row;
    }

    return \@rows;    # return aref of href
}

method modify (Int       :$id!,
               Int|Undef :$priority,
               Str|Undef :$state,
               Int       :$hold_flag = 0,
               Int       :$hold_until_epoch = 0) {
                   
    my %values;
    $values{pri}              = $priority         if defined $priority;
    $values{state}            = $state            if defined $state;
    $values{hold_until_epoch} = $hold_until_epoch if defined $hold_until_epoch;
    $values{hold_flag}        = $hold_flag;
    
    my %where;
    $where{rowid} = $id;

    my $sql = SQL::Abstract::Complete->new;
    my ( $stmt, @bind ) =
      $sql->update( 'tasks', \%values, \%where );
    
    my $dbh = $self->get_dbh;
    $dbh->do( $stmt, undef, @bind );
}

method add (Str       :$title!, 
            Str       :$state = 'pending',
            Int|Undef :$priority,
            Int       :$epoch = time) {

    my %values;
    $values{title} = $title;
    $values{state} = $state;
    $values{insert_epoch} = $epoch;
     
    if (defined $priority) {
        $values{pri} = $priority;
    }
    else {
        $values{pri} = DEFAULT_PRIORITY;
    }
    
    my $sql = SQL::Abstract::Complete->new;
    my ( $stmt, @bind ) =
      $sql->insert( 'tasks', \%values );
      
    my $dbh = $self->get_dbh;
    $dbh->do( $stmt, undef, @bind );
}

method get_dbh {

    my $db_path = $self->get_db_path;
    $self->debug("db_path: $db_path");

    if ( !-e $db_path ) {
        my $db_dir = dirname($db_path);
        $self->debug("db_dir: $db_dir");
        make_path($db_dir);
    }

    return DBI->connect( "dbi:SQLite:dbname=$db_path", '', '',
        { RaiseError => 1, PrintError => 0, AutoCommit => 1 } );
}

method init_db {

    my $dbh = $self->get_dbh;

    my $sql = qq{
        create table if not exists tasks (
            title        text not null,
            descript     text,
            state        text not null,
            pri          int default 10,
            insert_epoch int not null,
            done_epoch   int,
            done_flag    int default 0,
            CONSTRAINT title_unique UNIQUE (title)
        );  
    };
    my $rc = $dbh->do($sql);

    $self->upgrade_db();
}

method upgrade_db (Object :$dbh) {

    $dbh = $self->get_dbh if !$dbh;

    if ( !$self->_column_exists( dbh => $dbh, col => 'hold_until_epoch' ) ) {

        my $sql = qq{
            alter table tasks
            add hold_until_epoch int
        };
        $dbh->do($sql);
    }

    if ( !$self->_column_exists( dbh => $dbh, col => 'hold_flag' ) ) {

        my $sql = qq{
            alter table tasks
            add hold_flag int
        };
        $dbh->do($sql);
    }
}

method _column_exists (Object :$dbh,
                      Str    :$col!) {

    $dbh = $self->get_dbh if !$dbh;

    my $sql = qq{
        pragma table_info(tasks);
    };

    my $sth = $dbh->prepare($sql);
    $sth->execute;

    my $found = 0;

    while ( my $has_col = ( $sth->fetchrow_array )[1] ) {

        if ( $has_col eq $col ) {
            $found = 1;
        }
    }

    return $found;
}

method _is_done (Num    :$id!,
                 Object :$dbh) {

    $dbh = $self->get_dbh if !$dbh;

    my $sql = SQL::Abstract::Complete->new;
    my ( $stmt, @bind ) =
      $sql->select( 'tasks', ['*'], { rowid => $id } );

    my $href = $dbh->selectrow_hashref( $stmt, undef, @bind );

    # qc
    if ( $href->{done_flag} ) {
        if ( !$href->{done_epoch} ) {
            confess "done_flag is set, but missing done_epoch";
        }
    }
    else {
        if ( $href->{done_epoch} ) {
            confess "done_flag is not set, but done_epoch is";
        }
    }

    if ( $href->{done_flag} ) {
        return 1;
    }

    return 0;
}

method debug ($msg!) {

    if ( $ENV{DEBUG} ) {
        chomp $msg;
        print STDERR "[DEBUG] $msg\n";
    }
}

method my_error (@args) {

    print STDERR "ERROR: @args\n";
    exit 2;
}

################################################################

=head1 AUTHOR

John Gravatt, C<< <john at gravatt.org> >>

=head1 BUGS

Please report any bugs or feature requests to C<bug-taskez at rt.cpan.org>, or through
the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=TaskEz>.  I will be notified, and then you'll
automatically be notified of progress on your bug as I make changes.




=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc TaskEz


You can also look for information at:

=over 4

=item * RT: CPAN's request tracker (report bugs here)

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=TaskEz>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/TaskEz>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/TaskEz>

=item * Search CPAN

L<http://search.cpan.org/dist/TaskEz/>

=back


=head1 ACKNOWLEDGEMENTS


=head1 LICENSE AND COPYRIGHT

Copyright 2018 John Gravatt.

This program is free software; you can redistribute it and/or modify it
under the terms of the the Artistic License (2.0). You may obtain a
copy of the full license at:

L<http://www.perlfoundation.org/artistic_license_2_0>

Any use, modification, and distribution of the Standard or Modified
Versions is governed by this Artistic License. By using, modifying or
distributing the Package, you accept this license. Do not use, modify,
or distribute the Package, if you do not accept this license.

If your Modified Version has been derived from a Modified Version made
by someone other than you, you are nevertheless required to ensure that
your Modified Version complies with the requirements of this license.

This license does not grant you the right to use any trademark, service
mark, tradename, or logo of the Copyright Holder.

This license includes the non-exclusive, worldwide, free-of-charge
patent license to make, have made, use, offer to sell, sell, import and
otherwise transfer the Package with respect to any patent claims
licensable by the Copyright Holder that are necessarily infringed by the
Package. If you institute patent litigation (including a cross-claim or
counterclaim) against any party alleging that the Package constitutes
direct or contributory patent infringement, then this Artistic License
to you shall terminate on the date that such litigation is filed.

Disclaimer of Warranty: THE PACKAGE IS PROVIDED BY THE COPYRIGHT HOLDER
AND CONTRIBUTORS "AS IS' AND WITHOUT ANY EXPRESS OR IMPLIED WARRANTIES.
THE IMPLIED WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR
PURPOSE, OR NON-INFRINGEMENT ARE DISCLAIMED TO THE EXTENT PERMITTED BY
YOUR LOCAL LAW. UNLESS REQUIRED BY LAW, NO COPYRIGHT HOLDER OR
CONTRIBUTOR WILL BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, OR
CONSEQUENTIAL DAMAGES ARISING IN ANY WAY OUT OF THE USE OF THE PACKAGE,
EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.


=cut

1;    # End of TaskEz
