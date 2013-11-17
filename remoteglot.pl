#! /usr/bin/perl

#
# remoteglot - Connects an abitrary UCI-speaking engine to ICS for easier post-game
#              analysis, or for live analysis of relayed games. (Do not use for
#              cheating! Cheating is bad for your karma, and your abuser flag.)
#
# Copyright 2007 Steinar H. Gunderson <sgunderson@bigfoot.com>
# Licensed under the GNU General Public License, version 2.
#

use Net::Telnet;
use FileHandle;
use IPC::Open2;
use Time::HiRes;
use JSON::XS;
use strict;
use warnings;

# Configuration
my $server = "freechess.org";
my $target = "GMCarlsen";
my $engine_cmdline = "'./Deep Rybka 4 SSE42 x64'";
my $engine2_cmdline = "./stockfish_13111119_x64_modern_sse42";
my $telltarget = undef;   # undef to be silent
my @tell_intervals = (5, 20, 60, 120, 240, 480, 960);  # after each move
my $uci_assume_full_compliance = 0;                    # dangerous :-)
my $update_max_interval = 2.0;
my $second_engine_start_depth = 8;
my @masters = (
	'Sesse',
	'Sessse',
	'Sesssse',
	'greatestguns',
	'beuki'
);

# Program starts here
$SIG{ALRM} = sub { output(); };
my $latest_update = undef;

$| = 1;

open(FICSLOG, ">ficslog.txt")
	or die "ficslog.txt: $!";
print FICSLOG "Log starting.\n";
select(FICSLOG);
$| = 1;

open(UCILOG, ">ucilog.txt")
	or die "ucilog.txt: $!";
print UCILOG "Log starting.\n";
select(UCILOG);
$| = 1;
select(STDOUT);

# open the chess engine
my $engine = open_engine($engine_cmdline, 'E1');
my $engine2 = open_engine($engine2_cmdline, 'E2');
my ($last_move, $last_tell);
my $last_text = '';
my $last_told_text = '';
my ($pos_waiting, $pos_calculating, $move_calculating_second_engine);
my %refutation_moves = ();

uciprint($engine, "setoption name UCI_AnalyseMode value true");
# uciprint($engine, "setoption name NalimovPath value /srv/tablebase");
uciprint($engine, "setoption name NalimovUsage value Rarely");
uciprint($engine, "setoption name Hash value 1024");
# uciprint($engine, "setoption name MultiPV value 2");
uciprint($engine, "ucinewgame");

uciprint($engine2, "setoption name UCI_AnalyseMode value true");
# uciprint($engine2, "setoption name NalimovPath value /srv/tablebase");
uciprint($engine2, "setoption name NalimovUsage value Rarely");
uciprint($engine2, "setoption name Hash value 1024");
uciprint($engine2, "setoption name Threads value 8");
# uciprint($engine2, "setoption name MultiPV value 2");
uciprint($engine2, "ucinewgame");

print "Chess engine ready.\n";

# now talk to FICS
my $t = Net::Telnet->new(Timeout => 10, Prompt => '/fics% /');
$t->input_log(\*FICSLOG);
$t->open($server);
$t->print("SesseBOT");
$t->waitfor('/Press return to enter the server/');
$t->cmd("");

# set some options
$t->cmd("set shout 0");
$t->cmd("set seek 0");
$t->cmd("set style 12");
$t->cmd("observe $target");

