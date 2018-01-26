#!perl -T
use 5.006;
use strict;
use warnings;
use Test::More;

plan tests => 1;

BEGIN {
    use_ok( 'TaskEz' ) || print "Bail out!\n";
}

diag( "Testing TaskEz $TaskEz::VERSION, Perl $], $^X" );
