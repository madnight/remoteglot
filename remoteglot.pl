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
require 'Position.pm';
require 'Engine.pm';
use strict;
use warnings;

# Configuration
my $server = "freechess.org";
my $target = "GMCarlsen";
my $engine_cmdline = "'./Deep Rybka 4 SSE42 x64'";
my $engine2_cmdline = "./stockfish_13111119_x64_modern_sse42";  # undef for none
my $uci_assume_full_compliance = 0;                    # dangerous :-)
my $update_max_interval = 1.0;
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
my $last_move;
my $last_text = '';
my ($pos_waiting, $pos_calculating, $pos_calculating_second_engine);

uciprint($engine, "setoption name UCI_AnalyseMode value true");
# uciprint($engine, "setoption name NalimovPath value /srv/tablebase");
uciprint($engine, "setoption name NalimovUsage value Rarely");
uciprint($engine, "setoption name Hash value 1024");
# uciprint($engine, "setoption name MultiPV value 2");
uciprint($engine, "ucinewgame");

if (defined($engine2)) {
	uciprint($engine2, "setoption name UCI_AnalyseMode value true");
	# uciprint($engine2, "setoption name NalimovPath value /srv/tablebase");
	uciprint($engine2, "setoption name NalimovUsage value Rarely");
	uciprint($engine2, "setoption name Hash value 1024");
	uciprint($engine2, "setoption name Threads value 8");
	uciprint($engine2, "setoption name MultiPV value 500");
	uciprint($engine2, "ucinewgame");
}

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
	if (defined($engine2)) {
		vec($rin, fileno($engine2->{'read'}), 1) = 1;
	}
	vec($rin, fileno($t), 1) = 1;

	my ($nfound, $timeleft) = select($rout=$rin, undef, undef, 5.0);
	my $sleep = 1.0;

	while (1) {
		my $line = $t->getline(Timeout => 0, errmode => 'return');
		last if (!defined($line));

		chomp $line;
		$line =~ tr/\r//d;
		if ($line =~ /^<12> /) {
			my $pos = Position->new($line);
			
			# if this is already in the queue, ignore it
			next if (defined($pos_waiting) && $pos->fen() eq $pos_waiting->fen());

			# if we're already chewing on this and there's nothing else in the queue,
			# also ignore it
			next if (!defined($pos_waiting) && defined($pos_calculating) &&
			         $pos->fen() eq $pos_calculating->fen());

			# if we're already thinking on something, stop and wait for the engine
			# to approve
			if (defined($pos_calculating)) {
				if (!defined($pos_waiting)) {
					uciprint($engine, "stop");
				}
				if ($uci_assume_full_compliance) {
					$pos_waiting = $pos;
				} else {
					uciprint($engine, "position fen " . $pos->fen());
					uciprint($engine, "go infinite");
					$pos_calculating = $pos;
				}
			} else {
				# it's wrong just to give the FEN (the move history is useful,
				# and per the UCI spec, we should really have sent "ucinewgame"),
				# but it's easier
				uciprint($engine, "position fen " . $pos->fen());
				uciprint($engine, "go infinite");
				$pos_calculating = $pos;
			}

			if (defined($engine2)) {
				if (defined($pos_calculating_second_engine)) {
					uciprint($engine2, "stop");
				} else {
					uciprint($engine2, "position fen " . $pos->fen());
					uciprint($engine2, "go infinite");
					$pos_calculating_second_engine = $pos;
				}
				$engine2->{'info'} = {};
			}

			$engine->{'info'} = {};
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
		my @lines = $engine->read_lines();
		for my $line (@lines) {
			next if $line =~ /(upper|lower)bound/;
			handle_uci($engine, $line, 1);
		}
		$sleep = 0;

		output();
	}
	if (defined($engine2) && $nfound > 0 && vec($rout, fileno($engine2->{'read'}), 1) == 1) {
		my @lines = $engine2->read_lines();
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
				uciprint($engine, "position fen " . $pos_waiting->fen());
				uciprint($engine, "go infinite");

				$pos_calculating = $pos_waiting;
				$pos_waiting = undef;
			}
		} else {
			$engine2->{'info'} = {};
			my $pos = $pos_waiting // $pos_calculating;
			uciprint($engine2, "position fen " . $pos->fen());
			uciprint($engine2, "go infinite");
			$pos_calculating_second_engine = $pos;
		}
	}
}

