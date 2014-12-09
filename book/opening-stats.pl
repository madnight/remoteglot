#! /usr/bin/perl
use strict;
use warnings;
use CGI;
use JSON::XS;
use lib '..';
use Position;
use ECO;

#ECO::unpersist();

my $cgi = CGI->new;
my $fen = $ARGV[0];
my $pos = Position->from_fen($fen);
my $hex = unpack('H*', $pos->bitpacked_fen);
system("./binlookup", "./open.mtbl", $hex);

