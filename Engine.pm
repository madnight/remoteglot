#! /usr/bin/perl
use strict;
use warnings;

package Engine;

sub open {
	my ($class, $cmdline, $tag) = @_;

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

	return bless $engine;
}

sub print {
	my ($engine, $msg) = @_;
	print { $engine->{'write'} } "$msg\n";
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



1;
