#! /usr/bin/perl
#
# Get eco.pgn from ftp://ftp.cs.kent.ac.uk/pub/djb/pgn-extract/eco.pgn,
# or any other opening database you might want to use as a base.
#
use strict;
use warnings;
use Chess::PGN::Parse;

require 'Position.pm';

package ECO;

our %fen_to_opening = ();
our @openings = ();

sub init {
	{
		my $pos = Position->start_pos("white", "black");
		my $key = _key_for_pos($pos);
		push @openings, { eco => 'A00', name => 'Start position' };
		$fen_to_opening{$key} = $#openings;
	}

	my $pgn = Chess::PGN::Parse->new("eco.pgn")
		or die "can't open eco.pgn\n";
	while ($pgn->read_game()) {
		my $tags = $pgn->tags();
		$pgn->quick_parse_game;
		my $pos = Position->start_pos("white", "black");
		my $moves = $pgn->moves // [];
		my $eco = $pgn->eco;
		next if (!defined($eco));
		my $name = $tags->{'Opening'};
		if (exists($tags->{'Variation'}) && $tags->{'Variation'} ne '') {
			$name .= ": " . $tags->{'Variation'};
		}
		for (my $i = 0; $i < scalar @$moves; ++$i) {
			my ($from_row, $from_col, $to_row, $to_col, $promo) = $pos->parse_pretty_move($moves->[$i]);
			$pos = $pos->make_move($from_row, $from_col, $to_row, $to_col, $promo, $moves->[$i]);
		}
		my $key = _key_for_pos($pos);
		push @openings, { eco => $pgn->eco(), name => $name };
		$fen_to_opening{$key} = $#openings;
	}
}

sub persist {
	my $filename = shift;
	open my $fh, ">", $filename
		or die "openings.txt: $!";
	for my $opening (@openings) {
		print $fh $opening->{'eco'}, " ", $opening->{'name'}, "\n";
	}
	close $fh;
}

sub unpersist {
	my $filename = shift;
	open my $fh, "<", $filename
		or die "openings.txt: $!";
	while (<$fh>) {
		chomp;
		push @openings, $_;
	}
	close $fh;
}

sub get_opening_num {  # May return undef.
	my $pos = shift;
	return $fen_to_opening{_key_for_pos($pos)};
}

sub _key_for_pos {
	my $pos = shift;
	my $key = $pos->fen;
	# Remove the move clocks.
	$key =~ s/ \d+ \d+$//;
	return $key;
}

1;
