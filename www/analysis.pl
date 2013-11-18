#! /usr/bin/perl
use CGI;
use POSIX;
use Date::Manip;
use Linux::Inotify2;
use AnyEvent;
use strict;
use warnings;

my $json_filename = "/srv/analysis.sesse.net/www/analysis.json";

my $cv = AnyEvent->condvar;
my $updated = 0;
my $cgi = CGI->new;
my $inotify = Linux::Inotify2->new;
$inotify->watch($json_filename, IN_MODIFY, sub {
	$updated = 1;
	$cv->send;
});
        
my $inotify_w = AnyEvent->io (
	fh => $inotify->fileno, poll => 'r', cb => sub { $inotify->poll }
);
my $wait = AnyEvent->timer (
	after => 30,
	cb    => sub { $cv->send; },
);

my $ims = 0;
if (exists($ENV{'HTTP_IF_MODIFIED_SINCE'})) {
	my $date = Date::Manip::Date->new;
	$date->parse($ENV{'HTTP_IF_MODIFIED_SINCE'});
	$ims = $date->printf("%s");
}
my $time = (stat($json_filename))[9];

# If we have something that's modified since IMS, send it out at once
if ($time > $ims) {
	output();
	exit;
}

# If not, wait, then send. Apache will deal with the 304-ing.
if (defined($cgi->param('first')) && $cgi->param('first') != 1) {
	$cv->recv;
}
output();

sub output {
	my $time = (stat($json_filename))[9];
	my $lm_str = POSIX::strftime("%a, %d %b %Y %H:%M:%S %z", localtime($time));

	print CGI->header(-type=>'text/json',
			  -last_modified=>$lm_str,
	                  -access_control_allow_origin=>'http://analysis.sesse.net',
	                  -expires=>'now');
	open my $fh, "<", $json_filename
		or die "$json_filename: $!";
	my $data;
	{
		local $/ = undef;
		$data = <$fh>;
	}
	print $data;
}
