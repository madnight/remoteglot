#! /usr/bin/perl
use strict;
use warnings;
use CGI;
use JSON::XS;
use lib '..';
use Position;
use ECO;

ECO::unpersist("../book/openings.txt");

my $cgi = CGI->new;
my $fen = $cgi->param('fen');
my $pos = Position->from_fen($fen);
my $hex = unpack('H*', $pos->bitpacked_fen);
open my $fh, "-|", "../book/binlookup", "../book/open.mtbl", $hex
	or die "../book/binlookup: $!";

my $opening;

my @moves = ();
while (<$fh>) {
	chomp;
	my ($move, $white, $draw, $black, $opening_num, $white_avg_elo, $black_avg_elo, $num_elo) = split;
	push @moves, {
		move => $move,
		white => $white * 1,
		draw => $draw * 1,
		black => $black * 1,
		white_avg_elo => $white_avg_elo * 1,
		black_avg_elo => $black_avg_elo * 1,
		num_elo => $num_elo * 1
	};
	$opening = $ECO::openings[$opening_num];
}
close $fh;

@moves = sort { num($b) <=> num($a) } @moves;

print $cgi->header(-type=>'application/json');
print JSON::XS::encode_json({ moves => \@moves, opening => $opening });

sub num {
	my $x = shift;
	return $x->{'white'} + $x->{'draw'} + $x->{'black'};
}
