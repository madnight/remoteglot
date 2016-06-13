#! /usr/bin/perl

#
# remoteglot - Connects an abitrary UCI-speaking engine to ICS for easier post-game
#              analysis, or for live analysis of relayed games. (Do not use for
#              cheating! Cheating is bad for your karma, and your abuser flag.)
#
# Copyright 2007 Steinar H. Gunderson <steinar+remoteglot@gunderson.no>
# Licensed under the GNU General Public License, version 2.
#

use AnyEvent;
use AnyEvent::Handle;
use AnyEvent::HTTP;
use Chess::PGN::Parse;
use EV;
use Net::Telnet;
use File::Slurp;
use IPC::Open2;
use Time::HiRes;
use JSON::XS;
use URI::Escape;
use DBI;
use DBD::Pg;
require 'Position.pm';
require 'Engine.pm';
require 'config.pm';
use strict;
use warnings;
no warnings qw(once);

# Program starts here
my $latest_update = undef;
my $output_timer = undef;
my $http_timer = undef;
my $stop_pgn_fetch = 0;
my $tb_retry_timer = undef;
my %tb_cache = ();
my $tb_lookup_running = 0;
my $last_written_json = undef;

# Persisted so we can restart.
# TODO: Figure out an appropriate way to deal with database restarts
# and/or Postgres going away entirely.
my $dbh = DBI->connect($remoteglotconf::dbistr, $remoteglotconf::dbiuser, $remoteglotconf::dbipass)
	or die DBI->errstr;
$dbh->{RaiseError} = 1;

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

open(TBLOG, ">tblog.txt")
	or die "tblog.txt: $!";
print TBLOG "Log starting.\n";
select(TBLOG);
$| = 1;

select(STDOUT);
umask 0022;

# open the chess engine
my $engine = open_engine($remoteglotconf::engine_cmdline, 'E1', sub { handle_uci(@_, 1); });
my $engine2 = open_engine($remoteglotconf::engine2_cmdline, 'E2', sub { handle_uci(@_, 0); });
my $last_move;
my $last_text = '';
my ($pos_waiting, $pos_calculating, $pos_calculating_second_engine);

uciprint($engine, "setoption name UCI_AnalyseMode value true");
while (my ($key, $value) = each %remoteglotconf::engine_config) {
	uciprint($engine, "setoption name $key value $value");
}
uciprint($engine, "ucinewgame");

if (defined($engine2)) {
	uciprint($engine2, "setoption name UCI_AnalyseMode value true");
	while (my ($key, $value) = each %remoteglotconf::engine2_config) {
		uciprint($engine2, "setoption name $key value $value");
	}
	uciprint($engine2, "setoption name MultiPV value 500");
	uciprint($engine2, "ucinewgame");
}

print "Chess engine ready.\n";

# now talk to FICS
my $t = Net::Telnet->new(Timeout => 10, Prompt => '/fics% /');
$t->input_log(\*FICSLOG);
$t->open($remoteglotconf::server);
$t->print($remoteglotconf::nick);
$t->waitfor('/Press return to enter the server/');
$t->cmd("");

# set some options
$t->cmd("set shout 0");
$t->cmd("set seek 0");
$t->cmd("set style 12");

my $ev1 = AnyEvent->io(
	fh => fileno($t),
	poll => 'r',
	cb => sub {    # what callback to execute
		while (1) {
			my $line = $t->getline(Timeout => 0, errmode => 'return');
			return if (!defined($line));

			chomp $line;
			$line =~ tr/\r//d;
			handle_fics($line);
		}
	}
);
if (defined($remoteglotconf::target)) {
	if ($remoteglotconf::target =~ /^http:/) {
		fetch_pgn($remoteglotconf::target);
	} else {
		$t->cmd("observe $remoteglotconf::target");
	}
}
print "FICS ready.\n";

# Engine events have already been set up by Engine.pm.
EV::run;

sub handle_uci {
	my ($engine, $line, $primary) = @_;

	return if $line =~ /(upper|lower)bound/;

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
			return if (!$remoteglotconf::uci_assume_full_compliance);
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
	output();
}

my $getting_movelist = 0;
my $pos_for_movelist = undef;
my @uci_movelist = ();
my @pretty_movelist = ();

