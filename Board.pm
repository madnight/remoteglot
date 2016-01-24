#! /usr/bin/perl
#
# There are too many chess modules on CPAN already, so here's another one...
#
use strict;
use warnings;

package Board;

sub new {
	my ($class, @rows) = @_;
	my $board = [];

	for my $row (0..7) {
		for my $col (0..7) {
			$board->[$row][$col] = substr($rows[$row], $col, 1);
		}
	}

	return bless $board;
}

sub clone {
	my ($board) = shift;
	my $nb = [];

	for my $row (0..7) {
		$nb->[$row] = [ @{$board->[$row]} ];
	}

	return bless $nb;
}

# Returns a new board.
sub make_move {
	my ($board, $from_row, $from_col, $to_row, $to_col, $promo) = @_;
	my $move = move_to_uci_notation($from_row, $from_col, $to_row, $to_col, $promo);
	my $piece = $board->[$from_row][$from_col];
	my $nb = $board->clone();

	if ($piece eq '-') {
		die "Invalid move $move";
	}

	# white short castling
	if ($move eq 'e1g1' && $piece eq 'K') {
		# king
		$nb->[7][4] = '-';
		$nb->[7][6] = $piece;

		# rook
		$nb->[7][7] = '-';
		$nb->[7][5] = 'R';

		return $nb;
	}

	# white long castling
	if ($move eq 'e1c1' && $piece eq 'K') {
		# king
		$nb->[7][4] = '-';
		$nb->[7][2] = $piece;

		# rook
		$nb->[7][0] = '-';
		$nb->[7][3] = 'R';

		return $nb;
	}

	# black short castling
	if ($move eq 'e8g8' && $piece eq 'k') {
		# king
		$nb->[0][4] = '-';
		$nb->[0][6] = $piece;

		# rook
		$nb->[0][7] = '-';
		$nb->[0][5] = 'r';

		return $nb;
	}

	# black long castling
	if ($move eq 'e8c8' && $piece eq 'k') {
		# king
		$nb->[0][4] = '-';
		$nb->[0][2] = $piece;

		# rook
		$nb->[0][0] = '-';
		$nb->[0][3] = 'r';

		return $nb;
	}

	# check if the from-piece is a pawn
	if (lc($piece) eq 'p') {
		# attack?
		if ($from_col != $to_col) {
			# en passant?
			if ($board->[$to_row][$to_col] eq '-') {
				if ($piece eq 'p') {
					$nb->[$to_row - 1][$to_col] = '-';
				} else {
					$nb->[$to_row + 1][$to_col] = '-';
				}
			}
		}
		if (defined($promo) && $promo ne '') {
			if ($piece eq 'p') {
				$piece = lc($promo);
			} else {
				$piece = uc($promo);
			}
		}
	}

	# update the board
	$nb->[$from_row][$from_col] = '-';
	$nb->[$to_row][$to_col] = $piece;

	return $nb;
}

sub _pos_to_square {
	my ($row, $col) = @_;
	return sprintf("%c%d", ord('a') + $col, 8 - $row);
}

sub _col_letter_to_num {
        return ord(shift) - ord('a');
}

sub _row_letter_to_num {
        return 7 - (ord(shift) - ord('1'));
}

sub _square_to_pos {
	my ($square) = @_;
	$square =~ /^([a-h])([1-8])$/ or die "Invalid square $square";	
	return (_row_letter_to_num($2), _col_letter_to_num($1));
}

sub move_to_uci_notation {
	my ($from_row, $from_col, $to_row, $to_col, $promo) = @_;
	$promo //= "";
	return _pos_to_square($from_row, $from_col) . _pos_to_square($to_row, $to_col) . $promo;
}

