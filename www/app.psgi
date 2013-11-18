#! /usr/bin/perl -T

use strict;
use warnings;
use lib qw(./include);

# These need to come before the Billig modules, so that exit is properly redirected.
use CGI::PSGI;
use CGI::Emulate::PSGI;
use CGI::Compile;

use Plack::Request;

# Older versions of File::pushd (used by CGI::Compile) have a performance trap
# that's hard to pin down. Warn about it.
use File::pushd;
if ($File::pushd::VERSION < 1.005) {
	print STDERR "WARNING: You are using a version of File::pushd older than 1.005. This will work, but it has performance implications.\n";
	print STDERR "Do not run in production!\n\n";
}

my $cgi = CGI::Compile->compile('/srv/analysis.sesse.net/analysis.pl');
my $handler = CGI::Emulate::PSGI->handler($cgi);

sub {
	my $env = shift;
	return &$handler($env);
}
