#! /usr/bin/perl
use strict;
use warnings;
require 'Position.pm';

my $pos = Position->start_pos('NN', 'NN');
while (<>) {
	chomp;
	my @pvs = split / /, $_;
	print join(' ', prettyprint_pv_no_cache($pos->{'board'}, @pvs)), "\n";
}

sub prettyprint_pv_no_cache {
	my ($board, @pvs) = @_;

	if (scalar @pvs == 0 || !defined($pvs[0])) {
		return ();
	}

	my $pv = shift @pvs;
	my ($from_col, $from_row, $to_col, $to_row, $promo) = parse_uci_move($pv);
	my ($pretty, $nb) = $board->prettyprint_move($from_row, $from_col, $to_row, $to_col, $promo);
	return ( $pretty, prettyprint_pv_no_cache($nb, @pvs) );
}

sub col_letter_to_num {
	return ord(shift) - ord('a');
}

sub row_letter_to_num {
	return 7 - (ord(shift) - ord('1'));
}

sub parse_uci_move {
	my $move = shift;
	my $from_col = col_letter_to_num(substr($move, 0, 1));
	my $from_row = row_letter_to_num(substr($move, 1, 1));
	my $to_col   = col_letter_to_num(substr($move, 2, 1));
	my $to_row   = row_letter_to_num(substr($move, 3, 1));
	my $promo    = substr($move, 4, 1);
	return ($from_col, $from_row, $to_col, $to_row, $promo);
}
