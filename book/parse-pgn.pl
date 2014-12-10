#! /usr/bin/perl
use Chess::PGN::Parse;
use Data::Dumper;
use strict;
use warnings;
use lib '..';
use Position;
use Engine;
use ECO;

my $TEXTOUT = 0;
my $BINOUT = 1;

ECO::init();

my ($filename, $my_num, $tot_num) = @ARGV;

my $pgn = Chess::PGN::Parse->new($filename)
	or die "can't open $filename\n";
my $game_num = 0;
while ($pgn->read_game()) {
	next unless ($game_num++ % $tot_num == $my_num);
	my $tags = $pgn->tags();
#	next unless $tags->{'WhiteElo'} >= 2000;
#	next unless $tags->{'BlackElo'} >= 2000;
	$pgn->quick_parse_game;
	my $pos = Position->start_pos($pgn->white, $pgn->black);
	my $result = $pgn->result;
	my $binresult;
	if ($result eq '1-0') {
		$binresult = chr(0);
	} elsif ($result eq '1/2-1/2') {
		$binresult = chr(1);
	} elsif ($result eq '0-1') {
		$binresult = chr(2);
	} else {
		die "Unknown result $result";
	}
	my $binwhiteelo = pack('l', $tags->{'WhiteElo'});
	my $binblackelo = pack('l', $tags->{'BlackElo'});
	my $moves = $pgn->moves;
	my $opening = ECO::get_opening_num($pos);
#	print STDERR $pgn->white, " ", $pgn->black, "\n";
	for (my $i = 0; $i + 1 < scalar @$moves; ++$i) {
		my ($from_row, $from_col, $to_row, $to_col, $promo) = $pos->parse_pretty_move($moves->[$i]);
		my $next_move = $moves->[$i];
		my $bpfen = $pos->bitpacked_fen;
		my $fen = $pos->fen;
		$opening = ECO::get_opening_num($pos) // $opening;
		print "$fen $next_move $result $opening\n" if $TEXTOUT;
		if ($BINOUT) {
			print chr(length($bpfen) + length($next_move)) . $bpfen . $next_move;
			print $binresult . $binwhiteelo . $binblackelo;
			print pack('l', $opening);
		}
		$pos = $pos->make_move($from_row, $from_col, $to_row, $to_col, $promo, $moves->[$i]);
	}
}
