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

sub start_pos {
	my ($class, $white, $black) = @_;
	return $class->new("<12> rnbqkbnr pppppppp -------- -------- -------- -------- PPPPPPPP RNBQKBNR W -1 1 1 1 1 0 dummygamenum $white $black -2 dummytime dummyincrement 39 39 dummytime dummytime 1 none (0:00) none 0 0 0");
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

sub parse_pretty_move {
        my ($pos, $move) = @_;
	return $pos->{'board'}->parse_pretty_move($move, $pos->{'toplay'});
}

# Returns a new Position object.
sub make_move {
        my ($pos, $from_row, $from_col, $to_row, $to_col, $promo) = @_;

	my $from_square = _pos_to_square($from_row, $from_col);
	my $to_square = _pos_to_square($to_row, $to_col);

	my $np = {};
	$np->{'board'} = $pos->{'board'}->make_move($from_row, $from_col, $to_row, $to_col, $promo);
	if ($pos->{'toplay'} eq 'W') {
		$np->{'toplay'} = 'B';
		$np->{'move_num'} = $pos->{'move_num'};
	} else {
		$np->{'toplay'} = 'W';
		$np->{'move_num'} = $pos->{'move_num'} + 1;
	}

	my $piece = $pos->{'board'}[$from_row][$from_col];
	my $dest_piece = $pos->{'board'}[$to_row][$to_col];

	# Find out if this was a two-step pawn move.
	if (lc($piece) eq 'p' && abs($from_row - $to_row) == 2) {
		$np->{'ep_file_num'} = $from_col;
	} else {
		$np->{'ep_file_num'} = -1;
	}

	# Castling rights.
	$np->{'white_castle_k'} = $pos->{'white_castle_k'};
	$np->{'white_castle_q'} = $pos->{'white_castle_q'};
	$np->{'black_castle_k'} = $pos->{'black_castle_k'};
	$np->{'black_castle_q'} = $pos->{'black_castle_q'};
	if ($piece eq 'K') {
		$np->{'white_castle_k'} = 0;
		$np->{'white_castle_q'} = 0;
	} elsif ($piece eq 'k') {
		$np->{'black_castle_k'} = 0;
		$np->{'black_castle_q'} = 0;
	} elsif ($from_square eq 'a1' || $to_square eq 'a1') {
		$np->{'white_castle_q'} = 0;
	} elsif ($from_square eq 'h1' || $to_square eq 'h1') {
		$np->{'white_castle_k'} = 0;
	} elsif ($from_square eq 'a8' || $to_square eq 'a8') {
		$np->{'black_castle_q'} = 0;
	} elsif ($from_square eq 'h8' || $to_square eq 'h8') {
		$np->{'black_castle_k'} = 0;
	}

	# 50-move rule.
	if (lc($piece) eq 'p' || $dest_piece ne '-') {
		$np->{'time_since_100move_rule_reset'} = 0;
	} else {
		$np->{'time_since_100move_rule_reset'} = $pos->{'time_since_100move_rule_reset'} + 1;
	}
	$np->{'player_w'} = $pos->{'player_w'};
	$np->{'player_b'} = $pos->{'player_b'};
	$np->{'last_move'} = '(move)';  # FIXME
	return bless $np;
}

sub _pos_to_square {
        my ($row, $col) = @_;
        return sprintf("%c%d", ord('a') + $col, 8 - $row);
}

1;