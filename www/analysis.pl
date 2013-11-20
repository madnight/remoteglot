#! /usr/bin/perl
use CGI;
use Linux::Inotify2;
use AnyEvent;
use IPC::ShareLite;
use Storable;
use strict;
use warnings;

our $json_filename = "/srv/analysis.sesse.net/www/analysis.json";

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

my $unique = $cgi->param('unique');
our $num_viewers = count_viewers($unique);

# Yes, this is reinventing If-Modified-Since, but browsers are so incredibly
# unpredictable on this, so blargh.
my $ims = 0;
if (defined($cgi->param('ims')) && $cgi->param('ims') ne '') {
	$ims = $cgi->param('ims');
}
my $time = (stat($json_filename))[9];

# If we have something that's modified since IMS, send it out at once
if ($time > $ims) {
	output();
	exit;
}

# If not, wait, then send.
$cv->recv;
output();

sub count_viewers {
	my $unique = shift;
	my $time = time;
	my $share = IPC::ShareLite->new(
		-key => 'RGLT',
		-create  => 'yes',
		-destroy => 'no',
		-size => 1048576,
	) or die "IPC::ShareLite: $!";
        $share->lock(IPC::ShareLite::LOCK_EX);
	my $viewers = {};
	eval {
        	$viewers = Storable::thaw($share->fetch());
	};
	$viewers->{$unique} = time;

	# Go through and remove old viewers, and count them at the same time.
	my $num_viewers = 0;
	while (my ($key, $value) = each %$viewers) {
		if ($time - $value > 60) {
			delete $viewers->{$key};
		} else {
			++$num_viewers;
		}
	}

        $share->store(Storable::freeze($viewers));
        $share->unlock();

	return $num_viewers;
}

sub output {
	open my $fh, "<", $json_filename
		or die "$json_filename: $!";
	my $data;
	{
		local $/ = undef;
		$data = <$fh>;
	}
	my $time = (stat($fh))[9];
	close $fh;

	print CGI->header(-type=>'text/json',
			  -x_remoteglot_last_modified=>$time,
			  -x_remoteglot_num_viewers=>$num_viewers,
	                  -access_control_allow_origin=>'http://analysis.sesse.net',
	                  -access_control_expose_headers=>'X-Remoteglot-Last-Modified, X-Remoteglot-Num-Viewers',
	                  -expires=>'now');
	print $data;
}