sub parse_infos {
	my ($engine, @x) = @_;
	my $mpv = '';

	my $info = $engine->{'info'};

	# Search for "multipv" first of all, since e.g. Stockfish doesn't put it first.
	for my $i (0..$#x - 1) {
		if ($x[$i] =~ 'multipv') {
			$mpv = $x[$i + 1];
			next;
		}
	}

	while (scalar @x > 0) {
		if ($x[0] =~ 'multipv') {
			# Dealt with above
			shift @x;
			shift @x;
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

sub prettyprint_pv {
	my ($board, @pvs) = @_;

	if (scalar @pvs == 0 || !defined($pvs[0])) {
		return ();
	}

	my $pv = shift @pvs;
	my ($from_col, $from_row, $to_col, $to_row, $promo) = parse_uci_move($pv);
	my ($pretty, $nb) = $board->prettyprint_move($from_row, $from_col, $to_row, $to_col, $promo);
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
				$text .= ", one Syzygy hit";
			} else {
				$text .= sprintf ", %u Syzygy hits", $info->{'tbhits'};
			}
		}
		$text .= "\n\n";
	}

	#$text .= book_info($pos_calculating->fen(), $pos_calculating->{'board'}, $pos_calculating->{'toplay'});

	my @refutation_lines = ();
	if (defined($engine2)) {
		for (my $mpv = 1; $mpv < 500; ++$mpv) {
			my $info = $engine2->{'info'};
			last if (!exists($info->{'pv' . $mpv}));
			eval {
				my $pv = $info->{'pv' . $mpv};

				my $pretty_move = join('', prettyprint_pv($pos_calculating_second_engine->{'board'}, $pv->[0]));
				my @pretty_pv = prettyprint_pv($pos_calculating_second_engine->{'board'}, @$pv);
				if (scalar @pretty_pv > 5) {
					@pretty_pv = @pretty_pv[0..4];
					push @pretty_pv, "...";
				}
				my $key = $pretty_move;
				my $line = sprintf("  %-6s %6s %3s  %s",
					$pretty_move,
					short_score($info, $pos_calculating_second_engine, $mpv, 0),
					"d" . $info->{'depth' . $mpv},
					join(', ', @pretty_pv));
				push @refutation_lines, [ $key, $line ];
			};
		}
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
}

sub output_json {
	my $info = $engine->{'info'};

	my $json = {};
	$json->{'position'} = $pos_calculating->to_json_hash();
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
	my @refutation_lines = ();
	if (defined($engine2)) {
		for (my $mpv = 1; $mpv < 500; ++$mpv) {
			my $info = $engine2->{'info'};
			my $pretty_move = "";
			my @pretty_pv = ();
			last if (!exists($info->{'pv' . $mpv}));

			eval {
				my $pv = $info->{'pv' . $mpv};
				my $pretty_move = join('', prettyprint_pv($pos_calculating->{'board'}, $pv->[0]));
				my @pretty_pv = prettyprint_pv($pos_calculating->{'board'}, @$pv);
				$refutation_lines{$pv->[0]} = {
					sort_key => $pretty_move,
					depth => $info->{'depth' . $mpv},
					score_sort_key => score_sort_key($info, $pos_calculating, $mpv, 0),
					pretty_score => short_score($info, $pos_calculating, $mpv, 0),
					pretty_move => $pretty_move,
					pv_pretty => \@pretty_pv,
				};
				$refutation_lines{$pv->[0]}->{'pv_uci'} = $pv;
			};
		}
	}
	$json->{'refutation_lines'} = \%refutation_lines;

	open my $fh, ">/srv/analysis.sesse.net/www/analysis.json.tmp"
		or return;
	print $fh JSON::XS::encode_json($json);
	close $fh;
	rename("/srv/analysis.sesse.net/www/analysis.json.tmp", "/srv/analysis.sesse.net/www/analysis.json");
}

sub uciprint {
	my ($engine, $msg) = @_;
	$engine->print($msg);
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

	if (defined($info->{'score_mate' . $mpv})) {
		if ($invert) {
			return 99999 - $info->{'score_mate' . $mpv};
		} else {
			return -(99999 - $info->{'score_mate' . $mpv});
		}
	} else {
		if (exists($info->{'score_cp' . $mpv})) {
			my $score = $info->{'score_cp' . $mpv};
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
			if ($score == 0) {
				return "Score:  0.00";
			}
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
	return undef if (!defined($cmdline));
	my $engine = Engine->open($cmdline, $tag);

	uciprint($engine, "uci");

	# gobble the options
	my $seen_uciok = 0;
	while (!$seen_uciok) {
		for my $line ($engine->read_lines()) {
			if ($line =~ /uciok/) {
				$seen_uciok = 1;
			}
			handle_uci($engine, $line);
		}
	}
	
	return $engine;
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
