#! /usr/bin/perl
#
# There are too many chess modules on CPAN already, so here's another one...
#
use strict;
use warnings;

require 'Board.pm';

package Position;

# Takes in a FICS style 12-type position.
sub new {
	my ($class, $str) = @_;
	my $pos = {};
	my (@x) = split / /, $str;

	$pos->{'board'} = Board->new(@x[1..8]);
	$pos->{'toplay'} = $x[9];
	$pos->{'ep_file_num'} = $x[10];
	$pos->{'white_castle_k'} = $x[11];
	$pos->{'white_castle_q'} = $x[12];
	$pos->{'black_castle_k'} = $x[13];
	$pos->{'black_castle_q'} = $x[14];
	$pos->{'time_since_100move_rule_reset'} = $x[15];
	$pos->{'player_w'} = $x[17];
	$pos->{'player_b'} = $x[18];
	$pos->{'player_w'} =~ s/^W?[FCIG]M//;
	$pos->{'player_b'} =~ s/^W?[FCIG]M//;
	$pos->{'move_num'} = $x[26];
	$pos->{'last_move'} = $x[29];

	bless $pos, $class;
	return $pos;
}

sub fen {
	my $pos = shift;

	# the board itself
	my $fen = $pos->{'board'}->fen();

	# white/black to move
	$fen .= " ";
	$fen .= lc($pos->{'toplay'});

	# castling
	my $castling = "";
	$castling .= "K" if ($pos->{'white_castle_k'} == 1);
	$castling .= "Q" if ($pos->{'white_castle_q'} == 1);
	$castling .= "k" if ($pos->{'black_castle_k'} == 1);
	$castling .= "q" if ($pos->{'black_castle_q'} == 1);
	$castling = "-" if ($castling eq "");
	# $castling = "-"; # chess960
	$fen .= " ";
	$fen .= $castling;

	# en passant
	my $ep = "-";
	if ($pos->{'ep_file_num'} != -1) {
		my $col = $pos->{'ep_file_num'};
		my $nep = (qw(a b c d e f g h))[$col];

		if ($pos->{'toplay'} eq 'B') {
			$nep .= "3";
		} else {
			$nep .= "6";
		}

		#
		# Showing the en passant square when actually no capture can be made
		# seems to confuse at least Rybka. Thus, check if there's actually
		# a pawn of the opposite side that can do the en passant move, and if
		# not, just lie -- it doesn't matter anyway. I'm unsure what's the
		# "right" thing as per the standard, though.
		#
		if ($pos->{'toplay'} eq 'B') {
			$ep = $nep if ($col > 0 && $pos->{'board'}[4][$col-1] eq 'p');
			$ep = $nep if ($col < 7 && $pos->{'board'}[4][$col+1] eq 'p');
		} else {
			$ep = $nep if ($col > 0 && $pos->{'board'}[3][$col-1] eq 'P');
			$ep = $nep if ($col < 7 && $pos->{'board'}[3][$col+1] eq 'P');
		}
	}
	$fen .= " ";
	$fen .= $ep;

	# half-move clock
	$fen .= " ";
	$fen .= $pos->{'time_since_100move_rule_reset'};

	# full-move clock
	$fen .= " ";
	$fen .= $pos->{'move_num'};

	return $fen;
}

sub to_json_hash {
	my $pos = shift;
	return { %$pos, board => undef, fen => $pos->fen() };
}

1;