# Note: This is in general not a validation that the move is actually allowed
# (e.g. you can castle even though you're in check).
sub parse_pretty_move {
	my ($board, $move, $toplay) = @_;

	# Strip check or mate
	$move =~ s/[+#]$//;

	if ($move eq '0-0' or $move eq 'O-O') {
		if ($toplay eq 'W') {
			return (_square_to_pos('e1'), _square_to_pos('g1'));
		} else {
			return (_square_to_pos('e8'), _square_to_pos('g8'));
		}
	} elsif ($move eq '0-0-0' or $move eq 'O-O-O') {
		if ($toplay eq 'W') {
			return (_square_to_pos('e1'), _square_to_pos('c1'));
		} else {
			return (_square_to_pos('e8'), _square_to_pos('c8'));
		}
	}

	# Parse promo
	my $promo;
	if ($move =~ s/=?([QRNB])$//) {
		$promo = $1;
	}

	$move =~ /^([KQRBN])?([a-h])?([1-8])?x?([a-h][1-8])$/ or die "Invalid move $move";
	my $piece = $1;
	my $from_col = defined($2) ? _col_letter_to_num($2) : undef;
	my $from_row = defined($3) ? _row_letter_to_num($3) : undef;
	if (!defined($piece) && (!defined($from_col) || !defined($from_row))) {
		$piece = 'P';
	}
	my ($to_row, $to_col) = _square_to_pos($4);
	
	# Find all possible from-squares that could have been meant.
	my @squares = ();
	my $side = 'K';
	if ($toplay eq 'B') {
		$piece = lc($piece) if defined($piece);
		$side = 'k';
	}
	for my $row (0..7) {
		next if (defined($from_row) && $from_row != $row);
		for my $col (0..7) {
			next if (defined($from_col) && $from_col != $col);
			next if (defined($piece) && $board->[$row][$col] ne $piece);
			push @squares, [ $row, $col ];
		}
	}
	if (scalar @squares > 1) {
		# Filter out pieces which cannot reach this square.
		@squares = grep { $board->can_reach($piece, $_->[0], $_->[1], $to_row, $to_col) } @squares;
	}
	if (scalar @squares > 1) {
		# See if doing this move would put us in check
		# (yes, there are clients that expect us to do this).
		@squares = grep { !$board->make_move($_->[0], $_->[1], $to_row, $to_col, $promo)->in_check($side) } @squares;
	}
	if (scalar @squares == 0) {
		die "Impossible move $move";
	}
	if (scalar @squares != 1) {
		die "Ambigious move $move";
	}
	return (@{$squares[0]}, $to_row, $to_col, $promo);
}

sub fen {
	my ($board) = @_;
	my @rows = ();
	for my $row (0..7) {
		my $str = join('', @{$board->[$row]});
                $str =~ s/(-+)/length($1)/ge;
		push @rows, $str;
        }

	return join('/', @rows);
}

# Returns a compact bit string describing the same data as fen().
# This is encoded using a Huffman-like encoding, and should be
# typically about 1/3 the number of bytes.
sub bitpacked_fen {
	my ($board) = @_;
	my $bits = "";

	for my $row (0..7) {
		for my $col (0..7) {
			my $piece = $board->[$row][$col];
			if ($piece eq '-') {
				$bits .= "0";
				next;
			}

			my $color = (lc($piece) eq $piece) ? 0 : 1;
			$bits .= "1" . $color;

			if (lc($piece) eq 'p') {
				$bits .= "0";
			} elsif (lc($piece) eq 'n') {
				$bits .= "100";
			} elsif (lc($piece) eq 'b') {
				$bits .= "101";
			} elsif (lc($piece) eq 'r') {
				$bits .= "1110";
			} elsif (lc($piece) eq 'q') {
				$bits .= "11110";
			} elsif (lc($piece) eq 'k') {
				$bits .= "11111";
			} else {
				die "Unknown piece $piece";
			}
		}
	}

	return pack('b*', $bits);
}

sub can_reach {
	my ($board, $piece, $from_row, $from_col, $to_row, $to_col) = @_;
	
	# can't eat your own piece
	my $dest_piece = $board->[$to_row][$to_col];
	if ($dest_piece ne '-') {
		return 0 if (($piece eq lc($piece)) == ($dest_piece eq lc($dest_piece)));
	}
	
	if ($piece eq 'p') {
		# black pawn
		if ($to_col == $from_col && $to_row == $from_row + 1) {
			return ($dest_piece eq '-');
		}
		if ($to_col == $from_col && $from_row == 1 && $to_row == 3) {
			my $middle_piece = $board->[2][$to_col];
			return ($dest_piece eq '-' && $middle_piece eq '-');
		}
		if (abs($to_col - $from_col) == 1 && $to_row == $from_row + 1) {
			if ($dest_piece eq '-') {
				# En passant. TODO: check that the last move was indeed an EP move
				return ($to_row == 5 && $board->[4][$to_col] eq 'P');
			} else {
				return 1;
			}
		}
		return 0;
	}
	if ($piece eq 'P') {
		# white pawn
		if ($to_col == $from_col && $to_row == $from_row - 1) {
			return ($dest_piece eq '-');
		}
		if ($to_col == $from_col && $from_row == 6 && $to_row == 4) {
			my $middle_piece = $board->[5][$to_col];
			return ($dest_piece eq '-' && $middle_piece eq '-');
		}
		if (abs($to_col - $from_col) == 1 && $to_row == $from_row - 1) {
			if ($dest_piece eq '-') {
				# En passant. TODO: check that the last move was indeed an EP move
				return ($to_row == 2 && $board->[3][$to_col] eq 'p');
			} else {
				return 1;
			}
		}
		return 0;
	}
	
	if (lc($piece) eq 'r') {
		return 0 unless ($from_row == $to_row || $from_col == $to_col);

		# check that there's a clear passage
		if ($from_row == $to_row) {
			if ($from_col > $to_col) {
				($to_col, $from_col) = ($from_col, $to_col);
			}

			for my $c (($from_col+1)..($to_col-1)) {
				my $middle_piece = $board->[$to_row][$c];
				return 0 if ($middle_piece ne '-');
			}

			return 1;
		} else {
			if ($from_row > $to_row) {
				($to_row, $from_row) = ($from_row, $to_row);
			}

			for my $r (($from_row+1)..($to_row-1)) {
				my $middle_piece = $board->[$r][$to_col];
				return 0 if ($middle_piece ne '-');	
			}

			return 1;
		}
	}
	if (lc($piece) eq 'b') {
		return 0 unless (abs($from_row - $to_row) == abs($from_col - $to_col));

		my $dr = ($to_row - $from_row) / abs($to_row - $from_row);
		my $dc = ($to_col - $from_col) / abs($to_col - $from_col);

		my $r = $from_row + $dr;
		my $c = $from_col + $dc;

		while ($r != $to_row) {
			my $middle_piece = $board->[$r][$c];
			return 0 if ($middle_piece ne '-');
			
			$r += $dr;
			$c += $dc;
		}

		return 1;
	}
	if (lc($piece) eq 'n') {
		my $diff_r = abs($from_row - $to_row);
		my $diff_c = abs($from_col - $to_col);
		return 1 if ($diff_r == 2 && $diff_c == 1);
		return 1 if ($diff_r == 1 && $diff_c == 2);
		return 0;
	}
	if ($piece eq 'q') {
		return (can_reach($board, 'r', $from_row, $from_col, $to_row, $to_col) ||
		        can_reach($board, 'b', $from_row, $from_col, $to_row, $to_col));
	}
	if ($piece eq 'Q') {
		return (can_reach($board, 'R', $from_row, $from_col, $to_row, $to_col) ||
		        can_reach($board, 'B', $from_row, $from_col, $to_row, $to_col));
	}
	if (lc($piece) eq 'k') {
		return (abs($from_row - $to_row) <= 1 && abs($from_col - $to_col) <= 1);
	}

	# unknown piece
	return 0;
}

# Like can_reach, but also checks the move doesn't put the side in check.
# We use this in prettyprint_move to reduce the disambiguation, because Chess.js
# needs moves to be in minimally disambiguated form.
sub can_legally_reach {
	my ($board, $piece, $from_row, $from_col, $to_row, $to_col) = @_;

	return 0 if (!can_reach($board, $piece, $from_row, $from_col, $to_row, $to_col));

	my $nb = $board->make_move($from_row, $from_col, $to_row, $to_col);
	my $side = ($piece eq lc($piece)) ? 'k' : 'K';

	return !in_check($nb, $side);
}

my %pieces_against_side = (
	k => { K => 1, Q => 1, R => 1, N => 1, B => 1, P => 1 },
	K => { k => 1, q => 1, r => 1, n => 1, b => 1, p => 1 },
);

# Returns whether the given side (given as k or K for black and white) is in check.
sub in_check {
	my ($board, $side) = @_;
	my ($kr, $kc) = _find_piece($board, $side);

	# check all pieces for the possibility of threatening this king
	for my $row (0..7) {
		next unless grep { exists($pieces_against_side{$side}{$_}) } @{$board->[$row]};
		for my $col (0..7) {
			my $piece = $board->[$row][$col];
			next if ($piece eq '-');
			return 1 if ($board->can_reach($piece, $row, $col, $kr, $kc));
		}
	}

	return 0;
}

sub _find_piece {
	my ($board, $piece) = @_;

	for my $row (0..7) {
		next unless grep { $_ eq $piece } @{$board->[$row]};
		for my $col (0..7) {
			if ($board->[$row][$col] eq $piece) {
				return ($row, $col);
			}
		}
	}

	return (undef, undef);
}

# Returns if the given side (given as k or K) is in mate.
sub in_mate {
	my ($board, $side, $in_check) = @_;
	return 0 if (!$in_check);

	# try all possible moves for the side in check
	for my $row (0..7) {
		for my $col (0..7) {
			my $piece = $board->[$row][$col];
			next if ($piece eq '-');

			if ($side eq 'K') {
				next if ($piece eq lc($piece));
			} else {
				next if ($piece eq uc($piece));
			}

			for my $dest_row (0..7) {
				for my $dest_col (0..7) {
					next if ($row == $dest_row && $col == $dest_col);
					next unless ($board->can_reach($piece, $row, $col, $dest_row, $dest_col));

					my $nb = $board->make_move($row, $col, $dest_row, $dest_col);
					return 0 if (!$nb->in_check($side));
				}
			}
		}
	}

	# nothing to do; mate
	return 1;
}

# Returns the short algebraic form of the move, as well as the new position.
sub prettyprint_move {
	my ($board, $from_row, $from_col, $to_row, $to_col, $promo) = @_;
	my $pretty = $board->_prettyprint_move_no_check_or_mate($from_row, $from_col, $to_row, $to_col, $promo);

	my $nb = $board->make_move($from_row, $from_col, $to_row, $to_col, $promo);

	my $piece = $board->[$from_row][$from_col];
	my $other_side = (uc($piece) eq $piece) ? 'k' : 'K';
	my $in_check = $nb->in_check($other_side);
	if ($nb->in_mate($other_side, $in_check)) {
		$pretty .= '#';
	} elsif ($in_check) {
		$pretty .= '+';
	}
	return ($pretty, $nb);
}

sub num_pieces {
	my ($board) = @_;

	my $num = 0;
	for my $row (0..7) {
		for my $col (0..7) {
			my $piece = $board->[$row][$col];
			++$num if ($piece ne '-');
		}
	}
	return $num;	
}

sub _prettyprint_move_no_check_or_mate {
        my ($board, $from_row, $from_col, $to_row, $to_col, $promo) = @_;
	my $piece = $board->[$from_row][$from_col];
	my $move = move_to_uci_notation($from_row, $from_col, $to_row, $to_col, $promo);

	if ($piece eq '-') {
		die "Invalid move $move";
	}

	# white short castling
	if ($move eq 'e1g1' && $piece eq 'K') {
		return 'O-O';
	}

	# white long castling
	if ($move eq 'e1c1' && $piece eq 'K') {
		return 'O-O-O';
	}

	# black short castling
	if ($move eq 'e8g8' && $piece eq 'k') {
		return 'O-O';
	}

	# black long castling
	if ($move eq 'e8c8' && $piece eq 'k') {
		return 'O-O-O';
	}

	my $pretty;

	# check if the from-piece is a pawn
	if (lc($piece) eq 'p') {
		# attack?
		if ($from_col != $to_col) {
			$pretty = substr($move, 0, 1) . 'x' . _pos_to_square($to_row, $to_col);
		} else {
			$pretty = _pos_to_square($to_row, $to_col);
		}

		if (defined($promo) && $promo ne '') {
			# promotion
			$pretty .= "=";
			$pretty .= uc($promo);
		}
		return $pretty;
	}

	$pretty = uc($piece);

	# see how many of these pieces could go here, in all
	my $num_total = 0;
	for my $col (0..7) {
		for my $row (0..7) {
			next unless ($board->[$row][$col] eq $piece);
			++$num_total if ($board->can_legally_reach($piece, $row, $col, $to_row, $to_col));
		}
	}

	# see how many of these pieces from the given row could go here
	my $num_row = 0;
	for my $col (0..7) {
		next unless ($board->[$from_row][$col] eq $piece);
		++$num_row if ($board->can_legally_reach($piece, $from_row, $col, $to_row, $to_col));
	}

	# and same for columns
	my $num_col = 0;
	for my $row (0..7) {
		next unless ($board->[$row][$from_col] eq $piece);
		++$num_col if ($board->can_legally_reach($piece, $row, $from_col, $to_row, $to_col));
	}

	# see if we need to disambiguate
	if ($num_total > 1) {
		if ($num_col == 1) {
			$pretty .= substr($move, 0, 1);
		} elsif ($num_row == 1) {
			$pretty .= substr($move, 1, 1);
		} else {
			$pretty .= substr($move, 0, 2);
		}
	}

	# attack?
	if ($board->[$to_row][$to_col] ne '-') {
		$pretty .= 'x';
	}

	$pretty .= _pos_to_square($to_row, $to_col);
	return $pretty;
}

1;