# main loop
print "FICS ready.\n";
while (1) {
	my $rin = '';
	my $rout;
	vec($rin, fileno($engine->{'read'}), 1) = 1;
	vec($rin, fileno($engine2->{'read'}), 1) = 1;
	vec($rin, fileno($t), 1) = 1;

	my ($nfound, $timeleft) = select($rout=$rin, undef, undef, 5.0);
	my $sleep = 1.0;

	while (1) {
		my $line = $t->getline(Timeout => 0, errmode => 'return');
		last if (!defined($line));

		chomp $line;
		$line =~ tr/\r//d;
		if ($line =~ /^<12> /) {
			my $pos = style12_to_pos($line);
			
			# if this is already in the queue, ignore it
			next if (defined($pos_waiting) && $pos->{'fen'} eq $pos_waiting->{'fen'});

			# if we're already chewing on this and there's nothing else in the queue,
			# also ignore it
			next if (!defined($pos_waiting) && defined($pos_calculating) &&
			         $pos->{'fen'} eq $pos_calculating->{'fen'});

			# if we're already thinking on something, stop and wait for the engine
			# to approve
			if (defined($pos_calculating)) {
				if (!defined($pos_waiting)) {
					uciprint($engine, "stop");
				}
				if ($uci_assume_full_compliance) {
					$pos_waiting = $pos;
				} else {
					uciprint($engine, "position fen " . $pos->{'fen'});
					uciprint($engine, "go infinite");
					$pos_calculating = $pos;
				}
			} else {
				# it's wrong just to give the FEN (the move history is useful,
				# and per the UCI spec, we should really have sent "ucinewgame"),
				# but it's easier
				uciprint($engine, "position fen " . $pos->{'fen'});
				uciprint($engine, "go infinite");
				$pos_calculating = $pos;
			}

			%refutation_moves = calculate_refutation_moves($pos);
			if (defined($move_calculating_second_engine)) {
				uciprint($engine2, "stop");
				$move_calculating_second_engine = undef;
			} else {
				give_new_move_to_second_engine($pos);
			}

			$engine->{'info'} = {};
			$engine2->{'info'} = {};
			$last_move = time;

			# 
			# Output a command every move to note that we're
			# still paying attention -- this is a good tradeoff,
			# since if no move has happened in the last half
			# hour, the analysis/relay has most likely stopped
			# and we should stop hogging server resources.
			#
			$t->cmd("date");
		}
		if ($line =~ /^([A-Za-z]+)(?:\([A-Z]+\))* tells you: (.*)$/) {
			my ($who, $msg) = ($1, $2);

			next if (grep { $_ eq $who } (@masters) == 0);
	
			if ($msg =~ /^fics (.*?)$/) {
				$t->cmd("tell $who Executing '$1' on FICS.");
				$t->cmd($1);
			} elsif ($msg =~ /^uci (.*?)$/) {
				$t->cmd("tell $who Sending '$1' to the engine.");
				print { $engine->{'write'} } "$1\n";
			} else {
				$t->cmd("tell $who Couldn't understand '$msg', sorry.");
			}
		}
		#print "FICS: [$line]\n";
		$sleep = 0;
	}
	
	# any fun on the UCI channel?
	if ($nfound > 0 && vec($rout, fileno($engine->{'read'}), 1) == 1) {
		my @lines = read_lines($engine);
		for my $line (@lines) {
			next if $line =~ /(upper|lower)bound/;
			handle_uci($engine, $line, 1);
		}
		$sleep = 0;

		output();
	}
	if ($nfound > 0 && vec($rout, fileno($engine2->{'read'}), 1) == 1) {
		my @lines = read_lines($engine2);
		for my $line (@lines) {
			next if $line =~ /(upper|lower)bound/;
			handle_uci($engine2, $line, 0);
		}
		$sleep = 0;

		output();
	}

	sleep $sleep;
}

