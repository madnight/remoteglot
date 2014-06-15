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
		for my $col (0..7) {
			$nb->[$row][$col] = $board->[$row][$col];
		}
	}

	return bless $nb;
}

# Returns a new board.
sub make_move {
	my ($board, $from_row, $from_col, $to_row, $to_col, $promo) = @_;
	my $move = _move_to_uci_notation($from_row, $from_col, $to_row, $to_col, $promo);
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
					$nb->[$to_row + 1][$to_col] = '-';
				} else {
					$nb->[$to_row - 1][$to_col] = '-';
				}
			}
		} else {
			if ($promo ne '') {
				if ($piece eq 'p') {
					$piece = $promo;
				} else {
					$piece = uc($promo);
				}
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

sub _move_to_uci_notation {
	my ($from_row, $from_col, $to_row, $to_col, $promo) = @_;
	$promo //= "";
	return _pos_to_square($from_row, $from_col) . _pos_to_square($to_row, $to_col) . $promo;
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

sub can_reach {
	my ($board, $piece, $from_row, $from_col, $to_row, $to_col) = @_;
	
	# can't eat your own piece
	my $dest_piece = $board->[$to_row][$to_col];
	if ($dest_piece ne '-') {
		return 0 if (($piece eq lc($piece)) == ($dest_piece eq lc($dest_piece)));
	}

	if (lc($piece) eq 'k') {
		return (abs($from_row - $to_row) <= 1 && abs($from_col - $to_col) <= 1);
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

	# TODO: en passant
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
			return ($dest_piece ne '-');
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
			return ($dest_piece ne '-');
		}
		return 0;
	}
	
	# unknown piece
	return 0;
}

# Returns 'none', 'white', 'black' or 'both', depending on which sides are in check.
# The latter naturally indicates an invalid position.
sub in_check {
	my $board = shift;
	my ($black_check, $white_check) = (0, 0);

	my ($wkr, $wkc, $bkr, $bkc) = _find_kings($board);

	# check all pieces for the possibility of threatening the two kings
	for my $row (0..7) {
		for my $col (0..7) {
			my $piece = $board->[$row][$col];
			next if ($piece eq '-');
		
			if (uc($piece) eq $piece) {
				# white piece
				$black_check = 1 if ($board->can_reach($piece, $row, $col, $bkr, $bkc));
			} else {
				# black piece
				$white_check = 1 if ($board->can_reach($piece, $row, $col, $wkr, $wkc));
			}
		}
	}

	if ($black_check && $white_check) {
		return 'both';
	} elsif ($black_check) {
		return 'black';
	} elsif ($white_check) {
		return 'white';
	} else {
		return 'none';
	}
}

sub _find_kings {
	my $board = shift;
	my ($wkr, $wkc, $bkr, $bkc);

	for my $row (0..7) {
		for my $col (0..7) {
			my $piece = $board->[$row][$col];
			if ($piece eq 'K') {
				($wkr, $wkc) = ($row, $col);
			} elsif ($piece eq 'k') {
				($bkr, $bkc) = ($row, $col);
			}
		}
	}

	return ($wkr, $wkc, $bkr, $bkc);
}

# Returns if any side is in mate.
sub in_mate {
	my $board = shift;
	my $check = $board->in_check();
	return 0 if ($check eq 'none');

	# try all possible moves for the side in check
	for my $row (0..7) {
		for my $col (0..7) {
			my $piece = $board->[$row][$col];
			next if ($piece eq '-');

			if ($check eq 'white') {
				next if ($piece eq lc($piece));
			} else {
				next if ($piece eq uc($piece));
			}

			for my $dest_row (0..7) {
				for my $dest_col (0..7) {
					next if ($row == $dest_row && $col == $dest_col);
					next unless ($board->can_reach($piece, $row, $col, $dest_row, $dest_col));

					my $nb = $board->clone();
					$nb->[$row][$col] = '-';
					$nb->[$dest_row][$dest_col] = $piece;
					my $new_check = $nb->in_check();
					return 0 if ($new_check ne $check && $new_check ne 'both');
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
	if ($nb->in_mate()) {
		$pretty .= '#';
	} elsif ($nb->in_check() ne 'none') {
		$pretty .= '+';
	}
	return ($pretty, $nb);
}

sub _prettyprint_move_no_check_or_mate {
        my ($board, $from_row, $from_col, $to_row, $to_col, $promo) = @_;
	my $piece = $board->[$from_row][$from_col];
	my $move = _move_to_uci_notation($from_row, $from_col, $to_row, $to_col, $promo);

	if ($piece eq '-') {
		die "Invalid move $move";
	}

	# white short castling
	if ($move eq 'e1g1' && $piece eq 'K') {
		return '0-0';
	}

	# white long castling
	if ($move eq 'e1c1' && $piece eq 'K') {
		return '0-0-0';
	}

	# black short castling
	if ($move eq 'e8g8' && $piece eq 'k') {
		return '0-0';
	}

	# black long castling
	if ($move eq 'e8c8' && $piece eq 'k') {
		return '0-0-0';
	}

	my $pretty;

	# check if the from-piece is a pawn
	if (lc($piece) eq 'p') {
		# attack?
		if ($from_col != $to_col) {
			$pretty = substr($move, 0, 1) . 'x' . _pos_to_square($to_row, $to_col);
		} else {
			$pretty = _pos_to_square($to_row, $to_col);

			if (defined($promo) && $promo ne '') {
				# promotion
				$pretty .= "=";
				$pretty .= $promo;
			}
		}
		return $pretty;
	}

	$pretty = uc($piece);

	# see how many of these pieces could go here, in all
	my $num_total = 0;
	for my $col (0..7) {
		for my $row (0..7) {
			next unless ($board->[$row][$col] eq $piece);
			++$num_total if ($board->can_reach($piece, $row, $col, $to_row, $to_col));
		}
	}

	# see how many of these pieces from the given row could go here
	my $num_row = 0;
	for my $col (0..7) {
		next unless ($board->[$from_row][$col] eq $piece);
		++$num_row if ($board->can_reach($piece, $from_row, $col, $to_row, $to_col));
	}

	# and same for columns
	my $num_col = 0;
	for my $row (0..7) {
		next unless ($board->[$row][$from_col] eq $piece);
		++$num_col if ($board->can_reach($piece, $row, $from_col, $to_row, $to_col));
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
