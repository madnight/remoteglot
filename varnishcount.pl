#! /usr/bin/perl
use AnyEvent;
use AnyEvent::Handle;
use EV;
use LWP::Simple;
require 'config.pm';
use strict;
use warnings;
no warnings qw(once);

my $url = $ARGV[0] // "/analysis.pl";  # Technically an URL regex, not an URL.
my $port = $ARGV[1] // 5000;

open my $fh, "-|", "varnishncsa -F '%{%s}t %U %q tffb=%{Varnish:time_firstbyte}x' -q 'ReqURL ~ \"^$url\"'"
	or die "varnishncsa: $!";
my %uniques = ();

my $ev = AnyEvent::Handle->new(
	fh => $fh,
	on_read => sub {
		my ($hdl) = @_;
		$hdl->push_read(
			line => sub {
				my ($hdl, $line, $eof) = @_;
				handle_line($line);
			}
		);
	},
);
my $ev2 = AnyEvent->timer(
	interval => 1.0,
	cb => \&output
);
EV::run;

sub handle_line {
	my $line = shift;
	$line =~ m#(\d+) $url \?ims=\d+&unique=(.*) tffb=(.*)# or return;
	$uniques{$2} = {
		last_seen => $1 + $3,
		grace => undef,
	};
	my $now = time;
	print "[$now] $1 $2 $3\n";
}

sub output {
	my $mtime = (stat($remoteglotconf::json_output))[9] - 1;  # Compensate for subsecond issues.
	my $now = time;

	while (my ($unique, $hash) = each %uniques) {
		my $last_seen = $hash->{'last_seen'};
		if ($now - $last_seen <= 5) {
			# We've seen this user in the last five seconds;
			# it's okay.
			next;
		}
		if ($last_seen >= $mtime) {
			# This user has the latest version;
			# they are probably just hanging.
			next;
		}
		if (!defined($hash->{'grace'})) {
			# They have five seconds after a new JSON has been
			# provided to get get it, or they're out.
			# We don't simply use $mtime, since we don't want to
			# reset the grace timer just because a new JSON is
			# published.
			$hash->{'grace'} = $mtime;
		}
		if ($now - $hash->{'grace'} > 5) {
			printf "Timing out %s (last_seen=%d, now=%d, mtime=%d, grace=%d)\n",
				$unique, $last_seen, $now, $mtime, $hash->{'grace'};
			delete $uniques{$unique};
		}
	}

	my $num_viewers = scalar keys %uniques;	
	printf "%d entries in hash, mtime=$mtime\n", scalar keys %uniques;
	LWP::Simple::get('http://127.0.0.1:' . $port . '/override-num-viewers?num=' . $num_viewers);	
}