sub handle_uci {
	my ($engine, $line, $primary) = @_;

	chomp $line;
	$line =~ tr/\r//d;
	$line =~ s/  / /g;  # Sometimes needed for Zappa Mexico
	print UCILOG localtime() . " $engine->{'tag'} <= $line\n";
	if ($line =~ /^info/) {
		my (@infos) = split / /, $line;
		shift @infos;

		parse_infos($engine, @infos);
	}
	if ($line =~ /^id/) {
		my (@ids) = split / /, $line;
		shift @ids;

		parse_ids($engine, @ids);
	}
	if ($line =~ /^bestmove/) {
		if ($primary) {
			return if (!$uci_assume_full_compliance);
			if (defined($pos_waiting)) {
				uciprint($engine, "position fen " . $pos_waiting->{'fen'});
				uciprint($engine, "go infinite");

				$pos_calculating = $pos_waiting;
				$pos_waiting = undef;
			}
		} else {
			if (defined($move_calculating_second_engine)) {	
				my $move = $refutation_moves{$move_calculating_second_engine};
				$move->{'pv'} = $engine->{'info'}{'pv'} // $engine->{'info'}{'pv1'};
				$move->{'score_cp'} = $engine->{'info'}{'score_cp'} // $engine->{'info'}{'score_cp1'} // 0;
				$move->{'score_mate'} = $engine->{'info'}{'score_mate'} // $engine->{'info'}{'score_mate1'};
				$move->{'toplay'} = $pos_calculating->{'toplay'};
			}
			give_new_move_to_second_engine($pos_waiting // $pos_calculating);
		}
	}
}

sub parse_infos {
	my ($engine, @x) = @_;
	my $mpv = '';

	my $info = $engine->{'info'};

	while (scalar @x > 0) {
		if ($x[0] =~ 'multipv') {
			shift @x;
			$mpv = shift @x;
			next;
		}
		if ($x[0] =~ /^(currmove|currmovenumber|cpuload)$/) {
			my $key = shift @x;
			my $value = shift @x;
			$info->{$key} = $value;
			next;
		}
		if ($x[0] =~ /^(depth|seldepth|hashfull|time|nodes|nps|tbhits)$/) {
			my $key = shift @x;
			my $value = shift @x;
			$info->{$key . $mpv} = $value;
			next;
		}
		if ($x[0] eq 'score') {
			shift @x;

			delete $info->{'score_cp' . $mpv};
			delete $info->{'score_mate' . $mpv};

			while ($x[0] =~ /^(cp|mate|lowerbound|upperbound)$/) {
				if ($x[0] eq 'cp') {
					shift @x;
					$info->{'score_cp' . $mpv} = shift @x;
				} elsif ($x[0] eq 'mate') {
					shift @x;
					$info->{'score_mate' . $mpv} = shift @x;
				} else {
					shift @x;
				}
			}
			next;
		}
		if ($x[0] eq 'pv') {
			$info->{'pv' . $mpv} = [ @x[1..$#x] ];
			last;
		}
		if ($x[0] eq 'string' || $x[0] eq 'UCI_AnalyseMode' || $x[0] eq 'setting' || $x[0] eq 'contempt') {
			last;
		}

		#print "unknown info '$x[0]', trying to recover...\n";
		#shift @x;
		die "Unknown info '" . join(',', @x) . "'";

	}
}

sub parse_ids {
	my ($engine, @x) = @_;

	while (scalar @x > 0) {
		if ($x[0] =~ /^(name|author)$/) {
			my $key = shift @x;
			my $value = join(' ', @x);
			$engine->{'id'}{$key} = $value;
			last;
		}

		# unknown
		shift @x;
	}
}

sub style12_to_pos {
	my $str = shift;
	my %pos = ();
	my (@x) = split / /, $str;
	
	$pos{'board'} = [ @x[1..8] ];
	$pos{'toplay'} = $x[9];
	$pos{'ep_file_num'} = $x[10];
	$pos{'white_castle_k'} = $x[11];
	$pos{'white_castle_q'} = $x[12];
	$pos{'black_castle_k'} = $x[13];
	$pos{'black_castle_q'} = $x[14];
	$pos{'time_to_100move_rule'} = $x[15];
	$pos{'move_num'} = $x[26];
	$pos{'last_move'} = $x[29];
	$pos{'fen'} = make_fen(\%pos);

	return \%pos;
}

sub make_fen {
	my $pos = shift;

	# the board itself
	my (@board) = @{$pos->{'board'}};
	for my $rank (0..7) {
		$board[$rank] =~ s/(-+)/length($1)/ge;
	}
	my $fen = join('/', @board);

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
			$ep = $nep if ($col > 0 && substr($pos->{'board'}[4], $col-1, 1) eq 'p');
			$ep = $nep if ($col < 7 && substr($pos->{'board'}[4], $col+1, 1) eq 'p');
		} else {
			$ep = $nep if ($col > 0 && substr($pos->{'board'}[3], $col-1, 1) eq 'P');
			$ep = $nep if ($col < 7 && substr($pos->{'board'}[3], $col+1, 1) eq 'P');
		}
	}
	$fen .= " ";
	$fen .= $ep;

	# half-move clock
	$fen .= " ";
	$fen .= $pos->{'time_to_100move_rule'};

	# full-move clock
	$fen .= " ";
	$fen .= $pos->{'move_num'};

	return $fen;
}

sub make_move {
	my ($board, $from_row, $from_col, $to_row, $to_col, $promo) = @_;
	my $move = move_to_uci_notation($from_row, $from_col, $to_row, $to_col, $promo);
	my $piece = substr($board->[$from_row], $from_col, 1);
	my @nb = @$board;

	if ($piece eq '-') {
		die "Invalid move $move";
	}

	# white short castling
	if ($move eq 'e1g1' && $piece eq 'K') {
		# king
		substr($nb[7], 4, 1, '-');
		substr($nb[7], 6, 1, $piece);
		
		# rook
		substr($nb[7], 7, 1, '-');
		substr($nb[7], 5, 1, 'R');
				
		return \@nb;
	}

	# white long castling
	if ($move eq 'e1c1' && $piece eq 'K') {
		# king
		substr($nb[7], 4, 1, '-');
		substr($nb[7], 2, 1, $piece);
		
		# rook
		substr($nb[7], 0, 1, '-');
		substr($nb[7], 3, 1, 'R');
				
		return \@nb;
	}

	# black short castling
	if ($move eq 'e8g8' && $piece eq 'k') {
		# king
		substr($nb[0], 4, 1, '-');
		substr($nb[0], 6, 1, $piece);
		
		# rook
		substr($nb[0], 7, 1, '-');
		substr($nb[0], 5, 1, 'r');
				
		return \@nb;
	}

	# black long castling
	if ($move eq 'e8c8' && $piece eq 'k') {
		# king
		substr($nb[0], 4, 1, '-');
		substr($nb[0], 2, 1, $piece);
		
		# rook
		substr($nb[0], 0, 1, '-');
		substr($nb[0], 3, 1, 'r');
				
		return \@nb;
	}

	# check if the from-piece is a pawn
	if (lc($piece) eq 'p') {
		# attack?
		if ($from_col != $to_col) {
			# en passant?
			if (substr($board->[$to_row], $to_col, 1) eq '-') {
				if ($piece eq 'p') {
					substr($nb[$to_row + 1], $to_col, 1, '-');
				} else {
					substr($nb[$to_row - 1], $to_col, 1, '-');
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
	substr($nb[$from_row], $from_col, 1, '-');
	substr($nb[$to_row], $to_col, 1, $piece);

	return \@nb;
}

sub prettyprint_pv {
	my ($board, @pvs) = @_;

	if (scalar @pvs == 0 || !defined($pvs[0])) {
		return ();
	}

	my $pv = shift @pvs;
	my $from_col = col_letter_to_num(substr($pv, 0, 1));
	my $from_row = row_letter_to_num(substr($pv, 1, 1));
	my $to_col   = col_letter_to_num(substr($pv, 2, 1));
	my $to_row   = row_letter_to_num(substr($pv, 3, 1));
	my $promo    = substr($pv, 4, 1);

	my $nb = make_move($board, $from_row, $from_col, $to_row, $to_col, $promo);
	my $piece = substr($board->[$from_row], $from_col, 1);

	if ($piece eq '-') {
		die "Invalid move $pv";
	}

	# white short castling
	if ($pv eq 'e1g1' && $piece eq 'K') {
		return ('0-0', prettyprint_pv($nb, @pvs));
	}

	# white long castling
	if ($pv eq 'e1c1' && $piece eq 'K') {
		return ('0-0-0', prettyprint_pv($nb, @pvs));
	}

	# black short castling
	if ($pv eq 'e8g8' && $piece eq 'k') {
		return ('0-0', prettyprint_pv($nb, @pvs));
	}

	# black long castling
	if ($pv eq 'e8c8' && $piece eq 'k') {
		return ('0-0-0', prettyprint_pv($nb, @pvs));
	}

	my $pretty;

	# check if the from-piece is a pawn
	if (lc($piece) eq 'p') {
		# attack?
		if ($from_col != $to_col) {
			$pretty = substr($pv, 0, 1) . 'x' . substr($pv, 2, 2);
		} else {
			$pretty = substr($pv, 2, 2);

			if (length($pv) == 5) {
				# promotion
				$pretty .= "=";
				$pretty .= uc(substr($pv, 4, 1));

				if ($piece eq 'p') {
					$piece = substr($pv, 4, 1);
				} else {
					$piece = uc(substr($pv, 4, 1));
				}
			}
		}
	} else {
		$pretty = uc($piece);

		# see how many of these pieces could go here, in all
		my $num_total = 0;
		for my $col (0..7) {
			for my $row (0..7) {
				next unless (substr($board->[$row], $col, 1) eq $piece);
				++$num_total if (can_reach($board, $piece, $row, $col, $to_row, $to_col));
			}
		}

		# see how many of these pieces from the given row could go here
		my $num_row = 0;
		for my $col (0..7) {
			next unless (substr($board->[$from_row], $col, 1) eq $piece);
			++$num_row if (can_reach($board, $piece, $from_row, $col, $to_row, $to_col));
		}
		
		# and same for columns
		my $num_col = 0;
		for my $row (0..7) {
			next unless (substr($board->[$row], $from_col, 1) eq $piece);
			++$num_col if (can_reach($board, $piece, $row, $from_col, $to_row, $to_col));
		}
		
		# see if we need to disambiguate
		if ($num_total > 1) {
			if ($num_col == 1) {
				$pretty .= substr($pv, 0, 1);
			} elsif ($num_row == 1) {
				$pretty .= substr($pv, 1, 1);
			} else {
				$pretty .= substr($pv, 0, 2);
			}
		}

		# attack?
		if (substr($board->[$to_row], $to_col, 1) ne '-') {
			$pretty .= 'x';
		}

		$pretty .= substr($pv, 2, 2);
	}

	if (in_mate($nb)) {
		$pretty .= '#';
	} elsif (in_check($nb) ne 'none') {
		$pretty .= '+';
	}
	return ($pretty, prettyprint_pv($nb, @pvs));
}

sub output {
	#return;

	return if (!defined($pos_calculating));

	# Don't update too often.
	my $age = Time::HiRes::tv_interval($latest_update);
	if ($age < $update_max_interval) {
		Time::HiRes::alarm($update_max_interval + 0.01 - $age);
		return;
	}
	
	my $info = $engine->{'info'};
	
	#
	# Some programs _always_ report MultiPV, even with only one PV.
	# In this case, we simply use that data as if MultiPV was never
	# specified.
	#
	if (exists($info->{'pv1'}) && !exists($info->{'pv2'})) {
		for my $key (qw(pv score_cp score_mate nodes nps depth seldepth tbhits)) {
			if (exists($info->{$key . '1'})) {
				$info->{$key} = $info->{$key . '1'};
			}
		}
	}
	
	#
	# Check the PVs first. if they're invalid, just wait, as our data
	# is most likely out of sync. This isn't a very good solution, as
	# it can frequently miss stuff, but it's good enough for most users.
	#
	eval {
		my $dummy;
		if (exists($info->{'pv'})) {
			$dummy = prettyprint_pv($pos_calculating->{'board'}, @{$info->{'pv'}});
		}
	
		my $mpv = 1;
		while (exists($info->{'pv' . $mpv})) {
			$dummy = prettyprint_pv($pos_calculating->{'board'}, @{$info->{'pv' . $mpv}});
			++$mpv;
		}
	};
	if ($@) {
		$engine->{'info'} = {};
		return;
	}

	output_screen();
	output_json();
	$latest_update = [Time::HiRes::gettimeofday];
}

sub output_screen {
	my $info = $engine->{'info'};
	my $id = $engine->{'id'};

	my $text = 'Analysis';
	if ($pos_calculating->{'last_move'} ne 'none') {
		if ($pos_calculating->{'toplay'} eq 'W') {
			$text .= sprintf ' after %u. ... %s', ($pos_calculating->{'move_num'}-1), $pos_calculating->{'last_move'};
		} else {
			$text .= sprintf ' after %u. %s', $pos_calculating->{'move_num'}, $pos_calculating->{'last_move'};
		}
		if (exists($id->{'name'})) {
			$text .= ',';
		}
	}

	if (exists($id->{'name'})) {
		$text .= " by $id->{'name'}:\n\n";
	} else {
		$text .= ":\n\n";
	}

	return unless (exists($pos_calculating->{'board'}));
		
	if (exists($info->{'pv1'}) && exists($info->{'pv2'})) {
		# multi-PV
		my $mpv = 1;
		while (exists($info->{'pv' . $mpv})) {
			$text .= sprintf "  PV%2u", $mpv;
			my $score = short_score($info, $pos_calculating, $mpv);
			$text .= "  ($score)" if (defined($score));

			my $tbhits = '';
			if (exists($info->{'tbhits' . $mpv}) && $info->{'tbhits' . $mpv} > 0) {
				if ($info->{'tbhits' . $mpv} == 1) {
					$tbhits = ", 1 tbhit";
				} else {
					$tbhits = sprintf ", %u tbhits", $info->{'tbhits' . $mpv};
				}
			}

			if (exists($info->{'nodes' . $mpv}) && exists($info->{'nps' . $mpv}) && exists($info->{'depth' . $mpv})) {
				$text .= sprintf " (%5u kn, %3u kn/s, %2u ply$tbhits)",
					$info->{'nodes' . $mpv} / 1000, $info->{'nps' . $mpv} / 1000, $info->{'depth' . $mpv};
			}

			$text .= ":\n";
			$text .= "  " . join(', ', prettyprint_pv($pos_calculating->{'board'}, @{$info->{'pv' . $mpv}})) . "\n";
			$text .= "\n";
			++$mpv;
		}
	} else {
		# single-PV
		my $score = long_score($info, $pos_calculating, '');
		$text .= "  $score\n" if defined($score);
		$text .=  "  PV: " . join(', ', prettyprint_pv($pos_calculating->{'board'}, @{$info->{'pv'}}));
		$text .=  "\n";

		if (exists($info->{'nodes'}) && exists($info->{'nps'}) && exists($info->{'depth'})) {
			$text .= sprintf "  %u nodes, %7u nodes/sec, depth %u ply",
				$info->{'nodes'}, $info->{'nps'}, $info->{'depth'};
		}
		if (exists($info->{'seldepth'})) {
			$text .= sprintf " (%u selective)", $info->{'seldepth'};
		}
		if (exists($info->{'tbhits'}) && $info->{'tbhits'} > 0) {
			if ($info->{'tbhits'} == 1) {
				$text .= ", one Nalimov hit";
			} else {
				$text .= sprintf ", %u Nalimov hits", $info->{'tbhits'};
			}
		}
		$text .= "\n\n";
	}

	#$text .= book_info($pos_calculating->{'fen'}, $pos_calculating->{'board'}, $pos_calculating->{'toplay'});

	my @refutation_lines = ();
	for my $move (keys %refutation_moves) {
		eval {
			my $m = $refutation_moves{$move};
			die if ($m->{'depth'} < $second_engine_start_depth);
			my $pretty_move = join('', prettyprint_pv($pos_calculating->{'board'}, $move));
			my @pretty_pv = prettyprint_pv($pos_calculating->{'board'}, $move, @{$m->{'pv'}});
			if (scalar @pretty_pv > 5) {
				@pretty_pv = @pretty_pv[0..4];
				push @pretty_pv, "...";
			}
			#my $key = score_sort_key($refutation_moves{$move}, $pos_calculating, '', 1);
			my $key = $pretty_move;
			my $line = sprintf("  %-6s %6s %3s  %s",
				$pretty_move,
				short_score($refutation_moves{$move}, $pos_calculating, '', 1),
				"d" . $m->{'depth'},
				join(', ', @pretty_pv));
			push @refutation_lines, [ $key, $line ];
		};
	}

	if ($#refutation_lines >= 0) {
		$text .= "Shallow search of all legal moves:\n\n";
		for my $line (sort { $a->[0] cmp $b->[0] } @refutation_lines) {
			$text .= $line->[1] . "\n";
		}
		$text .= "\n\n";	
	}	

	if ($last_text ne $text) {
		print "[H[2J"; # clear the screen
		print $text;
		$last_text = $text;
	}

	# Now construct the tell text, if any
	return if (!defined($telltarget));

	my $tell_text = '';

	if (exists($id->{'name'})) {
		$tell_text .= "Analysis by $id->{'name'} -- see http://analysis.sesse.net/ for more information\n";
	} else {
		$tell_text .= "Computer analysis -- http://analysis.sesse.net/ for more information\n";
	}

	if (exists($info->{'pv1'}) && exists($info->{'pv2'})) {
		# multi-PV
		my $mpv = 1;
		while (exists($info->{'pv' . $mpv})) {
			$tell_text .= sprintf "  PV%2u", $mpv;
			my $score = short_score($info, $pos_calculating, $mpv);
			$tell_text .= "  ($score)" if (defined($score));

			if (exists($info->{'depth' . $mpv})) {
				$tell_text .= sprintf " (%2u ply)", $info->{'depth' . $mpv};
			}

			$tell_text .= ": ";
			$tell_text .= join(', ', prettyprint_pv($pos_calculating->{'board'}, @{$info->{'pv' . $mpv}}));
			$tell_text .= "\n";
			++$mpv;
		}
	} else {
		# single-PV
		my $score = long_score($info, $pos_calculating, '');
		$tell_text .= "  $score\n" if defined($score);
		$tell_text .= "  PV: " . join(', ', prettyprint_pv($pos_calculating->{'board'}, @{$info->{'pv'}}));
		if (exists($info->{'depth'})) {
			$tell_text .= sprintf " (depth %u ply)", $info->{'depth'};
		}
		$tell_text .=  "\n";
	}

	# see if a new tell is called for -- it is if the delay has expired _and_
	# this is not simply a repetition of the last one
	if ($last_told_text ne $tell_text) {
		my $now = time;
		for my $iv (@tell_intervals) {
			last if ($now - $last_move < $iv);
			next if ($last_tell - $last_move >= $iv);

			for my $line (split /\n/, $tell_text) {
				$t->print("tell $telltarget [$target] $line");
			}

			$last_told_text = $text;
			$last_tell = $now;

			last;
		}
	}
}

sub output_json {
	my $info = $engine->{'info'};

	my $json = {};
	$json->{'position'} = $pos_calculating;
	$json->{'id'} = $engine->{'id'};
	$json->{'score'} = long_score($info, $pos_calculating, '');

	$json->{'nodes'} = $info->{'nodes'};
	$json->{'nps'} = $info->{'nps'};
	$json->{'depth'} = $info->{'depth'};
	$json->{'tbhits'} = $info->{'tbhits'};
	$json->{'seldepth'} = $info->{'seldepth'};

	# single-PV only for now
	$json->{'pv_uci'} = $info->{'pv'};
	$json->{'pv_pretty'} = [ prettyprint_pv($pos_calculating->{'board'}, @{$info->{'pv'}}) ];

	my %refutation_lines = ();
	for my $move (keys %refutation_moves) {
		my $m = $refutation_moves{$move};
		my $pretty_move = "";
		my @pretty_pv = ();
		eval {
			$pretty_move = join('', prettyprint_pv($pos_calculating->{'board'}, $move));
			@pretty_pv = prettyprint_pv($pos_calculating->{'board'}, $move, @{$m->{'pv'}});
		};
		$refutation_lines{$move} = {
			sort_key => $pretty_move,
			depth => $m->{'depth'},
			score_sort_key => score_sort_key($refutation_moves{$move}, $pos_calculating, '', 1),
			pretty_score => short_score($refutation_moves{$move}, $pos_calculating, '', 1),
			pretty_move => $pretty_move,
			pv_pretty => \@pretty_pv,
		};
		eval {
			$refutation_lines{$move}->{'pv_uci'} = [ $move, @{$m->{'pv'}} ];
		};
	}
	$json->{'refutation_lines'} = \%refutation_lines;

	open my $fh, ">analysis.json.tmp"
		or return;
	print $fh JSON::XS::encode_json($json);
	close $fh;
	rename("analysis.json.tmp", "analysis.json");	
}

sub find_kings {
	my $board = shift;
	my ($wkr, $wkc, $bkr, $bkc);

	for my $row (0..7) {
		for my $col (0..7) {
			my $piece = substr($board->[$row], $col, 1);
			if ($piece eq 'K') {
				($wkr, $wkc) = ($row, $col);
			} elsif ($piece eq 'k') {
				($bkr, $bkc) = ($row, $col);
			}
		}
	}

	return ($wkr, $wkc, $bkr, $bkc);
}

sub in_mate {
	my $board = shift;
	my $check = in_check($board);
	return 0 if ($check eq 'none');

	# try all possible moves for the side in check
	for my $row (0..7) {
		for my $col (0..7) {
			my $piece = substr($board->[$row], $col, 1);
			next if ($piece eq '-');

			if ($check eq 'white') {
				next if ($piece eq lc($piece));
			} else {
				next if ($piece eq uc($piece));
			}

			for my $dest_row (0..7) {
				for my $dest_col (0..7) {
					next if ($row == $dest_row && $col == $dest_col);
					next unless (can_reach($board, $piece, $row, $col, $dest_row, $dest_col));

					my @nb = @$board;
					substr($nb[$row], $col, 1, '-');
					substr($nb[$dest_row], $dest_col, 1, $piece);

					my $new_check = in_check(\@nb);
					return 0 if ($new_check ne $check && $new_check ne 'both');
				}
			}
		}
	}

	# nothing to do; mate
	return 1;
}

sub in_check {
	my $board = shift;
	my ($black_check, $white_check) = (0, 0);

	my ($wkr, $wkc, $bkr, $bkc) = find_kings($board);

	# check all pieces for the possibility of threatening the two kings
	for my $row (0..7) {
		for my $col (0..7) {
			my $piece = substr($board->[$row], $col, 1);
			next if ($piece eq '-');
		
			if (uc($piece) eq $piece) {
				# white piece
				$black_check = 1 if (can_reach($board, $piece, $row, $col, $bkr, $bkc));
			} else {
				# black piece
				$white_check = 1 if (can_reach($board, $piece, $row, $col, $wkr, $wkc));
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

sub can_reach {
	my ($board, $piece, $from_row, $from_col, $to_row, $to_col) = @_;
	
	# can't eat your own piece
	my $dest_piece = substr($board->[$to_row], $to_col, 1);
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
				my $middle_piece = substr($board->[$to_row], $c, 1);
				return 0 if ($middle_piece ne '-');	
			}

			return 1;
		} else {
			if ($from_row > $to_row) {
				($to_row, $from_row) = ($from_row, $to_row);
			}

			for my $r (($from_row+1)..($to_row-1)) {
				my $middle_piece = substr($board->[$r], $to_col, 1);
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
			my $middle_piece = substr($board->[$r], $c, 1);
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
			my $middle_piece = substr($board->[2], $to_col, 1);
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
			my $middle_piece = substr($board->[5], $to_col, 1);
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

sub uciprint {
	my ($engine, $msg) = @_;
	print { $engine->{'write'} } "$msg\n";
	print UCILOG localtime() . " $engine->{'tag'} => $msg\n";
}

sub short_score {
	my ($info, $pos, $mpv, $invert) = @_;

	$invert //= 0;
	if ($pos->{'toplay'} eq 'B') {
		$invert = !$invert;
	}

	if (defined($info->{'score_mate' . $mpv})) {
		if ($invert) {
			return sprintf "M%3d", -$info->{'score_mate' . $mpv};
		} else {
			return sprintf "M%3d", $info->{'score_mate' . $mpv};
		}
	} else {
		if (exists($info->{'score_cp' . $mpv})) {
			my $score = $info->{'score_cp' . $mpv} * 0.01;
			if ($score == 0) {
				return " 0.00";
			}
			if ($invert) {
				$score = -$score;
			}
			return sprintf "%+5.2f", $score;
		}
	}

	return undef;
}

sub score_sort_key {
	my ($info, $pos, $mpv, $invert) = @_;

	$invert //= 0;
	if ($pos->{'toplay'} eq 'B') {
		$invert = !$invert;
	}

	if (defined($info->{'score_mate' . $mpv})) {
		if ($invert) {
			return -(99999 - $info->{'score_mate' . $mpv});
		} else {
			return 99999 - $info->{'score_mate' . $mpv};
		}
	} else {
		if (exists($info->{'score_cp' . $mpv})) {
			my $score = $info->{'score_cp' . $mpv};
			if ($score == 0) {
				return " 0.00";
			}
			if ($invert) {
				$score = -$score;
			}
			return $score;
		}
	}

	return undef;
}

sub long_score {
	my ($info, $pos, $mpv) = @_;

	if (defined($info->{'score_mate' . $mpv})) {
		my $mate = $info->{'score_mate' . $mpv};
		if ($pos->{'toplay'} eq 'B') {
			$mate = -$mate;
		}
		if ($mate > 0) {
			return sprintf "White mates in %u", $mate;
		} else {
			return sprintf "Black mates in %u", -$mate;
		}
	} else {
		if (exists($info->{'score_cp' . $mpv})) {
			my $score = $info->{'score_cp' . $mpv} * 0.01;
			if ($pos->{'toplay'} eq 'B') {
				$score = -$score;
			}
			return sprintf "Score: %+5.2f", $score;
		}
	}

	return undef;
}

my %book_cache = ();
sub book_info {
	my ($fen, $board, $toplay) = @_;

	if (exists($book_cache{$fen})) {
		return $book_cache{$fen};
	}

	my $ret = `./booklook $fen`;
	return "" if ($ret =~ /Not found/ || $ret eq '');

	my @moves = ();

	for my $m (split /\n/, $ret) {
		my ($move, $annotation, $win, $draw, $lose, $rating, $rating_div) = split /,/, $m;

		my $pmove;
		if ($move eq '')  {
			$pmove = '(current)';
		} else {
			($pmove) = prettyprint_pv($board, $move);
			$pmove .= $annotation;
		}

		my $score;
		if ($toplay eq 'W') {
			$score = 1.0 * $win + 0.5 * $draw + 0.0 * $lose;
		} else {
			$score = 0.0 * $win + 0.5 * $draw + 1.0 * $lose;
		}
		my $n = $win + $draw + $lose;
		
		my $percent;
		if ($n == 0) {
			$percent = "     ";
		} else {
			$percent = sprintf "%4u%%", int(100.0 * $score / $n + 0.5);
		}

		push @moves, [ $pmove, $n, $percent, $rating ];
	}

	@moves[1..$#moves] = sort { $b->[2] cmp $a->[2] } @moves[1..$#moves];
	
	my $text = "Book moves:\n\n              Perf.     N     Rating\n\n";
	for my $m (@moves) {
		$text .= sprintf "  %-10s %s   %6u    %4s\n", $m->[0], $m->[2], $m->[1], $m->[3]
	}

	return $text;
}

sub open_engine {
	my ($cmdline, $tag) = @_;
	my ($uciread, $uciwrite);
	my $pid = IPC::Open2::open2($uciread, $uciwrite, $cmdline);

	my $engine = {
		pid => $pid,
		read => $uciread,
		readbuf => '',
		write => $uciwrite,
		info => {},
		ids => {},
		tag => $tag,
	};

	uciprint($engine, "uci");

	# gobble the options
	while (<$uciread>) {
		/uciok/ && last;
		handle_uci($engine, $_);
	}
	
	return $engine;
}

sub read_lines {
	my $engine = shift;

	# 
	# Read until we've got a full line -- if the engine sends part of
	# a line and then stops we're pretty much hosed, but that should
	# never happen.
	#
	while ($engine->{'readbuf'} !~ /\n/) {
		my $tmp;
		my $ret = sysread $engine->{'read'}, $tmp, 4096;

		if (!defined($ret)) {
			next if ($!{EINTR});
			die "error in reading from the UCI engine: $!";
		} elsif ($ret == 0) {
			die "EOF from UCI engine";
		}

		$engine->{'readbuf'} .= $tmp;
	}

	# Blah.
	my @lines = ();
	while ($engine->{'readbuf'} =~ s/^([^\n]*)\n//) {
		my $line = $1;
		$line =~ tr/\r\n//d;
		push @lines, $line;
	}
	return @lines;
}

# Find all possible legal moves.
sub calculate_refutation_moves {
	my $pos = shift;
	my $board = $pos->{'board'};
	my %refutation_moves = ();
	for my $col (0..7) {
		for my $row (0..7) {
			my $piece = substr($board->[$row], $col, 1);

			# Check that there's a piece of the right color on this square.
			next if ($piece eq '-');
			if ($pos->{'toplay'} eq 'W') {
				next if ($piece ne uc($piece));
			} else {
				next if ($piece ne lc($piece));
			}

			for my $to_col (0..7) {
				for my $to_row (0..7) {
					next if ($col == $to_col && $row == $to_row);
					next unless (can_reach($board, $piece, $row, $col, $to_row, $to_col));

					my $promo = "";  # FIXME
					my $nb = make_move($board, $row, $col, $to_row, $to_col, $promo);
					my $check = in_check($nb);
					next if ($check eq 'both');
					if ($pos->{'toplay'} eq 'W') {
						next if ($check eq 'white');
					} else {
						next if ($check eq 'black');
					}
					my $move = move_to_uci_notation($row, $col, $to_row, $to_col, $promo);
					$refutation_moves{$move} = { depth => $second_engine_start_depth - 1, score_cp => 0, pv => '' };
				}
			}
		}
	}
	return %refutation_moves;
}

sub give_new_move_to_second_engine {
	my $pos = shift;
				
	# Find the move that's been analyzed the shortest but is most promising.
	# Tie-break on UCI move representation.
	my $best_move = undef;
	for my $move (sort keys %refutation_moves) {
		if (!defined($best_move)) {
			$best_move = $move;
			next;
		}
		my $best = $refutation_moves{$best_move};
		my $this = $refutation_moves{$move};

		if ($this->{'depth'} < $best->{'depth'} ||
		    ($this->{'depth'} == $best->{'depth'} && $this->{'score_cp'} < $best->{'score_cp'})) {
			$best_move = $move;
			next;
		}
	}

	my $m = $refutation_moves{$best_move};
	++$m->{'depth'};
	uciprint($engine2, "position fen " . $pos->{'fen'} . " moves " . $best_move);
	uciprint($engine2, "go depth " . $m->{'depth'});
	$move_calculating_second_engine = $best_move;
}

sub col_letter_to_num {
	return ord(shift) - ord('a');
}

sub row_letter_to_num {
	return 7 - (ord(shift) - ord('1'));
}

sub move_to_uci_notation {
	my ($from_row, $from_col, $to_row, $to_col, $promo) = @_;
	$promo //= "";
	return sprintf("%c%d%c%d%s", ord('a') + $from_col, 8 - $from_row, ord('a') + $to_col, 8 - $to_row, $promo);
}
