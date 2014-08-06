#! /usr/bin/perl
use strict;
use warnings;
use IPC::Open2;

package Engine;

sub open {
	my ($class, $cmdline, $tag, $cb) = @_;

	my ($uciread, $uciwrite);
	my $pid = IPC::Open2::open2($uciread, $uciwrite, $cmdline);

	my $ev = AnyEvent::Handle->new(
		fh => $uciread,
		on_error => sub {
			my ($handle, $fatal, $msg) = @_;
			die "Error in reading from the UCI engine: $msg";
		}
	);
	my $engine = {
		pid => $pid,
		read => $uciread,
		readbuf => '',
		write => $uciwrite,
		info => {},
		ids => {},
		tag => $tag,
		ev => $ev,
		cb => $cb,
		seen_uciok => 0,
	};

	print $uciwrite "uci\n";
	$ev->push_read(line => sub { $engine->_anyevent_handle_line(@_) });
	return bless $engine;
}

sub print {
	my ($engine, $msg) = @_;
	print { $engine->{'write'} } "$msg\n";
}

sub _anyevent_handle_line {
	my ($engine, $handle, $line) = @_;

	if (!$engine->{'seen_uciok'}) {
		# Gobble up lines until we see uciok.
		if ($line =~ /^uciok$/) {
			$engine->{'seen_uciok'} = 1;
		}
	} else {
		$engine->{'cb'}($engine, $line);
	}
	$engine->{'ev'}->push_read(line => sub { $engine->_anyevent_handle_line(@_) });
}

1;