sub handle_fics {
	my $line = shift;
	if ($line =~ /^<12> /) {
		handle_position(Position->new($line));
		$t->cmd("moves");
	}
	if ($line =~ /^Movelist for game /) {
		my $pos = $pos_waiting // $pos_calculating;
		if (defined($pos)) {
			@uci_movelist = ();
			@pretty_movelist = ();
			$pos_for_movelist = Position->start_pos($pos->{'player_w'}, $pos->{'player_b'});
			$getting_movelist = 1;
		}
	}
	if ($getting_movelist &&
	    $line =~ /^\s* \d+\. \s+                     # move number
                       (\S+) \s+ \( [\d:.]+ \) \s*       # first move, then time
	               (?: (\S+) \s+ \( [\d:.]+ \) )?    # second move, then time 
	             /x) {
		eval {
			my $uci_move;
			($pos_for_movelist, $uci_move) = $pos_for_movelist->make_pretty_move($1);
			push @uci_movelist, $uci_move;
			push @pretty_movelist, $1;

			if (defined($2)) {
				($pos_for_movelist, $uci_move) = $pos_for_movelist->make_pretty_move($2);
				push @uci_movelist, $uci_move;
				push @pretty_movelist, $2;
			}
		};
		if ($@) {
			warn "Error when getting FICS move history: $@";
			$getting_movelist = 0;
		}
	}
	if ($getting_movelist &&
	    $line =~ /^\s+ \{.*\} \s+ (?: \* | 1\/2-1\/2 | 0-1 | 1-0 )/x) {
		# End of movelist.
		for my $pos ($pos_waiting, $pos_calculating) {
			next if (!defined($pos));
			if ($pos->fen() eq $pos_for_movelist->fen()) {
				$pos->{'history'} = \@pretty_movelist;
			}
		}
		$getting_movelist = 0;
	}
	if ($line =~ /^([A-Za-z]+)(?:\([A-Z]+\))* tells you: (.*)$/) {
		my ($who, $msg) = ($1, $2);

		next if (grep { $_ eq $who } (@remoteglotconf::masters) == 0);

		if ($msg =~ /^fics (.*?)$/) {
			$t->cmd("tell $who Executing '$1' on FICS.");
			$t->cmd($1);
		} elsif ($msg =~ /^uci (.*?)$/) {
			$t->cmd("tell $who Sending '$1' to the engine.");
			print { $engine->{'write'} } "$1\n";
		} elsif ($msg =~ /^pgn (.*?)$/) {
			my $url = $1;
			$t->cmd("tell $who Starting to poll '$url'.");
			fetch_pgn($url);
		} elsif ($msg =~ /^stoppgn$/) {
			$t->cmd("tell $who Stopping poll.");
			$stop_pgn_fetch = 1;
			$http_timer = undef;
		} elsif ($msg =~ /^quit$/) {
			$t->cmd("tell $who Bye bye.");
			exit;
		} else {
			$t->cmd("tell $who Couldn't understand '$msg', sorry.");
		}
	}
	#print "FICS: [$line]\n";
}

# Starts periodic fetching of PGNs from the given URL.
sub fetch_pgn {
	my ($url) = @_;
	AnyEvent::HTTP::http_get($url, sub {
		handle_pgn(@_, $url);
	});
}

my ($last_pgn_white, $last_pgn_black);
my @last_pgn_uci_moves = ();
my $pgn_hysteresis_counter = 0;

