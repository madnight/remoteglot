#! /usr/bin/perl
#
# There are too many chess modules on CPAN already, so here's another one...
#
use strict;
use warnings;
use MIME::Base64;

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
	$pos->{'white_clock'} = $x[24];
	$pos->{'black_clock'} = $x[25];
	$pos->{'move_num'} = $x[26];
	if ($x[27] =~ /([a-h][1-8])-([a-h][1-8])/) {
		$pos->{'last_move_uci'} = $1 . $2;
	} else {
		$pos->{'last_move_uci'} = undef;
	}
	$pos->{'last_move'} = $x[29];
	$pos->{'prettyprint_cache'} = {};

	bless $pos, $class;
	return $pos;
}

sub start_pos {
	my ($class, $white, $black) = @_;
	$white = "base64:" . MIME::Base64::encode_base64($white);
	$black = "base64:" . MIME::Base64::encode_base64($black);
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
		$ep = (qw(a b c d e f g h))[$col];

		if ($pos->{'toplay'} eq 'B') {
			$ep .= "3";
		} else {
			$ep .= "6";
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

# Returns a compact bit string describing the same data as fen(),
# except for the half-move and full-move clock.
sub bitpacked_fen {
	my $pos = shift;
	my $board = $pos->{'board'}->bitpacked_fen();

	my $bits = "";
	if ($pos->{'toplay'} eq 'W') {
		$bits .= "0";
	} else {
		$bits .= "1";
	}

	$bits .= $pos->{'white_castle_k'};
	$bits .= $pos->{'white_castle_q'};
	$bits .= $pos->{'black_castle_k'};
	$bits .= $pos->{'black_castle_q'};

	my $col = $pos->{'ep_file_num'};
	if ($col == -1) {
		$bits .= "0";
	} else {
		$bits .= "1";
		$bits .= (qw(000 001 010 011 100 101 110 111))[$col];
	}

	return $board . pack('b*', $bits);
}

sub to_json_hash {
	my $pos = shift;
	my $json = { %$pos, fen => $pos->fen() };
	delete $json->{'board'};
	delete $json->{'prettyprint_cache'};
	delete $json->{'black_castle_k'};
	delete $json->{'black_castle_q'};
	delete $json->{'white_castle_k'};
	delete $json->{'white_castle_q'};
	delete $json->{'time_since_100move_rule_reset'};
	if ($json->{'player_w'} =~ /^base64:(.*)$/) {
		$json->{'player_w'} = MIME::Base64::decode_base64($1);
	}
	if ($json->{'player_b'} =~ /^base64:(.*)$/) {
		$json->{'player_b'} = MIME::Base64::decode_base64($1);
	}
	return $json;
}

sub parse_pretty_move {
        my ($pos, $move) = @_;
	return $pos->{'board'}->parse_pretty_move($move, $pos->{'toplay'});
}

sub num_pieces {
	my ($pos) = @_;
	return $pos->{'board'}->num_pieces();
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
	my ($move, $nb) = $pos->{'board'}->prettyprint_move($from_row, $from_col, $to_row, $to_col, $promo);
	$np->{'last_move'} = $move;
	$np->{'last_move_uci'} = Board::move_to_uci_notation($from_row, $from_col, $to_row, $to_col, $promo);

	return bless $np;
}

# Returns a new Position object, and the parsed UCI move.
sub make_pretty_move {
	my ($pos, $move) = @_;

	my ($from_row, $from_col, $to_row, $to_col, $promo) = $pos->parse_pretty_move($move);
	my $uci_move = Board::move_to_uci_notation($from_row, $from_col, $to_row, $to_col, $promo);
	$pos = $pos->make_move($from_row, $from_col, $to_row, $to_col, $promo);
	return ($pos, $uci_move);
}

sub _pos_to_square {
        my ($row, $col) = @_;
        return sprintf("%c%d", ord('a') + $col, 8 - $row);
}

sub apply_uci_pv {
	my ($pos, @pv) = @_;

	my $pvpos = $pos;
	for my $pv_move (@pv) {
		my ($from_row, $from_col, $to_row, $to_col, $promo) = _parse_uci_move($pv_move);
		$pvpos = $pvpos->make_move($from_row, $from_col, $to_row, $to_col, $promo);
	}

	return $pvpos;
}

sub _col_letter_to_num {
	return ord(shift) - ord('a');
}

sub _row_letter_to_num {
	return 7 - (ord(shift) - ord('1'));
}

sub _parse_uci_move {
        my $move = shift;
        my $from_col = _col_letter_to_num(substr($move, 0, 1));
        my $from_row = _row_letter_to_num(substr($move, 1, 1));
        my $to_col   = _col_letter_to_num(substr($move, 2, 1));
        my $to_row   = _row_letter_to_num(substr($move, 3, 1));
        my $promo    = substr($move, 4, 1);
        return ($from_row, $from_col, $to_row, $to_col, $promo);
}

1;