sub handle_pgn {
	my ($body, $header, $url) = @_;

	if ($stop_pgn_fetch) {
		$stop_pgn_fetch = 0;
		$http_timer = undef;
		return;
	}

	my $pgn = Chess::PGN::Parse->new(undef, $body);
	if (!defined($pgn)) {
		warn "Error in parsing PGN from $url [body='$body']\n";
	} elsif (!$pgn->read_game()) {
		warn "Error in reading PGN game from $url [body='$body']\n";
	} elsif ($body !~ /^\[/) {
		warn "Malformed PGN from $url [body='$body']\n";
	} else {
		eval {
			# Skip to the right game.
			while (defined($remoteglotconf::pgn_filter) &&
			       !&$remoteglotconf::pgn_filter($pgn)) {
				$pgn->read_game() or die "Out of games during filtering";
			}

			$pgn->parse_game({ save_comments => 'yes' });
			my $white = $pgn->white;
			my $black = $pgn->black;
			$white =~ s/,.*//;  # Remove first name.
			$black =~ s/,.*//;  # Remove first name.
			my $pos = Position->start_pos($white, $black);
			my $moves = $pgn->moves;
			my @uci_moves = ();
			my @repretty_moves = ();
			for my $move (@$moves) {
				my ($npos, $uci_move) = $pos->make_pretty_move($move);
				push @uci_moves, $uci_move;

				# Re-prettyprint the move.
				my ($from_row, $from_col, $to_row, $to_col, $promo) = parse_uci_move($uci_move);
				my ($pretty, undef) = $pos->{'board'}->prettyprint_move($from_row, $from_col, $to_row, $to_col, $promo);
				push @repretty_moves, $pretty;
				$pos = $npos;
			}
			if ($pgn->result eq '1-0' || $pgn->result eq '1/2-1/2' || $pgn->result eq '0-1') {
				$pos->{'result'} = $pgn->result;
			}
			$pos->{'history'} = \@repretty_moves;

			extract_clock($pgn, $pos);

			# Sometimes, PGNs lose a move or two for a short while,
			# or people push out new ones non-atomically. 
			# Thus, if we PGN doesn't change names but becomes
			# shorter, we mistrust it for a few seconds.
			my $trust_pgn = 1;
			if (defined($last_pgn_white) && defined($last_pgn_black) &&
			    $last_pgn_white eq $pgn->white &&
			    $last_pgn_black eq $pgn->black &&
			    scalar(@uci_moves) < scalar(@last_pgn_uci_moves)) {
				if (++$pgn_hysteresis_counter < 3) {
					$trust_pgn = 0;	
				}
			}
			if ($trust_pgn) {
				$last_pgn_white = $pgn->white;
				$last_pgn_black = $pgn->black;
				@last_pgn_uci_moves = @uci_moves;
				$pgn_hysteresis_counter = 0;
				handle_position($pos);
			}
		};
		if ($@) {
			warn "Error in parsing moves from $url: $@\n";
		}
	}
	
	$http_timer = AnyEvent->timer(after => 1.0, cb => sub {
		fetch_pgn($url);
	});
}

sub handle_position {
	my ($pos) = @_;
	find_clock_start($pos, $pos_calculating);
		
	# if this is already in the queue, ignore it (just update the result)
	if (defined($pos_waiting) && $pos->fen() eq $pos_waiting->fen()) {
		$pos_waiting->{'result'} = $pos->{'result'};
		return;
	}

	# if we're already chewing on this and there's nothing else in the queue,
	# also ignore it
	if (!defined($pos_waiting) && defined($pos_calculating) &&
	    $pos->fen() eq $pos_calculating->fen()) {
		$pos_calculating->{'result'} = $pos->{'result'};
		return;
	}

	# if we're already thinking on something, stop and wait for the engine
	# to approve
	if (defined($pos_calculating)) {
		# Store the final data we have for this position in the history,
		# with the precise clock information we just got from the new
		# position. (Historic positions store the clock at the end of
		# the position.)
		#
		# Do not output anything new to the main analysis; that's
		# going to be obsolete really soon.
		$pos_calculating->{'white_clock'} = $pos->{'white_clock'};
		$pos_calculating->{'black_clock'} = $pos->{'black_clock'};
		delete $pos_calculating->{'white_clock_target'};
		delete $pos_calculating->{'black_clock_target'};
		output_json(1);

		if (!defined($pos_waiting)) {
			uciprint($engine, "stop");
		}
		if ($remoteglotconf::uci_assume_full_compliance) {
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

	schedule_tb_lookup();

	# 
	# Output a command every move to note that we're
	# still paying attention -- this is a good tradeoff,
	# since if no move has happened in the last half
	# hour, the analysis/relay has most likely stopped
	# and we should stop hogging server resources.
	#
	$t->cmd("date");
}

sub parse_infos {
	my ($engine, @x) = @_;
	my $mpv = '';

	my $info = $engine->{'info'};

	# Search for "multipv" first of all, since e.g. Stockfish doesn't put it first.
	for my $i (0..$#x - 1) {
		if ($x[$i] eq 'multipv') {
			$mpv = $x[$i + 1];
			next;
		}
	}

	while (scalar @x > 0) {
		if ($x[0] eq 'multipv') {
			# Dealt with above
			shift @x;
			shift @x;
			next;
		}
		if ($x[0] eq 'currmove' || $x[0] eq 'currmovenumber' || $x[0] eq 'cpuload') {
			my $key = shift @x;
			my $value = shift @x;
			$info->{$key} = $value;
			next;
		}
		if ($x[0] eq 'depth' || $x[0] eq 'seldepth' || $x[0] eq 'hashfull' ||
		    $x[0] eq 'time' || $x[0] eq 'nodes' || $x[0] eq 'nps' ||
		    $x[0] eq 'tbhits') {
			my $key = shift @x;
			my $value = shift @x;
			$info->{$key . $mpv} = $value;
			next;
		}
		if ($x[0] eq 'score') {
			shift @x;

			delete $info->{'score_cp' . $mpv};
			delete $info->{'score_mate' . $mpv};

			while ($x[0] eq 'cp' || $x[0] eq 'mate') {
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
		if ($x[0] eq 'name') {
			my $value = join(' ', @x);
			$engine->{'id'}{'author'} = $value;
			last;
		}

		# unknown
		shift @x;
	}
}

sub prettyprint_pv_no_cache {
	my ($board, @pvs) = @_;

	if (scalar @pvs == 0 || !defined($pvs[0])) {
		return ();
	}

	my $pv = shift @pvs;
	my ($from_row, $from_col, $to_row, $to_col, $promo) = parse_uci_move($pv);
	my ($pretty, $nb) = $board->prettyprint_move($from_row, $from_col, $to_row, $to_col, $promo);
	return ( $pretty, prettyprint_pv_no_cache($nb, @pvs) );
}

sub prettyprint_pv {
	my ($pos, @pvs) = @_;

	my $cachekey = join('', @pvs);
	if (exists($pos->{'prettyprint_cache'}{$cachekey})) {
		return @{$pos->{'prettyprint_cache'}{$cachekey}};
	} else {
		my @res = prettyprint_pv_no_cache($pos->{'board'}, @pvs);
		$pos->{'prettyprint_cache'}{$cachekey} = \@res;
		return @res;
	}
}

my %tbprobe_cache = ();

sub complete_using_tbprobe {
	my ($pos, $info, $mpv) = @_;

	# We need Fathom installed to do standalone TB probes.
	return if (!defined($remoteglotconf::fathom_cmdline));

	# If we already have a mate, don't bother; in some cases, it would even be
	# better than a tablebase score.
	return if defined($info->{'score_mate' . $mpv});

	# If we have a draw or near-draw score, there's also not much interesting
	# we could add from a tablebase. We only really want mates.
	return if ($info->{'score_cp' . $mpv} >= -12250 && $info->{'score_cp' . $mpv} <= 12250);

	# Run through the PV until we are at a 6-man position.
	# TODO: We could in theory only have 5-man data.
	my @pv = @{$info->{'pv' . $mpv}};
	my $key = $pos->fen() . " " . join('', @pv);
	my @moves = ();
	if (exists($tbprobe_cache{$key})) {
		@moves = @{$tbprobe_cache{$key}};
	} else {
		if ($mpv ne '') {
			# Force doing at least one move of the PV.
			my $move = shift @pv;
			push @moves, $move;
			$pos = $pos->make_move(parse_uci_move($move));
		}

		while ($pos->num_pieces() > 6 && $#pv > -1) {
			my $move = shift @pv;
			push @moves, $move;
			$pos = $pos->make_move(parse_uci_move($move));
		}

		return if ($pos->num_pieces() > 6);

		my $fen = $pos->fen();
		my $pgn_text = `fathom --path=/srv/syzygy "$fen"`;
		my $pgn = Chess::PGN::Parse->new(undef, $pgn_text);
		return if (!defined($pgn) || !$pgn->read_game() || ($pgn->result ne '0-1' && $pgn->result ne '1-0'));
		$pgn->quick_parse_game;
		$info->{'pv' . $mpv} = \@moves;

		# Splice the PV from the tablebase onto what we have so far.
		for my $move (@{$pgn->moves}) {
			my $uci_move;
			($pos, $uci_move) = $pos->make_pretty_move($move);
			push @moves, $uci_move;
		}

		$tbprobe_cache{$key} = \@moves;
	}

	$info->{'pv' . $mpv} = \@moves;

	my $matelen = int((1 + scalar @moves) / 2);
	if ((scalar @moves) % 2 == 0) {
		$info->{'score_mate' . $mpv} = -$matelen;
	} else {
		$info->{'score_mate' . $mpv} = $matelen;
	}
}

sub output {
	#return;

	return if (!defined($pos_calculating));

	# Don't update too often.
	my $age = Time::HiRes::tv_interval($latest_update);
	if ($age < $remoteglotconf::update_max_interval) {
		my $wait = $remoteglotconf::update_max_interval + 0.01 - $age;
		$output_timer = AnyEvent->timer(after => $wait, cb => \&output);
		return;
	}
	
	my $info = $engine->{'info'};

	#
	# If we have tablebase data from a previous lookup, replace the
	# engine data with the data from the tablebase.
	#
	my $fen = $pos_calculating->fen();
	if (exists($tb_cache{$fen})) {
		for my $key (qw(pv score_cp score_mate nodes nps depth seldepth tbhits)) {
			delete $info->{$key . '1'};
			delete $info->{$key};
		}
		$info->{'nodes'} = 0;
		$info->{'nps'} = 0;
		$info->{'depth'} = 0;
		$info->{'seldepth'} = 0;
		$info->{'tbhits'} = 0;

		my $t = $tb_cache{$fen};
		my $pv = $t->{'pv'};
		my $matelen = int((1 + $t->{'score'}) / 2);
		if ($t->{'result'} eq '1/2-1/2') {
			$info->{'score_cp'} = 0;
		} elsif ($t->{'result'} eq '1-0') {
			if ($pos_calculating->{'toplay'} eq 'B') {
				$info->{'score_mate'} = -$matelen;
			} else {
				$info->{'score_mate'} = $matelen;
			}
		} else {
			if ($pos_calculating->{'toplay'} eq 'B') {
				$info->{'score_mate'} = $matelen;
			} else {
				$info->{'score_mate'} = -$matelen;
			}
		}
		$info->{'pv'} = $pv;
		$info->{'tablebase'} = 1;
	} else {
		$info->{'tablebase'} = 0;
	}
	
	#
	# Some programs _always_ report MultiPV, even with only one PV.
	# In this case, we simply use that data as if MultiPV was never
	# specified.
	#
	if (exists($info->{'pv1'}) && !exists($info->{'pv2'})) {
		for my $key (qw(pv score_cp score_mate nodes nps depth seldepth tbhits)) {
			if (exists($info->{$key . '1'})) {
				$info->{$key} = $info->{$key . '1'};
			} else {
				delete $info->{$key};
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
			$dummy = prettyprint_pv($pos_calculating, @{$info->{'pv'}});
		}
	
		my $mpv = 1;
		while (exists($info->{'pv' . $mpv})) {
			$dummy = prettyprint_pv($pos_calculating, @{$info->{'pv' . $mpv}});
			++$mpv;
		}
	};
	if ($@) {
		$engine->{'info'} = {};
		return;
	}

	# Now do our own Syzygy tablebase probes to convert scores like +123.45 to mate.
	if (exists($info->{'pv'})) {
		complete_using_tbprobe($pos_calculating, $info, '');
	}

	my $mpv = 1;
	while (exists($info->{'pv' . $mpv})) {
		complete_using_tbprobe($pos_calculating, $info, $mpv);
		++$mpv;
	}

	output_screen();
	output_json(0);
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
			$text .= "  " . join(', ', prettyprint_pv($pos_calculating, @{$info->{'pv' . $mpv}})) . "\n";
			$text .= "\n";
			++$mpv;
		}
	} else {
		# single-PV
		my $score = long_score($info, $pos_calculating, '');
		$text .= "  $score\n" if defined($score);
		$text .=  "  PV: " . join(', ', prettyprint_pv($pos_calculating, @{$info->{'pv'}}));
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
				complete_using_tbprobe($pos_calculating_second_engine, $info, $mpv);
				my $pv = $info->{'pv' . $mpv};
				my $pretty_move = join('', prettyprint_pv($pos_calculating_second_engine, $pv->[0]));
				my @pretty_pv = prettyprint_pv($pos_calculating_second_engine, @$pv);
				if (scalar @pretty_pv > 5) {
					@pretty_pv = @pretty_pv[0..4];
					push @pretty_pv, "...";
				}
				my $key = $pretty_move;
				my $line = sprintf("  %-6s %6s %3s  %s",
					$pretty_move,
					short_score($info, $pos_calculating_second_engine, $mpv),
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
	my $historic_json_only = shift;
	my $info = $engine->{'info'};

	my $json = {};
	$json->{'position'} = $pos_calculating->to_json_hash();
	$json->{'engine'} = $engine->{'id'};
	if (defined($remoteglotconf::engine_url)) {
		$json->{'engine'}{'url'} = $remoteglotconf::engine_url;
	}
	if (defined($remoteglotconf::engine_details)) {
		$json->{'engine'}{'details'} = $remoteglotconf::engine_details;
	}
	if (defined($remoteglotconf::move_source)) {
		$json->{'move_source'} = $remoteglotconf::move_source;
	}
	if (defined($remoteglotconf::move_source_url)) {
		$json->{'move_source_url'} = $remoteglotconf::move_source_url;
	}
	$json->{'score'} = score_digest($info, $pos_calculating, '');
	$json->{'using_lomonosov'} = defined($remoteglotconf::tb_serial_key);

	$json->{'nodes'} = $info->{'nodes'};
	$json->{'nps'} = $info->{'nps'};
	$json->{'depth'} = $info->{'depth'};
	$json->{'tbhits'} = $info->{'tbhits'};
	$json->{'seldepth'} = $info->{'seldepth'};
	$json->{'tablebase'} = $info->{'tablebase'};
	$json->{'pv'} = [ prettyprint_pv($pos_calculating, @{$info->{'pv'}}) ];

	my %refutation_lines = ();
	my @refutation_lines = ();
	if (defined($engine2)) {
		for (my $mpv = 1; $mpv < 500; ++$mpv) {
			my $info = $engine2->{'info'};
			my $pretty_move = "";
			my @pretty_pv = ();
			last if (!exists($info->{'pv' . $mpv}));

			eval {
				complete_using_tbprobe($pos_calculating, $info, $mpv);
				my $pv = $info->{'pv' . $mpv};
				my $pretty_move = join('', prettyprint_pv($pos_calculating, $pv->[0]));
				my @pretty_pv = prettyprint_pv($pos_calculating, @$pv);
				$refutation_lines{$pretty_move} = {
					depth => $info->{'depth' . $mpv},
					score => score_digest($info, $pos_calculating, $mpv),
					move => $pretty_move,
					pv => \@pretty_pv,
				};
			};
		}
	}
	$json->{'refutation_lines'} = \%refutation_lines;

	# Piece together historic score information, to the degree we have it.
	if (!$historic_json_only && exists($pos_calculating->{'history'})) {
		my %score_history = ();

		my $q = $dbh->prepare('SELECT * FROM scores WHERE id=?');
		my $pos = Position->start_pos('white', 'black');
		my $halfmove_num = 0;
		for my $move (@{$pos_calculating->{'history'}}) {
			my $id = id_for_pos($pos, $halfmove_num);
			my $ref = $dbh->selectrow_hashref($q, undef, $id);
			if (defined($ref)) {
				$score_history{$halfmove_num} = [
					$ref->{'score_type'},
					$ref->{'score_value'}
				];
			}
			++$halfmove_num;
			($pos) = $pos->make_pretty_move($move);
		}
		$q->finish;

		# If at any point we are missing 10 consecutive moves,
		# truncate the history there. This is so we don't get into
		# a situation where we e.g. start analyzing at move 45,
		# but we have analysis for 1. e4 from some completely different game
		# and thus show a huge hole.
		my $consecutive_missing = 0;
		my $truncate_until = 0;
		for (my $i = $halfmove_num; $i --> 0; ) {
			if ($consecutive_missing >= 10) {
				delete $score_history{$i};
				next;
			}
			if (exists($score_history{$i})) {
				$consecutive_missing = 0;
			} else {
				++$consecutive_missing;
			}
		}

		$json->{'score_history'} = \%score_history;
	}

	# Give out a list of other games going on. (Empty is fine.)
	# TODO: Don't bother reading our own file, the data will be stale anyway.
	if (!$historic_json_only) {
		my @games = ();

		my $q = $dbh->prepare('SELECT * FROM current_games ORDER BY priority DESC, id');
		$q->execute;
		while (my $ref = $q->fetchrow_hashref) {
			eval {
				my $other_game_contents = File::Slurp::read_file($ref->{'json_path'});
				my $other_game_json = JSON::XS::decode_json($other_game_contents);

				die "Missing position" if (!exists($other_game_json->{'position'}));
				my $white = $other_game_json->{'position'}{'player_w'} // die 'Missing white';
				my $black = $other_game_json->{'position'}{'player_b'} // die 'Missing black';

				my $game = {
					id => $ref->{'id'},
					name => "$white–$black",
					url => $ref->{'url'},
					hashurl => $ref->{'hash_url'},
				};
				if (defined($other_game_json->{'position'}{'result'})) {
					$game->{'result'} = $other_game_json->{'position'}{'result'};
				} else {
					$game->{'score'} = $other_game_json->{'score'};
				}
				push @games, $game;
			};
			if ($@) {
				warn "Could not add external game " . $ref->{'json_path'} . ": $@";
			}
		}

		if (scalar @games > 0) {
			$json->{'games'} = \@games;
		}
	}

	my $json_enc = JSON::XS->new;
	$json_enc->canonical(1);
	my $encoded = $json_enc->encode($json);
	unless ($historic_json_only || !defined($remoteglotconf::json_output) ||
	        (defined($last_written_json) && $last_written_json eq $encoded)) {
		atomic_set_contents($remoteglotconf::json_output, $encoded);
		$last_written_json = $encoded;
	}

	if (exists($pos_calculating->{'history'}) &&
	    defined($remoteglotconf::json_history_dir)) {
		my $id = id_for_pos($pos_calculating);
		my $filename = $remoteglotconf::json_history_dir . "/" . $id . ".json";

		# Overwrite old analysis (assuming it exists at all) if we're
		# using a different engine, or if we've calculated deeper.
		# nodes is used as a tiebreaker. Don't bother about Multi-PV
		# data; it's not that important.
		my ($old_engine, $old_depth, $old_nodes) = get_json_analysis_stats($id);
		my $new_depth = $json->{'depth'} // 0;
		my $new_nodes = $json->{'nodes'} // 0;
		if (!defined($old_engine) ||
		    $old_engine ne $json->{'engine'}{'name'} ||
		    $new_depth > $old_depth ||
		    ($new_depth == $old_depth && $new_nodes >= $old_nodes)) {
			atomic_set_contents($filename, $encoded);
			if (defined($json->{'score'})) {
				$dbh->do('INSERT INTO scores (id, score_type, score_value, engine, depth, nodes) VALUES (?,?,?,?,?,?) ' .
				         '    ON CONFLICT (id) DO UPDATE SET ' .
				         '        score_type=EXCLUDED.score_type, ' .
					 '        score_value=EXCLUDED.score_value, ' .
					 '        engine=EXCLUDED.engine, ' .
					 '        depth=EXCLUDED.depth, ' .
					 '        nodes=EXCLUDED.nodes',
					undef,
					$id, $json->{'score'}[0], $json->{'score'}[1],
					$json->{'engine'}{'name'}, $new_depth, $new_nodes);
			}
		}
	}
}

sub atomic_set_contents {
	my ($filename, $contents) = @_;

	open my $fh, ">", $filename . ".tmp"
		or return;
	print $fh $contents;
	close $fh;
	rename($filename . ".tmp", $filename);
}

sub id_for_pos {
	my ($pos, $halfmove_num) = @_;

	$halfmove_num //= scalar @{$pos->{'history'}};
	(my $fen = $pos->fen()) =~ tr,/ ,-_,;
	return "move$halfmove_num-$fen";
}

sub get_json_analysis_stats {
	my $id = shift;
	my $ref = $dbh->selectrow_hashref('SELECT * FROM scores WHERE id=?', undef, $id);
	if (defined($ref)) {
		return ($ref->{'engine'}, $ref->{'depth'}, $ref->{'nodes'});
	} else {
		return ('', 0, 0);
	}
}

sub uciprint {
	my ($engine, $msg) = @_;
	$engine->print($msg);
	print UCILOG localtime() . " $engine->{'tag'} => $msg\n";
}

sub short_score {
	my ($info, $pos, $mpv) = @_;

	my $invert = ($pos->{'toplay'} eq 'B');
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
				if ($info->{'tablebase'}) {
					return "TB draw";
				} else {
					return " 0.00";
				}
			}
			if ($invert) {
				$score = -$score;
			}
			return sprintf "%+5.2f", $score;
		}
	}

	return undef;
}

# Sufficient for computing long_score, short_score, plot_score and
# (with side-to-play information) score_sort_key.
sub score_digest {
	my ($info, $pos, $mpv) = @_;

	if (defined($info->{'score_mate' . $mpv})) {
		my $mate = $info->{'score_mate' . $mpv};
		if ($pos->{'toplay'} eq 'B') {
			$mate = -$mate;
		}
		return ['m', $mate];
	} else {
		if (exists($info->{'score_cp' . $mpv})) {
			my $score = $info->{'score_cp' . $mpv};
			if ($pos->{'toplay'} eq 'B') {
				$score = -$score;
			}
			if ($score == 0 && $info->{'tablebase'}) {
				return ['d', undef];
			} else {
				return ['cp', int($score)];
			}
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
				if ($info->{'tablebase'}) {
					return "Theoretical draw";
				} else {
					return "Score:  0.00";
				}
			}
			if ($pos->{'toplay'} eq 'B') {
				$score = -$score;
			}
			return sprintf "Score: %+5.2f", $score;
		}
	}

	return undef;
}

# For graphs; a single number in centipawns, capped at +/- 500.
sub plot_score {
	my ($info, $pos, $mpv) = @_;

	my $invert = ($pos->{'toplay'} eq 'B');
	if (defined($info->{'score_mate' . $mpv})) {
		my $mate = $info->{'score_mate' . $mpv};
		if ($invert) {
			$mate = -$mate;
		}
		if ($mate > 0) {
			return 500;
		} else {
			return -500;
		}
	} else {
		if (exists($info->{'score_cp' . $mpv})) {
			my $score = $info->{'score_cp' . $mpv};
			if ($invert) {
				$score = -$score;
			}
			$score = 500 if ($score > 500);
			$score = -500 if ($score < -500);
			return int($score);
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
			($pmove) = prettyprint_pv_no_cache($board, $move);
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

sub extract_clock {
	my ($pgn, $pos) = @_;

	# Look for extended PGN clock tags.
	my $tags = $pgn->tags;
	if (exists($tags->{'WhiteClock'}) && exists($tags->{'BlackClock'})) {
		$pos->{'white_clock'} = hms_to_sec($tags->{'WhiteClock'});
		$pos->{'black_clock'} = hms_to_sec($tags->{'BlackClock'});
		return;
	}

	# Look for TCEC-style time comments.
	my $moves = $pgn->moves;
	my $comments = $pgn->comments;
	my $last_black_move = int((scalar @$moves) / 2);
	my $last_white_move = int((1 + scalar @$moves) / 2);

	my $black_key = $last_black_move . "b";
	my $white_key = $last_white_move . "w";

	if (exists($comments->{$white_key}) &&
	    exists($comments->{$black_key}) &&
	    $comments->{$white_key} =~ /(?:tl=|clk )(\d+:\d+:\d+)/ &&
	    $comments->{$black_key} =~ /(?:tl=|clk )(\d+:\d+:\d+)/) {
		$comments->{$white_key} =~ /(?:tl=|clk )(\d+:\d+:\d+)/;
		$pos->{'white_clock'} = hms_to_sec($1);
		$comments->{$black_key} =~ /(?:tl=|clk )(\d+:\d+:\d+)/;
		$pos->{'black_clock'} = hms_to_sec($1);
		return;
	}

	delete $pos->{'white_clock'};
	delete $pos->{'black_clock'};
}

sub hms_to_sec {
	my $hms = shift;
	return undef if (!defined($hms));
	$hms =~ /(\d+):(\d+):(\d+)/;
	return $1 * 3600 + $2 * 60 + $3;
}

sub find_clock_start {
	my ($pos, $prev_pos) = @_;

	# If the game is over, the clock is stopped.
	if (exists($pos->{'result'}) &&
	    ($pos->{'result'} eq '1-0' ||
	     $pos->{'result'} eq '1/2-1/2' ||
	     $pos->{'result'} eq '0-1')) {
		return;
	}

	# When we don't have any moves, we assume the clock hasn't started yet.
	if ($pos->{'move_num'} == 1 && $pos->{'toplay'} eq 'W') {
		if (defined($remoteglotconf::adjust_clocks_before_move)) {
			&$remoteglotconf::adjust_clocks_before_move(\$pos->{'white_clock'}, \$pos->{'black_clock'}, 1, 'W');
		}
		return;
	}

	# TODO(sesse): Maybe we can get the number of moves somehow else for FICS games.
	# The history is needed for id_for_pos.
	if (!exists($pos->{'history'})) {
		return;
	}

	my $id = id_for_pos($pos);
	my $clock_info = $dbh->selectrow_hashref('SELECT * FROM clock_info WHERE id=?', undef, $id);
	if (defined($clock_info)) {
		$pos->{'white_clock'} //= $clock_info->{'white_clock'};
		$pos->{'black_clock'} //= $clock_info->{'black_clock'};
		if ($pos->{'toplay'} eq 'W') {
			$pos->{'white_clock_target'} = $clock_info->{'white_clock_target'};
		} else {
			$pos->{'black_clock_target'} = $clock_info->{'black_clock_target'};
		}
		return;
	}

	# OK, we haven't seen this position before, so we assume the move
	# happened right now.

	# See if we should do our own clock management (ie., clock information
	# is spurious or non-existent).
	if (defined($remoteglotconf::adjust_clocks_before_move)) {
		my $wc = $pos->{'white_clock'} // $prev_pos->{'white_clock'};
		my $bc = $pos->{'black_clock'} // $prev_pos->{'black_clock'};
		if (defined($prev_pos->{'white_clock_target'})) {
			$wc = $prev_pos->{'white_clock_target'} - time;
		}
		if (defined($prev_pos->{'black_clock_target'})) {
			$bc = $prev_pos->{'black_clock_target'} - time;
		}
		&$remoteglotconf::adjust_clocks_before_move(\$wc, \$bc, $pos->{'move_num'}, $pos->{'toplay'});
		$pos->{'white_clock'} = $wc;
		$pos->{'black_clock'} = $bc;
	}

	my $key = ($pos->{'toplay'} eq 'W') ? 'white_clock' : 'black_clock';
	if (!exists($pos->{$key})) {
		# No clock information.
		return;
	}
	my $time_left = $pos->{$key};
	my ($white_clock_target, $black_clock_target);
	if ($pos->{'toplay'} eq 'W') {
		$white_clock_target = $pos->{'white_clock_target'} = time + $time_left;
	} else {
		$black_clock_target = $pos->{'black_clock_target'} = time + $time_left;
	}
	local $dbh->{AutoCommit} = 0;
	$dbh->do('DELETE FROM clock_info WHERE id=?', undef, $id);
	$dbh->do('INSERT INTO clock_info (id, white_clock, black_clock, white_clock_target, black_clock_target) VALUES (?, ?, ?, ?, ?)', undef,
		$id, $pos->{'white_clock'}, $pos->{'black_clock'}, $white_clock_target, $black_clock_target);
	$dbh->commit;
}

sub schedule_tb_lookup {
	return if (!defined($remoteglotconf::tb_serial_key));
	my $pos = $pos_waiting // $pos_calculating;
	return if (exists($tb_cache{$pos->fen()}));

	# If there's more than seven pieces, there's not going to be an answer,
	# so don't bother.
	return if ($pos->num_pieces() > 7);

	# Max one at a time. If it's still relevant when it returns,
	# schedule_tb_lookup() will be called again.
	return if ($tb_lookup_running);

	$tb_lookup_running = 1;
	my $url = 'http://158.250.18.203:6904/tasks/addtask?auth.login=' .
		$remoteglotconf::tb_serial_key .
		'&auth.password=aquarium&type=0&fen=' . 
		URI::Escape::uri_escape($pos->fen());
	print TBLOG "Downloading $url...\n";
	AnyEvent::HTTP::http_get($url, sub {
		handle_tb_lookup_return(@_, $pos, $pos->fen());
	});
}

sub handle_tb_lookup_return {
	my ($body, $header, $pos, $fen) = @_;
	print TBLOG "Response for [$fen]:\n";
	print TBLOG $header . "\n\n";
	print TBLOG $body . "\n\n";
	eval {
		my $response = JSON::XS::decode_json($body);
		if ($response->{'ErrorCode'} != 0) {
			die "Unknown tablebase server error: " . $response->{'ErrorDesc'};
		}
		my $state = $response->{'Response'}{'StateString'};
		if ($state eq 'COMPLETE') {
			my $pgn = Chess::PGN::Parse->new(undef, $response->{'Response'}{'Moves'});
			if (!defined($pgn) || !$pgn->read_game()) {
				warn "Error in parsing PGN\n";
			} else {
				$pgn->quick_parse_game;
				my $pvpos = $pos;
				my $moves = $pgn->moves;
				my @uci_moves = ();
				for my $move (@$moves) {
					my $uci_move;
					($pvpos, $uci_move) = $pvpos->make_pretty_move($move);
					push @uci_moves, $uci_move;
				}
				$tb_cache{$fen} = {
					result => $pgn->result,
					pv => \@uci_moves,
					score => $response->{'Response'}{'Score'},
				};
				output();
			}
		} elsif ($state =~ /QUEUED/ || $state =~ /PROCESSING/) {
			# Try again in a second. Note that if we have changed
			# position in the meantime, we might query a completely
			# different position! But that's fine.
		} else {
			die "Unknown response state " . $state;
		}

		# Wait a second before we schedule another one.
		$tb_retry_timer = AnyEvent->timer(after => 1.0, cb => sub {
			$tb_lookup_running = 0;
			schedule_tb_lookup();
		});
	};
	if ($@) {
		warn "Error in tablebase lookup: $@";

		# Don't try this one again, but don't block new lookups either.
		$tb_lookup_running = 0;
	}
}

sub open_engine {
	my ($cmdline, $tag, $cb) = @_;
	return undef if (!defined($cmdline));
	return Engine->open($cmdline, $tag, $cb);
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
	return ($from_row, $from_col, $to_row, $to_col, $promo);
}
